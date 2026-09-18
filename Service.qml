import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "Model.js" as Model

// The whole plugin, minus its UI: one Lua hook, one soundpack, one player.
//
// Every other keyboard-sound tool on Linux reads /dev/input, which means the
// `input` group and a daemon. Hyprland already sees each key, and its Lua
// config is scriptable over IPC, so a single `hyprctl repl` at startup
// registers hl.on("input.keyboard.key") and has it re-broadcast the keycode as
// a socket2 custom event. Quickshell is already listening to socket2, so the
// key arrives here with no privileges, no daemon and no binary. The Lua
// callback runs on the compositor thread with a 50 ms budget, hence a bare
// dispatch there and all the work on this side.
//
// The hook is removed on disable and on destruction, so `omarchy plugin
// disable/remove` really stops it; `hyprctl reload` wipes runtime Lua state,
// so `configreloaded` re-registers.
Item {
  id: root

  property var shell: null
  property var manifest: null

  // A syncHook() that arrives while hyprctl is still running is replayed from
  // onExited instead of racing a second process against the first.
  property bool hookDirty: false
  property bool hooked: false
  property var packs: []
  property var sounds: ({})

  // Audio runs in player.py, a stdlib Python child fed JSON on stdin, not in
  // this process: Qt 6.11's PipeWire backend can wedge the shell after a
  // WirePlumber restart, and a helper that dies is one the shell restarts.
  // Its stdin pipe closes with the shell, which is how it knows to exit.
  property bool playerWanted: false
  property bool playerReady: false
  property bool playerFailed: false
  property int playerAttempts: 0
  property string playerStderr: ""
  property double playerLastTick: 0
  readonly property string playerState: playerFailed ? "failed" : playerReady ? "ready" : "starting"
  readonly property string playerProblem: playerFailed ? "Sound player failed: " + (playerStderr || "see the shell log") : ""

  // Services are not handed their inline settings, so this is the plugin's
  // own entry read out of shell.json. It is applied locally on a write as
  // well: the shell replaces shell.json atomically, and the rename moves the
  // file out from under the watch, so the reload cannot be relied on to bring
  // the value back. FileView.text() is a call rather than a property and
  // cannot be bound to either, hence a plain property fed by onLoaded.
  property var settings: ({})

  // Sounds while the session is locked would put the password's keycodes on
  // Hyprland's socket2, so the hook comes off for the duration.
  //
  // Omarchy 4.0.3 keeps omarchy.lock out of the public service map, so a
  // plugin cannot read the lock service. The state comes instead from
  // omarchy-hyprland-session-locked, the helper the lock service itself uses:
  // it reports an ext-session-lock through Hyprland's solitaryBlockedBy.
  // Polling it costs one short-lived process a second; refreshing Quickshell's
  // Hyprland monitors instead would blank lastIpcObject for every other
  // consumer in the shell, which is not this plugin's to do.
  property bool locked: false

  // False until the helper has actually answered. Anything that leaves the
  // state unknown, the first poll after startup, an undetermined answer, or
  // sounds being switched on again after the poller was stopped, has to hold
  // the hook off: an unknown lock state may be a locked one.
  property bool lockKnown: false

  // Which keys are held and which releases are still waiting to count; the
  // rules live in Model.pressKey / releaseKey / dueReleases.
  property var keys: Model.keyState()
  property bool releasePending: false

  // Armed by setSoundpack; the click fires once the player reports the
  // picked pack loaded.
  property bool sampleOnLoad: false

  readonly property string manifestId: manifest && manifest.id ? manifest.id : "io.github.terrifiedbug.omathock"

  readonly property string pluginDir: Model.dirFromUrl(Qt.resolvedUrl("."))
  readonly property string bundledRoot: pluginDir + "/soundpacks"
  readonly property string userRoot: (Quickshell.env("XDG_DATA_HOME") || Quickshell.env("HOME") + "/.local/share") + "/omathock/soundpacks"

  // Not "enabled": that shadows Item.enabled.
  readonly property bool soundEnabled: Model.setting(settings, "enabled") !== false
  readonly property string soundpack: String(Model.setting(settings, "soundpack"))
  readonly property int volume: Model.normalizeVolume(Model.setting(settings, "volume"))

  // A soundpack named in settings but missing from disk falls back to the
  // first installed pack, so a bad name is audible rather than silent.
  readonly property var pack: {
    for (var i = 0; i < packs.length; i++) if (packs[i].slug === soundpack) return packs[i]
    return packs.length > 0 ? packs[0] : null
  }
  readonly property string packSlug: pack ? pack.slug : ""

  // hl.on only exists when Hyprland runs the Lua config. usingLua starts false
  // and flips when the version query answers a beat after construction, so a
  // false here is not yet a verdict — the Connections below retry on change.
  readonly property bool luaReady: Hyprland.usingLua === true
  readonly property bool hookWanted: soundEnabled && luaReady && lockKnown && !locked

  function send(msg) {
    if (player.running) player.write(JSON.stringify(msg) + "\n")
  }

  function sendLoad() {
    if (root.pack) send({ cmd: "load", dir: root.pack.dir, takes: Model.packTakes(root.sounds), volume: root.volume })
  }

  // The mixer overlaps the same sample freely, so a random take is enough:
  // nothing here needs to avoid a take that is still ringing.
  function play(name, up) {
    if (!lockKnown || locked) return
    var takes = Model.takesFor(sounds, name, up)
    if (takes.length === 0) return
    send({ cmd: "play", take: takes[Math.floor(Math.random() * takes.length)] })
  }

  function onPlayerLine(line) {
    var msg
    try { msg = JSON.parse(String(line)) } catch (e) { return }
    if (!msg || typeof msg !== "object") return
    if (msg.evt === "tick") {
      playerLastTick = Date.now()
    } else if (msg.evt === "ready") {
      playerReady = true
      playerLastTick = Date.now()
      playerStable.restart()
      sendLoad()
      send({ cmd: "volume", value: volume })
    } else if (msg.evt === "loaded") {
      if (sampleOnLoad) { sampleOnLoad = false; play("default", false) }
      if (msg.failed && msg.failed.length > 0) console.warn("omathock: " + msg.failed.length + " takes failed:", msg.failed.join("; "))
    } else if (msg.evt === "error") {
      console.warn("omathock: player:", msg.msg)
    }
  }

  // A retry from the CLI or the panel after "Sound player failed".
  function restartPlayer() {
    playerFailed = false
    playerAttempts = 0
    playerWanted = soundEnabled
  }

  // Rebuild the whole inline entry, the way first-party panels do, and let the
  // value come back through the FileView rather than applying it locally.
  function persist(values) {
    var entry = { id: manifestId }
    for (var existing in settings) if (existing !== "id") entry[existing] = settings[existing]
    for (var key in values) entry[key] = values[key]
    settings = entry
    if (shell && typeof shell.updateEntryInline === "function") shell.updateEntryInline(manifestId, entry)
    else console.warn("omathock: shell has no updateEntryInline, setting not saved")
  }

  function setEnabled(on) {
    persist({ enabled: on === true })
  }

  function setSoundpack(slug) {
    if (slug === soundpack) return
    for (var i = 0; i < packs.length; i++) if (packs[i].slug === slug) { sampleOnLoad = true; persist({ soundpack: slug }); return }
  }

  function setVolume(percent) {
    persist({ volume: Model.normalizeVolume(percent) })
  }

  // Rescan the pack directories; also the retry for the player, since the
  // panel calls this on every open and the CLI through `refresh`.
  function refreshPacks() {
    restartPlayer()
    if (findProc.running) return
    findProc.running = true
  }

  function syncHook() {
    if (!luaReady) return
    if (hookProc.running) { hookDirty = true; return }
    hookProc.command = ["hyprctl", "repl", hookWanted ? Model.LUA_REGISTER : Model.LUA_UNREGISTER]
    hookProc.running = true
  }

  Component.onCompleted: {
    refreshPacks()
    syncHook()
    playerWanted = soundEnabled
  }

  // A key held while the hook goes away never sends its release, so the state
  // is dropped rather than left holding that key down forever.
  onHookWantedChanged: {
    keys = Model.keyState()
    releasePending = false
    syncHook()
  }

  // The poller only runs while sounds are on, so whatever it last saw goes
  // stale the moment they go off. Cleared on the way out as well as the way
  // in: leaving a stale value behind lets hookWanted re-evaluate on the
  // enable edge, before this handler runs, and arm from it. The player
  // follows the toggle too, with its failure count reset for the way back in.
  onSoundEnabledChanged: {
    lockKnown = false
    restartPlayer()
  }

  onVolumeChanged: send({ cmd: "volume", value: volume })

  // Unload (disable, remove, hot reload) must take the hook with it, and the
  // component is already going away, so this cannot be a tracked Process.
  // The player's stdin closes with this object, which is its cue to exit;
  // stopping it here is only the backstop.
  Component.onDestruction: {
    player.running = false
    if (luaReady) Quickshell.execDetached(["hyprctl", "repl", Model.LUA_UNREGISTER])
  }

  // watchChanges reports the change; the re-read is the handler's job.
  FileView {
    id: shellConfig
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false

    onFileChanged: reload()
    onLoaded: root.settings = Model.findEntry(text(), root.manifestId)
  }

  // Only the selected pack is parsed; switching packs re-points this view.
  FileView {
    id: packConfig
    path: root.pack ? root.pack.dir + "/config.json" : ""
    watchChanges: true
    printErrors: false

    onFileChanged: reload()

    onLoaded: {
      var pack = Model.normalizePack(text())
      if (pack.format === "") console.warn("omathock: unreadable soundpack config:", path)
      root.sounds = pack.sounds
      root.sendLoad()
    }

    onPathChanged: if (path === "") { root.sampleOnLoad = false; root.sounds = ({}) }
  }

  // A missing user root makes find exit 1 after listing the bundled root;
  // stderr is deliberately unwired, so "no user packs yet" stays silent.
  Process {
    id: findProc
    command: ["find", root.bundledRoot, root.userRoot, "-mindepth", "2", "-maxdepth", "2", "-name", "config.json"]

    stdout: StdioCollector {
      waitForEnd: true

      onStreamFinished: root.packs = Model.parsePacks(text)
    }
  }

  Process {
    id: hookProc

    stdout: StdioCollector {
      waitForEnd: true

      onStreamFinished: {
        var out = String(text || "").trim()
        root.hooked = root.hookWanted && out === "ok"
        if (out !== "ok") console.warn("omathock: hyprctl repl:", out)
      }
    }

    onExited: if (root.hookDirty) { root.hookDirty = false; root.syncHook() }
  }

  Process {
    id: player
    command: ["python3", "-u", root.pluginDir + "/player.py"]
    running: root.playerWanted
    stdinEnabled: true

    stdout: SplitParser {
      onRead: function(line) { root.onPlayerLine(line) }
    }

    stderr: SplitParser {
      onRead: function(line) { root.playerStderr = String(line).trim() }
    }

    // A fresh start owes a fresh reason: the last run's stderr must not be
    // reported for this one.
    onStarted: {
      root.playerAttempts += 1
      root.playerStderr = ""
    }

    // Five exits inside thirty seconds is a helper that cannot run (no
    // python3, no libpulse, unreadable file): stop and say so rather than
    // spin. A helper that stays up thirty seconds resets the count.
    onExited: function(exitCode) {
      root.playerReady = false
      root.playerWanted = false
      playerStable.stop()
      if (!root.soundEnabled) return
      if (root.playerAttempts >= 5) { root.playerFailed = true; return }
      playerRestart.restart()
    }
  }

  Timer {
    id: playerRestart
    interval: 1500

    onTriggered: root.playerWanted = root.soundEnabled && !root.playerFailed
  }

  Timer {
    id: playerStable
    interval: 30000

    onTriggered: root.playerAttempts = 0
  }

  // The helper ticks every two seconds from its mixer thread; six seconds
  // of silence is a helper stuck in libpulse, which only a kill gets out of.
  Timer {
    id: playerWatchdog
    interval: 3000
    repeat: true
    running: player.running && root.playerReady

    onTriggered: if (Date.now() - root.playerLastTick > 6000) player.signal(9)
  }

  Connections {
    target: Hyprland

    function onUsingLuaChanged() {
      root.syncHook()
    }

    function onRawEvent(event) {
      // A reload rebuilt Hyprland's Lua state; the subscription is gone.
      if (event.name === "configreloaded") {
        root.syncHook()
        return
      }
      if (event.name !== "custom" || !root.soundEnabled) return
      var key = Model.parseEvent(event.data)
      if (!key) return
      if (key.up) {
        if (Model.releaseKey(root.keys, key.code, key.name, Date.now())) root.releasePending = true
      } else if (Model.pressKey(root.keys, key.code)) {
        root.play(key.name, false)
      }
    }
  }

  // Runs only while a release is waiting out the repeat window, and stops as
  // soon as the last one has played.
  Timer {
    id: releaseFlush
    interval: 15
    repeat: true
    running: root.releasePending

    onTriggered: {
      var due = Model.dueReleases(root.keys, Date.now())
      for (var i = 0; i < due.length; i++) root.play(due[i], true)
      root.releasePending = Model.hasPending(root.keys)
    }
  }

  // 0 locked, 1 unlocked, 2 undetermined; an undetermined answer leaves the
  // last known state alone. One process a second only while sounds are on.
  Process {
    id: lockProc
    command: ["omarchy-hyprland-session-locked"]

    onExited: function(exitCode) {
      // 0 locked, 1 unlocked, anything else undetermined, which drops back to
      // not knowing rather than standing on a stale answer. `locked` is
      // assigned before `lockKnown`: the other order lets hookWanted see a
      // known-and-unlocked state for an instant while the answer was locked.
      if (exitCode !== 0 && exitCode !== 1) {
        root.lockKnown = false
        return
      }
      root.locked = exitCode === 0
      root.lockKnown = true
    }
  }

  Timer {
    id: lockPoll
    interval: 1000
    repeat: true
    running: root.soundEnabled
    triggeredOnStart: true

    onTriggered: if (!lockProc.running) lockProc.running = true
  }

  // usingLua only ever flips false -> true, so a legacy hyprland.conf leaves
  // the startup path silent. Say it once rather than letting the user wonder
  // why nothing clicks.
  Timer {
    id: legacyNotice
    interval: 3000
    running: root.soundEnabled

    onTriggered: if (!root.luaReady) console.warn("omathock: Hyprland is not running the Lua config; no key hook available")
  }

  IpcHandler {
    target: "omathock"

    function ping(): string {
      return "ok"
    }

    function status(): string {
      return JSON.stringify({
        enabled: root.soundEnabled,
        soundpack: root.packSlug,
        volume: root.volume,
        hooked: root.hooked,
        lua: root.luaReady,
        locked: root.locked,
        player: root.playerState,
        playerProblem: root.playerProblem,
        packs: root.packs.map(function(p) { return p.slug })
      })
    }

    function toggle(): string {
      root.setEnabled(!root.soundEnabled)
      return "ok"
    }

    function enable(): string {
      root.setEnabled(true)
      return "ok"
    }

    function disable(): string {
      root.setEnabled(false)
      return "ok"
    }

    function soundpack(slug: string): string {
      for (var i = 0; i < root.packs.length; i++) if (root.packs[i].slug === slug) { root.setSoundpack(slug); return "ok" }
      return "unknown"
    }

    function volume(percent: int): string {
      root.setVolume(percent)
      return "ok"
    }

    function refresh(): string {
      root.refreshPacks()
      return "ok"
    }

    function previewVolume(percent: int): string {
      root.setVolume(percent)
      root.play("default", false)
      return "ok"
    }
  }
}
