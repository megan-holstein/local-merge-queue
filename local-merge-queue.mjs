#!/usr/bin/env node
// local-merge-queue — a local merge queue for git repositories.
//
// Branch agents enqueue a finished branch; the owner approves it; the merge queue lands
// the approved entries one at a time, rebasing each onto a main that may have
// moved since the branch was cut. It stalls on conflict rather than evicting,
// because these branches overlap and landing them out of order relocates a
// conflict instead of avoiding it.
//
// Full contract and the agent-facing workflow: ./README.md

import { execFileSync, spawn, spawnSync } from 'node:child_process'
import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))

// WHERE THE CONFIG AND THE QUEUE LIVE. The two environment variables win over
// everything below, always. They exist so the tool can be exercised end to end
// against a throwaway repo instead of against the real ones, and so an
// installation whose config and queue predate these defaults can pin the paths
// it already has. Absent them, the defaults are the XDG ones a stranger would
// expect to find.
const XDG_CONFIG = process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config')
const XDG_STATE = process.env.XDG_STATE_HOME || path.join(os.homedir(), '.local', 'state')
const CONFIG_PATH = process.env.LOCAL_MERGE_QUEUE_CONFIG || path.join(XDG_CONFIG, 'local-merge-queue', 'repos.json')
const STATE_DIR = process.env.LOCAL_MERGE_QUEUE_STATE || path.join(XDG_STATE, 'local-merge-queue')
const QUEUE_PATH = path.join(STATE_DIR, 'queue.json')
const LOCK_DIR = path.join(STATE_DIR, 'locks')
const REPORT_DIR = path.join(STATE_DIR, 'reports')
// A branch name may contain `/` (feat/x), which a file name cannot, so the report's name
// carries it as %2F: one flat file per entry, whatever the branch is called.
const reportFile = (key, branch) => path.join(REPORT_DIR, `${key}-${branch.replaceAll('/', '%2F')}.md`)
const QUEUE_LOCK = path.join(STATE_DIR, 'queue.lock')
const BATCH_DIR = path.join(STATE_DIR, 'batch')

// ─── small helpers ──────────────────────────────────────────────────────────

const bold = s => `[1m${s}[0m`
const dim = s => `[2m${s}[0m`
const red = s => `[31m${s}[0m`
const green = s => `[32m${s}[0m`
const yellow = s => `[33m${s}[0m`

function die (msg, code = 1) {
  console.error(red(`local-merge-queue: ${msg}`))
  process.exit(code)                    // `process.exit` skips every `finally`; the exit handler below releases what this process holds
}

// A RELATIVE CHECKOUT PATH RESOLVES AGAINST THE CONFIG'S `root`, which defaults
// to the directory the config file itself sits in. A path beginning with `~/`
// never consults it, so a registry whose paths are all absolute behaves the same
// whatever `root` says — which is the property that lets an existing config
// keep working when the defaults move.
let CONFIG_ROOT = path.dirname(CONFIG_PATH)

function expand (p) {
  if (!p) return p
  if (p.startsWith('~/')) return path.join(os.homedir(), p.slice(2))
  return path.resolve(CONFIG_ROOT, p)
}

// Paths must be compared after symlink resolution: git always reports the real
// path, while a config (or a cwd reached through a symlink, as one checkout
// here is) may not. Comparing the two unresolved silently finds no repo.
function real (p) {
  try { return fs.realpathSync(p) } catch { return path.resolve(p) }
}

function readJSON (file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')) } catch { return fallback }
}

function writeJSON (file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true })
  fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n')
}

// git that throws on failure, returning trimmed stdout.
function git (args, cwd) {
  return execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()
}

// git that never throws; returns {ok, out, err}.
function gitTry (args, cwd) {
  const r = spawnSync('git', args, { cwd, encoding: 'utf8' })
  return { ok: r.status === 0, out: (r.stdout || '').trim(), err: (r.stderr || '').trim() }
}

// A shell command with live output, for gate steps.
function run (cmd, cwd, env = {}) {
  const r = spawnSync('bash', ['-lc', cmd], {
    cwd,
    stdio: 'inherit',
    env: { ...process.env, ...env }
  })
  return r.status === 0
}

// WHAT THIS PROCESS HOLDS IS RELEASED ON EVERY WAY OUT. `die` calls process.exit,
// which skips every `finally`, so locks and the batch marks are released from the
// `exit` event instead, and a signal is turned into an exit. A process killed
// with SIGKILL runs nothing, so it leaves a lock whose holder is dead; the next
// command finds the holder gone and breaks the lock (see `lockStale`).
const exitCleanups = []
let exiting = false
function onExit (fn) { exitCleanups.push(fn) }
process.on('exit', () => {
  if (exiting) return
  exiting = true
  while (exitCleanups.length) { try { exitCleanups.pop()() } catch { /* nothing to be done at exit */ } }
})

// A gate runs in a process group of its own, so that an interruption can end all
// of it: the shell, and whatever the shell started, which would otherwise go on
// running (in the batch worktree, against a lock nobody holds).
const gateGroups = new Set()
let signalled = false
function handleSignal (sig, code) {
  if (signalled) process.exit(code)
  signalled = true
  console.error(yellow(`\nlocal-merge-queue: ${sig} — stopping the gate and releasing what this run holds`))
  const groups = [...gateGroups]
  for (const pid of groups) { try { process.kill(-pid, 'SIGTERM') } catch { /* already gone */ } }
  const started = Date.now()
  const timer = setInterval(() => {
    let alive = false
    for (const pid of groups) { try { process.kill(-pid, 0); alive = true } catch { /* gone */ } }
    if (alive && Date.now() - started < 5000) return
    for (const pid of groups) { try { process.kill(-pid, 'SIGKILL') } catch { /* gone */ } }
    clearInterval(timer)
    process.exit(code)
  }, 50)
}
for (const [sig, code] of [['SIGINT', 130], ['SIGTERM', 143], ['SIGHUP', 129]]) process.on(sig, () => handleSignal(sig, code))

// A gate step, setup step or final check with live output, in a process group of
// its own. Asynchronous, so that a signal is handled while it runs.
// `timeoutMs` (from the repository's or lane's `gateTimeoutMinutes`) ends a step that runs
// longer: its process group gets SIGTERM, then SIGKILL five seconds later, and the step
// counts as failed, with `gateTimedOut` set for the caller to say so. A gate that hangs
// would otherwise hold the landing lock for ever, since a live holder is never broken.
let gateTimedOut = false
function runGate (cmd, cwd, env = {}, { timeoutMs = 0 } = {}) {
  return new Promise(resolve => {
    gateTimedOut = false
    // Once a signal has come in, nothing more is started and nothing downstream of a
    // killed gate runs (a fallback, a stall report): the promise never settles and the
    // signal handler ends the process.
    if (signalled) return
    const child = spawn('bash', ['-lc', cmd], { cwd, stdio: 'inherit', env: { ...process.env, ...env }, detached: true })
    gateGroups.add(child.pid)
    noteGateGroup(child.pid)
    let timedOut = false
    let timer = null
    const finish = ok => { clearTimeout(timer); gateGroups.delete(child.pid); noteGateGroup(null); if (!signalled) resolve(ok) }
    if (timeoutMs > 0) {
      timer = setTimeout(() => {
        timedOut = true
        gateTimedOut = true
        console.error(yellow(`\n  local-merge-queue: the step ran past its limit of ${fmtMinutes(timeoutMs / 60000)} — ending it`))
        try { process.kill(-child.pid, 'SIGTERM') } catch { /* gone */ }
        setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL') } catch { /* gone */ } }, 5000).unref()
      }, timeoutMs)
    }
    child.on('error', () => finish(false))
    child.on('close', code => {
      if (!timedOut) return finish(code === 0)
      // The shell is gone; wait (bounded) until its whole group is, so that nothing the
      // gate started is still running when the entry is stalled and the lock released.
      const started = Date.now()
      const poll = setInterval(() => {
        if (groupAlive(child.pid) && Date.now() - started < 8000) return
        clearInterval(poll)
        finish(false)
      }, 100)
    })
  })
}

const fmtMinutes = m => `${m} minute${m === 1 ? '' : 's'}`

// THE GATE'S PROCESS GROUP IS RECORDED IN THE LANDING LOCK. A gate runs in a group of
// its own, so a run killed with SIGKILL leaves the gate running; the stale lock then
// admitted a second run, which started a second gate in the same worktree while the
// first still ran (found by the independent re-check, 2026-11-21). With the group in
// the lock's owner record, `lockStale` treats a lock whose run is dead but whose gate
// group is alive as held, and the message names the group.
let gateLock = null        // { dir, token }: the landing lock this process holds
function noteGateGroup (pgid) {
  if (!gateLock) return
  try {
    const f = path.join(gateLock.dir, 'owner.json')
    const o = readJSON(f, null)
    if (!o || o.token !== gateLock.token) return
    if (pgid) o.gatePgid = pgid; else delete o.gatePgid
    const tmp = `${f}.tmp-${process.pid}`
    fs.writeFileSync(tmp, JSON.stringify(o))
    fs.renameSync(tmp, f)
  } catch { /* the lock was released or taken over meanwhile */ }
}

const groupHint = pgid => `ps -o pid,pgid,etime,command -g ${pgid}`

// Does any process of this group still exist? EPERM means one does, and is not ours.
function groupAlive (pgid) {
  if (!Number.isInteger(pgid) || pgid <= 1) return false
  try { process.kill(-pgid, 0); return true } catch (e) { return e.code === 'EPERM' }
}

// Is a rebase sitting half-finished in this worktree? Asked of git rather than
// remembered, because the stall report's instructions are only true when the
// answer is yes — and of the three stall kinds, two (a failed gate, a failed
// setup) happen after the rebase has finished cleanly and leave nothing to
// resolve.
function rebaseInProgress (wt) {
  const g = gitTry(['rev-parse', '--absolute-git-dir'], wt)
  if (!g.ok) return false
  return fs.existsSync(path.join(g.out, 'rebase-merge')) ||
         fs.existsSync(path.join(g.out, 'rebase-apply'))
}

// A TEST SEAM, like LOCAL_MERGE_QUEUE_TEST_PAUSE_IN_LOCK: with LOCAL_MERGE_QUEUE_TEST_HOLD=<prefix>
// the run stops at a named point, writes <prefix>.<point>, and waits (up to 15 s) for
// <prefix>.<point>.go, so a test can act in the window between two checks. Never set outside tests.
function testHold (point) {
  const seam = process.env.LOCAL_MERGE_QUEUE_TEST_HOLD
  if (!seam) return
  fs.writeFileSync(`${seam}.${point}`, '')
  for (let i = 0; i < 300 && !fs.existsSync(`${seam}.${point}.go`); i++) sleepMs(50)
}

function pidAlive (pid) {
  try { process.kill(pid, 0); return true } catch { return false }
}

function nowISO () { return new Date().toISOString() }

// ─── config & state ─────────────────────────────────────────────────────────

function loadConfig () {
  if (!fs.existsSync(CONFIG_PATH)) {
    die(`no config at ${CONFIG_PATH}\n` +
        `  Write one there, or point LOCAL_MERGE_QUEUE_CONFIG at one elsewhere.\n` +
        `  repos.example.json, beside this script, documents every key with a worked example.`)
  }
  const cfg = readJSON(CONFIG_PATH, null)
  if (!cfg) die(`the config at ${CONFIG_PATH} is not valid JSON`)
  if (!cfg.repos || typeof cfg.repos !== 'object') {
    die(`the config at ${CONFIG_PATH} has no "repos" object — see repos.example.json`)
  }
  if (cfg.root) CONFIG_ROOT = expand(cfg.root)
  for (const [key, repo] of Object.entries(cfg.repos)) {
    repo.key = key
    repo.checkout = real(expand(repo.checkout))
    repo.mainBranch ||= 'main'
    repo.lanes = loadLanes(key, repo)
    checkBatch(key, repo)
    checkTimeout(key, repo)
  }
  return cfg
}

// `gateTimeoutMinutes`: how long one setup step, gate step or final check may run, at repo
// level or (overriding it) inside a lane. A positive number; fractions are allowed.
function checkTimeout (key, repo) {
  const bad = (where, v) => die(`repo "${key}": ${where}gateTimeoutMinutes must be a positive number of minutes, not ${JSON.stringify(v)}`)
  if (repo.gateTimeoutMinutes !== undefined && !(typeof repo.gateTimeoutMinutes === 'number' && repo.gateTimeoutMinutes > 0 && Number.isFinite(repo.gateTimeoutMinutes))) bad('', repo.gateTimeoutMinutes)
  for (const [name, lane] of Object.entries(repo.lanes)) {
    const v = lane.gateTimeoutMinutes
    if (v !== undefined && !(typeof v === 'number' && v > 0 && Number.isFinite(v))) bad(`lane "${name}": `, v)
  }
}
function gateTimeoutMs (repo, laneName) {
  const m = repo.lanes[laneName]?.gateTimeoutMinutes ?? repo.gateTimeoutMinutes
  return m ? m * 60000 : 0
}

// `batch` is opt-in per repository: {"max": 5}. Absent, the repository lands one
// entry at a time, as it always has. A repo-level key, never a lane's. ONLY A `max` TURNS
// BATCHING ON FOR EVERY RUN: a `batch` with `keep` or `lockfiles` and no `max` configures
// the batch worktree for the runs that pass `--batch`, and leaves the rest unbatched.
const BATCH_DEFAULT_MAX = 5
function checkBatch (key, repo) {
  if (repo.batch === undefined) return
  const b = repo.batch
  if (!b || typeof b !== 'object' || Array.isArray(b) || (b.max !== undefined && (!Number.isInteger(b.max) || b.max < 2))) {
    die(`repo "${key}": "batch" must look like { "max": 5 } or { "keep": ["node_modules"] }; a "max" is an integer of at least 2 (a batch of one is a landing run of one), and only a "max" turns batching on for every run`)
  }
  // `keep`: the dependency directories of the batch worktree that survive between
  // batches (relative paths, e.g. ["node_modules"]). `lockfiles`: the files whose
  // change means the kept directories cannot be trusted (default: the usual
  // lockfile names at the root and beside each kept directory).
  for (const k of ['keep', 'lockfiles']) {
    const v = b[k]
    if (v === undefined) continue
    if (!Array.isArray(v) || !v.every(x => typeof x === 'string' && x && !path.isAbsolute(x) && !x.split('/').includes('..'))) {
      die(`repo "${key}": batch.${k} must be an array of relative paths inside the repository, with no ".."`)
    }
  }
}

// Is this landing run batched, and how many entries at most? `--no-batch` and
// `--batch` override the config in either direction; `--batch` on a repo with no
// `batch` key uses the default maximum.
function batchFor (repo, args) {
  if (args['--batch'] && args['--no-batch']) die('pass --batch or --no-batch, not both')
  if (args['--no-batch']) return null
  if (args['--batch']) return { max: repo.batch?.max ?? BATCH_DEFAULT_MAX }
  return repo.batch?.max ? { max: repo.batch.max } : null
}

// A LANE IS A SET OF PATHS WITH ITS OWN SETUP AND GATE. Every repo has lanes
// once it is loaded: a repo that declares none gets one implicit lane, named
// after the repo, taking every path, with the repo-level keys moved onto it.
// Everything after this function reads `repo.lanes` and never the repo-level
// keys, which is what makes a repo without `lanes` behave exactly as it did
// before lanes existed.
const LANE_KEYS = ['setupWhen', 'setup', 'gate', 'gateEnv', 'gateModifies', 'finalCheck', 'protectedPaths', 'deploy', 'reach']

function loadLanes (key, repo) {
  if (repo.lanes === undefined) {
    const lane = { paths: '*' }
    for (const k of LANE_KEYS) if (repo[k] !== undefined) lane[k] = repo[k]
    for (const k of LANE_KEYS) delete repo[k]
    repo.shared = []
    checkGateModifies(key, key, lane)
    return { [key]: finishLane(lane) }
  }
  if (!repo.lanes || typeof repo.lanes !== 'object' || Array.isArray(repo.lanes) || !Object.keys(repo.lanes).length) {
    die(`repo "${key}": "lanes" must be an object naming at least one lane`)
  }
  for (const k of LANE_KEYS) {
    if (repo[k] !== undefined) {
      die(`repo "${key}" declares "lanes", so "${k}" belongs inside a lane, not at repo level — move it into the lane it governs`)
    }
  }
  if (repo.shared !== undefined && !(Array.isArray(repo.shared) && repo.shared.every(p => typeof p === 'string'))) {
    die(`repo "${key}": "shared" must be an array of path prefixes`)
  }
  repo.shared ||= []
  const lanes = {}
  let catchAll = null
  for (const [name, lane] of Object.entries(repo.lanes)) {
    if (!lane || typeof lane !== 'object' || Array.isArray(lane)) die(`repo "${key}": lane "${name}" must be an object`)
    const p = lane.paths
    if (p === '*') {
      if (catchAll) die(`repo "${key}": lanes "${catchAll}" and "${name}" both take "*" — only one lane may`)
      catchAll = name
    } else if (!(Array.isArray(p) && p.length && p.every(x => typeof x === 'string'))) {
      die(`repo "${key}": lane "${name}" needs "paths", an array of path prefixes or the string "*"`)
    }
    lanes[name] = finishLane({ ...lane })
    checkReach(key, name, lanes[name])
    checkGateModifies(key, name, lanes[name])
  }
  return lanes
}

// A lane's `reach` is how code outside the lane can still break it. Its `when`
// is a command run in the branch's worktree with the changed paths on stdin
// (one per line); exit 0 means the change reaches this lane, so the entry
// carries the lane too, and exit 1 means it does not. `gate` is what the entry
// runs for the lane when only `reach` put it there (the lane's own `gate` runs
// when the entry changed a path of the lane itself).
function checkReach (key, name, lane) {
  if (lane.reach === undefined) return
  const r = lane.reach
  if (!r || typeof r !== 'object' || Array.isArray(r) || typeof r.when !== 'string' || !r.when.trim()) {
    die(`repo "${key}": lane "${name}" has "reach", which needs a "when" command (exit 0 = the change reaches this lane)`)
  }
  if (r.gate !== undefined && !(Array.isArray(r.gate) && r.gate.every(x => typeof x === 'string'))) {
    die(`repo "${key}": lane "${name}": reach.gate must be an array of commands`)
  }
}

// `gateModifies`: path prefixes (relative to the repository root) a gate step of the lane may
// change in the entry's worktree, such as a lockfile an install rewrites. Empty by default. The
// commit binding does not count a tracked change under one of them as a change during the gate.
function checkGateModifies (key, name, lane) {
  const v = lane.gateModifies
  if (v === undefined) return
  if (!Array.isArray(v) || !v.every(x => typeof x === 'string' && x && !path.isAbsolute(x) && !x.split('/').includes('..'))) {
    die(`repo "${key}": lane "${name}": gateModifies must be an array of relative path prefixes inside the repository, with no ".."`)
  }
}

function finishLane (lane) {
  lane.gate ||= []
  lane.setup ||= []
  lane.protectedPaths ||= []
  return lane
}

// Brackets, lane by lane in the output, appear only for a repo with more than
// one lane, so a one-lane repo prints what it printed before lanes existed.
function multiLane (repo) { return Object.keys(repo.lanes).length > 1 }

// The lanes one path belongs to, by the lanes' own rules: under `shared` it belongs to every
// lane, under a lane's prefix to that lane, and any other path to the lane that takes "*".
// A path that matches no lane at all (no "*" lane in the repo) belongs to none.
function lanesForPath (repo, p) {
  const names = Object.keys(repo.lanes)
  if (repo.shared.some(s => p.startsWith(s))) return names
  const owners = names.filter(n => Array.isArray(repo.lanes[n].paths) && repo.lanes[n].paths.some(s => p.startsWith(s)))
  if (owners.length) return owners
  const catchAll = names.find(n => repo.lanes[n].paths === '*')
  return catchAll ? [catchAll] : []
}

// Which lanes does a branch touch? The paths its diff against the merge base
// with `mainBranch` changes, each mapped to lanes: a path under a lane's prefix
// belongs to that lane, a path under `shared` belongs to every lane, and a path
// no lane claims belongs to the lane that takes "*". A repo with no such lane
// refuses the path by name. An empty diff (a cleanup-only entry) has no lanes.
// The result is an array of lane names in config order, without duplicates.
//
// A batch candidate is not a branch cut from `main`, so it names its own base
// (`base`: the candidate tip the entry was put on) and asks to be told of a
// failure by an exception (`fail`) rather than by the process ending.
function lanesOf (repo, cwd, branch, out = {}, { base: given = null, fail = die } = {}) {
  let from = given
  if (!from) {
    const base = gitTry(['merge-base', repo.mainBranch, branch], cwd)
    if (!base.ok) fail(`cannot find where "${branch}" left ${repo.mainBranch} to work out its lanes: ${base.err}`)
    from = base.out
  }
  const diff = gitTry(['diff', '--name-only', from, branch], cwd)
  if (!diff.ok) fail(`cannot list the files "${branch}" changes to work out its lanes: ${diff.err}`)
  const names = Object.keys(repo.lanes)
  const hit = new Set()
  const changed = diff.out.split('\n').filter(Boolean)
  for (const p of changed) {
    const owners = lanesForPath(repo, p)
    if (!owners.length) fail(`"${branch}" changes ${p}, which no lane of ${repo.key} claims and no lane takes "*"`)
    owners.forEach(n => hit.add(n))
  }
  // REACH: a lane the paths above did not put in the entry can still be broken
  // by them (a test in one lane that bundles a file of another). The lane says
  // so with `reach.when`, and the entry then carries the lane as well. The
  // question is asked only of a lane the diff did not already hit, and only
  // when the diff is not empty.
  const reached = []
  if (changed.length) {
    for (const n of names) {
      const r = repo.lanes[n].reach
      if (hit.has(n) || !r) continue
      const res = spawnSync('bash', ['-c', r.when], { cwd, input: changed.join('\n') + '\n', encoding: 'utf8', env: process.env })
      if (res.status === 0) { hit.add(n); reached.push(n) }
      else if (res.status !== 1) {
        // The command could not answer (missing script, crash). A lane's tests are
        // not skipped on a failure to ask, so the lane is counted as reached.
        console.log(red(`  lane ${n}: reach check exited ${res.status}${res.error ? ` (${res.error.message})` : ''} — counting the lane as reached`))
        hit.add(n); reached.push(n)
      }
    }
  }
  out.reached = names.filter(n => reached.includes(n))
  return names.filter(n => hit.has(n))
}

