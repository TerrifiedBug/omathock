// Pure helpers for OmaThock. Qt-free so node can test them
// (test/model.test.js); Service.qml owns the hook, the player and the settings.
//
// Key names are thock's, not Linux's: the soundpacks are thock/mechvibes packs
// keyed by macOS-flavoured names ("optionLeft", "capsLock", "arrUp"), so the
// evdev code coming off Hyprland's Lua bus is translated into that vocabulary
// rather than the packs being rewritten. Mechvibes and MechvibesDX packs are
// normalised into that same shape on load (normalizePack).

var DEFAULTS = { enabled: true, soundpack: "drop-holy-panda", volume: 100 }

// Tag prefixing every socket2 custom event this plugin emits.
var EVENT_TAG = "omathock"

// Registration is remove-then-add so a re-run is idempotent without a guard
// global: a subscription orphaned by `hyprctl reload` may refuse :remove(),
// hence the pcall. The callback runs on the compositor thread with a 50 ms
// budget, so it only re-emits the event — never exec, never I/O. The event
// time travels with the code because parseEvent uses it to tell a real key
// press from injected input.
var LUA_REGISTER = "if _G.__omathock then pcall(function() _G.__omathock:remove() end) end _G.__omathock = hl.on(\"input.keyboard.key\", function(code, time, state) hl.dispatch(hl.dsp.event(\"" + EVENT_TAG + ",\" .. code .. \",\" .. state .. \",\" .. time)) end) return \"ok\""

var LUA_UNREGISTER = "if _G.__omathock then pcall(function() _G.__omathock:remove() end) _G.__omathock = nil end return \"ok\""

// evdev code (input-event-codes.h) -> thock key name. Right ctrl deliberately
// reuses ctrlLeft and the keypad reuses the main-row names: no pack ships a
// distinct sound for either.
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
  // Delete reuses the backspace take: no pack records a forward delete.
  // Insert has no name in any pack and falls through to "default".
  110: "insert", 111: "backspace",
  125: "command", 126: "command"
}

// tplai packs call it "backspace", mechvibes packs call it "del".
var KEY_ALIASES = { backspace: "del" }

// Hyprland reports xkb codes; xkb = evdev + 8. An unmapped code is not a
// typing key: "input.keyboard.key" fires for every keyboard-class device the
// compositor has, and a laptop has many — lid switch, HID hotkeys, power
// button, a Bluetooth headset's AVRCP controls. Those used to fall through to
// the pack's "default" sound, which is how a thock arrives while nobody is
// typing, so they now name no key and play nothing.
function keyName(xkbCode) {
  return KEY_NAMES[Number(xkbCode) - 8] || ""
}

// "omathock,<code>,<state>,<timeMs>" -> { code, name, up }. Anything else is
// another plugin's custom event and must be ignored, not guessed at.
//
// A zero timestamp means the event carries no hardware time, which is what
// injected input looks like: `wtype` and friends drive a Wayland virtual
// keyboard and pass no time base, while a real key press, including one an
// input method re-emits, keeps the original event time. Automation typing
// into a terminal should not click. Tools that inject through uinput do carry
// kernel timestamps and are indistinguishable from a person, so this catches
// the common case rather than every case.
function parseEvent(data) {
  var parts = String(data === undefined || data === null ? "" : data).split(",")
  if (parts.length !== 4 || parts[0] !== EVENT_TAG) return null
  if (!/^\d+$/.test(parts[1]) || (parts[2] !== "0" && parts[2] !== "1") || !/^\d+$/.test(parts[3])) return null
  if (Number(parts[3]) === 0) return null
  var name = keyName(parts[1])
  if (name === "") return null
  return { code: Number(parts[1]), name: name, up: parts[2] === "0" }
}

// How long a release waits before it counts as a release. Key repeat runs at
// input:repeat_rate (40/s on Omarchy, so 25 ms), so a gap this size cannot
// occur inside a repeat stream, while a person lifting a finger and pressing
// the same key again takes far longer.
var UP_DEBOUNCE_MS = 35

function keyState() {
  return { down: {}, pending: {} }
}

// A held key is not one event stream but three, depending on the keyboard:
// nothing at all until release (a plain physical keyboard), a flood of
// releases (wtype), or press/release pairs at the repeat rate (an input
// method re-emitting what it grabbed). On top of that fcitx5 delivers every
// event twice with an identical timestamp. All three have to sound like one
// key press, which is what these three functions are for: a press while the
// key is logically down is silent, and a release only counts once it has gone
// UP_DEBOUNCE_MS without another press — a repeat's next press cancels it, so
// a held key stays one press until the finger really lifts.

