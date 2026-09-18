const test = require("node:test")
const assert = require("node:assert")
const Model = require("../Model.js")

const take = (file, start = 0, end = 0) => ({ file, start, end })

// A tplai-shaped pack: several takes for down, one for up.
const tplai = {
  default: { down: [take("1.wav"), take("2.wav"), take("3.wav")], up: [take("101.wav")] },
  space: { down: [take("201.wav")], up: [take("251.wav")] },
  backspace: { down: [take("301.wav")], up: [take("351.wav")] }
}

// A mechvibes-shaped pack: no key-up recordings, backspace spelled "del".
const mechvibes = {
  default: { down: [take("a.wav")], up: [] },
  del: { down: [take("b.wav")], up: [] }
}

test("keyName translates typing keys and names nothing else", () => {
  assert.equal(Model.keyName(38), "a")
  assert.equal(Model.keyName(65), "space")
  assert.equal(Model.keyName(22), "backspace")
  assert.equal(Model.keyName(119), "backspace")
  assert.equal(Model.keyName(118), "insert")
  assert.equal(Model.keyName(999), "")
  // Volume up (evdev 115) is a keyboard-class event from a media device.
  assert.equal(Model.keyName(123), "")
})

test("parseEvent accepts this plugin's events and rejects everything else", () => {
  assert.deepEqual(Model.parseEvent("omathock,38,1,1200"), { code: 38, name: "a", up: false })
  assert.equal(Model.parseEvent("omathock,38,0,1200").up, true)
  assert.equal(Model.parseEvent("other,1,1,1200"), null)
  assert.equal(Model.parseEvent("omathock,x,1,1200"), null)
  assert.equal(Model.parseEvent("omathock,38,1"), null)
  assert.equal(Model.parseEvent(undefined), null)
})

test("parseEvent stays silent for media keys and injected input", () => {
  // Brightness up (evdev 225) from the laptop's HID hotkeys.
  assert.equal(Model.parseEvent("omathock,233,1,1200"), null)
  // wtype and friends drive a virtual keyboard with no hardware time.
  assert.equal(Model.parseEvent("omathock,38,1,0"), null)
})

test("a plain press and release click once each", () => {
  const state = Model.keyState()
  assert.equal(Model.pressKey(state, 38), true)
  assert.equal(Model.releaseKey(state, 38, "a", 1000), true)
  assert.deepEqual(Model.dueReleases(state, 1000 + 34), [])
  assert.deepEqual(Model.dueReleases(state, 1000 + 35), ["a"])
  assert.equal(Model.hasPending(state), false)
})

test("the echo an input method adds is silent", () => {
  const state = Model.keyState()
  Model.pressKey(state, 38)
  assert.equal(Model.pressKey(state, 38), false)
  assert.equal(Model.releaseKey(state, 38, "a", 1000), true)
  assert.equal(Model.releaseKey(state, 38, "a", 1000), false)
  assert.deepEqual(Model.dueReleases(state, 1100), ["a"])
})

test("a held key repeating as press/release pairs stays one press", () => {
  const state = Model.keyState()
  assert.equal(Model.pressKey(state, 38), true)
  let now = 1000
  for (let i = 0; i < 20; i++) {
    assert.equal(Model.releaseKey(state, 38, "a", now), true)
    now += 25
    assert.deepEqual(Model.dueReleases(state, now), [])
    assert.equal(Model.pressKey(state, 38), false)
  }
  // Only the real lift, once the stream stops, plays the key-up sound.
  Model.releaseKey(state, 38, "a", now)
  assert.deepEqual(Model.dueReleases(state, now + 40), ["a"])
})

test("a held key flooding releases stays one press", () => {
  const state = Model.keyState()
  Model.pressKey(state, 38)
  assert.equal(Model.releaseKey(state, 38, "a", 1000), true)
  for (let i = 0; i < 20; i++) assert.equal(Model.releaseKey(state, 38, "a", 1000 + i), false)
  assert.deepEqual(Model.dueReleases(state, 1100), ["a"])
})

test("deliberate re-presses and other keys stay audible", () => {
  const state = Model.keyState()
  Model.pressKey(state, 38)
  Model.releaseKey(state, 38, "a", 1000)
  assert.deepEqual(Model.dueReleases(state, 1040), ["a"])
  assert.equal(Model.pressKey(state, 38), true)
  assert.equal(Model.pressKey(state, 39), true)
})