// The lanes an entry's setup and gate run for. An entry with no lanes (empty
// diff) runs nothing, except in a one-lane repo, where it still runs the one
// lane exactly as it did before lanes existed. A multi-lane entry runs the
// setup and gate of each lane it touches, one lane after another in config
// order.
function laneNamesFor (repo, entry) {
  if (entry.lanes && entry.lanes.length) return entry.lanes.filter(n => repo.lanes[n])
  return multiLane(repo) ? [] : Object.keys(repo.lanes)
}

// The lanes an entry holds in the queue: the lanes a stalled entry blocks, and
// the lanes an entry waits on when another entry has stalled. It is
// `laneNamesFor` with one difference: an entry that carries no `lanes` at all
// (enqueued before lanes existed) holds every lane, because nobody has worked
// out which lanes it touches. So in a one-lane repo every entry holds the one
// lane, a cleanup-only entry included, and a stall there holds everything
// behind it, as it always has. In a multi-lane repo a cleanup-only entry holds
// no lane, and no stall ever blocks it.
function queueLanesOf (repo, entry) {
  if (!Array.isArray(entry.lanes)) return Object.keys(repo.lanes)
  return laneNamesFor(repo, entry)
}

// "lane a" or "lanes a, b", for the console and the stall report.
function lanePhrase (names) {
  return `${names.length === 1 ? 'lane' : 'lanes'} ${names.join(', ')}`
}

// An entry's lanes as `status` shows them: a lane the entry reached through the
// import graph and not through its own paths carries "~".
function laneLabels (entry) {
  return (entry.lanes || []).map(n => (entry.reached || []).includes(n) ? `${n}~` : n)
}

// The steps an entry runs for one of its lanes: the lane's own gate, or, where
// the lane was only reached, its `reach.gate` (the lane's gate when it has none).
function gateStepsFor (repo, entry, name) {
  const lane = repo.lanes[name]
  const onlyReached = (entry.reached || []).includes(name)
  return onlyReached && lane.reach?.gate ? lane.reach.gate : lane.gate
}

// The stalled entries of a repo, in queue order.
function stalledIn (key, entries) {
  return entries.filter(e => e.repo === key && e.status === 'stalled')
}

// Every lane some stalled entry of this repo holds.
function blockedLanes (repo, entries) {
  return new Set(stalledIn(repo.key, entries).flatMap(e => queueLanesOf(repo, e)))
}

// Does a stall hold this entry back? An approved entry waits while any stalled
// entry of its repo shares a lane with it. A stalled entry that `resume` is
// about to retry waits only on a stalled entry AHEAD of it that shares a lane,
// so two stalls in one lane still land in queue order, and neither waits on
// itself.
function heldByStall (repo, entry, entries) {
  const mine = queueLanesOf(repo, entry)
  if (!mine.length) return false
  const at = entries.indexOf(entry)
  return entries.some((e, i) =>
    e !== entry && e.repo === repo.key && e.status === 'stalled' &&
    (entry.status !== 'stalled' || i < at) &&
    queueLanesOf(repo, e).some(n => mine.includes(n)))
}

// `protectedPaths` is read before an entry's lanes are final (a conflict
// stops the rebase that would settle them), so every lane's prefixes count.
// That is also the rule itself: protected content is the owner's whatever lane
// it sits in, so a conflict in any lane's protected path is the owner's call.
function protectedOf (repo) {
  return Object.values(repo.lanes).flatMap(l => l.protectedPaths)
}

// The deploy marker is a property of the host that builds a lane. A lane with a
// `deploy.skipMarker` has one; a lane without writes none and is never settled.
// Returns the names of the lanes that have one, in config order.
function deployLanes (repo) {
  return Object.keys(repo.lanes).filter(n => repo.lanes[n].deploy?.skipMarker)
}

// Is the lane's last build one the host was told to skip? The question is asked
// of `main` and never of the queue's memory.
//
// A "*" lane takes every path, so its host builds every push and the answer is
// the tip, as it was before lanes existed. Any other lane's host is filtered
// by path, so only a commit that changes one of its paths (its prefixes or a
// `shared` prefix), or an empty commit, makes it build. The rule walks the
// first-parent history of `main` from the tip and stops at the first commit
// that is either of those; the lane is undeployed when that commit carries the
// marker. A plain `git log -- <paths>` fails twice here: without `--first-parent`
// it follows the branch side of a `--no-ff` merge and returns the branch's own
// commit, never the merge that carries the marker; with it, an empty commit
// changes no path and never appears, so every later run would republish again.
// An empty commit counts for every lane, because a path-filtered host must
// build one (see the README), so any unmarked empty commit means every lane's
// host built.
function laneUndeployed (repo, name) {
  const lane = repo.lanes[name]
  const marker = lane.deploy?.skipMarker
  if (!marker) return false
  const cwd = repo.checkout
  if (lane.paths === '*') {
    const tip = gitTry(['log', '-1', '--format=%B', repo.mainBranch], cwd)
    return tip.ok && tip.out.includes(marker)
  }
  // A prefix is matched the way `lanesOf` matches it, by `startsWith`, so the
  // pathspec is the prefix followed by a glob, with the prefix's own glob
  // characters escaped.
  const specs = [...lane.paths, ...repo.shared].map(p => `:(top)${p.replace(/[*?[\\]/g, '\\$&')}*`)
  const touch = gitTry(['log', '-1', '--first-parent', '--format=%H', repo.mainBranch, '--', ...specs], cwd)
  const touchSha = touch.ok ? touch.out : ''
  let stop = touchSha
  // Empty commits after the last commit that touched the lane, newest first. A
  // commit is empty when its tree equals its first parent's tree, and the
  // first parent of each commit in this list is the next one down it.
  const range = touchSha ? `${touchSha}..${repo.mainBranch}` : repo.mainBranch
  const after = gitTry(['log', '--first-parent', '--format=%H %T', range], cwd)
  if (after.ok && after.out) {
    const rows = after.out.split('\n').map(l => l.split(' '))
    const below = touchSha ? gitTry(['rev-parse', `${touchSha}^{tree}`], cwd) : null
    for (let i = 0; i < rows.length; i++) {
      const parentTree = i + 1 < rows.length ? rows[i + 1][1] : (below && below.ok ? below.out : null)
      if (parentTree && rows[i][1] === parentTree) { stop = rows[i][0]; break }
    }
  }
  if (!stop) return false
  const msg = gitTry(['log', '-1', '--format=%B', stop], cwd)
  return msg.ok && msg.out.includes(marker)
}

// ─── locks: a directory, created whole, owned by a token ─────────────────────────
//
// A lock is a directory holding `owner.json` ({pid, token, since}). It is CREATED
// COMPLETE: the directory and its owner file are built beside the lock and
// renamed into place, which fails when the lock exists, so there is never a lock
// with no owner for a second process to misjudge.
//
// A lock's holder is alive or it is not. A lock whose holder process is gone is
// debris and is broken; a lock whose holder is alive is never broken, however
// long it has been held (a hung holder is reported by `status`, and a command
// that waits on it fails with the holder's pid and age). Breaking is serialised
// by a second lock, the breaker's, and the breaker moves the lock aside only if it
// is exactly the lock it judged stale (same token); otherwise it puts it back. A
// release removes the lock only if the token in it is the releaser's own, so a
// process whose lock was broken can never delete the lock of the one that took
// over. A lock with no owner file (left by a version before this one, or by a
// holder killed mid-create) is debris once it has sat untouched for five seconds.
const newToken = () => `${process.pid}-${crypto.randomBytes(8).toString('hex')}`
function sleepMs (ms) { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms) }

function lockOwner (dir) { return readJSON(path.join(dir, 'owner.json'), null) }

function lockCreate (dir, token) {
  fs.mkdirSync(path.dirname(dir), { recursive: true })
  const tmp = `${dir}.new-${token}`
  fs.mkdirSync(tmp)
  try {
    fs.writeFileSync(path.join(tmp, 'owner.json'), JSON.stringify({ pid: process.pid, token, since: nowISO() }))
    fs.renameSync(tmp, dir)
    return true
  } catch (e) {
    fs.rmSync(tmp, { recursive: true, force: true })
    if (['EEXIST', 'ENOTEMPTY', 'EISDIR', 'ENOTDIR'].includes(e.code)) return false
    throw e
  }
}

// Why this lock is debris, or null. A live holder is never stale.
function lockStale (dir) {
  const o = lockOwner(dir)
  if (o && Number.isInteger(o.pid)) {
    if (pidAlive(o.pid)) return null
    if (groupAlive(o.gatePgid)) return null          // the run is dead, its gate is not: the lock is still held
    return `its holder, pid ${o.pid}, is gone`
  }
  try { if (Date.now() - fs.statSync(dir).mtimeMs > 5000) return 'it has no owner' } catch { /* released while we looked */ }
  return null
}

const sameOwner = (a, b) => (!a && !b) || (a && b && (a.token && b.token ? a.token === b.token : a.pid === b.pid && a.since === b.since))

// Break the lock that `judged` (the owner read when it was judged stale) describes.
// True when that lock is gone.
function lockBreak (dir, judged) {
  const guard = `${dir}.breaker`
  const t = newToken()
  if (!lockCreate(guard, t)) {
    if (lockStale(guard)) {                          // a breaker that died holding it
      const away = `${guard}.away-${t}`
      try { fs.renameSync(guard, away); fs.rmSync(away, { recursive: true, force: true }) } catch { /* another got there */ }
    }
    return false
  }
  try {
    if (!sameOwner(lockOwner(dir), judged) || !lockStale(dir)) return false   // it changed hands meanwhile
    const away = `${dir}.away-${t}`
    try { fs.renameSync(dir, away) } catch { return false }
    if (!sameOwner(lockOwner(away), judged)) {       // what moved is not what was judged: put it back
      try { fs.renameSync(away, dir) } catch { /* the path was taken meanwhile */ }
      return false
    }
    fs.rmSync(away, { recursive: true, force: true })
    return true
  } finally {
    lockRelease(guard, t)
  }
}

// Take the lock, waiting up to `waitMs` for a live holder. Returns {token}, or
// {token: null, owner} when a live holder still has it. `onBroken` is told of each
// stale lock it breaks.
function lockAcquire (dir, { waitMs = 0, onBroken = () => {} } = {}) {
  const token = newToken()
  const deadline = Date.now() + waitMs
  while (true) {
    if (lockCreate(dir, token)) return { token }
    const owner = lockOwner(dir)
    const why = lockStale(dir)
    if (why) {
      if (lockBreak(dir, owner)) onBroken(owner, why)
      else sleepMs(5 + Math.floor(Math.random() * 15))
      continue
    }
    if (Date.now() >= deadline) return { token: null, owner }
    sleepMs(20 + Math.floor(Math.random() * 40))
  }
}

// Remove the lock only if it is still ours.
function lockRelease (dir, token) {
  if (!token) return
  const o = lockOwner(dir)
  if (!o || o.token !== token) return                // guard 1: the lock is not ours, so it is not touched at all
  const seam = process.env.LOCAL_MERGE_QUEUE_TEST_RELEASE_SEAM      // a test seam: stop between the two guards
  if (seam) {
    fs.writeFileSync(`${seam}.checked`, '')
    for (let i = 0; i < 200 && !fs.existsSync(`${seam}.go`); i++) sleepMs(50)
  }
  const away = `${dir}.gone-${token}`
  try { fs.renameSync(dir, away) } catch { return }
  if (lockOwner(away)?.token !== token) {            // guard 2: not ours after all (it changed hands in between): put it back
    try { fs.renameSync(away, dir) } catch { /* taken meanwhile */ }
    return
  }
  fs.rmSync(away, { recursive: true, force: true })
}

// How long a lock has been held, for the messages that name its holder.
function lockAge (owner) {
  const ms = Date.now() - Date.parse(owner?.since)
  if (!Number.isFinite(ms)) return '?'
  return ms < 90000 ? `${Math.round(ms / 1000)}s` : `${Math.round(ms / 60000)} min`
}

// ─── the queue file: one writer at a time, and every write is its own change ───
//
// THE QUEUE FILE IS SHARED BY EVERY SESSION ON THE MACHINE, AND A LANDING RUN
// TAKES MINUTES. A command that reads the queue, works, and writes its copy back
// erases whatever any other process wrote in between: on 2026-11-21 two entries
// were enqueued and approved while `land` ran in another process, and the run's
// write at the end took both out of the queue.
//
// So no command holds a copy of the queue across any work. Every write goes
// through `mutateQueue`: take the queue lock, READ THE FILE AGAIN, apply that
// command's own change to what is there now, write, release. The critical
// section holds no git call and no gate, so the lock is held for milliseconds.
const QUEUE_LOCK_WAIT_MS = Number(process.env.LOCAL_MERGE_QUEUE_LOCK_WAIT_MS) || 30000
let queueLockToken = null

function acquireQueueLock () {
  const got = lockAcquire(QUEUE_LOCK, {
    waitMs: QUEUE_LOCK_WAIT_MS,
    onBroken: (o, why) => console.error(yellow(`local-merge-queue: broke a stale queue lock (${why})`))
  })
  if (!got.token) {
    die(`the queue file stayed locked for ${QUEUE_LOCK_WAIT_MS / 1000}s by pid ${got.owner?.pid ?? '?'}, alive and holding it for ${lockAge(got.owner)} — a hung process? ` +
        `A lock is only broken once its holder is gone; end that process, or run \`local-merge-queue status\`.`)
  }
  queueLockToken = got.token
}

function releaseQueueLock () {
  if (!queueLockToken) return
  const t = queueLockToken
  queueLockToken = null
  lockRelease(QUEUE_LOCK, t)
}
onExit(releaseQueueLock)

// A queue file that exists and cannot be read is a defect to stop on, never an
// empty queue: the next write would replace every entry with one. The error names
// the previous good copy and the command that restores it; nothing is restored
// silently, because the copy is one write older than the file.
const QUEUE_PREV = `${QUEUE_PATH}.prev`
function unreadableQueue (why) {
  const restore = fs.existsSync(QUEUE_PREV)
    ? `The previous good copy is ${QUEUE_PREV}; to restore it:\n    cp "${QUEUE_PREV}" "${QUEUE_PATH}"`
    : `There is no previous copy (${QUEUE_PREV}) to restore.`
  die(`the queue file ${QUEUE_PATH} ${why}, and no command will write to it until it is fixed.\n  ${restore}`)
}
function loadQueue () {
  if (!fs.existsSync(QUEUE_PATH)) return { entries: [] }
  let q
  try { q = JSON.parse(fs.readFileSync(QUEUE_PATH, 'utf8')) } catch (e) { unreadableQueue(`cannot be read (${e.message})`) }
  if (!q || !Array.isArray(q.entries)) unreadableQueue('has no "entries" array')
  return q
}

// Written to a temporary file, flushed to disk, and renamed, so a reader without
// the lock never meets a half-written queue and a crash never leaves one. The copy
// being replaced is kept as `queue.json.prev` first, if it was a good one.
function saveQueue (q) {
  fs.mkdirSync(path.dirname(QUEUE_PATH), { recursive: true })
  try {
    const old = fs.readFileSync(QUEUE_PATH, 'utf8')
    JSON.parse(old)
    const tmpPrev = `${QUEUE_PREV}.tmp-${process.pid}`
    fs.writeFileSync(tmpPrev, old)
    fs.renameSync(tmpPrev, QUEUE_PREV)
  } catch { /* no file yet, or not a good one: there is nothing worth keeping */ }
  const tmp = `${QUEUE_PATH}.tmp-${process.pid}`
  const fd = fs.openSync(tmp, 'w')
  try { fs.writeSync(fd, JSON.stringify(q, null, 2) + '\n'); fs.fsyncSync(fd) } finally { fs.closeSync(fd) }
  fs.renameSync(tmp, QUEUE_PATH)
}

// Temporary files a killed writer left behind, older than an hour, by exact name
// pattern (`queue.json.tmp-<pid>`, `queue.json.prev.tmp-<pid>`, and the
// `queue.lock.new-`, `.away-` and `.gone-` directories of an interrupted lock).
let sweptTemps = false
function sweepQueueTemps () {
  if (sweptTemps) return
  sweptTemps = true
  let names = []
  try { names = fs.readdirSync(STATE_DIR) } catch { return }
  for (const n of names) {
    if (!/^queue\.json(\.prev)?\.tmp-\d+$/.test(n) && !/^queue\.lock\.(new|away|gone)-[\w-]+$/.test(n)) continue
    const f = path.join(STATE_DIR, n)
    try { if (Date.now() - fs.statSync(f).mtimeMs > 3600000) fs.rmSync(f, { recursive: true, force: true }) } catch { /* gone */ }
  }
}

// Read the queue afresh under the lock, let `fn` change it, write it back if it
// changed, and return what `fn` returned. `fn` must not run git, a gate, or
// anything else slow, and must not call `die` for a reason it could check first.
function mutateQueue (fn) {
  acquireQueueLock()
  try {
    sweepQueueTemps()
    const q = loadQueue()
    const before = JSON.stringify(q, null, 2) + '\n'
    const result = fn(q)
    if (process.env.LOCAL_MERGE_QUEUE_TEST_PAUSE_IN_LOCK) {      // a test seam: hold the lock until a file appears
      for (let i = 0; i < 200 && !fs.existsSync(process.env.LOCAL_MERGE_QUEUE_TEST_PAUSE_IN_LOCK); i++) sleepMs(50)
    }
    if (JSON.stringify(q, null, 2) + '\n' !== before || !fs.existsSync(QUEUE_PATH)) saveQueue(q)
    return result
  } finally {
    releaseQueueLock()
  }
}

const sameEntry = (e, entry) => e.repo === entry.repo && e.branch === entry.branch

// Change one entry of the queue as it stands NOW. Returns false when the entry
// is gone (dequeued during the run), in which case nothing is written: a run
// never brings back an entry somebody removed.
function patchEntry (entry, fields, drop = []) {
  return mutateQueue(q => {
    const e = q.entries.find(x => sameEntry(x, entry))
    if (!e) return false
    Object.assign(e, fields)
    for (const k of drop) delete e[k]
    return true
  })
}

function removeEntry (entry) {
  mutateQueue(q => { q.entries = q.entries.filter(x => !sameEntry(x, entry)) })
}

// The entry as the queue holds it now, or null.
function freshEntry (entry) {
  return loadQueue().entries.find(x => sameEntry(x, entry)) || null
}

function repoOf (cfg, key) {
  const r = cfg.repos[key]
  if (!r) die(`unknown repo "${key}". Known: ${Object.keys(cfg.repos).join(', ')}`)
  return r
}

// Identify which configured repo the cwd belongs to, and which branch it holds.
function detectHere (cfg) {
  let top
  try { top = real(git(['rev-parse', '--show-toplevel'], process.cwd())) } catch { return null }
  const branch = git(['rev-parse', '--abbrev-ref', 'HEAD'], top)
  // The main worktree of this repo is the first line of `git worktree list`.
  const primary = real(git(['worktree', 'list', '--porcelain'], top)
    .split('\n')[0].replace(/^worktree /, ''))
  for (const repo of Object.values(cfg.repos)) {
    if (repo.checkout === primary) return { repo, branch, worktree: top }
  }
  return null
}

function worktreeFor (repo, branch) {
  const out = git(['worktree', 'list', '--porcelain'], repo.checkout)
  let cur = null
  for (const line of out.split('\n')) {
    if (line.startsWith('worktree ')) cur = line.slice(9)
    else if (line.startsWith('branch ') && line.slice(7) === `refs/heads/${branch}`) return cur
  }
  return null
}

// An entry may declare `after: "<branch>"` or `after: "<repo>:<branch>"` —
// mobile-parity behind the website's cowriter-remote is the live case. A
// dependency counts as met only when it has actually landed, which means: gone
// from the queue AND either gone from its repo or already merged into its main.
// An `after` naming something nobody enqueued is treated as unmet, loudly,
// rather than silently passing.
function dependencyMet (cfg, entry, queued, simulated, quiet = false) {
  const spec = entry.after.includes(':') ? entry.after : `${entry.repo}:${entry.after}`
  const [depRepoKey, depBranch] = spec.split(':')
  if (simulated.has(depBranch)) return true
  if (queued.has(spec)) return false                        // still waiting its turn
  const depRepo = cfg.repos[depRepoKey]
  if (!depRepo) { if (!quiet) console.error(yellow(`  "${entry.branch}" waits on unknown repo "${depRepoKey}" — treating as unmet`)); return false }
  const exists = gitTry(['rev-parse', '--verify', `refs/heads/${depBranch}`], depRepo.checkout).ok
  if (!exists) return true                                  // deleted on landing
  const merged = gitTry(['merge-base', '--is-ancestor', depBranch, depRepo.mainBranch], depRepo.checkout).ok
  if (!merged) {
    if (!quiet) console.error(yellow(`  holding "${entry.branch}" — it waits on ${spec}, which has not landed`))
    return false
  }
  return true
}

