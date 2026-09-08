import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// The whole plugin, minus its UI: one Lua hook, one soundpack, one audio pool.
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

  // The SoundEffect pool's model. packConfig re-reads on every watcher event,
  // and a fresh array of identical names would make Instantiator throw away a
  // dozen loaded WAVs and decode them again, so the assignment is skipped
  // when the names match (Model.sameList). Packs that share file names, which
  // all the bundled ones do, then switch by re-pointing source instead.
  property var files: []

  // Services are not handed their inline settings, so this is the plugin's
  // own entry read out of shell.json. It is applied locally on a write as
  // well: the shell replaces shell.json atomically, and the rename moves the
  // file out from under the watch, so the reload cannot be relied on to bring
  // the value back. FileView.text() is a call rather than a property and
  // cannot be bound to either, hence a plain property fed by onLoaded.
  property var settings: ({})

  // Sounds while the session is locked would put the password's keycodes on
  // Hyprland's socket2 and fire a burst of play() calls straight through the
  // audio-graph rebuild that follows a resume, so the hook comes off for the
  // duration.
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

  // Unlocking is the dangerous moment, not the lock itself: the resume that
  // preceded it rebuilds the audio graph, and the crash this guards against
  // landed 1.3 s after a successful unlock, with WirePlumber still relinking
  // 4 s later. So the hook stays off a little past the unlock rather than
  // re-arming into the rebuild.
  property bool unlockSettling: false

  // Which keys are held and which releases are still waiting to count; the
  // rules live in Model.pressKey / releaseKey / dueReleases.
  property var keys: Model.keyState()
  property bool releasePending: false

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
  readonly property bool hookWanted: soundEnabled && luaReady && lockKnown && !locked && !unlockSettling

  function play(name, up) {
    if (!lockKnown || locked || unlockSettling) return
    var file = Model.soundFor(sounds, name, up, Math.random())
    if (!file) return
    var effect = pool.objectAt(files.indexOf(file))
    if (effect) effect.play()
  }

  // Called after every soundpack read: a watcher firing on an unchanged file
  // must not churn the pool.
  function refreshFiles() {
    var next = Model.packFiles(sounds)
    if (!Model.sameList(files, next)) files = next
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
    for (var i = 0; i < packs.length; i++) if (packs[i].slug === slug) { persist({ soundpack: slug }); return }
  }

  function setVolume(percent) {
    persist({ volume: Model.normalizeVolume(percent) })
  }

  function refreshPacks() {
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
  // enable edge, before this handler runs, and arm from it.
  onSoundEnabledChanged: lockKnown = false

  // Set on the way in, cleared only by the timer on the way out. Assigning it
  // here on unlock would be too late: hookWanted binds to `locked` too, and
  // nothing orders that binding's re-evaluation after this handler, so the
  // hook could re-arm for an instant in exactly the window being avoided.
  onLockedChanged: {
    if (locked) {
      unlockSettling = true
      unlockSettle.stop()
    } else {
      unlockSettle.restart()
    }
  }

  // Unload (disable, remove, hot reload) must take the hook with it, and the
  // component is already going away, so this cannot be a tracked Process.
  Component.onDestruction: if (luaReady) Quickshell.execDetached(["hyprctl", "repl", Model.LUA_UNREGISTER])

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
      try {
        root.sounds = JSON.parse(text()).sounds || ({})
      } catch (e) {
        root.sounds = ({})
        console.warn("omathock: unreadable soundpack config:", path)
      }
      root.refreshFiles()
    }

    onPathChanged: if (path === "") { root.sounds = ({}); root.refreshFiles() }
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

  // One preloaded SoundEffect per WAV of the current pack (a few dozen, well
  // under a megabyte): playing a key is then an index lookup, no file I/O on
  // the keystroke path.
  Instantiator {
    id: pool
    model: root.files

    delegate: SoundEffect {
      required property var modelData

      source: root.pack ? Util.fileUrl(root.pack.dir + "/" + modelData) : ""
      volume: root.volume / 100
    }
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

  // Started when the session unlocks; while it runs the hook stays off.
  Timer {
    id: unlockSettle
    interval: 4000

    onTriggered: root.unlockSettling = false
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
        packs: root.packs.map(function(p) { return p.slug })
      })
    }

    function toggle(): string {
      root.setEnabled(!root.soundEnabled)
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
  }
}
