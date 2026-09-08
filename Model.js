// Pure helpers for OmaThock. Qt-free so node can test them
// (test/model.test.js); Service.qml owns the hook, the audio and the settings.
//
// Key names are thock's, not Linux's: the soundpacks are thock/mechvibes packs
// keyed by macOS-flavoured names ("optionLeft", "capsLock", "arrUp"), so the
// evdev code coming off Hyprland's Lua bus is translated into that vocabulary
// rather than the packs being rewritten.

var DEFAULTS = { enabled: true, soundpack: "drop-holy-panda", volume: 100 }

// Tag prefixing every socket2 custom event this plugin emits.
var EVENT_TAG = "omathock"

// Registration is remove-then-add so a re-run is idempotent without a guard
// global: a subscription orphaned by `hyprctl reload` may refuse :remove(),
// hence the pcall. The callback runs on the compositor thread with a 50 ms
// budget, so it only dispatches an event — never exec, never I/O.
var LUA_REGISTER = "if _G.__omathock then pcall(function() _G.__omathock:remove() end) end _G.__omathock = hl.on(\"input.keyboard.key\", function(code, _, state) hl.dispatch(hl.dsp.event(\"" + EVENT_TAG + ",\" .. code .. \",\" .. state)) end) return \"ok\""

var LUA_UNREGISTER = "if _G.__omathock then pcall(function() _G.__omathock:remove() end) _G.__omathock = nil end return \"ok\""

// evdev code (input-event-codes.h) -> thock key name. Right ctrl deliberately
// reuses ctrlLeft and the keypad reuses the main-row names: no pack ships a
// distinct sound for either, and an unmapped code falls back to "default".
var KEY_NAMES = {
  1: "esc",
  2: "1", 3: "2", 4: "3", 5: "4", 6: "5", 7: "6", 8: "7", 9: "8", 10: "9", 11: "0",
  12: "-", 13: "=", 14: "backspace", 15: "tab",
  16: "q", 17: "w", 18: "e", 19: "r", 20: "t", 21: "y", 22: "u", 23: "i", 24: "o", 25: "p",
  26: "[", 27: "]", 28: "enter", 29: "ctrlLeft",
  30: "a", 31: "s", 32: "d", 33: "f", 34: "g", 35: "h", 36: "j", 37: "k", 38: "l",
  39: ";", 40: "'", 41: "`", 42: "shiftLeft", 43: "\\",
  44: "z", 45: "x", 46: "c", 47: "v", 48: "b", 49: "n", 50: "m",
  51: ",", 52: ".", 53: "/", 54: "shiftRight", 55: "*", 56: "optionLeft", 57: "space", 58: "capsLock",
  59: "f1", 60: "f2", 61: "f3", 62: "f4", 63: "f5", 64: "f6", 65: "f7", 66: "f8", 67: "f9", 68: "f10",
  69: "clear",
  71: "7", 72: "8", 73: "9", 74: "-", 75: "4", 76: "5", 77: "6", 78: "+",
  79: "1", 80: "2", 81: "3", 82: "0", 83: ".",
  87: "f11", 88: "f12",
  96: "enter", 97: "ctrlLeft", 98: "/", 100: "optionRight",
  102: "home", 103: "arrUp", 104: "pgUp", 105: "arrLeft", 106: "arrRight",
  107: "end", 108: "arrDown", 109: "pgDn",
  125: "command", 126: "command"
}

// tplai packs call it "backspace", mechvibes packs call it "del".
var KEY_ALIASES = { backspace: "del" }

// Hyprland reports xkb codes; xkb = evdev + 8.
function keyName(xkbCode) {
  return KEY_NAMES[Number(xkbCode) - 8] || "default"
}

// "omathock,<code>,<state>" -> { name, up }. Anything else is another
// plugin's custom event and must be ignored, not guessed at.
function parseEvent(data) {
  var parts = String(data === undefined || data === null ? "" : data).split(",")
  if (parts.length !== 3 || parts[0] !== EVENT_TAG) return null
  if (!/^\d+$/.test(parts[1]) || (parts[2] !== "0" && parts[2] !== "1")) return null
  return { name: keyName(parts[1]), up: parts[2] === "0" }
}