// Would this entry be picked up by THIS landing run? One predicate, used twice:
// once to choose the next entry to land, and once to ask whether anything is
// still behind the entry being landed — which is what decides whether its merge
// commit carries the skip marker (see `moreEligibleAfter`). Two copies of this
// rule would be two answers to the same question.
//
// `held` names the entries this run has already given up on: the ones that
// stalled during it and the ones `resume` found unready. A run never retries
// them, which is what lets the loop carry on past a stall without meeting the
// same entry again.
function eligible (cfg, entry, key, { queued, simulated, resuming, held = new Set(), quiet = false }) {
  if (entry.repo !== key) return false
  if (simulated.has(entry.branch)) return false
  if (held.has(entry.branch)) return false
  if (entry.status !== 'approved' && !(resuming && entry.status === 'stalled')) return false
  if (heldByStall(cfg.repos[key], entry, [...queued.values()])) return false
  if (entry.after && !dependencyMet(cfg, entry, queued, simulated, quiet)) return false
  return true
}

// Is there another entry this run will land after `entry`? Asked of the queue as
// it stands RIGHT NOW rather than of the snapshot taken before the gate ran,
// because a gate takes minutes and an entry can be dequeued inside them — and a
// wrong answer here is what would leave production sitting on a build nobody
// asked the host to make. It is only ever a lookahead, though: the entry behind
// this one may still stall, or turn out to be cleanup-only and push nothing. The
// end-of-run settle (`settleDeploy`) is what makes those cases safe.
//
// With a `lane`, only another entry that holds that lane counts, since the
// marker is per lane: an entry behind this one in another lane builds a
// different host.
function moreEligibleAfter (cfg, key, entry, { queue, simulated, resuming, held, lane }) {
  const q = queue || loadQueue()
  const queued = new Map(q.entries.map(e => [`${e.repo}:${e.branch}`, e]))
  return q.entries.some(e =>
    !(e.repo === entry.repo && e.branch === entry.branch) &&
    (!lane || queueLanesOf(cfg.repos[key], e).includes(lane)) &&
    eligible(cfg, e, key, { queued, simulated, resuming, held, quiet: true }))
}

// ─── locking ────────────────────────────────────────────────────────────────

// The repository's landing lock: one land per repo at a time. Same lock as the
// queue file's, with no wait: a live holder means a run is in progress.
let repoLockTokens = new Map()
function acquireLock (key) {
  const dir = path.join(LOCK_DIR, key)
  const got = lockAcquire(dir, {
    onBroken: (o, why) => console.error(yellow(`local-merge-queue: breaking a stale lock left by pid ${o?.pid ?? '?'} (${why})`))
  })
  if (!got.token) return null
  repoLockTokens.set(key, got.token)
  gateLock = { dir, token: got.token }
  onExit(() => releaseLock(key))
  return dir
}

function releaseLock (key) {
  const t = repoLockTokens.get(key)
  if (!t) return
  repoLockTokens.delete(key)
  if (gateLock?.token === t) gateLock = null
  lockRelease(path.join(LOCK_DIR, key), t)
}

// ─── the pull request, which is the roster ──────────────────────────────────

// A branch's row used to be a line in a hand-kept BRANCHES.md that this function
// deleted on landing. The pull request replaced that file on 2026-08-19, and it
// needs no deleting: the merge makes the branch's head reachable from main and
// GitHub closes the PR as merged without being asked.
//
// So the job here is no longer to WRITE the record but to VERIFY it, because a
// PR left open is now the only way `gh pr list` can lie about what is in flight.
// It reports; it never fails a landing. The merge is already pushed by the time
// this runs, and an unreachable GitHub is not a reason to call a landed branch
// unlanded.
function prFor (repo, branch, extraArgs = []) {
  if (!repo.githubRepo) return null
  const r = spawnSync('gh', ['pr', 'list', '-R', repo.githubRepo, '--head', branch,
                             '--json', 'number,state,isDraft', '--limit', '1', ...extraArgs],
                      { encoding: 'utf8' })
  if (r.status !== 0) return null
  try { return (JSON.parse(r.stdout || '[]'))[0] || null } catch { return null }
}

// Wait, briefly, for GitHub to register the PR as merged. Returns true once it
// has. See the long note at the remote-branch deletion for why this exists and
// what goes permanently wrong without it. Bounded on purpose: a landing run must not
// hang on GitHub being slow, and the caller's fallback (keep the branch, say so)
// is a safe place to land.
function waitForPrMerged (repo, branch, tries = 6, gapMs = 2500) {
  for (let i = 0; i < tries; i++) {
    const pr = prFor(repo, branch, ['--state', 'all'])
    if (pr && pr.state === 'MERGED') return true
    if (i < tries - 1) {
      if (i === 0) console.log(dim('  waiting for the pull request to register as merged…'))
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, gapMs)
    }
  }
  return false
}

// A PULL REQUEST STACKED ON THE BRANCH BEING LANDED IS CLOSED BY THE DELETION
// BELOW, AND CANNOT BE REOPENED. Work arrives in chains — each branch cut from
// the one before it, each PR based on its predecessor rather than on `main` —
// and GitHub closes a pull request the moment its BASE branch disappears.
// `gh pr reopen` answers "Could not open the pull request"; `gh pr edit --base`
// answers "Cannot change the base branch of a closed pull request". So the
// roster records live work as abandoned, and the only repair is opening a
// replacement PR by hand, which is what happened to #91 on 2026-09-05 when
// `templates-rename` landed underneath it.
//
// The fix is to move those PRs onto `main` first. It runs after the merge is
// pushed, so a retargeted PR's diff is the stack minus what just landed, and
// before the remote branch is deleted, which is the act that would close them.
//
// A failure here is REPORTED AND NOT FATAL. The branch is already on `main`; a
// missed retarget is a defect in the roster rather than in the code, and
// stopping the cleanup over one would leave a worktree and two branch refs
// behind to fix the smaller of the two problems.
function retargetStackedPrs (repo, branch) {
  if (!repo.githubRepo) return
  const r = spawnSync('gh', ['pr', 'list', '-R', repo.githubRepo, '--base', branch,
                             '--state', 'open', '--json', 'number,headRefName'],
                      { encoding: 'utf8' })
  if (r.status !== 0) {
    console.log(red(`  COULD NOT LIST THE PULL REQUESTS BASED ON ${branch}: ${(r.stderr || '').trim() || '(no stderr)'}`))
    console.log(red('  Any PR stacked on it will close as abandoned when the branch goes.'))
    return
  }
  let prs = []
  try { prs = JSON.parse(r.stdout || '[]') } catch { prs = [] }
  for (const pr of prs) {
    const e = spawnSync('gh', ['pr', 'edit', String(pr.number), '-R', repo.githubRepo,
                               '--base', repo.mainBranch], { encoding: 'utf8' })
    if (e.status === 0) {
      console.log(dim(`  pr #${pr.number} (${pr.headRefName}) retargeted from ${branch} onto ${repo.mainBranch}`))
    } else {
      console.log(red(`  RETARGETING PR #${pr.number} (${pr.headRefName}) ONTO ${repo.mainBranch} FAILED: ${(e.stderr || '').trim() || '(no stderr)'}`))
      console.log(red(`  It is based on ${branch} and will close as abandoned when that branch goes.`))
    }
  }
}

function reportPrState (repo, branch) {
  if (!repo.githubRepo) return 'no github repo configured'
  const pr = prFor(repo, branch, ['--state', 'all'])
  if (!pr) return 'no pull request found for this branch'
  if (pr.state === 'MERGED') return `#${pr.number} closed as merged`
  return { warn: `PR #${pr.number} is ${pr.state}, not MERGED — the branch landed but its pull request does not say so` }
}

// ─── preflight ──────────────────────────────────────────────────────────────

// A dirty primary checkout is somebody else's in-flight work; merging onto it
// would sweep their edits into the landing. Refuse, and name what is dirty.
function preflight (repo) {
  const problems = []
  const branch = git(['rev-parse', '--abbrev-ref', 'HEAD'], repo.checkout)
  if (branch !== repo.mainBranch) {
    problems.push(`primary checkout is on "${branch}", not "${repo.mainBranch}"`)
  }
  const dirty = git(['status', '--porcelain'], repo.checkout)
  if (dirty) {
    problems.push(`primary checkout has uncommitted changes:\n${dirty.split('\n').map(l => '      ' + l).join('\n')}`)
  }
  return problems
}

// ─── what the gate vouched for ──────────────────────────────────────────────

/**
 * THE GATE'S CLAIM IS THAT IT RAN ON EXACTLY WHAT WILL LAND, so the merge is bound
 * to the commit the gate ran on and not to whatever the branch ref holds later.
 *
 * Found by the independent re-check of 2026-11-21: a commit made in the entry's
 * worktree during the gate (which takes minutes, and on a loaded machine an hour)
 * moved the branch, and the merge, which named the branch, landed a tree the gate
 * had never seen. So after the setup, and before the gate runs, the run records
 * the branch's commit and the worktree's status; after the gate and again right
 * before the merge it asks whether either changed, and stalls the entry if so; and
 * the publish and the merge name the recorded commit, never the branch.
 *
 * What counts as a change in the worktree is a tracked file that differs from the
 * record (an edit, a staged change, a deletion). An untracked file is not a change
 * to what lands, since only commits land, and it does not stall the entry; cleanup
 * is what keeps such a file safe (`cleanupLanded`).
 */
// `ignored` adds the ignored files and directories (`!! path`), which the binding does not
// care about and cleanup does (`git worktree remove --force` deletes them).
// (Not through `gitTry`, which trims its output: the first status line begins with a space.)
const statusLines = (wt, { ignored = false } = {}) =>
  (spawnSync('git', ['status', '--porcelain', ...(ignored ? ['--ignored=traditional'] : [])], { cwd: wt, encoding: 'utf8' }).stdout || '').split('\n').filter(Boolean)
const trackedOnly = lines => lines.filter(l => !l.startsWith('??') && !l.startsWith('!!'))

function recordBinding (repo, entry, wt) {
  const head = gitTry(['rev-parse', 'HEAD'], wt)
  const ref = gitTry(['rev-parse', '--verify', '-q', `refs/heads/${entry.branch}`], repo.checkout)
  if (!head.ok || !ref.ok || head.out !== ref.out) return { error: `the worktree is not on the tip of ${entry.branch}` }
  return { sha: head.out, status: statusLines(wt) }
}

// A porcelain status line's path (both sides of a rename).
const statusPaths = l => l.slice(3).split(' -> ')

// Why the gate no longer vouches for what would land, or null. A tracked change under a
// `gateModifies` prefix of one of the lanes the entry gated is the gate's own doing.
function bindingBroken (repo, entry, wt, rec, gatedLanes = []) {
  const allowed = gatedLanes.flatMap(n => repo.lanes[n]?.gateModifies || [])
  const exempt = l => allowed.length > 0 && statusPaths(l).every(p => allowed.some(a => p === a || p.startsWith(a)))
  const short = s => s.slice(0, 9)
  const ref = gitTry(['rev-parse', '--verify', '-q', `refs/heads/${entry.branch}`], repo.checkout)
  if (!ref.ok) return `the branch ${entry.branch} is gone`
  if (ref.out !== rec.sha) return `${entry.branch} moved from ${short(rec.sha)}, the commit the gate ran on, to ${short(ref.out)}`
  const head = gitTry(['rev-parse', 'HEAD'], wt)
  if (!head.ok || head.out !== rec.sha) return `the worktree's HEAD moved from ${short(rec.sha)}, the commit the gate ran on, to ${head.ok ? short(head.out) : '(unreadable)'}`
  const was = trackedOnly(rec.status).filter(l => !exempt(l))
  const now = trackedOnly(statusLines(wt)).filter(l => !exempt(l))
  const differ = [...now.filter(l => !was.includes(l)), ...was.filter(l => !now.includes(l))]
  if (differ.length) {
    return `tracked files in the worktree changed (${differ.map(l => l.trim()).join('; ')}); if a gate step is meant to change such a file, name its path in the lane's "gateModifies"`
  }
  return null
}

// ─── origin's main moved under a passing gate ─────────────────────────────────

/**
 * THE PUSH OF `main` WAS REJECTED, SO DID ORIGIN'S `main` MOVE DURING THE GATE, AND IF IT DID,
 * DID ANYTHING THE GATE COVERED CHANGE?
 *
 * On 2026-11-22 a 54-minute gate passed and the push was rejected as a non-fast-forward
 * because a scheduled bot had pushed one commit to origin's `main` during the gate, changing
 * one data file under a folder outside every lane the entry's gate covered. The run rolled the
 * merge back and exited, and the gate had to be paid again. The remedy is conservative: fetch;
 * if every new commit changes only paths that belong to no lane this entry gated, the merge is
 * redone on the new `main` without a new gate (what merges is still the gated commit), at most
 * twice; in every other case the entry stalls and says `main` moved under a passing gate.
 *
 * A path belongs to a lane by the lanes' own rules (`lanesForPath`; a path no lane claims
 * belongs to none, so it is outside). A lane the entry gated that has a `reach` rule is asked
 * about the commit's paths too, since a path outside the lane can still be one the lane's tests
 * read. A commit is examined by its own changes (against each parent, for a merge), never by
 * the net diff of the range, so a change that a later commit reverts still counts.
 *
 * Returns { moved: false } when origin's `main` is where the run left it (the push failed for
 * another reason), else { moved: true, newTip, commits: [{sha, subject, paths, inside}], blocker }
 * where `blocker` says why the merge may not be redone, or null.
 */
function inspectMovedMain (repo, gatedLanes, wt, base) {
  const main = repo.mainBranch
  const short = x => x.slice(0, 9)
  const fetched = gitTry(['fetch', 'origin', main], repo.checkout)
  const tip = gitTry(['rev-parse', '--verify', '-q', `origin/${main}`], repo.checkout)
  if (!fetched.ok || !tip.ok || tip.out === base) return { moved: false }
  const newTip = tip.out
  if (!gitTry(['merge-base', '--is-ancestor', base, newTip], repo.checkout).ok) {
    return { moved: true, newTip, commits: [], blocker: `origin/${main} was rewritten: it no longer descends from ${short(base)}, the commit the gate ran against` }
  }
  const shas = gitTry(['rev-list', '--reverse', `${base}..${newTip}`], repo.checkout).out.split('\n').filter(Boolean)
  const commits = shas.map(sha => {
    const subject = gitTry(['log', '-1', '--format=%s', sha], repo.checkout).out
    const raw = spawnSync('git', ['diff-tree', '-m', '--root', '-r', '--name-only', '--no-commit-id', '-z', sha], { cwd: repo.checkout, encoding: 'utf8' })
    const paths = [...new Set((raw.stdout || '').split('\0').filter(Boolean))]
    const inside = []                              // how this commit touches what the gate covered
    for (const p of paths) {
      for (const n of lanesForPath(repo, p).filter(n => gatedLanes.includes(n))) {
        if (!inside.some(i => i.lane === n && i.how === 'touches')) inside.push({ lane: n, how: 'touches', path: p })
      }
    }
    if (paths.length) {
      for (const n of gatedLanes) {
        const r = repo.lanes[n].reach
        if (!r || inside.some(i => i.lane === n)) continue
        const res = spawnSync('bash', ['-c', r.when], { cwd: wt, input: paths.join('\n') + '\n', encoding: 'utf8', env: process.env })
        if (res.status !== 1) inside.push({ lane: n, how: 'reaches', path: paths.join(', ') })   // 0 = reached; anything else could not answer, so it counts
      }
    }
    return { sha: gitTry(['log', '-1', '--format=%h', sha], repo.checkout).out, subject, paths, inside }
  })
  const bad = commits.filter(c => c.inside.length)
  const where = i => multiLane(repo) ? `lane ${i.lane}` : 'what the gate covers'
  const blocker = bad.length
    ? `${bad.length === 1 ? 'a commit changes' : `${bad.length} commits change`} what the gate covered: ${bad.map(c => `${c.sha} "${c.subject}" ${c.inside.map(i => `${i.how} ${where(i)} (${i.path})`).join(', ')}`).join('; ')}`
    : null
  return { moved: true, newTip, commits, blocker }
}

// ─── local main must equal origin's before an entry starts ───────────────────

/**
 * A RUN KILLED BETWEEN ITS LOCAL MERGE AND ITS PUSH LEAVES `main` AHEAD OF ORIGIN, and
 * the next run used to read the entry as already landed: the independent re-check
 * (2026-11-21) killed a run during the push, and the next run cleaned up the entry,
 * deleting its worktree and its branch local and remote, though the merge existed
 * nowhere but in the primary checkout. So before an entry starts, `main` is brought to
 * `origin/main` by a fast-forward, and a `main` that is ahead of origin (or has
 * diverged) stops the run with the commits named; nothing is cleaned up or reset
 * for the operator, since the commits may be somebody's own. Returns the problem, or null.
 */
function syncMainWithOrigin (repo) {
  const main = repo.mainBranch
  const fetched = gitTry(['fetch', 'origin', '--prune'], repo.checkout)
  if (!fetched.ok) return `git fetch failed: ${fetched.err}`
  if (!gitTry(['rev-parse', '--verify', '-q', `origin/${main}`], repo.checkout).ok) return `origin has no ${main} branch`
  const extra = gitTry(['log', '--format=%h %s', `origin/${main}..${main}`], repo.checkout).out.split('\n').filter(Boolean)
  if (extra.length) {
    return `${main} in ${repo.checkout} has ${extra.length} commit(s) that origin/${main} does not:\n` +
      extra.slice(0, 5).map(l => `    ${l}`).join('\n') + (extra.length > 5 ? `\n    … and ${extra.length - 5} more` : '') + '\n' +
      `  A landing run killed between its merge and its push leaves exactly this, and no entry has been cleaned up: the entries' branches and worktrees are untouched.\n` +
      `  If these commits are such leftovers, discard them with: git -C ${repo.checkout} reset --hard origin/${main}\n` +
      `  If they are anybody's own work, push or move them first. Then land again.`
  }
  const ff = gitTry(['merge', '--ff-only', `origin/${main}`], repo.checkout)
  if (!ff.ok) return `${main} could not fast-forward to origin: ${ff.err}`
  if (git(['rev-parse', main], repo.checkout) !== git(['rev-parse', `origin/${main}`], repo.checkout)) return `${main} does not equal origin/${main} after the fast-forward`
  return null
}

// ─── the worktree's generated environment ───────────────────────────────────

/**
 * A FRESH WORKTREE IS NOT YET A WORKING CHECKOUT, and the gate runs in one.
 *
 * What a worktree lacks is untracked or generated — `node_modules`, env files,
 * `core.hooksPath`, natively-rebuilt modules — so an agent whose own work needed
 * no build never runs the repo's setup, and the FIRST thing to notice is the
 * merge queue's gate, minutes into a landing run, dying on something that is not the
 * branch's fault. It happened three times on 2026-08-24, twice as `esbuild
 * ENOENT` out of an empty `node_modules` (`fragments-context`,
 * `tour-tray-vestige`), and each one cost a person a diagnose-install-resume
 * cycle for a queue whose whole purpose is not needing one.
 *
 * So the merge queue fills the environment in itself. `setupWhen` is a probe whose
 * NONZERO exit means setup is needed, which keeps a landing run of an already-working
 * worktree free: the probe runs, exits 0, and nothing else happens. Configure
 * `setup` without a probe and every landing run pays for it, which is why both live
 * repos carry one.
 *
 * The commands run in the worktree with `LOCAL_MERGE_QUEUE_CHECKOUT` pointing at the
 * primary checkout, because most of what a worktree is missing is a copy of
 * something the primary checkout already has.
 */
async function ensureWorktreeSetup (repo, wt, laneNames, { force = false } = {}) {
  const env = {
    LOCAL_MERGE_QUEUE_CHECKOUT: repo.checkout,
    LOCAL_MERGE_QUEUE_WORKTREE: wt,
    LOCAL_MERGE_QUEUE_REPO: repo.key
  }
  let ran = false
  for (const name of laneNames) {
    const lane = repo.lanes[name]
    if (!lane.setup.length) continue
    const timeoutMs = gateTimeoutMs(repo, name)
    if (!force && lane.setupWhen && await runGate(lane.setupWhen, wt, env, { timeoutMs })) continue
    const label = multiLane(repo) ? `${repo.key}/${name}` : repo.key
    console.log(yellow(`  this worktree has no generated environment — running ${label}'s setup`))
    for (const step of lane.setup) {
      console.log(dim(`  setup: ${step}`))
      if (!await runGate(step, wt, env, { timeoutMs })) return { ok: false, ran: true, failed: step, probe: lane.setupWhen, lane: name, timedOut: gateTimedOut, timeoutMs }
    }
    console.log(dim('  setup complete — the gate has an environment to run in'))
    ran = true
  }
  return { ok: true, ran }
}

// ─── the known-red allow-list ────────────────────────────────────────────────

/**
 * A SUITE KNOWN TO BE RED, NAMED, DATED AND ISSUE-BACKED, SO ONE SESSION'S
 * FAILURE DOES NOT STALL EVERY OTHER SESSION'S LANDING.
 *
 * A gate that runs a whole test sweep before the merge stalls an entry on any
 * red suite, and a suite one session broke and is fixing stalls every
 * session's entries until it lands. The allow-list is the pressure valve, and
 * it is deliberately small and temporary:
 *
 *   "knownRed": [{ "suite": "test/x.test.mjs", "issue": "owner/repo#12",
 *                  "expires": "2026-11-25", "why": "optional, one clause" }]
 *
 * - `issue` and `expires` are required. An entry past its date is EXPIRED and
 *   honored no more: the suite blocks again, which is the point of a date.
 * - An expiry more than 30 days out is INVALID, and at most 5 entries count.
 * - `knownRedRefuse` names a file in the repo (one suite path per line) that
 *   lists suites the allow-list may never name, such as the data-safety suites;
 *   an entry naming one is REFUSED and honored never.
 *
 * The queue prints every entry and its state at the start of every landing run
 * and in `status`. The honored ones are written to a file whose path reaches
 * every gate step, setup step and final check as $LOCAL_MERGE_QUEUE_KNOWN_RED
 * (tab-separated: suite, issue, expires), and the repo's test runner decides
 * what a listed suite's failure means. A run with no honored entry leaves the
 * variable unset, so a runner that reads it sees nothing.
 */
