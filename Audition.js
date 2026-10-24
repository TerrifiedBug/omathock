// The service owns one audition. Load replies and scheduled callbacks carry
// identities so superseded selections and cancelled timers cannot play later.
var KEYS = ["a", "s", "d", "space", "enter"]
var PRESS_GAP_MS = 165
var RELEASE_MS = 40

function create(deps) {
  var directory = ""
  var serial = 0
  var pendingLoad = null
  var sounds = {}
  var ready = false
  var wanted = false
  var generation = 0
  var cancelTimer = null

  function stop() {
    generation++
    if (cancelTimer) cancelTimer()
    cancelTimer = null
    deps.cancel()
  }

  function cancel() {
    wanted = false
    stop()
  }

  function select(nextDirectory) {
    if (directory === nextDirectory) return
    cancel()
    directory = nextDirectory
    pendingLoad = null
    ready = false
  }

  function start() {
    wanted = false
    var token = generation
    var step = 0
    function advance() {
      if (token !== generation) return
      cancelTimer = null
      if (!deps.allowed()) { cancel(); return }
      var takes = deps.takesFor(sounds, KEYS[Math.floor(step / 2)], step % 2 === 1)
      if (takes.length > 0) deps.play(takes[Math.floor(Math.random() * takes.length)])
      step++
      if (step < KEYS.length * 2)
        cancelTimer = deps.schedule(advance, step % 2 === 1 ? RELEASE_MS : PRESS_GAP_MS - RELEASE_MS)
    }
    advance()
  }

  function request() {
    cancel()
    if (!directory || !deps.allowed()) return
    wanted = true
    if (ready) start()
  }

  function beginLoad(nextDirectory, nextSounds) {
    select(nextDirectory)
    stop()
    ready = false
    pendingLoad = { dir: nextDirectory, request: ++serial, sounds: nextSounds }
    return serial
  }

  function loaded(message) {
    if (!pendingLoad || message.dir !== directory || message.request !== pendingLoad.request) return false
    var completed = pendingLoad
    pendingLoad = null
    if (!(message.takes > 0)) { cancel(); return false }
    sounds = completed.sounds
    ready = true
    if (wanted) start()
    return true
  }

  function reset() {
    cancel()
    pendingLoad = null
    ready = false
  }

  return { select: select, beginLoad: beginLoad, loaded: loaded, request: request, cancel: cancel, reset: reset }
}

if (typeof module !== "undefined") module.exports = { create: create }