// Pick one WAV for a key press/release. `r` is a caller-supplied [0,1) so the
// choice stays testable; packs ship several takes per key to avoid machine-gun
// repetition. Falls through key -> alias -> "default", and a direction the
// pack does not record (most have no key-up) yields "" — play nothing.
function soundFor(sounds, name, up, r) {
  var pack = sounds || {}
  var entry = pack[name] || pack[KEY_ALIASES[name]] || pack.default
  var list = entry ? (up ? entry.up : entry.down) : null
  if (!list || list.length === undefined || list.length === 0) {
    var fallback = pack.default
    list = fallback ? (up ? fallback.up : fallback.down) : null
  }
  if (!list || list.length === undefined || list.length === 0) return ""
  return list[Math.floor(r * list.length)]
}

// Every distinct WAV a pack can play, sorted — the model for the SoundEffect
// pool, so each file is decoded once and played from memory.
function packFiles(sounds) {
  var seen = {}
  var out = []
  var keys = Object.keys(sounds || {})
  for (var i = 0; i < keys.length; i++) {
    var entry = sounds[keys[i]]
    if (!entry) continue
    var lists = [entry.down, entry.up]
    for (var l = 0; l < lists.length; l++) {
      var list = lists[l]
      if (!list || list.length === undefined) continue
      for (var j = 0; j < list.length; j++) {
        var file = list[j]
        if (typeof file !== "string" || file === "" || seen[file]) continue
        seen[file] = true
        out.push(file)
      }
    }
  }
  return out.sort()
}

// Directory name is the pack's identity, so it is also its label:
// "gateron-ink-black" -> "Gateron Ink Black", "IBM-buckling-spring" -> "IBM
// Buckling Spring" (only the first character is touched, acronyms survive).
function packLabel(slug) {
  return String(slug).split(/[-_]/).filter(function(word) { return word !== "" }).map(function(word) {
    return word.charAt(0).toUpperCase() + word.slice(1)
  }).join(" ")
}

// `find <bundled> <user> -mindepth 2 -maxdepth 2 -name config.json` output ->
// [{ slug, dir }]. find walks roots in argument order and the user root is
// second, so a same-named user pack overrides the bundled one.
function parsePacks(findOutput) {
  var bySlug = {}
  var lines = String(findOutput || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line.length < 13 || line.slice(-12) !== "/config.json") continue
    var dir = line.slice(0, -12)
    var slug = dir.slice(dir.lastIndexOf("/") + 1)
    if (slug === "") continue
    bySlug[slug] = { slug: slug, dir: dir }
  }
  return Object.keys(bySlug).sort().map(function(slug) { return bySlug[slug] })
}

// Qt.resolvedUrl(".") -> a plain path find and FileView can use.
function dirFromUrl(url) {
  return decodeURIComponent(String(url).replace(/^file:\/\//, "").replace(/\/$/, ""))
}

// The plugin's own entry in shell.json: a bar-layout entry when the widget is
// placed, otherwise a plugins[] entry. Garbage or a missing entry yields {},
// which reads as "all defaults".
function findEntry(configText, id) {
  var config = {}
  try { config = JSON.parse(configText || "") } catch (e) { return {} }
  if (!config) return {}
  var lists = []
  var layout = config.bar && config.bar.layout
  if (layout) lists.push(layout.left, layout.center, layout.right)
  lists.push(config.plugins)
  for (var l = 0; l < lists.length; l++) {
    var list = lists[l]
    if (!list || list.length === undefined) continue
    for (var i = 0; i < list.length; i++) if (list[i] && list[i].id === id) return list[i]
  }
  return {}
}

function setting(entry, name) {
  var value = entry ? entry[name] : undefined
  return value === undefined || value === null ? DEFAULTS[name] : value
}

function normalizeVolume(value) {
  var n = Math.round(Number(value))
  if (!isFinite(n)) return DEFAULTS.volume
  return Math.max(0, Math.min(100, n))
}

if (typeof module !== "undefined") {
  module.exports = {
    DEFAULTS: DEFAULTS,
    EVENT_TAG: EVENT_TAG,
    LUA_REGISTER: LUA_REGISTER,
    LUA_UNREGISTER: LUA_UNREGISTER,
    KEY_NAMES: KEY_NAMES,
    KEY_ALIASES: KEY_ALIASES,
    keyName: keyName,
    parseEvent: parseEvent,
    soundFor: soundFor,
    packFiles: packFiles,
    packLabel: packLabel,
    parsePacks: parsePacks,
    dirFromUrl: dirFromUrl,
    findEntry: findEntry,
    setting: setting,
    normalizeVolume: normalizeVolume
  }
}