const KNOWN_RED_MAX = 5
const KNOWN_RED_MAX_DAYS = 30

function todayISO () {
  if (process.env.LOCAL_MERGE_QUEUE_TODAY) return process.env.LOCAL_MERGE_QUEUE_TODAY
  const d = new Date()
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

function daysBetween (a, b) {
  return Math.round((Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`)) / 86400000)
}

function knownRedEntries (repo) {
  const raw = repo.knownRed
  if (raw === undefined) return []
  if (!Array.isArray(raw)) return [{ suite: '(knownRed)', state: 'invalid', why: '"knownRed" must be an array' }]
  let refuse = new Set()
  let refuseMissing = null
  if (repo.knownRedRefuse) {
    // Read from the primary checkout, which is on main. A refuse list that is not there refuses every entry: an allow-list
    // with no way to check what it names is not an allow-list.
    const file = path.join(repo.checkout, repo.knownRedRefuse)
    if (fs.existsSync(file)) {
      refuse = new Set(fs.readFileSync(file, 'utf8').split('\n').map(l => l.trim()).filter(l => l && !l.startsWith('#')))
    } else {
      refuseMissing = `${repo.knownRedRefuse} is not in ${repo.checkout}, so nothing can be checked against it`
    }
  }
  const today = todayISO()
  let honored = 0
  return raw.map(e => {
    const out = { suite: String(e?.suite ?? ''), issue: String(e?.issue ?? ''), expires: String(e?.expires ?? ''), why: e?.why ? String(e.why) : '' }
    const bad = why => ({ ...out, state: 'invalid', why })
    if (!out.suite || /\s/.test(out.suite)) return bad('"suite" must be one path with no spaces')
    if (!/^[\w.-]+\/[\w.-]+#\d+$/.test(out.issue)) return bad('"issue" must look like owner/repo#123')
    if (!/^\d{4}-\d{2}-\d{2}$/.test(out.expires) || Number.isNaN(Date.parse(`${out.expires}T00:00:00Z`))) return bad('"expires" must be a date, YYYY-MM-DD')
    if (refuseMissing) return bad(refuseMissing)
    if (refuse.has(out.suite)) return { ...out, state: 'refused', why: `${out.suite} is on ${repo.knownRedRefuse}; a suite on that list is never allowed to be red` }
    if (out.expires < today) return { ...out, state: 'expired', why: `expired ${out.expires}; the suite blocks again` }
    if (daysBetween(today, out.expires) > KNOWN_RED_MAX_DAYS) return bad(`expiry is more than ${KNOWN_RED_MAX_DAYS} days out`)
    if (honored >= KNOWN_RED_MAX) return { ...out, state: 'over-limit', why: `only ${KNOWN_RED_MAX} entries count` }
    honored++
    return { ...out, state: 'active', days: daysBetween(today, out.expires) }
  })
}

// Prints the allow-list (every entry, whatever its state) and hands the honored
// ones to the steps that follow through $LOCAL_MERGE_QUEUE_KNOWN_RED.
function announceKnownRed (repo, { write = true } = {}) {
  const entries = knownRedEntries(repo)
  const file = path.join(STATE_DIR, 'known-red', `${repo.key}.tsv`)
  if (write) {
    delete process.env.LOCAL_MERGE_QUEUE_KNOWN_RED
    fs.rmSync(file, { force: true })
  }
  if (!entries.length) return
  console.log(`\n${bold('known red')} ${dim(`(${repo.key}: temporary allow-list; a listed suite may fail without stalling an entry)`)}`)
  for (const e of entries) {
    if (e.state === 'active') {
      console.log(yellow(`  · ${e.suite} — ${e.issue}, expires ${e.expires} (${e.days === 0 ? 'today' : `${e.days} day${e.days === 1 ? '' : 's'}`})${e.why ? ` — ${e.why}` : ''}`))
    } else {
      console.log(red(`  · ${e.suite} — ${e.state.toUpperCase()}: ${e.why}`))
    }
  }
  const active = entries.filter(e => e.state === 'active')
  if (write && active.length) {
    fs.mkdirSync(path.dirname(file), { recursive: true })
    fs.writeFileSync(file, active.map(e => [e.suite, e.issue, e.expires].join('\t')).join('\n') + '\n')
    process.env.LOCAL_MERGE_QUEUE_KNOWN_RED = file
  }
}

// ─── one deploy per landing run, not one per branch ───────────────────────────────

/**
 * A REPO WHOSE HOST BUILDS EVERY PUSH TO `main` GETS ONE BUILD PER LANDING RUN,
 * NOT ONE PER BRANCH.
 *
 * One site here deploys production from `main` through Vercel's git
 * integration, so the push at step 4 IS a production deploy. Landing N branches
 * therefore shipped N builds, and every one but the last shipped a state that
 * existed for about ninety seconds while the queue was still moving. The owner's
 * ask, 2026-08-29: *"main should just redeploy at the end of the landing."*
 *
 * The mechanism is Vercel's own `ignoreCommand` (vercel.json), whose contract is
 * that exit 0 ignores the build and exit 1 lets it proceed, reading the commit
 * message out of the documented `VERCEL_GIT_COMMIT_MESSAGE`. So the merge queue
 * appends `deploy.skipMarker` to the merge commit message of every entry that
 * has another entry behind it, and leaves the LAST merge of the run unmarked.
 * One push, one build, the state a person actually asked for. With lanes the
 * marker is per lane: an entry carries the marker of each of its lanes that has
 * one when another eligible entry behind it shares that lane, so a run that
 * touches only lanes without a `deploy` key writes none.
 *
 * WHAT IS NOT DONE, AND WHY: the pushes themselves are not batched or deferred.
 * An unpushed merge is unbacked-up work, and the pull request retires itself
 * only because the landing tip is reachable from `main` at cleanup time. The
 * push cadence is load-bearing; only the BUILD per push is suppressed.
 *
 * `settleDeploy` is the safety net under the lookahead, and it is what makes the
 * messy paths correct rather than merely usual. The lookahead can be wrong in
 * two ways — the entry behind this one may stall and then be dequeued, or it may
 * turn out to be cleanup-only and push nothing — and both leave `main` sitting
 * on a merge the host was told to ignore, with production serving the build from
 * before the landing run. So at the end of every run, for each lane with a
 * marker that no stalled entry holds, the merge queue asks the state rather
 * than its own memory: is the lane's last build a merge that carries the marker
 * (`laneUndeployed`)? If any is, ONE empty commit publishes every lane. On the
 * ordinary path the lane's last build is unmarked and this does nothing at all.
 *
 * A stall deliberately does NOT settle the lanes it holds. The line is expected
 * to continue, and shipping the half-landed state mid-stall is the thing this
 * whole feature exists to stop; the resume that lands the last entry deploys it.
 */
function settleDeploy (repo, dryRun, blocked = new Set()) {
  // Each lane with a marker is settled unless a stalled entry holds it: the
  // line is expected to continue there. A one-lane repo with any stall holds
  // its one lane, so it settles exactly when it did before lanes existed.
  const lanes = deployLanes(repo).filter(n => !blocked.has(n))
  if (!lanes.length || dryRun) return
  gitTry(['fetch', 'origin', repo.mainBranch], repo.checkout)
  const ff = gitTry(['merge', '--ff-only', `origin/${repo.mainBranch}`], repo.checkout)
  if (!ff.ok) {
    console.log(yellow(`  ${repo.mainBranch} could not fast-forward to origin, so the deploy state was not checked`))
    return
  }
  const undeployed = lanes.filter(n => laneUndeployed(repo, n))
  if (!undeployed.length) return

  // THE MESSAGE MUST NOT CONTAIN THE MARKER. Interpolating it here — naming the
  // thing being fixed, which is the natural sentence to write — would make the
  // commit that exists to trigger a build the next one skipped, permanently and
  // silently. Asserted rather than trusted.
  const msg = `Redeploy ${repo.mainBranch}: the landing run ended on a merge the host was told not to build`
  if (deployLanes(repo).some(n => msg.includes(repo.lanes[n].deploy.skipMarker))) die('the redeploy commit message carries the skip marker — refusing to push a commit that cancels itself')

  // ONE EMPTY COMMIT SERVES EVERY LANE, so a run that finds several lanes
  // undeployed publishes once.
  console.log(yellow(`  ${repo.mainBranch} is sitting on a skipped build${multiLane(repo) ? ` in ${lanePhrase(undeployed)}` : ''} — publishing it`))
  const cm = gitTry(['commit', '--allow-empty', '-m', msg], repo.checkout)
  if (!cm.ok) {
    console.log(red(`  THE REDEPLOY COMMIT FAILED: ${cm.err || '(no stderr)'}`))
    console.log(red('  Production is still serving the build from before this landing run.'))
    return
  }
  const push = gitTry(['push', 'origin', repo.mainBranch], repo.checkout)
  if (!push.ok) {
    gitTry(['reset', '--hard', `origin/${repo.mainBranch}`], repo.checkout)
    console.log(red(`  THE REDEPLOY PUSH FAILED: ${push.err || '(no stderr)'}`))
    console.log(red(`  Rolled it back. Production is still serving the build from before this landing run;`))
    console.log(red(`  publish it with an empty commit on ${repo.mainBranch} once the push works.`))
    return
  }
  console.log(green(`  ${repo.mainBranch} republished — the host builds this one`))
}

// ─── stall reporting ────────────────────────────────────────────────────────

/**
 * THE INSTRUCTIONS MUST MATCH WHAT ACTUALLY STALLED.
 *
 * Every report used to end in "the rebase is left in progress — resolve in
 * place, then `git rebase --continue`", which is true of exactly one stall kind.
 * A gate failure and a setup failure both happen AFTER the rebase has finished
 * cleanly, so there is no conflict to resolve and no rebase to continue, and a
 * fixer sent looking for one starts by trying to work out what it broke. The
 * question is asked of git rather than tracked, so the two can never disagree:
 * `fixSteps` names what to actually run, and the rebase paragraph appears only
 * when a rebase is genuinely sitting there.
 */
function writeStallReport (repo, entry, kind, detail, conflicted, ownerCall, fixSteps = [], { behindMain = false } = {}) {
  fs.mkdirSync(REPORT_DIR, { recursive: true })
  const file = reportFile(repo.key, entry.branch)
  const midRebase = rebaseInProgress(entry.worktree)
  const clearIt = behindMain
    ? `**This branch was enqueued with \`--no-rebase\`, so the queue started no rebase.**
\`origin/${repo.mainBranch}\` has commits the branch does not contain. Merge them into
the branch, in its own worktree:

\`\`\`sh
cd "${entry.worktree}"
git merge origin/${repo.mainBranch}
# resolve any conflict, then commit the merge
\`\`\`

The merge commit keeps the branch's history as it is; a rebase would rewrite it.`
    : midRebase
    ? `The rebase is left in progress on purpose — resolve in place, in that worktree:

\`\`\`sh
cd "${entry.worktree}"
# resolve, then:
git add -A && git rebase --continue
\`\`\``
    : `**There is no conflict here, and no rebase to continue** — the branch is already
on top of \`origin/${repo.mainBranch}\`, and the rebase finished cleanly. The stall is
in the branch's own worktree, which is where it is fixed:

\`\`\`sh
cd "${entry.worktree}"
${fixSteps.length ? fixSteps.join('\n') : '# re-run what failed, and fix the cause'}
\`\`\`

Commit anything that belongs on the branch; a fix to the worktree's untracked
environment is not a commit and needs none.`
  // A repo with more than one lane says which lanes wait; a one-lane repo's
  // report reads as it did before lanes existed.
  const lanes = multiLane(repo) ? queueLanesOf(repo, entry) : null
  const behind = lanes
    ? `Entries that share ${lanePhrase(lanes)} with this one wait behind it, and nothing in ${lanes.length === 1 ? 'that lane' : 'those lanes'} was landed out of order. Entries in other lanes keep landing.`
    : 'Everything queued behind this entry is still waiting; nothing was landed out of\norder.'
  const body = `# Landing stalled — ${repo.key} / \`${entry.branch}\`

**When:** ${nowISO()}
**Why:** ${kind}
**Worktree:** \`${entry.worktree}\`
${lanes ? `**Lanes stalled:** ${lanes.join(', ')}\n` : ''}${ownerCall ? '\n> **OWNER DECISION REQUIRED.** The conflict touches a protected path, so the\n> resolution is protected content that is the owner\'s call, not an agent\'s.\n> Resolve nothing without the owner\'s word, then resume with `--owner-approved`.\n' : ''}
## Detail

\`\`\`
${detail}
\`\`\`
${conflicted.length ? `\n## Conflicted paths\n\n${conflicted.map(p => `- \`${p}\``).join('\n')}\n` : ''}
## How to clear it

${clearIt}

Then hand the line back to the merge queue:

\`\`\`sh
local-merge-queue resume ${repo.key}${ownerCall ? ' --owner-approved' : ''}
\`\`\`

${behind} If this branch should leave the queue instead, \`local-merge-queue dequeue ${entry.branch}\`
(that returns the branch to its worktree untouched${midRebase ? ', aborting the rebase' : ''}).
`
  fs.writeFileSync(file, body)
  return file
}

// ─── batched landing: a merge train, opt-in ─────────────────────────────────────
//
// ONE GATE FOR SEVERAL ENTRIES. Landing one at a time costs one gate per entry,
// and a gate that takes minutes (or an hour, on a loaded machine) makes N entries
// cost N of them. In the pattern of GitLab merge trains, GitHub's merge queue and
// bors, a batch builds the candidate main the one-at-a-time process WOULD have
// built, gates its tip once, and only then lands.
//
//   1. Form the batch: the next approved entries of the repo in queue order, up to
//      `max`, stopping at the first entry that is not eligible, is --no-rebase, is
//      already contained in main, carries merge commits a rebase would flatten, or
//      does not carry the same lanes (and reached lanes) as the first.
//   2. Build the candidate in a worktree of its own, on a detached HEAD: each entry
//      is rebased onto the previous result (or left as it is when it already
//      contains it, as `land` always does), its scaffolding removed, and merged
//      --no-ff. No branch moves, and nothing is pushed.
//   3. Gate the candidate's tip once: each of the batch's lanes' setup and gate,
//      each gate once. Because every entry carries the same lanes, no entry waits
//      on a gate of a lane it does not carry.
//   4. Green: the entries land through the ordinary path, one after another, with
//      their gate skipped, each checked against the tree the batch gated.
//      Red, a conflict, or any error: nothing was pushed, the candidate is
//      dropped, and the entries land one at a time, so the entry that fails is
//      the one that stalls.
// `published` names the entries whose rebased tips were already pushed to origin when the
// batch failed (a failure at the push of `main` or after the first publish), so that the
// message can say the remote branches were rewritten.
class BatchFailure extends Error {
  constructor (message, published = []) { super(message); this.published = published }
}

// The label a batch groups by: the lanes an entry carries, `~` marking one it only
// reached. A one-lane repo has one label for everything.
function batchKeyOf (repo, names, reached) {
  const run = laneNamesFor(repo, { lanes: names, reached })
  return { run, reached, key: laneLabels({ lanes: run, reached }).join(',') }
}

// Why this entry cannot join a batch, or null. `tip` is what the entry would be
// rebased onto.
function batchBlocker (repo, e, tip) {
  if (e.noRebase) return 'it is --no-rebase'
  if (!e.worktree || !fs.existsSync(e.worktree)) return 'its worktree is gone'
  if (!gitTry(['rev-parse', '--verify', '-q', `refs/heads/${e.branch}`], repo.checkout).ok) return 'its branch is gone'
  if (gitTry(['merge-base', '--is-ancestor', e.branch, `origin/${repo.mainBranch}`], repo.checkout).ok) return 'it is already in main (cleanup only)'
  const merges = gitTry(['rev-list', '--merges', '--count', `${tip}..${e.branch}`], repo.checkout)
  if (!merges.ok || merges.out !== '0') return 'it carries merge commits (a branch that merged main into itself is not rebased, and a batch rebases)'
  return null
}

// The entries a batch starting at `first` would hold, in queue order, or null.
// Reads the queue and the branches, and writes nothing, so a dry run can ask.
function formBatch (cfg, repo, key, first, q, { simulated, held, noBatch, preGated, max }) {
  if (first.status !== 'approved' || noBatch.has(first.branch) || preGated.has(first.branch)) return null
  const queued = new Map(q.entries.map(e => [`${e.repo}:${e.branch}`, e]))
  const sim = new Set(simulated)
  const members = []
  let groupKey = null
  for (let i = q.entries.indexOf(first); i < q.entries.length && members.length < max; i++) {
    const e = q.entries[i]
    if (e.repo !== key) continue
    if (e !== first) {
      if (noBatch.has(e.branch) || preGated.has(e.branch)) break
      if (!eligible(cfg, e, key, { queued, simulated: sim, resuming: false, held, quiet: true })) break
    }
    if (batchBlocker(repo, e, repo.mainBranch)) break
    let k = ''
    if (multiLane(repo)) {
      try {
        const found = {}
        const names = lanesOf(repo, repo.checkout, e.branch, found, { fail: m => { throw new Error(m) } })
        k = batchKeyOf(repo, names, found.reached).key
      } catch { break }
    }
    if (members.length && k !== groupKey) break
    groupKey = k
    members.push(e)
    sim.add(e.branch)
  }
  return members.length >= 2 ? members : null
}

// The gate steps of a batch, lane by lane, for the dry run and the announcement.
function batchGatePlan (repo, members) {
  const found = {}
  const names = multiLane(repo) ? lanesOf(repo, repo.checkout, members[0].branch, found, { fail: m => { throw new Error(m) } }) : Object.keys(repo.lanes)
  return batchKeyOf(repo, names, found.reached || [])
}

// The git floor for batching. The batch's tests were written against git 2.38 and
// newer, and an older git is refused rather than trusted.
function requireBatchGit () {
  const m = /git version (\d+)\.(\d+)/.exec(gitTry(['--version']).out)
  const ok = !!m && (Number(m[1]) > 2 || (Number(m[1]) === 2 && Number(m[2]) >= 38))
  if (!ok) die(`batched landing needs git 2.38 or newer, and this is ${m ? `git ${m[1]}.${m[2]}` : 'a git that does not report its version'}. Run without --batch (and without a "batch" key in the config), or upgrade git.`)
}

// THE BATCH WORKTREE. A batch is gated in one worktree of its own, `<state>/batch/<repo>`,
// on a detached HEAD, created on first use and kept, because it carries the
// repository's generated environment (installed dependencies) and rebuilding that
// for every batch would cost more than the batch saves. It is therefore NOT a fresh
// worktree, and before every batch it is made to look like one apart from the
// dependency directories the repository's config names:
//   - a rebase, merge or cherry-pick left in progress is aborted, and the tree is
//     reset hard to the commit the candidate is built on;
//   - every untracked and ignored file goes (`git clean -fdx`) except the
//     directories in `batch.keep`;
//   - the repository's lockfiles are hashed (`batch.lockfiles`, or the usual
//     lockfile names at the root and beside each `keep` directory) and the hash
//     is kept in `<state>/batch/<repo>.json`; when it differs from the last
//     successful setup, the `keep` directories are removed and the setup steps run
//     again, whatever the setup probe says;
//   - it is `git worktree lock`ed, so that `git worktree prune` never reaps it;
//   - if it cannot be made usable (a stale index.lock, a broken registration), it
//     is rebuilt from scratch, once, and the run says so.
const DEFAULT_LOCKFILES = ['package-lock.json', 'npm-shrinkwrap.json', 'yarn.lock', 'pnpm-lock.yaml', 'Cargo.lock', 'poetry.lock', 'Gemfile.lock', 'go.sum']
const batchKeep = repo => repo.batch?.keep ?? []
function batchLockfiles (repo) {
  if (repo.batch?.lockfiles) return repo.batch.lockfiles
  const dirs = new Set([''])
  for (const k of batchKeep(repo)) { const d = path.dirname(k); if (d !== '.') dirs.add(d) }
  return [...dirs].flatMap(d => DEFAULT_LOCKFILES.map(n => (d ? `${d}/${n}` : n)))
}
function lockfileHash (repo, bw) {
  const h = crypto.createHash('sha256')
  for (const n of batchLockfiles(repo)) {
    const f = path.join(bw, n)
    if (fs.existsSync(f)) { h.update(`${n}\0`); h.update(fs.readFileSync(f)); h.update('\0') }
  }
  return h.digest('hex')
}
const batchMetaPath = repo => path.join(BATCH_DIR, `${repo.key}.json`)

function ensureBatchWorktree (repo, base) {
  const bw = path.join(BATCH_DIR, repo.key)
  fs.mkdirSync(BATCH_DIR, { recursive: true })
  const prepare = () => {
    if (!fs.existsSync(path.join(bw, '.git'))) return false
    for (const op of [['rebase', '--abort'], ['merge', '--abort'], ['cherry-pick', '--abort']]) gitTry(op, bw)
    if (!gitTry(['checkout', '-f', '--detach', base], bw).ok) return false
    if (!gitTry(['reset', '--hard', '-q'], bw).ok) return false
    if (!gitTry(['clean', '-fdxq', ...batchKeep(repo).flatMap(k => ['-e', k])], bw).ok) return false
    return true
  }
  if (prepare()) return bw
  // Unusable, or not there. Rebuild it from scratch, once, and say so when there was something to rebuild.
  if (fs.existsSync(bw)) console.log(yellow(`  the batch worktree ${bw} is unusable — rebuilding it from scratch`))
  gitTry(['worktree', 'unlock', bw], repo.checkout)
  gitTry(['worktree', 'remove', '--force', '--force', bw], repo.checkout)
  // Exact path, and only inside the batch directory.
  if (path.dirname(bw) === BATCH_DIR && path.basename(bw) === repo.key) fs.rmSync(bw, { recursive: true, force: true })
  gitTry(['worktree', 'prune'], repo.checkout)
  fs.rmSync(batchMetaPath(repo), { force: true })
  const add = gitTry(['worktree', 'add', '--detach', bw, base], repo.checkout)
  if (!add.ok) throw new BatchFailure(`could not create the batch worktree ${bw}: ${add.err}`)
  gitTry(['worktree', 'lock', '--reason', 'local-merge-queue batch worktree', bw], repo.checkout)
  if (!prepare()) throw new BatchFailure(`the batch worktree ${bw} is unusable even rebuilt`)
  return bw
}

// A BATCH LANDS ATOMICALLY: the candidate is built with its final merge commits,
// its tip is gated once, and that exact commit is what `main` is pushed to, once.
// Nothing reaches the remote's `main` that was not part of the gated tree, and
// the states between the entries (a merge of the first alone) are not gated on
// their own and never exist on the remote. If anything fails before that push,
// nothing has landed: no entry's branch has moved, and the entries land one at
// a time. After the push, each entry is cleaned up as an entry landed alone is.
//
// Returns { landed: [entry…], lanes: [lane…] } once `main` is pushed; throws
// BatchFailure (or any other error) only BEFORE the push.
async function runBatch (cfg, repo, key, members, { held, onBuilt }) {
  const names = members.map(e => e.branch)
  const drift = syncMainWithOrigin(repo)
  if (drift) throw new BatchFailure(drift)
  const base = git(['rev-parse', repo.mainBranch], repo.checkout)

  // What each entry is now, so that a change during the gate is noticed.
  const info = new Map()
  for (const e of members) {
    const branchSha = git(['rev-parse', `refs/heads/${e.branch}`], repo.checkout)
    const head = gitTry(['rev-parse', 'HEAD'], e.worktree)
    if (!head.ok || head.out !== branchSha) throw new BatchFailure(`${e.branch}'s worktree is not on the tip of its branch`)
    if (gitTry(['status', '--porcelain'], e.worktree).out) throw new BatchFailure(`${e.branch}'s worktree has uncommitted changes`)
    const remote = gitTry(['rev-parse', '--verify', '-q', `refs/remotes/origin/${e.branch}`], repo.checkout)
    info.set(e.branch, { branchSha, remoteSha: remote.ok ? remote.out : '' })
  }

  const bw = ensureBatchWorktree(repo, base)
  const nohooks = ['-c', 'core.hooksPath=/dev/null']
  const must = (args, what) => { const r = gitTry([...nohooks, ...args], bw); if (!r.ok) throw new BatchFailure(`${what}: ${r.err || r.out}`); return r }
  const sim = new Set(names)
  let first = null
  for (let i = 0; i < members.length; i++) {
    const e = members[i]
    const tip = git(['rev-parse', 'HEAD'], bw)
    must(['checkout', '--detach', info.get(e.branch).branchSha], `could not check out ${e.branch}`)
    // As in `land`: a branch that already contains the main it lands on is not rebased.
    if (!gitTry(['merge-base', '--is-ancestor', tip, 'HEAD'], bw).ok) {
      const rb = gitTry([...nohooks, 'rebase', tip], bw)
      if (!rb.ok) {
        const where = gitTry(['diff', '--name-only', '--diff-filter=U'], bw).out.split('\n').filter(Boolean)
        gitTry(['rebase', '--abort'], bw)
        const ownerCall = where.some(p => protectedOf(repo).some(pp => p.startsWith(pp)))
        throw new BatchFailure(`${e.branch} conflicts with the entries before it${where.length ? ` in ${where.join(', ')}` : ''}${ownerCall ? ' (a protected path: the owner\'s call)' : ''}`)
      }
    }
    // The lanes, worked out exactly as `land` does for one entry: on the rebased
    // branch, before its scaffolding is removed.
    let k = { run: Object.keys(repo.lanes), reached: [], key: '' }
    if (multiLane(repo)) {
      const found = {}
      const laneNames = lanesOf(repo, bw, git(['rev-parse', 'HEAD'], bw), found, { base: tip, fail: m => { throw new BatchFailure(m) } })
      k = batchKeyOf(repo, laneNames, found.reached)
    }
    if (first && k.key !== first.key) throw new BatchFailure(`${e.branch} carries other lanes than ${members[0].branch}`)
    first ||= k
    // The scaffolding goes before the gate sees it, here as in `land`.
    if (fs.existsSync(path.join(bw, 'BRANCH.md'))) {
      must(['rm', '-q', 'BRANCH.md'], 'could not remove BRANCH.md')
      must(['commit', '-q', '-m', 'BRANCH.md goes, as scaffolding does before a merge'], 'could not commit the BRANCH.md removal')
    }
    info.get(e.branch).rebasedTip = git(['rev-parse', 'HEAD'], bw)
    must(['checkout', '--detach', tip], 'could not return to the candidate tip')
    // The merge commit as `land` writes it: the note, and the deploy marker of each lane the entry
    // changed when another entry follows it that shares the lane.
    const markers = []
    for (const n of first.run.filter(n => repo.lanes[n].deploy?.skipMarker && !first.reached.includes(n))) {
      const marker = repo.lanes[n].deploy.skipMarker
      const more = i < members.length - 1 || moreEligibleAfter(cfg, key, e, { queue: null, simulated: sim, resuming: false, held, lane: n })
      if (more && !markers.includes(marker)) markers.push(marker)
    }
    const msg = `Merge ${e.branch}${e.note ? ` — ${e.note}` : ''}${markers.map(m => ` ${m}`).join('')}`
    const mg = gitTry([...nohooks, 'merge', '--no-ff', '-m', msg, info.get(e.branch).rebasedTip], bw)
    if (!mg.ok) { gitTry(['merge', '--abort'], bw); throw new BatchFailure(`${e.branch} does not merge onto the entries before it: ${mg.err || mg.out}`) }
  }
  const candidate = git(['rev-parse', 'HEAD'], bw)
  const gatedTree = git(['rev-parse', 'HEAD^{tree}'], bw)
  console.log(dim(`  batch candidate built on ${base.slice(0, 9)}: ${names.join(', ')} (${candidate.slice(0, 9)})`))
  onBuilt(names)                       // `status` shows the batch for as long as the gate runs

  // The lockfiles decide whether the kept dependency directories can be trusted.
  const hash = lockfileHash(repo, bw)
  const recorded = readJSON(batchMetaPath(repo), {}).lockfiles
  const changed = recorded !== hash
  if (changed) {
    for (const d of batchKeep(repo)) fs.rmSync(path.join(bw, d), { recursive: true, force: true })
    console.log(dim(recorded === undefined
      ? '  the batch worktree has not been set up yet — setting it up'
      : '  the repository\'s lockfiles differ from the last setup of the batch worktree — setting it up again'))
  }
  // ONE GATE, on the tip, for the lanes the entries share.
  const setup = await ensureWorktreeSetup(repo, bw, first.run, { force: changed })
  if (!setup.ok) throw new BatchFailure(`worktree setup ${setup.timedOut ? `timed out after ${fmtMinutes(setup.timeoutMs / 60000)}` : 'failed'}${multiLane(repo) ? ` in lane ${setup.lane}` : ''}: ${setup.failed}`)
  writeJSON(batchMetaPath(repo), { lockfiles: hash })
  for (const name of first.run) {
    for (const step of gateStepsFor(repo, { reached: first.reached }, name)) {
      console.log(dim(`  gate: ${step}`))
      if (!await runGate(step, bw, repo.lanes[name].gateEnv || {}, { timeoutMs: gateTimeoutMs(repo, name) })) {
        throw new BatchFailure(`the gate${multiLane(repo) ? ` of lane ${name}` : ''} ${gateTimedOut ? `timed out after ${fmtMinutes(gateTimeoutMs(repo, name) / 60000)}` : 'failed'} on the candidate: ${step}`)
      }
    }
  }

  // BEFORE ANYTHING IS PUSHED, everything the gate vouched for is checked again.
  if (git(['rev-parse', 'HEAD'], bw) !== candidate || git(['rev-parse', 'HEAD^{tree}'], bw) !== gatedTree) throw new BatchFailure('the gate moved the batch worktree off the candidate')
  if (!run('git fetch origin --prune', repo.checkout)) throw new BatchFailure('git fetch failed after the gate')
  const now = gitTry(['rev-parse', `origin/${repo.mainBranch}`], repo.checkout)
  if (!now.ok || now.out !== base || git(['rev-parse', repo.mainBranch], repo.checkout) !== base) throw new BatchFailure(`${repo.mainBranch} moved while the candidate was gated, so the gate result is stale`)
  for (const e of members) {
    const was = info.get(e.branch)
    const fresh = freshEntry(e)
    if (!fresh || fresh.status !== 'approved') throw new BatchFailure(`${e.branch} was ${fresh ? 'unapproved' : 'dequeued'} while the batch was gated`)
    const sha = gitTry(['rev-parse', `refs/heads/${e.branch}`], repo.checkout)
    const remote = gitTry(['rev-parse', '--verify', '-q', `refs/remotes/origin/${e.branch}`], repo.checkout)
    const head = gitTry(['rev-parse', 'HEAD'], e.worktree)
    if (!sha.ok || sha.out !== was.branchSha || (remote.ok ? remote.out : '') !== was.remoteSha || !head.ok || head.out !== was.branchSha || gitTry(['status', '--porcelain'], e.worktree).out) {
      throw new BatchFailure(`${e.branch} changed while the batch was gated, so the gate did not see what would land`)
    }
  }

  // PUBLISH EACH ENTRY'S REBASED TIP, so that its pull request retires as merged,
  // and then push `main`, once, to the commit that was gated.
  const published = []
  for (const e of members) {
    const was = info.get(e.branch)
    const pub = gitTry(['push', `--force-with-lease=${e.branch}:${was.remoteSha}`, 'origin', `${was.rebasedTip}:refs/heads/${e.branch}`], repo.checkout)
    if (!pub.ok) throw new BatchFailure(`publishing the rebased tip of ${e.branch} failed: ${pub.err}`, published)
    published.push(e.branch)
  }
  // APPROVAL IS READ AGAIN AFTER THE TIPS ARE PUSHED AND BEFORE `main` IS: the pushes are
  // network round trips, and an entry unapproved or dequeued in that time must not land.
  for (const e of members) {
    const fresh = freshEntry(e)
    if (!fresh || fresh.status !== 'approved') throw new BatchFailure(`${e.branch} was ${fresh ? 'unapproved' : 'dequeued'} while the batch's tips were being published`, published)
  }
  const push = gitTry(['push', 'origin', `${candidate}:refs/heads/${repo.mainBranch}`], repo.checkout)
  if (!push.ok) throw new BatchFailure(`origin rejected the push of ${repo.mainBranch}, so nothing has landed: ${push.err}`, published)

  // ---- from here the batch has landed; nothing below may throw ----
  const ffm = gitTry(['merge', '--ff-only', candidate], repo.checkout)
  console.log(green(`  landed ${members.length} entries on ${repo.mainBranch} in one push (${candidate.slice(0, 9)})`))
  console.log(dim(`  The batch's final tree was gated once. The merges between the entries were not gated on their own, and never reached origin.`))
  if (!ffm.ok) console.log(red(`  ${repo.mainBranch} here could not fast-forward to the pushed commit: ${ffm.err}. origin has it; run: git -C ${repo.checkout} pull --ff-only`))
  for (const e of members) {
    const was = info.get(e.branch)
    console.log(`\n${bold('──')} ${bold(e.branch)} ${dim(e.worktree)} ${dim('(landed in the batch)')}`)
    // The branch moves to the tip that was published, so that cleanup can prove it contained.
    // NEVER WITH `reset --hard`, which discards work: the worktree is checked, and moved with
    // `reset --keep` (which refuses rather than discard) only if it is still on the commit
    // the batch was built from with nothing changed; otherwise it stays as it is and cleanup
    // keeps the worktree and the branch (see `cleanupLanded`).
    const head = gitTry(['rev-parse', 'HEAD'], e.worktree)
    if (head.ok && head.out === was.branchSha && !gitTry(['status', '--porcelain'], e.worktree).out) {
      const rs = gitTry(['reset', '--keep', '-q', was.rebasedTip], e.worktree)
      if (!rs.ok) console.log(red(`  COULD NOT MOVE ${e.branch} TO ITS PUBLISHED TIP: ${rs.err}`))
    } else {
      console.log(red(`  ${e.branch}'s worktree changed after the batch's final check, so its branch was not moved to the published tip`))
    }
    try { cleanupLanded(repo, e, e.worktree, { landedTip: was.rebasedTip }) } catch (err) { console.log(red(`  cleanup of ${e.branch} failed: ${err.message}`)) }
    e.status = 'landed'
    removeEntry(e)
  }
  return { landed: members, lanes: first.run.filter(n => !first.reached.includes(n)) }
}

// ─── commands ───────────────────────────────────────────────────────────────

function cmdEnqueue (cfg, args) {
  const here = detectHere(cfg)
  const repoKey = args['--repo'] || here?.repo.key
  const branch = args['--branch'] || here?.branch
  if (!repoKey || !branch) {
    die('run this from inside the branch worktree, or pass --repo and --branch')
  }
  const repo = repoOf(cfg, repoKey)
  if (branch === repo.mainBranch) die(`"${branch}" is the main branch; there is nothing to enqueue`)

  const worktree = worktreeFor(repo, branch)
  if (!worktree) die(`no worktree holds "${branch}" in ${repo.key} — the merge queue lands branches from their worktrees`)

  // Unpushed work is unbacked-up work; the merge queue will not carry it.
  const upstream = gitTry(['rev-parse', '--abbrev-ref', `${branch}@{upstream}`], worktree)
  if (!upstream.ok) die(`"${branch}" has no upstream — push it first (git push -u origin ${branch})`)
  const ahead = git(['rev-list', '--count', `${upstream.out}..${branch}`], worktree)
  if (ahead !== '0') die(`"${branch}" has ${ahead} unpushed commit(s) — push before enqueuing`)
  const dirty = git(['status', '--porcelain'], worktree)
  if (dirty) die(`"${branch}"'s worktree is dirty — commit or discard before enqueuing`)

  // A branch with no pull request is a branch with no record. Since 2026-08-19
  // the PR IS the roster — what the branch is, what is open on it, whose call is
  // outstanding — so enqueuing without one queues work that `gh pr list` cannot
  // see. Refuse, and say exactly how to fix it. This checks only that a PR
  // exists; whether it is draft is deliberately not policed, because "not ready
  // to land" is a judgement the person approving it makes, not this tool.
  if (repo.githubRepo) {
    const pr = prFor(repo, branch)
    if (!pr) {
      die(`"${branch}" has no open pull request, and the pull request is the roster.\n` +
          `  Open one from its worktree, then enqueue again:\n\n` +
          `    cd ${worktree}\n` +
          `    gh pr create --base ${repo.mainBranch} --head ${branch} --draft \\\n` +
          `      --title "<what it is, in one clause>" --body-file <(…)\n\n` +
          `  The body carries what BRANCH.md used to: scope, what is done, what is left,\n` +
          `  how to verify, and any decision that is the owner's rather than an agent's.`)
    }
    console.log(dim(`  pull request: #${pr.number}${pr.isDraft ? ' (draft)' : ''}`))
  }

  const found = {}
  const lanes = lanesOf(repo, worktree, branch, found)
  // Everything above ran against the disk and the forge, and took as long as it
  // took. The queue is read only now, under its lock, and this one entry is the
  // only thing written to it.
  const result = mutateQueue(q => {
    const existing = q.entries.find(e => e.repo === repo.key && e.branch === branch)
    if (existing) {
      existing.worktree = worktree
      existing.lanes = lanes
      existing.reached = found.reached
      if (args['--note']) existing.note = args['--note']
      if (args['--after']) existing.after = args['--after']
      if (args['--no-rebase']) existing.noRebase = true
      return { updated: true, status: existing.status }
    }
    q.entries.push({
      repo: repo.key,
      branch,
      worktree,
      note: args['--note'] || '',
      after: args['--after'] || null,
      lanes,
      reached: found.reached,
      ...(args['--no-rebase'] ? { noRebase: true } : {}),
      status: 'enqueued',                 // enqueued → approved (the owner's word) → landed
      enqueued: nowISO()
    })
    return { updated: false }
  })
  if (result.updated) {
    console.log(`${bold('updated')} ${repo.key}/${branch} (status: ${result.status})`)
    return
  }
  console.log(`${green('enqueued')} ${repo.key}/${branch}`)
  console.log(dim('  Waiting for the owner\'s word. Nothing merges until it is approved.'))
}

function cmdStatus (cfg, args) {
  const q = loadQueue()
  const only = args._[0]
  const keys = only ? [only] : Object.keys(cfg.repos)
  let any = false
  for (const key of keys) {
    const repo = cfg.repos[key]
    if (!repo) continue
    const mine = q.entries.filter(e => e.repo === key)
    if (!mine.length) continue
    any = true
    console.log(`\n${bold(key)}  ${dim(repo.checkout)}`)
    // LOCKED means a landing run is going on: the lock's holder is alive. A lock
    // whose holder is gone is a dead run's debris, which the next land clears, and
    // anything a dead run left on its entries (a batch mark) is not shown.
    let running = false
    if (fs.existsSync(path.join(LOCK_DIR, key))) {
      const owner = readJSON(path.join(LOCK_DIR, key, 'owner.json'), null)
      running = !!owner && Number.isInteger(owner.pid) && pidAlive(owner.pid)
      if (running) console.log(yellow(`  LOCKED by pid ${owner.pid} since ${owner.since} (${lockAge(owner)})`))
      else if (groupAlive(owner?.gatePgid)) {
        console.log(yellow(`  a landing run died (pid ${owner.pid} is gone), but the gate it started is still running (process group ${owner.gatePgid}); the lock is held until that gate ends`))
        console.log(dim(`  look at what the group is first: ${groupHint(owner.gatePgid)}   (if it is not a gate, release the lock: rm -rf ${path.join(LOCK_DIR, key)})`))
      }
      else console.log(dim(`  a landing run died holding the lock (pid ${owner?.pid ?? '?'} is gone); the next land clears it`))
    }
    announceKnownRed(repo, { write: false })
    mine.forEach((e, i) => {
      const mark = e.status === 'approved' ? green('approved')
        : e.status === 'stalled' ? red('STALLED')
          : dim('enqueued')
      let delta = ''
      try {
        const lr = git(['rev-list', '--left-right', '--count', `${repo.mainBranch}...${e.branch}`], repo.checkout)
        const [behind, ahead] = lr.split(/\s+/)
        delta = dim(`+${ahead} −${behind}`)
      } catch { delta = dim('(delta unknown)') }
      const name = multiLane(repo) && e.lanes ? `${e.branch} [${laneLabels(e).join(', ')}]` : e.branch
      console.log(`  ${String(i + 1).padStart(2)}. ${name.padEnd(28)} ${mark.padEnd(18)} ${delta}`)
      if (e.after) console.log(dim(`      after: ${e.after}`))
      if (e.noRebase) console.log(dim('      no-rebase'))
      if (e.batch && running) console.log(dim(`      gated together with: ${e.batch.with.filter(b => b !== e.branch).join(', ')} (one batched gate run)`))
      if (e.note) console.log(dim(`      ${e.note}`))
      if (e.stallReason) console.log(red(`      ${e.stallReason}`))
    })
  }
  if (!any) console.log(dim('the queue is empty'))
  else {
    // THE QUEUE IS SHARED, AND THAT IS THE POINT. Several agents enqueue at once,
    // so an agent reading `status` routinely finds branches it never enqueued —
    // and has read that as a fault worth investigating or warning about (learned
    // 2026-08-28). Said here rather than only in the README because this listing,
    // not a doc read at the start of a session, is what is in front of it.
    console.log(dim('Several agents enqueue into this queue; entries you did not create are expected.'))
    console.log(dim('Before landing, confirm the approved set is the one the owner meant: local-merge-queue land <repo> --dry-run'))
    console.log('')
  }
  for (const key of keys) {
    if (!cfg.repos[key]) continue
    reportResidue(key, cfg.repos[key])
    reportUndeployedTip(key, cfg.repos[key])
    reportKept(key, q)
  }
}

// Landed entries whose worktree the run kept (it held files made after the gate): still on
// disk, in no queue entry, so `status` names them until they are cleared.
function reportKept (key, q) {
  const kept = (q.kept || []).filter(k => k.repo === key && fs.existsSync(k.worktree))
  if (!kept.length) return
  console.log(yellow(`${key}: ${kept.length} landed entr${kept.length === 1 ? 'y' : 'ies'} left a worktree kept, because it holds files the run did not make`))
  for (const k of kept) {
    console.log(dim(`  · ${k.branch} — ${k.worktree}`))
    console.log(dim(`    ${k.reason}`))
    console.log(dim(`    Look first: ${k.look}`))
    console.log(dim(`    Then, once you have kept what you want: ${k.cure}`))
  }
  console.log('')
}

/**
 * `main` sitting on a merge whose message told the host not to build it.
 *
 * It is the one state this feature can leave behind that nobody would otherwise
 * look for: the branches all landed, the queue is empty, `git log` looks
 * healthy, and production is serving the build from before the landing run. It arises
 * when the last entry of a run is dequeued rather than landed, and it is cleared
 * by the next landing run of that repo (`settleDeploy`), which is what this says.
 * Silent for every repo that configures no `deploy`.
 */
function reportUndeployedTip (key, repo) {
  const undeployed = deployLanes(repo).filter(n => laneUndeployed(repo, n))
  if (!undeployed.length) return
  console.log(yellow(`${key}: ${repo.mainBranch} is sitting on a build the host was told to skip${multiLane(repo) ? ` in ${lanePhrase(undeployed)}` : ''}`))
  console.log(dim(`  Production still serves what it served before that merge.`))
  console.log(dim(`  The next landing run of this repo publishes it:  local-merge-queue land ${key}`))
  console.log('')
}

/**
 * Branches this repo has LANDED and not finished putting away: a local ref that
 * is fully merged into `main`, has no worktree, and is in no queue entry.
 *
 * `status` reports it because an empty queue was the one place the merge queue said
 * nothing at all, and residue from a failed cleanup is invisible precisely when
 * there is nothing left to look at. Three branches accumulated this way in a day
 * (2026-08-19) and it took a roster sweep to notice. Reported, never deleted:
 * a ref that survived cleanup may be the one thing pointing at work somebody
 * still wants, and the merge queue has no business guessing which.
 */
function reportResidue (key, repo) {
  let merged
  try {
    merged = git(['branch', '--merged', repo.mainBranch, '--format=%(refname:short)'], repo.checkout)
      .split('\n').map(s => s.trim()).filter(Boolean)
      .filter(b => b !== repo.mainBranch)
  } catch { return }
  if (!merged.length) return
  let held = new Set()
  try {
    held = new Set(
      git(['worktree', 'list', '--porcelain'], repo.checkout)
        .split('\n').filter(l => l.startsWith('branch '))
        .map(l => l.slice('branch refs/heads/'.length))
    )
  } catch { /* no worktrees is a fine answer */ }
  // A SHELF IS A LANDED-LOOKING BRANCH ON PURPOSE. It preserves code that was
  // REMOVED from main, so it is fully merged by construction and reads exactly
  // like residue — and it is the one kind of branch that must never be deleted.
  // Matched on the word rather than a suffix: one repo here spells it
  // `analytics-page-shelved`, and a naming convention nobody has enforced across
  // four repos is not something to hang a delete suggestion on.
  const stale = merged.filter(b => !held.has(b) && !/shelf|shelved/i.test(b))
  if (!stale.length) return
  console.log(yellow(`${key}: ${stale.length} landed branch(es) still have a local ref`))
  for (const b of stale) console.log(dim(`  · ${b} — merged into ${repo.mainBranch}, no worktree`))
  console.log(dim(`  If they are residue from a landing run, clear them:`))
  console.log(dim(`    git -C ${repo.checkout} branch -d ${stale.join(' ')}`))
  console.log(dim(`  Check first — a branch preserving removed code looks identical from here.`))
  console.log('')
}

// One named entry, scoped to its repo. Branch names are unique within a repo,
// not across the queue: two repos can each enqueue a branch called
// "fitness-functions". The repo comes from --repo, or from the worktree the
// command runs in; with neither, a name two repos share is refused rather
// than guessed, because a guess can move or dequeue another session's entry.
function entryNamed (cfg, q, name, args) {
  const key = args['--repo'] || detectHere(cfg)?.repo.key
  const hits = q.entries.filter(x => x.branch === name && (!key || x.repo === key))
  if (!hits.length) die(`"${name}" is not in the queue${key ? ` for ${key}` : ''}`)
  if (hits.length > 1) {
    die(`"${name}" is queued in ${hits.map(x => x.repo).join(' and ')} — pass --repo <repo>`)
  }
  return hits[0]
}

// A name given to approve or unapprove without --repo must not reach two repos.
function refuseAmbiguous (q, names, args) {
  if (args['--repo']) return
  for (const name of names) {
    const repos = [...new Set(q.entries.filter(x => x.branch === name).map(x => x.repo))]
    if (repos.length > 1) die(`"${name}" is queued in ${repos.join(' and ')} — pass --repo <repo>`)
  }
}

function cmdApprove (cfg, args) {
  const all = args['--all']
  const names = args._
  if (!all && !names.length) die('name the branches to approve, or pass --all')
  refuseAmbiguous(loadQueue(), names, args)
  const n = mutateQueue(q => {
    let n = 0
    for (const e of q.entries) {
      if (e.status !== 'enqueued') continue
      if (args['--repo'] && e.repo !== args['--repo']) continue
      if (all || names.includes(e.branch)) { e.status = 'approved'; e.approved = nowISO(); n++ }
    }
    return n
  })
  console.log(`${green('approved')} ${n} branch(es). Land them with: local-merge-queue land <repo>`)
}

// The inverse of approve, and it exists because an approved entry is a state
// the owner may want to take back — a change of mind, a branch that needs one more
// look — without dequeuing it out of the queue and losing its place. It reaches
// only as far as the landing run: once a branch is landing, `dequeue` and `resume` are
// what govern it.
function cmdUnapprove (cfg, args) {
  const all = args['--all']
  const names = args._
  if (!all && !names.length) die('name the branches to unapprove, or pass --all')
  refuseAmbiguous(loadQueue(), names, args)
  const wanted = e => (all || names.includes(e.branch)) &&
    (!args['--repo'] || e.repo === args['--repo'])
  // A stalled entry is mid-landing: its worktree holds a rebase in progress, so
  // moving it back to enqueued would leave the queue describing a state the disk
  // does not. Say so rather than half-doing it.
  const { stalled, n } = mutateQueue(q => {
    const stalled = q.entries.filter(e => e.status === 'stalled' && wanted(e)).map(e => ({ repo: e.repo, branch: e.branch }))
    let n = 0
    for (const e of q.entries) {
      if (e.status !== 'approved') continue
      if (!wanted(e)) continue
      e.status = 'enqueued'
      delete e.approved
      delete e.batch
      n++
    }
    return { stalled, n }
  })
  for (const e of stalled) {
    console.log(yellow(`${e.repo}/${e.branch} is STALLED mid-landing — unapprove will not touch it.`))
    console.log(dim(`  Resolve it and ${bold('local-merge-queue resume')} ${e.repo}, or ${bold('local-merge-queue dequeue')} ${e.branch}.`))
  }
  if (!n) {
    console.log(dim('nothing to unapprove — no matching entry was approved'))
    return
  }
  console.log(`${yellow('enqueued')} ${n} branch(es) again. The branch, its worktree and its place in the queue are untouched.`)
  console.log(dim('  Re-approve with: local-merge-queue approve <branch>'))
}

function cmdDequeue (cfg, args) {
  const name = args._[0]
  if (!name) die('name the branch to dequeue')
  // The name is resolved first, outside the lock, because that runs git (the repo
  // is taken from the worktree the command runs in). Under the lock the entry is
  // found again by repo and branch, with no git at all.
  const target = entryNamed(cfg, loadQueue(), name, args)
  const e = mutateQueue(q => {
    const e = q.entries.find(x => sameEntry(x, target))
    if (e) q.entries = q.entries.filter(x => x !== e)
    return e
  })
  if (!e) die(`"${name}" left the queue while this command ran`)
  // If it stalled mid-rebase, put the worktree back as it was.
  if (e.status === 'stalled' && e.worktree && fs.existsSync(path.join(e.worktree, '.git'))) {
    gitTry(['rebase', '--abort'], e.worktree)
  }
  console.log(`${yellow('dequeued')} ${e.repo}/${e.branch} — the branch and its worktree are untouched`)
}

function cmdOrder (cfg, args) {
  const name = args._[0]
  if (!name) die('name the branch to move')
  if (!args['--first'] && !args['--last']) {
    const pos = Number(args._[1])
    if (!Number.isInteger(pos) || pos < 1) die('pass --first, --last, or a 1-based position')
  }
  const target = entryNamed(cfg, loadQueue(), name, args)   // resolved outside the lock; see cmdDequeue
  const e = mutateQueue(q => {
    const idx = q.entries.findIndex(x => sameEntry(x, target))
    if (idx < 0) return null
    const [e] = q.entries.splice(idx, 1)
    if (args['--first']) q.entries.unshift(e)
    else if (args['--last']) q.entries.push(e)
    else q.entries.splice(Number(args._[1]) - 1, 0, e)
    return e
  })
  if (!e) die(`"${name}" left the queue while this command ran`)
  console.log(`${green('reordered')} — land refactors early; every branch behind one rebases over it anyway`)
  cmdStatus(cfg, { _: [e.repo] })
}

// CLEANUP, the same for an entry landed alone and for each entry of a batch.
// `wt` is the entry's worktree; the branch is already on `main` and pushed.
//
// CLEANUP DESTROYS ONLY WHAT IT CAN SHOW IS LANDED. `landedTip` is the commit that was
// merged (the gated commit, or the published tip of a batched entry, or an already-merged
// branch's tip). The worktree is removed only if its HEAD is that commit and its status
// shows nothing the gate had not already found there (`baseline`: the status recorded
// after the setup; an empty list for an entry that was not gated in its own worktree),
// because `worktree remove --force` deletes uncommitted and untracked files, and work
// made in the worktree after the gate is the author's and was never landed. The remote
// branch is deleted only if its tip on origin IS the landed tip: a commit somebody
// pushed to it after the publish would be deleted with it. Either refusal is said in red
// as residue, and the merge is done regardless.
// A landed entry whose worktree was kept is no longer in the queue, so the queue file keeps
// a record of it (`kept`), for `status` to show until the worktree is gone. The run's exit
// status is 3 when any cleanup left residue (and nothing stalled or was refused).
let residueLeft = 0
function recordKept (repo, entry, wt, reason, cure, look) {
  mutateQueue(q => {
    q.kept = (q.kept || []).filter(k => fs.existsSync(k.worktree) && !(k.repo === repo.key && k.branch === entry.branch))
    q.kept.push({ repo: repo.key, branch: entry.branch, worktree: wt, reason, cure, look, since: nowISO() })
  })
}

// `baseline` is the worktree's status, ignored files included, as the gate left it, and `gated`
// says there is one; without it (a cleanup-only entry, a batched one) the worktree was clean
// when the entry was enqueued, and its ignored files (dependencies) are expected.
function cleanupLanded (repo, entry, wt, { landedTip = null, baseline = [], gated = false } = {}) {
  const short = x => String(x).slice(0, 9)
  if (!landedTip) {
    const tip = gitTry(['rev-parse', '--verify', '-q', `refs/heads/${entry.branch}`], repo.checkout)
    landedTip = tip.ok ? tip.out : null
  }
  // 5. Cleanup — the lifecycle the roster rule asks for, done by the thing
  //    that did the merge rather than by whoever remembers.
  //
  // A CLEANUP STEP THAT FAILS SAYS SO IN RED AND LEAVES A RESIDUE LINE.
  // It used to report every failure in dim, the same weight as a success,
  // at the very end of a landing run whose last two hundred lines are gate output.
  // Three branches in a row (`story-graph`, `audit-repairs`, `graph-colors`,
  // 2026-08-19) landed leaving their LOCAL ref behind, and nobody noticed
  // until a roster sweep found three branches that no longer existed
  // anywhere else. The failures were almost certainly printed; nothing about
  // how they were printed said they mattered.
  const residue = []
  const step = (label, res, note) => {
    if (res.ok) {
      console.log(dim(`  ${label}`))
      return true
    }
    console.log(red(`  ${label.toUpperCase()} FAILED: ${res.err || '(no stderr)'}`))
    residue.push(note)
    return false
  }

  const keepWorktree = []
  let ignoredHere = []
  if (fs.existsSync(wt)) {
    const all = statusLines(wt, { ignored: true })
    ignoredHere = all.filter(l => l.startsWith('!!')).map(l => l.slice(3))
    const extra = all.filter(l => !baseline.includes(l) && (gated || !l.startsWith('!!')))
    if (extra.length) {
      keepWorktree.push(gated
        ? `it holds files that appeared after the gate ended: ${extra.map(l => l.trim()).join('; ')}`
        : `it holds files that were not there when the entry was enqueued: ${extra.map(l => l.trim()).join('; ')}`)
    }
    const head = gitTry(['rev-parse', 'HEAD'], wt)
    if (landedTip && (!head.ok || head.out !== landedTip)) keepWorktree.push(`its HEAD is ${head.ok ? short(head.out) : '(unreadable)'}, not the landed tip ${short(landedTip)}`)
    if (!landedTip) keepWorktree.push('the landed tip could not be read')
  }
  // `worktree remove --force` deletes ignored files too, which no status line of the
  // ordinary kind shows: they are named here before they go, so the run never deletes
  // what its output did not say.
  if (!keepWorktree.length && ignoredHere.length) {
    console.log(dim(`  ignored files go with the worktree: ${ignoredHere.slice(0, 8).join(', ')}${ignoredHere.length > 8 ? `, and ${ignoredHere.length - 8} more` : ''}`))
  }
  const rm = keepWorktree.length ? null : gitTry(['worktree', 'remove', '--force', wt], repo.checkout)
  if (rm) step('worktree removed', rm, `worktree still registered at ${wt}`)
  else {
    const look = `git -C ${wt} status --ignored`
    const cure = `git -C ${repo.checkout} worktree remove --force ${wt} && git -C ${repo.checkout} branch -d ${entry.branch}`
    console.log(red(`  WORKTREE KEPT: ${keepWorktree.join('; ')}.`))
    console.log(red(`  Removing it would delete that work, so the worktree and the local branch stay; the merge is done.`))
    console.log(dim(`  Look first: ${look}`))
    console.log(dim(`  Then, once you have kept what you want: ${cure}`))
    residue.push(`worktree kept at ${wt}: ${keepWorktree.join('; ')}. Look first: ${look}. Then: ${cure} (branch -D instead of -d only if you do not want commits made there after the merge)`)
    recordKept(repo, entry, wt, keepWorktree.join('; '), cure, look)
  }
  // PRUNE BETWEEN THE TWO, ALWAYS. `git branch -d` refuses a branch git
  // still believes is checked out in a worktree, and a worktree whose
  // directory has gone without `worktree remove` leaves exactly that belief
  // behind in `.git/worktrees/`. This repo had a stale entry of that kind
  // sitting there while three branches failed to delete. Pruning is cheap,
  // idempotent, and touches only admin files for worktrees that are already
  // gone — it can never remove a live one.
  gitTry(['worktree', 'prune'], repo.checkout)
  let del = keepWorktree.length ? { ok: true, kept: true } : gitTry(['branch', '-d', entry.branch], repo.checkout)   // -d refuses if unmerged
  if (!del.ok) {
    // One retry, after a fetch. One way `-d` refuses is by reading the
    // branch as unmerged, and the merge that landed it is a commit `origin`
    // has and this checkout may not have re-read yet.
    gitTry(['fetch', 'origin', repo.mainBranch], repo.checkout)
    del = gitTry(['branch', '-d', entry.branch], repo.checkout)
  }
  if (!del.ok) {
    // AND IF IT STILL REFUSES, ASK THE QUESTION `-d` IS ASKING AND ANSWER IT
    // OURSELVES. `-d` is a safety check — "is this work reachable from
    // somewhere else?" — and here the answer is knowable exactly: the merge
    // that just landed is on `main`, so if the branch tip is an ancestor of
    // `main`, deleting the ref destroys nothing. That is the entire
    // guarantee `-d` exists to provide, verified directly rather than
    // inferred from whatever `-d` was unhappy about.
    //
    // WHY THIS IS NOT SIMPLY REACHING FOR `-D`. It is `-D` gated on a proof,
    // and the proof is the point: four branches landed on 2026-08-19 leaving
    // their local ref behind, `-d` took every one of them cleanly minutes
    // later, and the cause was never reproduced. A retry loop against an
    // unknown cause is a guess; asking "is this work safe to drop" and
    // getting a yes is not.
    const contained = gitTry(
      ['merge-base', '--is-ancestor', entry.branch, `origin/${repo.mainBranch}`],
      repo.checkout
    ).ok
    if (contained) {
      const forced = gitTry(['branch', '-D', entry.branch], repo.checkout)
      if (forced.ok) {
        console.log(dim(`  local branch deleted (forced — proved contained in ${repo.mainBranch})`))
        console.log(dim(`    \`branch -d\` had refused: ${del.err || '(no stderr)'}`))
      }
      del = forced
    }
  }
  if (!del.kept) step('local branch deleted', del, `local branch \`${entry.branch}\` still exists`)
  // MOVE ANY PULL REQUEST STACKED ON THIS BRANCH ONTO main BEFORE THE
  // REMOTE BRANCH GOES — deleting a PR's base branch closes it permanently.
  // See retargetStackedPrs for the whole argument. It never fails a landing.
  retargetStackedPrs(repo, entry.branch)
  // DELETING THE REMOTE BRANCH IS WHAT CLOSES THE PULL REQUEST, SO CONFIRM
  // IT WILL CLOSE AS *MERGED* BEFORE DOING IT.
  //
  // GitHub marks a PR merged when its head becomes reachable from the base,
  // and it decides that asynchronously. The publish at step 3b and the push
  // at step 4 make it true; they do not make GitHub have noticed yet. Delete
  // the branch inside that window and GitHub resolves the race the other
  // way — the PR closes as ABANDONED, permanently, with no API anywhere to
  // flip it afterwards.
  //
  // That is not hypothetical. On 2026-08-25 `deletion-completeness` landed
  // cleanly, its tip was published, its head WAS reachable from main — and
  // #98 still reads CLOSED, while the three entries either side of it read
  // MERGED. The difference was seconds. The roster is the record of what
  // happened, so a false entry in it is worse than a branch left behind:
  // one is a lie nobody can correct, the other is a line of cleanup.
  //
  // So: poll briefly, delete only on MERGED, and when it never arrives keep
  // the branch and say why. Skipped entirely when no githubRepo is
  // configured — the test suite runs against a bare local repo with no PR
  // to wait for, and must not pay for this.
  let rdel = { ok: true }
  let prState = 'no github repo configured'
  // The remote branch goes only if its tip on origin is the landed tip.
  const lsr = gitTry(['ls-remote', 'origin', `refs/heads/${entry.branch}`], repo.checkout)
  const remoteTip = lsr.ok ? (lsr.out.split(/\s+/)[0] || '') : null
  if (remoteTip === null || (remoteTip && remoteTip !== landedTip)) {
    console.log(red(remoteTip === null
      ? `  REMOTE BRANCH KEPT: origin could not be asked what its tip is (${lsr.err || 'no stderr'}).`
      : `  REMOTE BRANCH KEPT: its tip on origin is ${short(remoteTip)}, which is not the landed tip ${short(landedTip)} — somebody pushed to it after the publish, and deleting it would delete that work.`))
    residue.push(`remote branch \`${entry.branch}\` kept on purpose — ${remoteTip === null ? 'origin could not be read' : `its tip ${short(remoteTip)} is not the landed tip ${short(landedTip)}`}; look at it, then: git -C ${repo.checkout} push origin --delete ${entry.branch}`)
  } else if (!remoteTip) {
    console.log(dim('  remote branch already gone'))
  } else if (!repo.githubRepo) {
    rdel = gitTry(['push', 'origin', '--delete', entry.branch], repo.checkout)
    step('remote branch deleted', rdel, `remote branch \`${entry.branch}\` still exists`)
  } else {
    const merged = waitForPrMerged(repo, entry.branch)
    if (merged) {
      rdel = gitTry(['push', 'origin', '--delete', entry.branch], repo.checkout)
      step('remote branch deleted', rdel, `remote branch \`${entry.branch}\` still exists`)
    } else {
      console.log(red('  REMOTE BRANCH KEPT: its pull request has not registered as merged yet.'))
      console.log(red('  Deleting it now would close the PR as abandoned, which cannot be undone.'))
      console.log(dim(`  The merge is done and pushed. Once the PR reads MERGED, delete it with:`))
      console.log(dim(`    git -C ${repo.checkout} push origin --delete ${entry.branch}`))
      residue.push(
        `remote branch \`${entry.branch}\` kept on purpose — its PR had not registered as ` +
        'merged; delete it once GitHub catches up'
      )
    }
  }
  prState = reportPrState(repo, entry.branch)
  if (typeof prState === 'string') {
    console.log(dim(`  pr: ${prState}`))
  } else {
    console.log(red(`  ${prState.warn}`))
    residue.push(prState.warn)
  }

  // The branch IS landed either way — cleanup residue is untidiness, never a
  // reason to stall the line or to leave the entry looking unfinished. It is
  // said once, plainly, where the person running the landing run will read it.
  if (residue.length) {
    residueLeft += residue.length
    console.log(red(`  ${entry.branch} landed, but its cleanup left residue:`))
    for (const r of residue) console.log(red(`    · ${r}`))
    console.log(dim('    Clear it by hand; the merge itself is done and pushed.'))
  }
}

// The heart of it.
async function cmdLand (cfg, args, { resuming = false } = {}) {
  const key = args._[0] || detectHere(cfg)?.repo.key
  if (!key) die('name the repo to land (or run from inside one of its worktrees)')
  const repo = repoOf(cfg, key)
  const dryRun = !!args['--dry-run']
  const batchOpt = batchFor(repo, args)
  if (batchOpt) requireBatchGit()

  // A STALL HOLDS ONLY ITS OWN LANES, so `land` refuses only when every lane
  // of the repo is held. A one-lane repo's every stalled entry holds its one
  // lane (see `queueLanesOf`), so it refuses exactly when it always has.
  const q = loadQueue()
  const stalledNow = stalledIn(key, q.entries)
  const blocked = blockedLanes(repo, q.entries)
  if (stalledNow.length && !resuming && Object.keys(repo.lanes).every(n => blocked.has(n))) {
    const stalled = stalledNow[0]
    die(`${key} is stalled on "${stalled.branch}" — resolve it, then: local-merge-queue resume ${key}\n` +
        `  report: ${reportFile(key, stalled.branch)}` +
        stalledNow.slice(1).map(e => `\n  also stalled on "${e.branch}" — report: ${reportFile(key, e.branch)}`).join(''))
  }

  const problems = preflight(repo)
  if (problems.length) {
    die(`${key} is not ready to land:\n  - ${problems.join('\n  - ')}`)
  }

  const lock = dryRun ? true : acquireLock(key)
  // THE KNOWN-RED FILE IS WRITTEN UNDER THE LOCK: written before it, a second `land`
  // that was about to be refused deleted and rewrote the file the running holder's gates
  // read (found by the independent re-check, 2026-11-21).
  if (lock) announceKnownRed(repo, { write: !dryRun })
  if (!lock) {
    const owner = readJSON(path.join(LOCK_DIR, key, 'owner.json'), null)
    if (owner && !pidAlive(owner.pid) && groupAlive(owner.gatePgid)) {
      die(`${key}: the landing run (pid ${owner.pid}, since ${owner.since}) is gone, but the gate it started is still running (process group ${owner.gatePgid}), so the lock stays held until that gate ends.\n` +
          `  Look at what that group is before you end anything:  ${groupHint(owner.gatePgid)}\n` +
          `  If it is a gate of this repository, wait for it, or end it with:  kill -TERM -- -${owner.gatePgid}\n` +
          `  If it is not (a process group id can be reused by an unrelated process once the gate's own group is gone), nothing of this repository is running: ` +
          `confirm that, then release the lock by hand with:  rm -rf ${path.join(LOCK_DIR, key)}`)
    }
    die(`${key} is being landed already (pid ${owner?.pid ?? '?'}, since ${owner?.since ?? '?'})`)
  }
  // Whatever way this run ends (a die, a signal), its batch marks go and its lock is released.
  if (!dryRun) {
    onExit(() => { releaseQueueLock(); mutateQueue(q => { for (const e of q.entries) if (e.repo === key) delete e.batch }) })
  }

  if (multiLane(repo) && stalledNow.length && !resuming) {
    for (const e of stalledNow) {
      const names = queueLanesOf(repo, e)
      console.log(yellow(`  ${lanePhrase(names)} ${names.length === 1 ? 'waits' : 'wait'} behind the stall on "${e.branch}"; entries in other lanes keep landing`))
    }
  }

  // A DEAD RUN CAN LEAVE A BATCH MARK ON ENTRIES THAT NEVER LANDED; this run starts clean.
  if (!dryRun) {
    mutateQueue(q => { for (const e of q.entries) if (e.repo === key) delete e.batch })
  }
  // The entries this run starts with. Anything it lands that is not among them was
  // approved while it ran, and the output says so.
  const startedWith = new Set(loadQueue().entries
    .filter(e => e.repo === key && (e.status === 'approved' || (resuming && e.status === 'stalled'))).map(e => e.branch))
  const pickedUp = new Set()

  const landed = []
  const landedLanes = []              // lanes of every entry landed this run, for the final check
  const simulated = new Set()          // dry-run only; the real queue is never written
  // Entries this run gives up on: the ones that stall during it, and the ones
  // `resume` finds unready. Only a multi-lane repo carries on past either; a
  // one-lane repo still ends the run at the first, as it always has, because
  // every entry behind a stall there shares its one lane.
  const held = new Set()
  let refused = false                  // `resume` found a stalled entry unready
  // Batched landing (see `runBatch`): in a dry run, the entries it would gate
  // together; the entries a failed batch sent back to one-at-a-time landing; and
  // the batches this run landed.
  const preGated = new Map()
  const noBatch = new Set()
  const batchesRun = []
  // Record a stall in the queue as it stands now. False when the entry was
  // dequeued during the run: nothing is written, and nothing is left to hold the line.
  const recordStall = (entry, fields) => {
    Object.assign(entry, fields)
    if (patchEntry(entry, fields)) return true
    console.error(yellow(`  ${entry.branch} was dequeued during this run — no stall recorded`))
    held.add(entry.branch)
    return false
  }
  // Was the entry taken back during the run, by `unapprove` or `dequeue`? Then it
  // does not land, whatever the run read when it picked the entry.
  const withdrawn = entry => {
    const now = freshEntry(entry)
    if (now && now.status === 'approved') return false
    console.log(yellow(`  ${entry.branch} was ${now ? 'unapproved' : 'dequeued'} during this run — not landing it`))
    held.add(entry.branch)
    return true
  }
  // The line a multi-lane stall adds to its console report. At each stall a
  // one-lane repo returns at once; a multi-lane repo holds the entry and the
  // loop moves on to the entries in other lanes.
  const stallLine = e => multiLane(repo)
    ? `Entries in ${lanePhrase(queueLanesOf(repo, e))} wait behind it; entries in other lanes keep landing.`
    : null
  // A stall found after the gate has passed (the gate's claim no longer holds). Records it,
  // writes the report and says so; returns 'end' when the run ends here (a one-lane repo)
  // and 'next' when the loop goes on to the entries in other lanes.
  const stallAfterGate = (entry, reason, kind, detail, fixSteps, headline) => {
    if (!recordStall(entry, { status: 'stalled', ownerCall: false, stallReason: reason })) return 'next'
    const file = writeStallReport(repo, entry, kind, detail, [], false, fixSteps)
    console.error(red(`\n  STALLED — ${headline}`))
    console.error(`  report: ${file}`)
    if (!multiLane(repo)) return 'end'
    console.error(dim(`  ${stallLine(entry)}`))
    held.add(entry.branch)
    return 'next'
  }
  try {
    while (true) {
      const q2 = loadQueue()
      const queued = new Map(q2.entries.map(e => [`${e.repo}:${e.branch}`, e]))
      const entry = q2.entries.find(e => eligible(cfg, e, key, { queued, simulated, resuming, held }))
      if (!entry) break

      if (!dryRun && !startedWith.has(entry.branch) && !pickedUp.has(entry.branch)) {
        pickedUp.add(entry.branch)
        console.log(yellow(`\n  ${entry.branch} was approved during this run — picking it up`))
      }

      // BATCHED LANDING, WHEN ASKED FOR: gate several entries once, and land them in one push.
      if (batchOpt && !preGated.has(entry.branch) && !noBatch.has(entry.branch)) {
        const members = formBatch(cfg, repo, key, entry, q2, { simulated, held, noBatch, preGated, max: batchOpt.max })
        if (members) {
          const names = members.map(e => e.branch)
          if (dryRun) {
            console.log(`\n${bold('batch')} ${names.length} entries gated together, one gate run: ${names.join(', ')}`)
            const plan = batchGatePlan(repo, members)
            for (const n of plan.run) {
              const steps = gateStepsFor(repo, { reached: plan.reached }, n)
              console.log(dim(`  gate [${n}]: ${steps.length ? steps.join(' && ') : '(no steps)'}`))
            }
            for (const e of members) preGated.set(e.branch, { names })
          } else {
            console.log(`\n${bold('batch')} ${names.length} entries: ${names.join(', ')} — building the candidate and gating it once; nothing is pushed until the gate passes, and then main is pushed once`)
            const clearMarks = () => mutateQueue(q => { for (const e of q.entries) if (e.repo === key) delete e.batch })
            try {
              const markBatch = built => mutateQueue(q => { for (const e of q.entries) if (e.repo === key && built.includes(e.branch)) e.batch = { with: built } })
              const res = await runBatch(cfg, repo, key, members, { held, onBuilt: markBatch })
              batchesRun.push(names)
              for (const e of res.landed) landed.push(e.branch)
              landedLanes.push(...res.lanes)
              continue
            } catch (err) {
              for (const e of members) noBatch.add(e.branch)
              clearMarks()
              console.log(red(`  BATCH FAILED: ${err instanceof BatchFailure ? err.message : `unexpected error: ${err.message}`}`))
              const rewrote = err.published?.length
                ? ` The remote ${err.published.length === 1 ? 'branch' : 'branches'} of ${err.published.join(', ')} already carry ${err.published.length === 1 ? 'its' : 'their'} rebased ${err.published.length === 1 ? 'tip' : 'tips'}: origin's copy was rewritten (the same content; the next landing force-pushes it again with a lease).`
                : ''
              console.log(red(`  Nothing has landed and no entry's local branch moved.${rewrote} Falling back to landing ${names.join(', ')} one at a time.`))
            }
          }
        }
      }

      console.log(`\n${bold('──')} ${bold(entry.branch)} ${dim(entry.worktree)}${entry.noRebase ? ' ' + dim('no-rebase') : ''}`)
      if (dryRun) {
        const together = preGated.get(entry.branch)
        console.log(dim(entry.noRebase
          ? `  (dry run — no-rebase: would stall if origin/${repo.mainBranch} is not in the branch; otherwise gate, merge --no-ff, push, clean up)`
          : together
            ? `  (dry run — would be merged --no-ff in a batch whose one gate is run on the candidate and whose main is pushed once: ${together.names.join(', ')})`
            : '  (dry run — would rebase, gate, merge --no-ff, push, clean up)'))
        let dryLanes = Object.keys(repo.lanes)
        if (multiLane(repo)) {
          // Computed live and never stored: a dry run writes nothing.
          const live = gitTry(['rev-parse', '--verify', '-q', `refs/heads/${entry.branch}`], repo.checkout).ok
          const found = {}
          const shown = live ? lanesOf(repo, repo.checkout, entry.branch, found) : (entry.lanes || [])
          dryLanes = shown
          const shownEntry = { lanes: shown, reached: live ? found.reached : (entry.reached || []) }
          console.log(dim(`  lanes: [${laneLabels(shownEntry).join(', ')}]${shownEntry.reached.length ? '  (~ = reached through what a test imports, not through the entry\'s own paths)' : ''}`))
          for (const n of shown) {
            const steps = gateStepsFor(repo, shownEntry, n)
            console.log(dim(`  gate [${n}]: ${steps.length ? steps.join(' && ') : '(no steps)'}`))
          }
        }
        // The marker is per lane: say, for each lane of the entry that has one,
        // whether this merge would carry it.
        for (const n of dryLanes.filter(n => repo.lanes[n].deploy?.skipMarker)) {
          const here = multiLane(repo) ? ` for lane ${n}` : ''
          console.log(dim(moreEligibleAfter(cfg, key, entry, { queue: q2, simulated, resuming, held, lane: n })
            ? `  (dry run — its merge would carry ${repo.lanes[n].deploy.skipMarker}${here}; the host skips that build)`
            : `  (dry run — its merge would be unmarked${here}; this is the one the host builds)`))
        }
        simulated.add(entry.branch)
        landed.push(entry.branch)
        continue
      }

      const wt = entry.worktree
      if (!fs.existsSync(wt)) {
        die(`the worktree for "${entry.branch}" is gone (${wt}) — dequeue the entry or repair the worktree`)
      }

      // LOCAL MAIN MUST EQUAL ORIGIN'S BEFORE AN ENTRY STARTS (see `syncMainWithOrigin`),
      // and "already in main" is asked of origin's main: a merge that exists only in the
      // primary checkout is not a landed branch, and cleaning its entry up would delete
      // the only copy.
      console.log(dim('  fetching…'))
      const drift = syncMainWithOrigin(repo)
      if (drift) die(drift)
      // THE TRUNK THE ENTRY IS BUILT ON IS RECORDED HERE: local `main` as the sync left it. The
      // gate takes minutes, and a pull or a stray commit in the primary checkout during it would
      // move `main` under the rebase the gate ran on; the merge (and each redo) stalls the entry
      // if local `main` is no longer this commit.
      let trunk = git(['rev-parse', repo.mainBranch], repo.checkout)

      // A branch already contained in main needs cleanup, not a merge. This is
      // where the roster's "merged; delete the worktree and this row" backlog
      // lands — the state that accumulates when a merge and its cleanup were
      // two separate acts by two different people.
      const alreadyIn = gitTry(['merge-base', '--is-ancestor', entry.branch, `origin/${repo.mainBranch}`], repo.checkout).ok
      // Set at step 2 below; read again at the pre-merge publish, which is why it
      // is declared out here rather than beside its use.
      let current = false

      // Lanes of the entry being landed, set at step 2a; the final check reads
      // them once the merge is pushed.
      let runLanes = []
      // What the gate ran on: the branch's commit and the worktree's status, recorded
      // after the setup (see `recordBinding`).
      let binding = null

      if (alreadyIn) {
        console.log(dim(`  already contained in ${repo.mainBranch} — cleanup only, no merge`))
      } else {
        // 0. Resuming a stalled entry: the fixer finished the rebase in place.
        //    A setup or gate stall leaves no rebase at all, so this passes for
        //    those without asking anything of the fixer.
        //
        //    An entry that is not ready is refused. A one-lane repo refuses by
        //    ending the run, as it always has. A multi-lane repo reports the
        //    refusal in the same words, holds the entry stalled, and goes on
        //    with the other entries; the run then exits 1.
        let fresh = entry.status !== 'stalled'
        if (!fresh) {
          const notReady = rebaseInProgress(wt)
            ? `the rebase in ${wt} is still in progress — finish it (git rebase --continue) before resuming`
            : entry.ownerCall && !args['--owner-approved']
              ? `"${entry.branch}" stalled on a protected path — resume with --owner-approved once the owner has read the resolution`
              : null
          if (notReady) {
            if (!multiLane(repo)) die(notReady)
            console.error(red(`local-merge-queue: ${notReady}`))
            held.add(entry.branch)
            refused = true
            continue
          }
          const anc = gitTry(['merge-base', '--is-ancestor', `origin/${repo.mainBranch}`, entry.branch], repo.checkout)
          if (!anc.ok) {
            // In a multi-lane repo the other lanes keep landing while this
            // entry is stalled, so `main` moves under a fixer who resolved the
            // rebase onto the `main` of the stall. `resume` rebases the entry
            // again, through step 1 like any other entry; a conflict there
            // stalls it again. A one-lane repo lands nothing past a stall, so
            // there the branch is off `main` only if a push from outside the
            // queue moved it.
            //
            // A --no-rebase entry is never rebased. It falls through to step 2,
            // which stalls it again, with the same reason, unless the fixer
            // has merged origin/main into it.
            //
            // The `origin/main` asked about here was fetched at the start of this
            // entry, so a `main` that moved while the entry was stalled is seen, in
            // a one-lane repo as well: the entry is rebased again and gated again.
            if (entry.noRebase) {
              console.log(dim(`  ${entry.branch} does not contain origin/${repo.mainBranch} — checking it again (--no-rebase)`))
            } else {
              console.log(dim(`  ${repo.mainBranch} moved while ${entry.branch} was stalled — rebasing it again`))
            }
            fresh = true
          }
          entry.status = 'approved'
          delete entry.stallReason
          if (!patchEntry(entry, { status: 'approved' }, ['stallReason'])) {
            console.log(yellow(`  ${entry.branch} was dequeued during this run — skipping it`))
            held.add(entry.branch)
            continue
          }
        }

        // 1. Bring main and the branch up to date.
        if (fresh) {
          // 2. Put the branch on top of the main it will actually land on.
          //
          //    A BRANCH THAT ALREADY CONTAINS origin/main IS NOT REBASED. The
          //    rebase buys one thing: the branch is verified against the main it
          //    lands on. A branch that has MERGED current main has that already,
          //    and rebasing it anyway is not a no-op — it FLATTENS. A plain
          //    rebase drops every merge commit and replays the sides in one
          //    line, so a branch that folded sub-branches (the shape asked for
          //    whenever pieces are developed and tested together) meets its own
          //    commits stripped of the resolutions that reconciled them, and
          //    conflicts against ITSELF in files main never touched. Measured on
          //    one branch here, 2026-08-21, which had folded four: it had merged
          //    current main and merged clean, and a plain rebase still conflicted
          //    in 9 files on the FIRST of 47 commits.
          //
          //    --rebase-merges is NOT the fix. It re-PERFORMS each merge, so any
          //    merge that was resolved by hand raises its conflict again.
          //    Skipping is exact where replaying is a guess: with origin/main an
          //    ancestor, the merge --no-ff below lands the tested tree verbatim.
          current = gitTry(['merge-base', '--is-ancestor', `origin/${repo.mainBranch}`, entry.branch], wt).ok
          if (!current && entry.noRebase) {
            // The branch is never rebased: it lands as it is or not at all.
            if (!recordStall(entry, { status: 'stalled', ownerCall: false,
              stallReason: `main moved under a --no-rebase branch — merge origin/${repo.mainBranch} into it and resume` })) continue
            const file = writeStallReport(repo, entry, 'behind main (--no-rebase)',
              `origin/${repo.mainBranch} is not an ancestor of ${entry.branch}, and the entry is --no-rebase.`, [], false, [],
              { behindMain: true })
            console.error(red(`\n  STALLED — ${entry.stallReason}`))
            console.error(`  In ${wt}: git merge origin/${repo.mainBranch}, resolve if needed, commit.`)
            console.error(`  report: ${file}`)
            if (!multiLane(repo)) {
              console.error(dim('  Nothing behind it was landed. Merge, then: local-merge-queue resume ' + key))
              return { landed, stalledOn: entry.branch }
            }
            console.error(dim(`  ${stallLine(entry)} Merge, then: local-merge-queue resume ${key}`))
            held.add(entry.branch)
            continue
          }
          const rb = current
            ? { ok: true }
            : (console.log(dim(`  rebasing onto origin/${repo.mainBranch}…`)),
               gitTry(['rebase', `origin/${repo.mainBranch}`], wt))
          if (current) {
            console.log(dim(`  already on top of origin/${repo.mainBranch} — no rebase needed`))
          }
          if (!rb.ok) {
            const conflicted = git(['diff', '--name-only', '--diff-filter=U'], wt).split('\n').filter(Boolean)
            const ownerCall = conflicted.some(p => protectedOf(repo).some(pp => p.startsWith(pp)))
            if (!recordStall(entry, { status: 'stalled', ownerCall,
              stallReason: `rebase conflict in ${conflicted.length} file(s)${ownerCall ? ' — OWNER DECISION REQUIRED' : ''}` })) continue
            const file = writeStallReport(repo, entry, 'rebase conflict', rb.err || rb.out, conflicted, ownerCall)
            console.error(red(`\n  STALLED — rebase conflict on ${entry.branch}`))
            console.error(`  ${conflicted.length} conflicted file(s); the rebase is left in progress for you to resolve.`)
            if (ownerCall) console.error(red('  A conflicted path is protected — this one is the owner\'s call, not an agent\'s.'))
            console.error(`  report: ${file}`)
            if (!multiLane(repo)) {
              console.error(dim('  Nothing behind it was landed. Resolve, then: local-merge-queue resume ' + key))
              return { landed, stalledOn: entry.branch }
            }
            console.error(dim(`  ${stallLine(entry)} Resolve, then: local-merge-queue resume ${key}`))
            held.add(entry.branch)
            continue
          }
        }

        // 2a. THE ENTRY'S LANES, RECOMPUTED ON THE REBASED BRANCH. This is the
        //     authoritative set: a conflict resolution can touch a file the
        //     enqueue-time diff never saw.
        const found = {}
        entry.lanes = lanesOf(repo, wt, entry.branch, found)
        entry.reached = found.reached
        patchEntry(entry, { lanes: entry.lanes, reached: entry.reached })
        runLanes = laneNamesFor(repo, entry)
        if (entry.reached.length) console.log(dim(`  lanes: ${runLanes.map(n => entry.reached.includes(n) ? `${n} (reached)` : n).join(', ')}`))

        // 2b. THE BRANCH'S SCAFFOLDING GOES BEFORE THE GATE SEES IT.
        //
        // The roster rule has always said a branch's `BRANCH.md` is deleted in
        // the last commit before the merge. Nothing enforced it, so a branch
        // that forgot LEAKED ITS SCAFFOLDING INTO `main` — and then the next
        // branch to land, carrying a `BRANCH.md` of its own, collided with it
        // and stalled the whole line on a file no shipped thing reads.
        // `story-graph` leaked one that `audit-repairs` quietly cleaned up;
        // `seam-repairs` leaked another that stalled `platform-ontology-split`.
        // Two hand-resolutions in a day, for a rule a machine can simply keep.
        //
        // Doing it HERE rather than at the merge is deliberate: the gate's whole
        // claim is that it ran on exactly what will land, and stripping a file
        // after the gate would make that a sentence rather than a fact.
        const scaffold = path.join(wt, 'BRANCH.md')
        if (fs.existsSync(scaffold)) {
          const rmScaffold = gitTry(['rm', '-q', 'BRANCH.md'], wt)
          const cmScaffold = rmScaffold.ok
            ? gitTry(['commit', '-q', '-m', 'BRANCH.md goes, as scaffolding does before a merge'], wt)
            : rmScaffold
          if (cmScaffold.ok) console.log(dim('  BRANCH.md removed — scaffolding never lands'))
          else console.log(red(`  BRANCH.md NOT removed: ${cmScaffold.err || '(no stderr)'}`))
        }

        // 2c. GIVE THE WORKTREE THE ENVIRONMENT THE GATE NEEDS, IF IT HAS NONE.
        //
        // AFTER the rebase, deliberately: `npm install` installs what the
        // branch's own package.json asks for once the branch is on top of the
        // main it will land on, and a rebase that conflicts should cost nothing
        // — a stall at step 2 pays for no install at all.
        //
        // Which means a setup failure has NO rebase behind it to resolve, and
        // the report says so rather than sending the fixer looking for a
        // conflict that does not exist.
        //
        const setup = await ensureWorktreeSetup(repo, wt, runLanes)
        if (!setup.ok) {
          // A multi-lane repo names the lane whose setup failed.
          const inLane = multiLane(repo) ? ` in lane ${setup.lane}` : ''
          const verb = setup.timedOut ? `worktree setup timed out after ${fmtMinutes(setup.timeoutMs / 60000)}` : 'worktree setup failed'
          if (!recordStall(entry, { status: 'stalled', stallReason: `${verb}${inLane}: ${setup.failed}` })) continue
          const file = writeStallReport(repo, entry, `${verb}${inLane}`,
            `This worktree lacked its generated environment — \`${setup.probe || '(no probe configured)'}\` said so —\n` +
            (setup.timedOut ? `and the setup step that fills it in ran past its limit and was ended:\n\n` : `and the setup step that fills it in exited non-zero:\n\n`) +
            `    ${setup.failed}\n\n` +
            `Its output is above, in the landing run log. The gate never ran; nothing here is a\n` +
            `verdict on the branch.`,
            [], false, [setup.failed])
          console.error(red(`\n  STALLED — ${verb}${inLane} on ${entry.branch}`))
          console.error(`  the step that failed: ${setup.failed}`)
          console.error(dim('  The rebase is complete — there is no conflict to resolve, and the gate'))
          console.error(dim('  has not run. Fix the environment in that worktree, then: local-merge-queue resume ' + key))
          console.error(`  report: ${file}`)
          if (!multiLane(repo)) return { landed, stalledOn: entry.branch }
          console.error(dim(`  ${stallLine(entry)}`))
          held.add(entry.branch)
          continue
        }

        // 2d. WHAT THE GATE WILL RUN ON IS RECORDED HERE: the branch's commit and the
        //     worktree's status. The publish and the merge name this commit, and the
        //     entry stalls if the branch or the worktree has changed by then.
        binding = recordBinding(repo, entry, wt)
        if (binding.error) {
          const s = stallAfterGate(entry, binding.error, 'the worktree is not on its branch',
            `${binding.error}, so the gate would not run on the commit that would land.`,
            ['git status', `git checkout ${entry.branch}`], `${binding.error} (${entry.branch})`)
          if (s === 'end') return { landed, stalledOn: entry.branch }
          continue
        }

        // 3. The gate: what would break a writer, run on exactly what will land.
        let gateOK = true
        let gateFailed = null
        let gateLane = null
        let gateHung = false
        gate: for (const name of runLanes) {
          for (const step of gateStepsFor(repo, entry, name)) {
            console.log(dim(`  gate: ${step}`))
            if (!await runGate(step, wt, repo.lanes[name].gateEnv || {}, { timeoutMs: gateTimeoutMs(repo, name) })) { gateOK = false; gateHung = gateTimedOut; gateFailed = step; gateLane = name; break gate }
          }
        }
        if (!gateOK) {
          // A multi-lane repo names the lane whose gate failed.
          const inLane = multiLane(repo) ? ` in lane ${gateLane}` : ''
          const hung = `gate timed out after ${fmtMinutes(gateTimeoutMs(repo, gateLane) / 60000)}${inLane}`
          if (!recordStall(entry, { status: 'stalled', stallReason: gateHung ? hung : `gate failed after rebase${inLane}` })) continue
          const file = writeStallReport(repo, entry, gateHung ? hung : `gate failed after rebase${inLane}`,
            gateHung
              ? `The gate step \`${gateFailed}\` ran past its limit (gateTimeoutMinutes) and was ended, with its whole process group. Its output so far is above, in the landing run log.`
              : `The gate step \`${gateFailed}\` exited non-zero. Its output is above, in the landing run log.`,
            [], false, [gateFailed])
          console.error(red(gateHung
            ? `\n  STALLED — the gate${multiLane(repo) ? ` of lane ${gateLane}` : ''} timed out after ${fmtMinutes(gateTimeoutMs(repo, gateLane) / 60000)} on ${entry.branch}: ${gateFailed}`
            : `\n  STALLED — the gate${multiLane(repo) ? ` of lane ${gateLane}` : ''} failed on ${entry.branch} after rebasing.`))
          console.error(dim(gateHung
            ? '  The hung gate was ended and the landing lock is released when the run ends.'
            : '  This is the queue working: it passed on the old main and fails on the new one.'))
          console.error(`  report: ${file}`)
          if (!multiLane(repo)) return { landed, stalledOn: entry.branch }
          console.error(dim(`  ${stallLine(entry)}`))
          held.add(entry.branch)
          continue
        }

        // 3-. WHAT THE GATE LEFT BEHIND IS RECORDED HERE, for cleanup: whatever the worktree
        //     holds when the gate ends (build output, a temp folder, ignored files) is the
        //     gate's own, and is not "made since the gate". The binding above keeps the
        //     record from before the gate; cleanup uses this one.
        binding.after = statusLines(wt, { ignored: true })

        // 3a. THE QUEUE MAY HAVE CHANGED DURING THE GATE, which takes minutes. An
        //     entry unapproved or dequeued in that time is not landed.
        if (withdrawn(entry)) continue

        // 3a'. THE BRANCH AND THE WORKTREE ARE WHAT THE GATE RAN ON, or the gate's
        //      verdict is about something that will not land.
        const bound = () => {
          const broke = bindingBroken(repo, entry, wt, binding, runLanes)
          if (!broke) return 'ok'
          return stallAfterGate(entry, `changed during the gate: ${broke}`, 'the branch or its worktree changed during the gate',
            `${broke}.\n\nThe gate ran on ${binding.sha}, so the gate did not see what would land. Nothing was published or merged.`,
            ['git status', `git log --oneline origin/${repo.mainBranch}..${entry.branch}`,
             '# take out or commit what changed (the gate runs again on resume), then resume'],
            `${entry.branch} changed during the gate — ${broke}`)
        }
        testHold('before-first-check')
        let b = bound()
        if (b === 'end') return { landed, stalledOn: entry.branch }
        if (b === 'next') continue
        const trunkMoved = () => {
          const now = git(['rev-parse', repo.mainBranch], repo.checkout)
          return now === trunk ? null
            : `local ${repo.mainBranch} moved during the gate: it was ${trunk.slice(0, 9)} when the entry started and is ${now.slice(0, 9)} now (a pull, or a commit made in the primary checkout)`
        }

        // 3b. PUBLISH THE REBASED TIP BEFORE THE MERGE. Not optional bookkeeping:
        //     the pull request is the roster now, and this is the one step that
        //     lets it retire itself honestly.
        //
        //     GitHub marks a PR merged when its head commit becomes reachable
        //     from the base branch. A rebase at step 2 rewrote every SHA, so the
        //     commits about to land are ones `origin/<branch>` never held. Skip
        //     this push and the PR's head stays unreachable forever; the
        //     `push origin --delete` in cleanup below then closes it as CLOSED —
        //     a branch that landed cleanly, recorded as abandoned, in the list
        //     that is now the only record of what happened.
        //
        //     --force-with-lease and not --force: the fetch at step 1 made the
        //     remote-tracking ref current, so the lease refuses exactly when it
        //     should — somebody pushed to the branch after the landing run began.
        testHold('before-publish')
        const pub = gitTry(['push', '--force-with-lease', 'origin', `${binding.sha}:refs/heads/${entry.branch}`], wt)
        if (pub.ok) {
          console.log(dim(current
            ? '  tip published (its PR will close as merged)'
            : '  rebased tip published (its PR will close as merged)'))
        } else {
          console.log(red(`  PUBLISHING THE REBASED TIP FAILED: ${pub.err || '(no stderr)'}`))
          console.log(red('  The merge below still lands. Its PR will close as UNMERGED and needs'))
          console.log(red('  saying so by hand — the branch is fine; the record of it is not.'))
        }

        // 4. Land it. --no-ff keeps the branch one revertable unit.
        //
        //    AND, FOR A REPO WHOSE HOST BUILDS EVERY PUSH TO main, THE MESSAGE
        //    CARRIES THE SKIP MARKER UNLESS THIS IS THE LAST ENTRY OF THE RUN.
        //    The queue is re-read here rather than reusing q2: the gate above
        //    takes minutes, and an entry can be dequeued inside them, which would
        //    make this the last merge after all. See `settleDeploy` for the rest
        //    of the design and for what happens when this lookahead is wrong.
        console.log(dim(`  merging into ${repo.mainBranch}…`))
        //    The marker is per lane: each of the entry's lanes that has one is
        //    marked when another eligible entry behind this one shares the lane,
        //    and two lanes that share one marker write it once.
        const markers = []
        for (const n of runLanes.filter(n => repo.lanes[n].deploy?.skipMarker && !(entry.reached || []).includes(n))) {
          const marker = repo.lanes[n].deploy.skipMarker
          const more = moreEligibleAfter(cfg, key, entry, { queue: null, simulated, resuming, held, lane: n })
          const here = multiLane(repo) ? ` in lane ${n}` : ''
          console.log(dim(more
            ? `  marked ${marker} — another branch${here} is queued behind it, so the host skips this build`
            : `  unmarked${here} — the last of this run, so the host builds it`))
          if (more && !markers.includes(marker)) markers.push(marker)
        }
        if (withdrawn(entry)) continue
        testHold('before-second-check')
        b = bound()
        if (b === 'end') return { landed, stalledOn: entry.branch }
        if (b === 'next') continue
        // THE TRUNK IS RE-CHECKED BEFORE THE MERGE: the merge lands on local `main`, and a `main`
        // that is not the commit the gate's rebase was built on means the gate did not see the
        // trunk that would land (a pulled commit), or that a stray local commit would be pushed
        // ungated.
        const moved0 = trunkMoved()
        if (moved0) {
          const s = stallAfterGate(entry, `${moved0}, so the gate did not see the trunk this would land on`, 'local main moved during the gate',
            `${moved0}.\n\nThe gate ran on ${binding.sha}, rebased onto ${trunk}. Nothing was published to ${repo.mainBranch} or merged; local ${repo.mainBranch} was left as it is.`,
            ['# nothing to fix in the worktree. If the primary checkout holds a stray commit, move it elsewhere first;',
             '# resume then rebases the branch onto the current main and gates it again'],
            `${entry.branch} — ${moved0}`)
          if (s === 'end') return { landed, stalledOn: entry.branch }
          continue
        }
        const msg = `Merge ${entry.branch}${entry.note ? ` — ${entry.note}` : ''}${markers.map(m => ` ${m}`).join('')}`
        // THE GATED COMMIT IS WHAT MERGES, not whatever the branch ref holds now.
        let base = trunk                                                  // what the gate's merge was built on
        testHold('before-merge')
        const mg = gitTry(['merge', '--no-ff', '-m', msg, binding.sha], repo.checkout)
        if (!mg.ok) die(`merge failed unexpectedly after a clean rebase: ${mg.err}`)

        // 4a. THE PUSH. If origin rejects it because its `main` moved during the gate, the
        //     merge is redone on the new `main` without a new gate only when nothing the gate
        //     covered changed (see `inspectMovedMain`), at most twice; otherwise the entry stalls.
        let push = gitTry(['push', 'origin', repo.mainBranch], repo.checkout)
        let redos = 0
        let movedStall = null
        let gone = false
        while (!push.ok) {
          const mv = inspectMovedMain(repo, runLanes, wt, base)
          if (!mv.moved) {
            gitTry(['reset', '--hard', `origin/${repo.mainBranch}`], repo.checkout)
            die(`push to origin/${repo.mainBranch} failed, so the merge was rolled back locally:\n${push.err}`)
          }
          gitTry(['reset', '--hard', `origin/${repo.mainBranch}`], repo.checkout)      // the merge is rolled back either way
          let blocker = mv.blocker
          if (!blocker && redos >= 2) blocker = `origin/${repo.mainBranch} moved again after 2 redos of the merge`
          if (!blocker) { const broke = bindingBroken(repo, entry, wt, binding, runLanes); if (broke) blocker = `the gate no longer vouches for the entry: ${broke}` }
          if (!blocker && withdrawn(entry)) { gone = true; break }
          if (blocker) { movedStall = { mv, blocker }; break }
          redos++
          console.log(dim(`  origin/${repo.mainBranch} moved during the gate: ${mv.commits.length} new commit(s), none touching what the gate covered (${mv.commits.map(c => `${c.sha} ${c.subject}`).join('; ') || 'none'}) — redoing the merge on it without a new gate (redo ${redos} of 2)`))
          base = mv.newTip
          trunk = mv.newTip                   // local main was just reset to origin's
          const movedAgain = trunkMoved()
          if (movedAgain) { movedStall = { mv, blocker: movedAgain }; break }
          const again = gitTry(['merge', '--no-ff', '-m', msg, binding.sha], repo.checkout)
          if (!again.ok) {
            gitTry(['merge', '--abort'], repo.checkout)
            gitTry(['reset', '--hard', `origin/${repo.mainBranch}`], repo.checkout)
            movedStall = { mv, blocker: `the merge could not be redone on the new ${repo.mainBranch}: ${again.err}` }
            break
          }
          push = gitTry(['push', 'origin', repo.mainBranch], repo.checkout)
        }
        if (gone) continue
        if (movedStall) {
          const { mv, blocker } = movedStall
          const list = mv.commits.map(c => `${c.sha} ${c.subject}`)
          const named = list.length ? `${list.slice(0, 3).join('; ')}${list.length > 3 ? `; and ${list.length - 3} more` : ''}` : `origin/${repo.mainBranch} is now ${mv.newTip.slice(0, 9)}`
          const reason = `main moved under a passing gate: ${named} — ${blocker}`
          const s = stallAfterGate(entry, reason, 'main moved under a passing gate',
            `origin/${repo.mainBranch} moved while the gate ran, and the push was rejected. The gate passed on ${binding.sha}, built on ${base.slice(0, 9)}.\n\n` +
            `New commits on origin/${repo.mainBranch}:\n${mv.commits.map(c => `  ${c.sha} ${c.subject}\n    ${c.paths.join(', ') || '(no files)'}${c.inside.length ? `\n    ${c.inside.map(i => `${i.how} ${multiLane(repo) ? `lane ${i.lane}` : 'what the gate covers'} (${i.path})`).join('; ')}` : ''}`).join('\n') || '  (history was rewritten)'}\n\n` +
            `Why the merge was not redone without a new gate: ${blocker}.\n\nLocal ${repo.mainBranch} was reset to origin/${repo.mainBranch}; nothing of this entry reached ${repo.mainBranch}.` +
            (redos ? ` (The merge was redone ${redos} time(s) first.)` : ''),
            ['# nothing to fix in the worktree: resume rebases the branch onto the new main and gates it again'],
            `${entry.branch} — ${reason}`)
          if (s === 'end') return { landed, stalledOn: entry.branch }
          continue
        }
        if (redos) console.log(dim(`  (the merge was redone ${redos} time${redos === 1 ? '' : 's'} on a main that moved during the gate)`))
        console.log(green(`  landed on ${repo.mainBranch} and pushed`))
        // A lane the entry only reached was tested by it and changed nothing, so its
        // final check and deploy are not owed.
        landedLanes.push(...runLanes.filter(n => !(entry.reached || []).includes(n)))
      }

      cleanupLanded(repo, entry, wt, alreadyIn ? {} : { landedTip: binding.sha, baseline: binding.after, gated: true })

      entry.status = 'landed'
      entry.landedAt = nowISO()
      removeEntry(entry)
      landed.push(entry.branch)
    }

    // The line ran to the end. If `main` is nevertheless
    // sitting on a merge the host was told to ignore — the lookahead above can
    // be wrong, and an entry dequeued between two landing runs leaves exactly this —
    // publish it. On the ordinary path the last merge was unmarked and this does
    // nothing. Deliberately reached even when this run landed nothing, because
    // "the final entry was dequeued" is the case where nothing lands and the
    // undeployed tip is somebody else's leftover.
    //
    // A lane held by a stalled entry is not settled, for the reason
    // `settleDeploy` gives: the line is expected to continue there. A one-lane
    // repo with a stall holds its one lane, so it settles nothing.
    settleDeploy(repo, dryRun, blockedLanes(repo, loadQueue().entries))

    // 6. THE FINAL CHECK RUNS UNDER THE LANDING LOCK. It used to run after the lock was
    //    released, so a second `land` could fast-forward the primary checkout (and rewrite
    //    the known-red file) under it. The broad sweep, once, on the final tip. This
    //    REPORTS; it does not gate, because each entry already passed the gate on exactly
    //    its own content. A cleanup-only entry gates no lane, so in a one-lane repo
    //    `landedLanes` would miss it; the final check there runs whenever anything landed.
    if (landed.length) {
      const finalLanes = multiLane(repo)
        ? Object.keys(repo.lanes).filter(n => landedLanes.includes(n))
        : Object.keys(repo.lanes)
      for (const name of finalLanes) {
        const lane = repo.lanes[name]
        if (!lane.finalCheck || dryRun) continue
        console.log(`\n${bold('final check')} ${dim(lane.finalCheck)}`)
        const ok = await runGate(lane.finalCheck, repo.checkout, lane.gateEnv || {}, { timeoutMs: gateTimeoutMs(repo, name) })
        console.log(ok ? green('  final check passed')
          : gateTimedOut ? red(`  FINAL CHECK TIMED OUT after ${fmtMinutes(gateTimeoutMs(repo, name) / 60000)} and was ended — main is landed and pushed; this is a new task, not a rollback`)
          : red('  FINAL CHECK FAILED — main is landed and pushed; this is a new task, not a rollback'))
      }
    }
  } finally {
    if (!dryRun) {
      mutateQueue(q => { for (const e of q.entries) if (e.repo === key) delete e.batch })
      releaseLock(key)
    }
  }

  // The entries of this repo still stalled when the run ends: the ones that
  // stalled during it, the ones `resume` held, and the ones that stalled in an
  // earlier run and still hold their lanes. Only a multi-lane repo gets here
  // with any, and a dry run writes nothing, so it reports none.
  const stalledAtEnd = dryRun ? [] : stalledIn(key, loadQueue().entries)

  if (!landed.length && !stalledAtEnd.length) {
    console.log(dim('\nnothing approved to land'))
    return { landed, refused }
  }

  // The allow-list again, after the gate output that buries its first print.
  if (!dryRun) announceKnownRed(repo, { write: false })

  if (landed.length) {
    console.log(`\n${green(bold(dryRun ? 'would land' : 'landed'))} ${landed.length} branch(es) into ${key}/${repo.mainBranch}:`)
    landed.forEach(b => console.log(`  · ${b}`))
    for (const names of batchesRun) console.log(dim(`  gated together in one batch, landed in one push: ${names.join(', ')}`))
  }
  if (!stalledAtEnd.length) return { landed, refused }

  // EACH STALL, SAID AGAIN AT THE END, because the line carried on past it and
  // its first report may be hundreds of lines of gate output above.
  console.error(red(`\n${bold('stalled')} ${stalledAtEnd.length} branch(es) in ${key}:`))
  for (const e of stalledAtEnd) {
    console.error(red(`  · ${e.branch} [${queueLanesOf(repo, e).join(', ')}] — ${e.stallReason || 'stalled'}`))
    console.error(dim(`    report: ${reportFile(key, e.branch)}`))
  }
  const waiting = Object.keys(repo.lanes).filter(n => blockedLanes(repo, stalledAtEnd).has(n))
  console.error(dim(`  Entries in ${lanePhrase(waiting)} wait behind ${stalledAtEnd.length === 1 ? 'this stall' : 'these stalls'}; entries in other lanes keep landing.`))
  console.error(dim(`  Resolve each, then: local-merge-queue resume ${key}`))
  return { landed, refused, stalledOn: stalledAtEnd[0].branch }
}

async function cmdResume (cfg, args) {
  return cmdLand(cfg, args, { resuming: true })
}

function cmdHelp () {
  console.log(`
${bold('local-merge-queue')} — a local merge queue for git repositories

  ${bold('local-merge-queue enqueue')} [--repo R] [--branch B] [--after DEP] [--note "…"] [--no-rebase]
      Enqueue a finished branch. Run it from the branch's worktree and
      repo/branch are detected. Refuses unpushed or uncommitted work. The entry
      sits ${dim('enqueued')} until the owner approves it — enqueuing never merges anything.
      ${bold('--no-rebase')}: never rebase this branch; if main moved under it, stall and
      ask for ${dim('git merge origin/<main>')} in the worktree.

  ${bold('local-merge-queue status')} [repo]        Show the queue, each entry's state and delta.
  ${bold('local-merge-queue approve')} <branch>… | --all [--repo R]
      ${bold('The owner\'s word.')} Moves entries from enqueued to approved.
  ${bold('local-merge-queue unapprove')} <branch>… | --all [--repo R]
      Put approved entries back to enqueued. The entry keeps its place in the queue;
      nothing about the branch or its worktree moves. Refuses a stalled entry.
  ${bold('local-merge-queue order')} <branch> --first | --last | <position>
      Reorder. Land refactors early — everything behind one rebases over it anyway.
  ${bold('local-merge-queue land')} [repo] [--dry-run] [--batch | --no-batch]
      Land every approved entry, one at a time: rebase → gate → merge --no-ff →
      push → remove worktree → delete branch → delete roster row. Stalls on the
      first conflict; nothing that shares a lane with it lands out of order.
      ${bold('--batch')}: gate several approved entries that share lanes once, on a
      candidate main, then land them one by one (the repo's "batch": {"max": N}
      turns it on by default; ${bold('--no-batch')} turns it off for a run).
  ${bold('local-merge-queue resume')} [repo] [--owner-approved]
      Continue after a stall has been resolved in the worktree. Retries every
      stalled entry in queue order.
  ${bold('local-merge-queue dequeue')} <branch>       Remove an entry; the branch is left untouched.

Full contract: ${path.join(HERE, 'README.md')}
`)
}

// ─── argv ───────────────────────────────────────────────────────────────────

function parseArgs (argv) {
  const out = { _: [] }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a.startsWith('--')) {
      if (['--repo', '--branch', '--note', '--after'].includes(a)) out[a] = argv[++i]
      else out[a] = true
    } else out._.push(a)
  }
  return out
}

const [, , cmd, ...rest] = process.argv
const args = parseArgs(rest)

if (!cmd || cmd === 'help' || cmd === '--help') { cmdHelp(); process.exit(0) }

const cfg = loadConfig()
const commands = {
  enqueue: cmdEnqueue,
  status: cmdStatus,
  approve: cmdApprove,
  unapprove: cmdUnapprove,
  land: cmdLand,
  resume: cmdResume,
  dequeue: cmdDequeue,
  order: cmdOrder
}
const fn = commands[cmd]
if (!fn) { console.error(red(`local-merge-queue: unknown command "${cmd}"`)); cmdHelp(); process.exit(1) }

// A resume that found a stalled entry unready exits 1, as the refusal always
// has; a run that ends with any entry stalled exits 2.
const result = await fn(cfg, args)
if (result && result.refused) process.exit(1)
if (result && result.stalledOn) process.exit(2)
if (residueLeft) process.exit(3)             // landed, but a cleanup step left something behind (said in red above)