// True when the press should click.
function pressKey(state, code) {
  if (state.pending[code] !== undefined) {
    // Mid-repeat: the release that never happened, un-released.
    delete state.pending[code]
    state.down[code] = true
    return false
  }
  if (state.down[code]) return false
  state.down[code] = true
  return true
}

// True when the caller should start waiting to play the key-up sound.
function releaseKey(state, code, name, now) {
  if (!state.down[code]) return false
  delete state.down[code]
  state.pending[code] = { name: name, at: now }
  return true
}

// Key names whose release has now stood long enough to be real.
function dueReleases(state, now) {
  var out = []
  var codes = Object.keys(state.pending)
  for (var i = 0; i < codes.length; i++) {
    var entry = state.pending[codes[i]]
    if (now - entry.at < UP_DEBOUNCE_MS) continue
    out.push(entry.name)
    delete state.pending[codes[i]]
  }
  return out
}

function hasPending(state) {
  return Object.keys(state.pending).length > 0
}

// A take is one playable slice: { file, start, end } with the file relative
// to the pack directory and start/end in milliseconds; end 0 means end of
// file. Its key is the identity the player caches by and packTakes dedupes by.
function takeKey(take) {
  return take.file + "@" + take.start + "-" + take.end
}

// Every take a pack can play for a key press/release, in pack order. Falls
// through key -> alias -> "default"; a direction the pack does not record
// (most have no key-up) yields [] — play nothing. The caller picks the take.
function takesFor(sounds, name, up) {
  var pack = sounds || {}
  var entry = pack[name] || pack[KEY_ALIASES[name]] || pack.default
  var list = entry ? (up ? entry.up : entry.down) : null
  if (!list || list.length === undefined || list.length === 0) {
    var fallback = pack.default
    list = fallback ? (up ? fallback.up : fallback.down) : null
  }
  if (!list || list.length === undefined || list.length === 0) return []
  return list
}

// Every distinct take a pack can play, sorted by key: what the player decodes
// on load, so a keystroke is a lookup and never a file read.
function packTakes(sounds) {
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
        var take = list[j]
        if (!take || typeof take.file !== "string") continue
        var key = takeKey(take)
        if (seen[key]) continue
        seen[key] = true
        out.push(take)
      }
    }
  }
  return out.sort(function(a, b) { var ka = takeKey(a), kb = takeKey(b); return ka < kb ? -1 : ka > kb ? 1 : 0 })
}

// A pack file name is played from the pack directory and nowhere else:
// subdirectories are fine ("release/ENTER.mp3"), anything with ".." in it or
// an absolute path is not.
function safeFile(name) {
  return typeof name === "string" && name !== "" && name.charAt(0) !== "/" && name.indexOf("..") === -1
}

function wholeFile(name) {
  return { file: name, start: 0, end: 0 }
}

// Mechvibes names a family of variants as "GENERIC_R{0-4}.mp3", one file per
// number. Anything else is one whole file; an unsafe or empty name is nothing.
function expandFiles(name) {
  if (!safeFile(name)) return []
  var m = /^(.*)\{(\d+)-(\d+)\}(.*)$/.exec(name)
  if (!m) return [wholeFile(name)]
  var from = Number(m[2]), to = Number(m[3])
  if (to < from) return [wholeFile(name)]
  var out = []
  for (var n = from; n <= to; n++) out.push(wholeFile(m[1] + n + m[4]))
  return out
}

// Mechvibes keycodes come from iohook: a main-row key is its set-1 scancode,
// which is also its evdev code, and an extended (E0-prefixed) key arrives as
// 0xE00, 0xE000 or 0xEE00 OR-ed with the scancode. The low byte is the
// scancode in every variant; this is its evdev code.
var MECHVIBES_EXTENDED = {
  0x1C: 96, 0x1D: 97, 0x35: 98, 0x38: 100, 0x45: 69,
  0x47: 102, 0x48: 103, 0x49: 104, 0x4B: 105, 0x4D: 106,
  0x4F: 107, 0x50: 108, 0x51: 109, 0x52: 110, 0x53: 111,
  0x5B: 125, 0x5C: 126, 0x5D: 127
}