test("takesFor resolves key, then alias, then default", () => {
  assert.deepEqual(Model.takesFor(tplai, "backspace", false), [take("301.wav")])
  assert.deepEqual(Model.takesFor(mechvibes, "backspace", false), [take("b.wav")])
  assert.deepEqual(Model.takesFor(tplai, "f7", false), [take("1.wav"), take("2.wav"), take("3.wav")])
})

test("takesFor is empty when the pack has no recording for the direction", () => {
  assert.deepEqual(Model.takesFor(mechvibes, "backspace", true), [])
  assert.deepEqual(Model.takesFor({}, "a", false), [])
})

test("packTakes is the union of every take, deduped by slice and sorted", () => {
  assert.deepEqual(Model.packTakes(tplai).map(Model.takeKey),
    ["1.wav@0-0", "101.wav@0-0", "2.wav@0-0", "201.wav@0-0", "251.wav@0-0", "3.wav@0-0", "301.wav@0-0", "351.wav@0-0"])
  const slice = take("sound.ogg", 100, 200)
  const other = take("sound.ogg", 300, 350)
  assert.deepEqual(Model.packTakes({ a: { down: [slice] }, b: { down: [other], up: [take("sound.ogg", 100, 200)] } }), [slice, other])
})

test("normalizePack reads a thock config into object takes", () => {
  const out = Model.normalizePack(JSON.stringify({ sounds: { default: { down: ["1.wav", 7], up: [] }, a: { down: ["2.wav"] } } }))
  assert.equal(out.format, "thock")
  assert.deepEqual(out.sounds.default, { down: [take("1.wav")], up: [] })
  assert.deepEqual(out.sounds.a, { down: [take("2.wav")], up: [] })
})

test("normalizePack reads a mechvibes multi config", () => {
  const out = Model.normalizePack(JSON.stringify({
    key_define_type: "multi",
    sound: "GENERIC_R{0-4}.mp3",
    soundup: "release/GENERIC.mp3",
    defines: {
      "30": "a.wav",
      "14": "del.wav",
      "14-up": "del-up.wav",
      "57416": "up.wav",
      "3613": "ctrl.wav",
      "79": "keypad1.wav",
      "2": "one.wav",
      "16": null,
      "17": "../x.wav",
      "18": "x..y.wav",
      "999": "nowhere.wav"
    }
  }))
  assert.equal(out.format, "mechvibes")
  assert.deepEqual(out.sounds.default.down, [0, 1, 2, 3, 4].map(n => take("GENERIC_R" + n + ".mp3")))
  assert.deepEqual(out.sounds.default.up, [take("release/GENERIC.mp3")])
  assert.deepEqual(out.sounds.a, { down: [take("a.wav")], up: [] })
  assert.deepEqual(out.sounds.backspace, { down: [take("del.wav")], up: [take("del-up.wav")] })
  assert.deepEqual(out.sounds.arrUp.down, [take("up.wav")])
  assert.deepEqual(out.sounds.ctrlLeft.down, [take("ctrl.wav")])
  // Keypad 1 shares the main row's name and must not override it.
  assert.deepEqual(out.sounds["1"].down, [take("one.wav")])
  assert.equal(out.sounds.q, undefined)
  assert.equal(out.sounds.w, undefined)
  assert.equal(out.sounds.e, undefined)
})

test("normalizePack reads a mechvibes single sprite config", () => {
  const out = Model.normalizePack(JSON.stringify({
    key_define_type: "single",
    sound: "sound.ogg",
    defines: { "2": [2926, 125], "2-up": [3051, 77], "30": [100, 50], "31": "bad" }
  }))
  assert.equal(out.format, "mechvibes")
  assert.deepEqual(out.sounds["1"], { down: [take("sound.ogg", 2926, 3051)], up: [take("sound.ogg", 3051, 3128)] })
  assert.deepEqual(out.sounds.a.down, [take("sound.ogg", 100, 150)])
  assert.deepEqual(out.sounds.default, { down: [take("sound.ogg", 100, 150)], up: [] })
  assert.equal(out.sounds.s, undefined)
})

