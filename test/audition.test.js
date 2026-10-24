const test = require("node:test")
const assert = require("node:assert/strict")
const Audition = require("../Audition.js")
const Model = require("../Model.js")

function harness() {
  let now = 0
  let allowed = true
  let volume = 50
  const jobs = []
  const plays = []
  let cancellations = 0
  const unit = Audition.create({
    allowed: () => allowed,
    takesFor: Model.takesFor,
    play: take => plays.push({ take, at: now, volume }),
    cancel: () => { cancellations += 1 },
    schedule: (callback, delay) => {
      const job = { callback, at: now + delay, cancelled: false }
      jobs.push(job)
      return () => { job.cancelled = true }
    }
  })
  function advance(ms) {
    const end = now + ms
    for (;;) {
      const job = jobs.filter(j => !j.cancelled && j.at <= end).sort((a, b) => a.at - b.at)[0]
      if (!job) break
      job.cancelled = true
      now = job.at
      job.callback()
    }
    now = end
  }
  function load(dir, sounds = pack(dir)) {
    unit.select(dir)
    const request = unit.beginLoad(dir, sounds)
    return { evt: "loaded", dir, request, takes: Model.packTakes(sounds).length, failed: [] }
  }
  return {
    unit, plays, jobs, advance, load,
    allowed: value => { allowed = value },
    volume: value => { volume = value },
    cancellations: () => cancellations
  }
}

function pack(label, releases = true) {
  const sounds = {}
  for (const name of ["a", "s", "d", "space", "enter"]) {
    sounds[name] = {
      down: [{ file: label + "/" + name + ".wav", start: 0, end: 0 }],
      up: releases ? [{ file: label + "/" + name + "-up.wav", start: 0, end: 0 }] : []
    }
  }
  return sounds
}

test("before-load request waits for latest successful acknowledgement and plays five real keystrokes", () => {
  const h = harness()
  h.unit.select("A")
  h.unit.request()
  h.advance(1000)
  assert.deepEqual(h.plays, [])
  const ack = h.load("A")
  assert.equal(h.unit.loaded(ack), true)
  h.advance(700)
  assert.deepEqual(h.plays.map(p => p.take.file), [
    "A/a.wav", "A/a-up.wav", "A/s.wav", "A/s-up.wav", "A/d.wav",
    "A/d-up.wav", "A/space.wav", "A/space-up.wav", "A/enter.wav", "A/enter-up.wav"
  ])
  assert.equal(h.plays[9].at - h.plays[0].at, 700)
})

test("newest A to B to A request wins, even when the old acknowledgement has the same directory", () => {
  const h = harness()
  const firstA = h.load("A")
  h.unit.request()
  const b = h.load("B")
  h.unit.request()
  const lastA = h.load("A")
  h.unit.request()
  assert.notEqual(firstA.request, lastA.request)
  assert.equal(h.unit.loaded(firstA), false)
  assert.equal(h.unit.loaded(b), false)
  assert.equal(h.unit.loaded({ ...lastA, dir: "B" }), false)
  assert.deepEqual(h.plays, [])
  h.unit.loaded(lastA)
  h.advance(700)
  assert.equal(h.plays.length, 10)
  assert.ok(h.plays.every(p => p.take.file.startsWith("A/")))
})

test("cancel after start stops timer and helper voices, including callbacks delivered after cancellation", () => {
  const h = harness()
  h.unit.loaded(h.load("A"))
  h.unit.request()
  const late = h.jobs[0].callback
  assert.equal(h.plays.length, 1)
  const before = h.cancellations()
  h.unit.cancel()
  assert.equal(h.cancellations(), before + 1)
  late()
  h.advance(1000)
  assert.equal(h.plays.length, 1)
})

test("volume release replaces the old sequence at new gain; silent volume cancellation does not restart", () => {
  const h = harness()
  h.unit.loaded(h.load("A"))
  h.unit.request()
  h.advance(165)
  assert.equal(h.plays.length, 3)
  h.unit.cancel()
  h.volume(80)
  h.unit.request()
  h.advance(700)
  assert.equal(h.plays.length, 13)
  assert.ok(h.plays.slice(3).every(p => p.volume === 80))
  assert.equal(h.plays[3].take.file, "A/a.wav")
  h.unit.cancel()
  h.volume(20)
  h.advance(1000)
  assert.equal(h.plays.length, 13)
})

test("forbidden state clears pending and running auditions and never resumes on unlock", () => {
  for (const started of [false, true]) {
    const h = harness()
    const ack = h.load("A")
    if (started) h.unit.loaded(ack)
    h.unit.request()
    const count = h.plays.length
    h.allowed(false)
    h.unit.cancel()
    h.unit.loaded(ack)
    h.advance(1000)
    h.allowed(true)
    h.advance(1000)
    assert.equal(h.plays.length, count)
    h.allowed(false)
    h.unit.request()
    h.allowed(true)
    h.advance(1000)
    assert.equal(h.plays.length, count)
  }
})

test("a forbidden state at a timer boundary cancels without another keystroke", () => {
  const h = harness()
  h.unit.loaded(h.load("A"))
  h.unit.request()
  h.allowed(false)
  h.advance(1000)
  h.allowed(true)
  h.advance(1000)
  assert.equal(h.plays.length, 1)
})

test("packs without release takes play exactly five presses without synthetic releases", () => {
  const h = harness()
  h.unit.loaded(h.load("A", pack("A", false)))
  h.unit.request()
  h.advance(700)
  assert.deepEqual(h.plays.map(p => p.take.file), ["A/a.wav", "A/s.wav", "A/d.wav", "A/space.wav", "A/enter.wav"])
})

test("failed empty load and player exit discard pending requests", () => {
  const h = harness()
  let ack = h.load("A")
  h.unit.request()
  assert.equal(h.unit.loaded({ ...ack, takes: 0, failed: ["a.wav"] }), false)
  h.unit.loaded(ack)
  h.advance(700)
  assert.equal(h.plays.length, 0)
  ack = h.load("B")
  h.unit.request()
  h.unit.reset()
  assert.equal(h.unit.loaded(ack), false)
  const restarted = h.load("B")
  h.unit.loaded(restarted)
  h.advance(700)
  assert.equal(h.plays.length, 0)
})

test("config reload invalidates readiness and replaces ringing voices before accepting a new acknowledgement", () => {
  const h = harness()
  const old = h.load("A")
  h.unit.loaded(old)
  h.unit.request()
  const next = h.load("A", pack("replacement"))
  h.unit.request()
  assert.equal(h.unit.loaded(old), false)
  h.advance(700)
  assert.equal(h.plays.length, 1)
  h.unit.loaded(next)
  h.advance(700)
  assert.equal(h.plays.length, 11)
  assert.ok(h.plays.slice(1).every(p => p.take.file.startsWith("replacement/")))
})