function mechvibesEvdev(code) {
  if (code <= 255) return code
  var mapped = MECHVIBES_EXTENDED[code & 0xFF]
  return mapped === undefined ? -1 : mapped
}

// UI Events `code` name (MechvibesDX V2 keys) -> evdev code, for every key
// KEY_NAMES knows. Source: https://www.w3.org/TR/uievents-code/ and
// linux/input-event-codes.h.
var W3C_CODES = {
  Escape: 1,
  Digit1: 2, Digit2: 3, Digit3: 4, Digit4: 5, Digit5: 6, Digit6: 7, Digit7: 8, Digit8: 9, Digit9: 10, Digit0: 11,
  Minus: 12, Equal: 13, Backspace: 14, Tab: 15,
  KeyQ: 16, KeyW: 17, KeyE: 18, KeyR: 19, KeyT: 20, KeyY: 21, KeyU: 22, KeyI: 23, KeyO: 24, KeyP: 25,
  BracketLeft: 26, BracketRight: 27, Enter: 28, ControlLeft: 29,
  KeyA: 30, KeyS: 31, KeyD: 32, KeyF: 33, KeyG: 34, KeyH: 35, KeyJ: 36, KeyK: 37, KeyL: 38,
  Semicolon: 39, Quote: 40, Backquote: 41, ShiftLeft: 42, Backslash: 43,
  KeyZ: 44, KeyX: 45, KeyC: 46, KeyV: 47, KeyB: 48, KeyN: 49, KeyM: 50,
  Comma: 51, Period: 52, Slash: 53, ShiftRight: 54, NumpadMultiply: 55, AltLeft: 56, Space: 57, CapsLock: 58,
  F1: 59, F2: 60, F3: 61, F4: 62, F5: 63, F6: 64, F7: 65, F8: 66, F9: 67, F10: 68,
  NumLock: 69,
  Numpad7: 71, Numpad8: 72, Numpad9: 73, NumpadSubtract: 74, Numpad4: 75, Numpad5: 76, Numpad6: 77, NumpadAdd: 78,
  Numpad1: 79, Numpad2: 80, Numpad3: 81, Numpad0: 82, NumpadDecimal: 83,
  F11: 87, F12: 88,
  NumpadEnter: 96, ControlRight: 97, NumpadDivide: 98, AltRight: 100,
  Home: 102, ArrowUp: 103, PageUp: 104, ArrowLeft: 105, ArrowRight: 106,
  End: 107, ArrowDown: 108, PageDown: 109,
  Insert: 110, Delete: 111,
  MetaLeft: 125, MetaRight: 126
}

// Adds takes for a key name and direction unless that direction already has
// some: keys are visited in ascending evdev order, so the main row's sound
// wins over the keypad's when both map to one thock name.
function addTakes(sounds, name, up, takes) {
  if (takes.length === 0) return
  var entry = sounds[name] || (sounds[name] = { down: [], up: [] })
  var dir = up ? "up" : "down"
  if (entry[dir].length === 0) entry[dir] = takes
}

// The default is what every unnamed key plays. Mechvibes packs have no such
// entry, so "a" stands in, and failing that whatever was mapped first.
function defaultFrom(sounds, order) {
  var a = sounds[KEY_NAMES[30]]
  if (a && a.down.length > 0) return a.down
  for (var i = 0; i < order.length; i++) {
    var entry = sounds[order[i]]
    if (entry && entry.down.length > 0) return entry.down
  }
  return []
}

function thockSounds(config) {
  var sounds = {}
  var names = Object.keys(config.sounds)
  for (var i = 0; i < names.length; i++) {
    var raw = config.sounds[names[i]]
    if (!raw || typeof raw !== "object") continue
    var entry = { down: [], up: [] }
    var dirs = ["down", "up"]
    for (var d = 0; d < dirs.length; d++) {
      var list = raw[dirs[d]]
      if (!list || list.length === undefined) continue
      for (var j = 0; j < list.length; j++) if (safeFile(list[j])) entry[dirs[d]].push(wholeFile(list[j]))
    }
    sounds[names[i]] = entry
  }
  return sounds
}