test("normalizePack reads MechvibesDX V2 single and multi configs", () => {
  const single = Model.normalizePack(JSON.stringify({
    config_version: "2",
    definition_method: "single",
    audio_file: "KEY.wav",
    definitions: {
      KeyA: { timing: [[23.0, 132.0], [132.0, 264.0]] },
      Enter: { timing: [[500, 600]] },
      ArrowUp: { timing: [[700, 800]] },
      NumpadEnter: { timing: [[900, 1000]] },
      Fn: { timing: [[0, 1]] }
    }
  }))
  assert.equal(single.format, "mechvibesdx")
  assert.deepEqual(single.sounds.a, { down: [take("KEY.wav", 23, 132)], up: [take("KEY.wav", 132, 264)] })
  assert.deepEqual(single.sounds.enter, { down: [take("KEY.wav", 500, 600)], up: [] })
  assert.deepEqual(single.sounds.arrUp.down, [take("KEY.wav", 700, 800)])
  assert.deepEqual(single.sounds.default.down, [take("KEY.wav", 23, 132)])
  assert.equal(Object.keys(single.sounds).length, 4)

  const multi = Model.normalizePack(JSON.stringify({
    config_version: "2",
    definition_method: "multi",
    definitions: {
      Escape: { timing: [[0.0, 183.4]], audio_file: "ESC.wav" },
      KeyB: { timing: [[0, 90]], audio_file: "KEY1.wav" }
    }
  }))
  assert.equal(multi.format, "mechvibesdx")
  assert.deepEqual(multi.sounds.esc.down, [take("ESC.wav", 0, 183.4)])
  assert.deepEqual(multi.sounds.default.down, [take("ESC.wav", 0, 183.4)])
})

test("normalizePack yields nothing for garbage", () => {
  assert.deepEqual(Model.normalizePack("not json"), { sounds: {}, format: "" })
  assert.deepEqual(Model.normalizePack(JSON.stringify({ hello: 1 })), { sounds: {}, format: "" })
  assert.deepEqual(Model.normalizePack(""), { sounds: {}, format: "" })
})

test("packLabel title-cases a slug without mangling acronyms", () => {
  assert.equal(Model.packLabel("gateron-ink-black"), "Gateron Ink Black")
  assert.equal(Model.packLabel("IBM-buckling-spring"), "IBM Buckling Spring")
})

test("parsePacks sorts by slug and lets the user root win", () => {
  const out = Model.parsePacks([
    "/usr/share/omathock/soundpacks/topre/config.json",
    "/plug/soundpacks/drop-holy-panda/config.json",
    "/home/x/.local/share/omathock/soundpacks/topre/config.json",
    "",
    "/plug/soundpacks/drop-holy-panda/1.wav"
  ].join("\n"))
  assert.deepEqual(out, [
    { slug: "drop-holy-panda", dir: "/plug/soundpacks/drop-holy-panda" },
    { slug: "topre", dir: "/home/x/.local/share/omathock/soundpacks/topre" }
  ])
})

test("findEntry looks through the bar layout and the plugins list", () => {
  const config = JSON.stringify({
    bar: { layout: { left: [{ id: "omarchy.clock" }], center: [{ id: "me", volume: 30 }], right: [] } },
    plugins: [{ id: "other" }]
  })
  assert.equal(Model.findEntry(config, "me").volume, 30)
  assert.deepEqual(Model.findEntry(JSON.stringify({ plugins: [{ id: "me", enabled: false }] }), "me"), { id: "me", enabled: false })
  assert.deepEqual(Model.findEntry("not json", "me"), {})
  assert.deepEqual(Model.findEntry(config, "absent"), {})
})

test("setting falls back to the manifest defaults", () => {
  assert.equal(Model.setting({ volume: 0 }, "volume"), 0)
  assert.equal(Model.setting({ volume: null }, "volume"), 100)
  assert.equal(Model.setting({}, "soundpack"), "drop-holy-panda")
})

test("normalizeVolume clamps and rounds anything the CLI can pass", () => {
  assert.equal(Model.normalizeVolume("150"), 100)
  assert.equal(Model.normalizeVolume(-3), 0)
  assert.equal(Model.normalizeVolume("abc"), 100)
  assert.equal(Model.normalizeVolume(42.6), 43)
})

test("dirFromUrl turns a resolved QML url into a plain path", () => {
  assert.equal(Model.dirFromUrl("file:///home/x/my%20plugins/omathock/"), "/home/x/my plugins/omathock")
})
