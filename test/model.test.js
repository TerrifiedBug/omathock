const test = require("node:test")
const assert = require("node:assert")
const Model = require("../Model.js")

// A tplai-shaped pack: several takes for down, one for up.
const tplai = {
  default: { down: ["1.wav", "2.wav", "3.wav"], up: ["101.wav"] },
  space: { down: ["201.wav"], up: ["251.wav"] },
  backspace: { down: ["301.wav"], up: ["351.wav"] }
}

// A mechvibes-shaped pack: no key-up recordings, backspace spelled "del".
const mechvibes = {
  default: { down: ["a.wav"], up: [] },
  del: { down: ["b.wav"], up: [] }
}

test("keyName translates xkb codes into thock key names", () => {
  assert.equal(Model.keyName(38), "a")
  assert.equal(Model.keyName(65), "space")
  assert.equal(Model.keyName(22), "backspace")
  assert.equal(Model.keyName(999), "default")
})

test("parseEvent accepts this plugin's events and rejects everything else", () => {
  assert.deepEqual(Model.parseEvent("omathock,38,1"), { code: 38, name: "a", up: false })
  assert.equal(Model.parseEvent("omathock,38,0").up, true)
  assert.equal(Model.parseEvent("other,1,1"), null)
  assert.equal(Model.parseEvent("omathock,x,1"), null)
  assert.equal(Model.parseEvent("omathock,38"), null)
  assert.equal(Model.parseEvent(undefined), null)
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

test("soundFor resolves key, then alias, then default", () => {
  assert.equal(Model.soundFor(tplai, "backspace", false, 0), "301.wav")
  assert.equal(Model.soundFor(mechvibes, "backspace", false, 0), "b.wav")
  assert.equal(Model.soundFor(tplai, "f7", false, 0), "1.wav")
})

test("soundFor stays silent when the pack has no recording for the direction", () => {
  assert.equal(Model.soundFor(mechvibes, "backspace", true, 0), "")
  assert.equal(Model.soundFor({}, "a", false, 0), "")
})

test("soundFor picks a take from the caller's random draw", () => {
  assert.equal(Model.soundFor(tplai, "a", false, 0), "1.wav")
  assert.equal(Model.soundFor(tplai, "a", false, 0.99), "3.wav")
})

test("packFiles is the sorted unique union of every take", () => {
  assert.deepEqual(Model.packFiles(tplai), ["1.wav", "101.wav", "2.wav", "201.wav", "251.wav", "3.wav", "301.wav", "351.wav"])
  assert.deepEqual(Model.packFiles({ a: { down: ["x.wav"] }, b: { down: ["x.wav"], up: ["x.wav"] } }), ["x.wav"])
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