// Mechvibes v1: defines keyed "<code>" (press) and "<code>-up" (release).
// "multi" values are file names, "single" values are [start_ms, duration_ms]
// into one sprite file, config.sound.
function mechvibesSounds(config) {
  var single = config.key_define_type === "single"
  var sprite = safeFile(config.sound) ? config.sound : ""
  var keys = Object.keys(config.defines).map(function(k) {
    var m = /^(\d+)(-up)?$/.exec(k)
    return m ? { key: k, code: Number(m[1]), up: m[2] !== undefined } : null
  }).filter(function(k) { return k !== null }).sort(function(a, b) { return a.code - b.code || (a.up ? 1 : 0) - (b.up ? 1 : 0) })
  var sounds = {}
  var order = []
  for (var i = 0; i < keys.length; i++) {
    var name = KEY_NAMES[mechvibesEvdev(keys[i].code)]
    if (name === undefined) continue
    var value = config.defines[keys[i].key]
    var takes
    if (single) {
      if (sprite === "" || !value || value.length !== 2 || !isFinite(value[0]) || !isFinite(value[1])) continue
      takes = [{ file: sprite, start: Number(value[0]), end: Number(value[0]) + Number(value[1]) }]
    } else {
      takes = expandFiles(value)
    }
    if (!sounds[name]) order.push(name)
    addTakes(sounds, name, keys[i].up, takes)
  }
  var down = single ? [] : expandFiles(config.sound)
  sounds.default = { down: down.length > 0 ? down : defaultFrom(sounds, order), up: expandFiles(config.soundup) }
  return sounds
}

// MechvibesDX V2: definitions keyed by UI Events code name, each with
// timing [[down_start, down_end], [up_start, up_end]?] in ms into either the
// top-level audio_file ("single") or its own ("multi").
function mechvibesDxSounds(config) {
  var single = config.definition_method !== "multi"
  var sprite = safeFile(config.audio_file) ? config.audio_file : ""
  var names = Object.keys(config.definitions).filter(function(n) { return W3C_CODES[n] !== undefined })
    .sort(function(a, b) { return W3C_CODES[a] - W3C_CODES[b] })
  var sounds = {}
  var order = []
  for (var i = 0; i < names.length; i++) {
    var name = KEY_NAMES[W3C_CODES[names[i]]]
    var def = config.definitions[names[i]]
    if (name === undefined || !def || typeof def !== "object") continue
    var file = single ? sprite : (safeFile(def.audio_file) ? def.audio_file : "")
    var timing = def.timing
    if (file === "" || !timing || timing.length === undefined) continue
    if (!sounds[name]) order.push(name)
    for (var d = 0; d < 2 && d < timing.length; d++) {
      var span = timing[d]
      if (!span || span.length !== 2 || !isFinite(span[0]) || !isFinite(span[1])) continue
      addTakes(sounds, name, d === 1, [{ file: file, start: Number(span[0]), end: Number(span[1]) }])
    }
  }
  sounds.default = { down: defaultFrom(sounds, order), up: [] }
  return sounds
}

// config.json text -> { sounds, format }, sounds in the thock shape
// { "<name>": { down: [take], up: [take] }, default: {...} } whatever the
// pack's own format was. Unparseable or unrecognised -> { sounds: {}, format: "" }.
function normalizePack(configText) {
  var config
  try { config = JSON.parse(configText || "") } catch (e) { return { sounds: {}, format: "" } }
  if (!config || typeof config !== "object") return { sounds: {}, format: "" }
  if (config.sounds && typeof config.sounds === "object") return { sounds: thockSounds(config), format: "thock" }
  if (config.defines && typeof config.defines === "object") return { sounds: mechvibesSounds(config), format: "mechvibes" }
  if (config.definitions && typeof config.definitions === "object" && String(config.config_version) === "2") return { sounds: mechvibesDxSounds(config), format: "mechvibesdx" }
  return { sounds: {}, format: "" }
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
    keyState: keyState,
    pressKey: pressKey,
    releaseKey: releaseKey,
    dueReleases: dueReleases,
    hasPending: hasPending,
    takesFor: takesFor,
    takeKey: takeKey,
    packTakes: packTakes,
    normalizePack: normalizePack,
    MECHVIBES_EXTENDED: MECHVIBES_EXTENDED,
    W3C_CODES: W3C_CODES,
    packLabel: packLabel,
    parsePacks: parsePacks,
    dirFromUrl: dirFromUrl,
    findEntry: findEntry,
    setting: setting,
    normalizeVolume: normalizeVolume
  }
}
