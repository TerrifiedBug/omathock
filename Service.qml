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

  readonly property string manifestId: manifest && manifest.id ? manifest.id : "io.github.terrifiedbug.omathock"

  readonly property string pluginDir: Model.dirFromUrl(Qt.resolvedUrl("."))
  readonly property string bundledRoot: pluginDir + "/soundpacks"
  readonly property string userRoot: (Quickshell.env("XDG_DATA_HOME") || Quickshell.env("HOME") + "/.local/share") + "/omathock/soundpacks"

  // Services are not handed their inline settings, so shell.json is read
  // directly and stays the single source of truth: a write goes out through
  // updateEntryInline and comes back through this watched FileView.
  readonly property var settings: Model.findEntry(shellConfig.text(), manifestId)
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
  readonly property var files: Model.packFiles(sounds)

  // hl.on only exists when Hyprland runs the Lua config. usingLua starts false
  // and flips when the version query answers a beat after construction, so a
  // false here is not yet a verdict — the Connections below retry on change.
  readonly property bool luaReady: Hyprland.usingLua === true
  readonly property bool hookWanted: soundEnabled && luaReady

  function play(name, up) {
    var file = Model.soundFor(sounds, name, up, Math.random())
    if (!file) return
    var effect = pool.objectAt(files.indexOf(file))
    if (effect) effect.play()
  }

  // Rebuild the whole inline entry, the way first-party panels do, and let the
  // value come back through the FileView rather than applying it locally.
  function persist(values) {
    var entry = { id: manifestId }
    for (var existing in settings) if (existing !== "id") entry[existing] = settings[existing]
    for (var key in values) entry[key] = values[key]
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

  onHookWantedChanged: syncHook()

  // Unload (disable, remove, hot reload) must take the hook with it, and the
  // component is already going away, so this cannot be a tracked Process.
  Component.onDestruction: if (luaReady) Quickshell.execDetached(["hyprctl", "repl", Model.LUA_UNREGISTER])

  FileView {
    id: shellConfig
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
  }

  // Only the selected pack is parsed; switching packs re-points this view.
  FileView {
    id: packConfig
    path: root.pack ? root.pack.dir + "/config.json" : ""
    watchChanges: true
    printErrors: false

    onLoaded: {
      try {
        root.sounds = JSON.parse(text()).sounds || ({})
      } catch (e) {
        root.sounds = ({})
        console.warn("omathock: unreadable soundpack config:", path)
      }
    }

    onPathChanged: if (path === "") root.sounds = ({})
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
      if (key) root.play(key.name, key.up)
    }
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
