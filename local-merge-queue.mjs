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

import { execFileSync, spawnSync } from 'node:child_process'
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

// ─── small helpers ──────────────────────────────────────────────────────────

const bold = s => `[1m${s}[0m`
const dim = s => `[2m${s}[0m`
const red = s => `[31m${s}[0m`
const green = s => `[32m${s}[0m`
const yellow = s => `[33m${s}[0m`

function die (msg, code = 1) {
  console.error(red(`local-merge-queue: ${msg}`))
  process.exit(code)
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
  }
  return cfg
}

// A LANE IS A SET OF PATHS WITH ITS OWN SETUP AND GATE. Every repo has lanes
// once it is loaded: a repo that declares none gets one implicit lane, named
// after the repo, taking every path, with the repo-level keys moved onto it.
// Everything after this function reads `repo.lanes` and never the repo-level
// keys, which is what makes a repo without `lanes` behave exactly as it did
// before lanes existed.
const LANE_KEYS = ['setupWhen', 'setup', 'gate', 'gateEnv', 'finalCheck', 'protectedPaths', 'deploy']

function loadLanes (key, repo) {
  if (repo.lanes === undefined) {
    const lane = { paths: '*' }
    for (const k of LANE_KEYS) if (repo[k] !== undefined) lane[k] = repo[k]
    for (const k of LANE_KEYS) delete repo[k]
    repo.shared = []
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
  }
  return lanes
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

// Which lanes does a branch touch? The paths its diff against the merge base
// with `mainBranch` changes, each mapped to lanes: a path under a lane's prefix
// belongs to that lane, a path under `shared` belongs to every lane, and a path
// no lane claims belongs to the lane that takes "*". A repo with no such lane
// refuses the path by name. An empty diff (a cleanup-only entry) has no lanes.
// The result is an array of lane names in config order, without duplicates.
function lanesOf (repo, cwd, branch) {
  const base = gitTry(['merge-base', repo.mainBranch, branch], cwd)
  if (!base.ok) die(`cannot find where "${branch}" left ${repo.mainBranch} to work out its lanes: ${base.err}`)
  const diff = gitTry(['diff', '--name-only', base.out, branch], cwd)
  if (!diff.ok) die(`cannot list the files "${branch}" changes to work out its lanes: ${diff.err}`)
  const names = Object.keys(repo.lanes)
  const hit = new Set()
  for (const p of diff.out.split('\n').filter(Boolean)) {
    if (repo.shared.some(s => p.startsWith(s))) { names.forEach(n => hit.add(n)); continue }
    const owners = names.filter(n => Array.isArray(repo.lanes[n].paths) && repo.lanes[n].paths.some(s => p.startsWith(s)))
    if (owners.length) { owners.forEach(n => hit.add(n)); continue }
    const catchAll = names.find(n => repo.lanes[n].paths === '*')
    if (!catchAll) die(`"${branch}" changes ${p}, which no lane of ${repo.key} claims and no lane takes "*"`)
    hit.add(catchAll)
  }
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

function loadQueue () {
  return readJSON(QUEUE_PATH, { entries: [] })
}

function saveQueue (q) {
  writeJSON(QUEUE_PATH, q)
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

function acquireLock (key) {
  const dir = path.join(LOCK_DIR, key)
  fs.mkdirSync(LOCK_DIR, { recursive: true })
  try {
    fs.mkdirSync(dir)                                  // atomic on POSIX
  } catch (e) {
    if (e.code !== 'EEXIST') throw e
    const owner = readJSON(path.join(dir, 'owner.json'), null)
    if (owner && pidAlive(owner.pid)) return null
    // The holder is gone; the lock is debris.
    console.error(yellow(`local-merge-queue: breaking a stale lock left by pid ${owner?.pid ?? '?'}`))
    fs.rmSync(dir, { recursive: true, force: true })
    fs.mkdirSync(dir)
  }
  writeJSON(path.join(dir, 'owner.json'), { pid: process.pid, since: nowISO() })
  return dir
}

function releaseLock (key) {
  fs.rmSync(path.join(LOCK_DIR, key), { recursive: true, force: true })
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
function ensureWorktreeSetup (repo, wt, laneNames) {
  const env = {
    LOCAL_MERGE_QUEUE_CHECKOUT: repo.checkout,
    LOCAL_MERGE_QUEUE_WORKTREE: wt,
    LOCAL_MERGE_QUEUE_REPO: repo.key
  }
  let ran = false
  for (const name of laneNames) {
    const lane = repo.lanes[name]
    if (!lane.setup.length) continue
    if (lane.setupWhen && run(lane.setupWhen, wt, env)) continue
    const label = multiLane(repo) ? `${repo.key}/${name}` : repo.key
    console.log(yellow(`  this worktree has no generated environment — running ${label}'s setup`))
    for (const step of lane.setup) {
      console.log(dim(`  setup: ${step}`))
      if (!run(step, wt, env)) return { ok: false, ran: true, failed: step, probe: lane.setupWhen, lane: name }
    }
    console.log(dim('  setup complete — the gate has an environment to run in'))
    ran = true
  }
  return { ok: true, ran }
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
function writeStallReport (repo, entry, kind, detail, conflicted, ownerCall, fixSteps = []) {
  fs.mkdirSync(REPORT_DIR, { recursive: true })
  const file = path.join(REPORT_DIR, `${repo.key}-${entry.branch}.md`)
  const midRebase = rebaseInProgress(entry.worktree)
  const clearIt = midRebase
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

// ─── commands ───────────────────────────────────────────────────────────────

function cmdEnqueue (cfg, args) {
  const q = loadQueue()
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

  const lanes = lanesOf(repo, worktree, branch)
  const existing = q.entries.find(e => e.repo === repo.key && e.branch === branch)
  if (existing) {
    existing.worktree = worktree
    existing.lanes = lanes
    if (args['--note']) existing.note = args['--note']
    if (args['--after']) existing.after = args['--after']
    saveQueue(q)
    console.log(`${bold('updated')} ${repo.key}/${branch} (status: ${existing.status})`)
    return
  }

  q.entries.push({
    repo: repo.key,
    branch,
    worktree,
    note: args['--note'] || '',
    after: args['--after'] || null,
    lanes,
    status: 'enqueued',                 // enqueued → approved (the owner's word) → landed
    enqueued: nowISO()
  })
  saveQueue(q)
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
    const locked = fs.existsSync(path.join(LOCK_DIR, key))
    if (locked) {
      const owner = readJSON(path.join(LOCK_DIR, key, 'owner.json'), null)
      console.log(yellow(`  LOCKED by pid ${owner?.pid ?? '?'} since ${owner?.since ?? '?'}`))
    }
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
      const name = multiLane(repo) && e.lanes ? `${e.branch} [${e.lanes.join(', ')}]` : e.branch
      console.log(`  ${String(i + 1).padStart(2)}. ${name.padEnd(28)} ${mark.padEnd(18)} ${delta}`)
      if (e.after) console.log(dim(`      after: ${e.after}`))
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
  }
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
  const q = loadQueue()
  const all = args['--all']
  const names = args._
  if (!all && !names.length) die('name the branches to approve, or pass --all')
  refuseAmbiguous(q, names, args)
  let n = 0
  for (const e of q.entries) {
    if (e.status !== 'enqueued') continue
    if (args['--repo'] && e.repo !== args['--repo']) continue
    if (all || names.includes(e.branch)) { e.status = 'approved'; e.approved = nowISO(); n++ }
  }
  saveQueue(q)
  console.log(`${green('approved')} ${n} branch(es). Land them with: local-merge-queue land <repo>`)
}

// The inverse of approve, and it exists because an approved entry is a state
// the owner may want to take back — a change of mind, a branch that needs one more
// look — without dequeuing it out of the queue and losing its place. It reaches
// only as far as the landing run: once a branch is landing, `dequeue` and `resume` are
// what govern it.
function cmdUnapprove (cfg, args) {
  const q = loadQueue()
  const all = args['--all']
  const names = args._
  if (!all && !names.length) die('name the branches to unapprove, or pass --all')
  refuseAmbiguous(q, names, args)
  const wanted = e => (all || names.includes(e.branch)) &&
    (!args['--repo'] || e.repo === args['--repo'])
  // A stalled entry is mid-landing: its worktree holds a rebase in progress, so
  // moving it back to enqueued would leave the queue describing a state the disk
  // does not. Say so rather than half-doing it.
  const stalled = q.entries.filter(e => e.status === 'stalled' && wanted(e))
  for (const e of stalled) {
    console.log(yellow(`${e.repo}/${e.branch} is STALLED mid-landing — unapprove will not touch it.`))
    console.log(dim(`  Resolve it and ${bold('local-merge-queue resume')} ${e.repo}, or ${bold('local-merge-queue dequeue')} ${e.branch}.`))
  }
  let n = 0
  for (const e of q.entries) {
    if (e.status !== 'approved') continue
    if (!wanted(e)) continue
    e.status = 'enqueued'
    delete e.approved
    n++
  }
  saveQueue(q)
  if (!n) {
    console.log(dim('nothing to unapprove — no matching entry was approved'))
    return
  }
  console.log(`${yellow('enqueued')} ${n} branch(es) again. The branch, its worktree and its place in the queue are untouched.`)
  console.log(dim('  Re-approve with: local-merge-queue approve <branch>'))
}

function cmdDequeue (cfg, args) {
  const q = loadQueue()
  const name = args._[0]
  if (!name) die('name the branch to dequeue')
  const e = entryNamed(cfg, q, name, args)
  // If it stalled mid-rebase, put the worktree back as it was.
  if (e.status === 'stalled' && e.worktree && fs.existsSync(path.join(e.worktree, '.git'))) {
    gitTry(['rebase', '--abort'], e.worktree)
  }
  q.entries = q.entries.filter(x => x !== e)
  saveQueue(q)
  console.log(`${yellow('dequeued')} ${e.repo}/${e.branch} — the branch and its worktree are untouched`)
}

function cmdOrder (cfg, args) {
  const q = loadQueue()
  const name = args._[0]
  if (!name) die('name the branch to move')
  const idx = q.entries.indexOf(entryNamed(cfg, q, name, args))
  const [e] = q.entries.splice(idx, 1)
  if (args['--first']) q.entries.unshift(e)
  else if (args['--last']) q.entries.push(e)
  else {
    const pos = Number(args._[1])
    if (!Number.isInteger(pos) || pos < 1) die('pass --first, --last, or a 1-based position')
    q.entries.splice(pos - 1, 0, e)
  }
  saveQueue(q)
  console.log(`${green('reordered')} — land refactors early; every branch behind one rebases over it anyway`)
  cmdStatus(cfg, { _: [e.repo] })
}

// The heart of it.
function cmdLand (cfg, args, { resuming = false } = {}) {
  const key = args._[0] || detectHere(cfg)?.repo.key
  if (!key) die('name the repo to land (or run from inside one of its worktrees)')
  const repo = repoOf(cfg, key)
  const dryRun = !!args['--dry-run']

  // A STALL HOLDS ONLY ITS OWN LANES, so `land` refuses only when every lane
  // of the repo is held. A one-lane repo's every stalled entry holds its one
  // lane (see `queueLanesOf`), so it refuses exactly when it always has.
  const q = loadQueue()
  const stalledNow = stalledIn(key, q.entries)
  const blocked = blockedLanes(repo, q.entries)
  if (stalledNow.length && !resuming && Object.keys(repo.lanes).every(n => blocked.has(n))) {
    const stalled = stalledNow[0]
    die(`${key} is stalled on "${stalled.branch}" — resolve it, then: local-merge-queue resume ${key}\n` +
        `  report: ${path.join(REPORT_DIR, `${key}-${stalled.branch}.md`)}` +
        stalledNow.slice(1).map(e => `\n  also stalled on "${e.branch}" — report: ${path.join(REPORT_DIR, `${key}-${e.branch}.md`)}`).join(''))
  }

  const problems = preflight(repo)
  if (problems.length) {
    die(`${key} is not ready to land:\n  - ${problems.join('\n  - ')}`)
  }

  const lock = dryRun ? true : acquireLock(key)
  if (!lock) {
    const owner = readJSON(path.join(LOCK_DIR, key, 'owner.json'), null)
    die(`${key} is being landed already (pid ${owner?.pid ?? '?'}, since ${owner?.since ?? '?'})`)
  }

  if (multiLane(repo) && stalledNow.length && !resuming) {
    for (const e of stalledNow) {
      const names = queueLanesOf(repo, e)
      console.log(yellow(`  ${lanePhrase(names)} ${names.length === 1 ? 'waits' : 'wait'} behind the stall on "${e.branch}"; entries in other lanes keep landing`))
    }
  }

  const landed = []
  const landedLanes = []              // lanes of every entry landed this run, for the final check
  const simulated = new Set()          // dry-run only; the real queue is never written
  // Entries this run gives up on: the ones that stall during it, and the ones
  // `resume` finds unready. Only a multi-lane repo carries on past either; a
  // one-lane repo still ends the run at the first, as it always has, because
  // every entry behind a stall there shares its one lane.
  const held = new Set()
  let refused = false                  // `resume` found a stalled entry unready
  // The line a multi-lane stall adds to its console report. At each stall a
  // one-lane repo returns at once; a multi-lane repo holds the entry and the
  // loop moves on to the entries in other lanes.
  const stallLine = e => multiLane(repo)
    ? `Entries in ${lanePhrase(queueLanesOf(repo, e))} wait behind it; entries in other lanes keep landing.`
    : null
  try {
    while (true) {
      const q2 = loadQueue()
      const queued = new Map(q2.entries.map(e => [`${e.repo}:${e.branch}`, e]))
      const entry = q2.entries.find(e => eligible(cfg, e, key, { queued, simulated, resuming, held }))
      if (!entry) break

      console.log(`\n${bold('──')} ${bold(entry.branch)} ${dim(entry.worktree)}`)
      if (dryRun) {
        console.log(dim('  (dry run — would rebase, gate, merge --no-ff, push, clean up)'))
        let dryLanes = Object.keys(repo.lanes)
        if (multiLane(repo)) {
          // Computed live and never stored: a dry run writes nothing.
          const live = gitTry(['rev-parse', '--verify', '-q', `refs/heads/${entry.branch}`], repo.checkout).ok
          const shown = live ? lanesOf(repo, repo.checkout, entry.branch) : (entry.lanes || [])
          dryLanes = shown
          console.log(dim(`  lanes: [${shown.join(', ')}]`))
          for (const n of shown) {
            const steps = repo.lanes[n].gate
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

      // A branch already contained in main needs cleanup, not a merge. This is
      // where the roster's "merged; delete the worktree and this row" backlog
      // lands — the state that accumulates when a merge and its cleanup were
      // two separate acts by two different people.
      const alreadyIn = gitTry(['merge-base', '--is-ancestor', entry.branch, repo.mainBranch], repo.checkout).ok
      // Set at step 2 below; read again at the pre-merge publish, which is why it
      // is declared out here rather than beside its use.
      let current = false

      // Lanes of the entry being landed, set at step 2a; the final check reads
      // them once the merge is pushed.
      let runLanes = []

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
            // there the branch is off `main` only if someone moved it by hand.
            if (!multiLane(repo)) die(`"${entry.branch}" is not on top of origin/${repo.mainBranch} — rebase it before resuming`)
            console.log(dim(`  ${repo.mainBranch} moved while ${entry.branch} was stalled — rebasing it again`))
            fresh = true
          }
          entry.status = 'approved'
          delete entry.stallReason
          saveQueue(q2)
        }

        // 1. Bring main and the branch up to date.
        if (fresh) {
          console.log(dim('  fetching…'))
          if (!run('git fetch origin --prune', repo.checkout)) die('git fetch failed')
          const pull = gitTry(['merge', '--ff-only', `origin/${repo.mainBranch}`], repo.checkout)
          if (!pull.ok) die(`${repo.mainBranch} could not fast-forward to origin: ${pull.err}`)

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
            entry.status = 'stalled'
            entry.ownerCall = ownerCall
            entry.stallReason = `rebase conflict in ${conflicted.length} file(s)${ownerCall ? ' — OWNER DECISION REQUIRED' : ''}`
            saveQueue(q2)
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
        entry.lanes = lanesOf(repo, wt, entry.branch)
        saveQueue(q2)
        runLanes = laneNamesFor(repo, entry)

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
        const setup = ensureWorktreeSetup(repo, wt, runLanes)
        if (!setup.ok) {
          // A multi-lane repo names the lane whose setup failed.
          const inLane = multiLane(repo) ? ` in lane ${setup.lane}` : ''
          entry.status = 'stalled'
          entry.stallReason = `worktree setup failed${inLane}: ${setup.failed}`
          saveQueue(q2)
          const file = writeStallReport(repo, entry, `worktree setup failed${inLane}`,
            `This worktree lacked its generated environment — \`${setup.probe || '(no probe configured)'}\` said so —\n` +
            `and the setup step that fills it in exited non-zero:\n\n` +
            `    ${setup.failed}\n\n` +
            `Its output is above, in the landing run log. The gate never ran; nothing here is a\n` +
            `verdict on the branch.`,
            [], false, [setup.failed])
          console.error(red(`\n  STALLED — worktree setup failed${inLane} on ${entry.branch}`))
          console.error(`  the step that failed: ${setup.failed}`)
          console.error(dim('  The rebase is complete — there is no conflict to resolve, and the gate'))
          console.error(dim('  has not run. Fix the environment in that worktree, then: local-merge-queue resume ' + key))
          console.error(`  report: ${file}`)
          if (!multiLane(repo)) return { landed, stalledOn: entry.branch }
          console.error(dim(`  ${stallLine(entry)}`))
          held.add(entry.branch)
          continue
        }

        // 3. The gate: what would break a writer, run on exactly what will land.
        let gateOK = true
        let gateFailed = null
        let gateLane = null
        gate: for (const name of runLanes) {
          for (const step of repo.lanes[name].gate) {
            console.log(dim(`  gate: ${step}`))
            if (!run(step, wt, repo.lanes[name].gateEnv || {})) { gateOK = false; gateFailed = step; gateLane = name; break gate }
          }
        }
        if (!gateOK) {
          // A multi-lane repo names the lane whose gate failed.
          const inLane = multiLane(repo) ? ` in lane ${gateLane}` : ''
          entry.status = 'stalled'
          entry.stallReason = `gate failed after rebase${inLane}`
          saveQueue(q2)
          const file = writeStallReport(repo, entry, `gate failed after rebase${inLane}`,
            `The gate step \`${gateFailed}\` exited non-zero. Its output is above, in the landing run log.`,
            [], false, [gateFailed])
          console.error(red(`\n  STALLED — the gate${multiLane(repo) ? ` of lane ${gateLane}` : ''} failed on ${entry.branch} after rebasing.`))
          console.error(dim('  This is the queue working: it passed on the old main and fails on the new one.'))
          console.error(`  report: ${file}`)
          if (!multiLane(repo)) return { landed, stalledOn: entry.branch }
          console.error(dim(`  ${stallLine(entry)}`))
          held.add(entry.branch)
          continue
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
        const pub = gitTry(['push', '--force-with-lease', 'origin', `${entry.branch}:${entry.branch}`], wt)
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
        for (const n of runLanes.filter(n => repo.lanes[n].deploy?.skipMarker)) {
          const marker = repo.lanes[n].deploy.skipMarker
          const more = moreEligibleAfter(cfg, key, entry, { queue: null, simulated, resuming, held, lane: n })
          const here = multiLane(repo) ? ` in lane ${n}` : ''
          console.log(dim(more
            ? `  marked ${marker} — another branch${here} is queued behind it, so the host skips this build`
            : `  unmarked${here} — the last of this run, so the host builds it`))
          if (more && !markers.includes(marker)) markers.push(marker)
        }
        const msg = `Merge ${entry.branch}${entry.note ? ` — ${entry.note}` : ''}${markers.map(m => ` ${m}`).join('')}`
        const mg = gitTry(['merge', '--no-ff', '-m', msg, entry.branch], repo.checkout)
        if (!mg.ok) die(`merge failed unexpectedly after a clean rebase: ${mg.err}`)

        const push = gitTry(['push', 'origin', repo.mainBranch], repo.checkout)
        if (!push.ok) {
          gitTry(['reset', '--hard', `origin/${repo.mainBranch}`], repo.checkout)
          die(`push to origin/${repo.mainBranch} failed, so the merge was rolled back locally:\n${push.err}`)
        }
        console.log(green(`  landed on ${repo.mainBranch} and pushed`))
        landedLanes.push(...runLanes)
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

      const rm = gitTry(['worktree', 'remove', '--force', wt], repo.checkout)
      step('worktree removed', rm, `worktree still registered at ${wt}`)
      // PRUNE BETWEEN THE TWO, ALWAYS. `git branch -d` refuses a branch git
      // still believes is checked out in a worktree, and a worktree whose
      // directory has gone without `worktree remove` leaves exactly that belief
      // behind in `.git/worktrees/`. This repo had a stale entry of that kind
      // sitting there while three branches failed to delete. Pruning is cheap,
      // idempotent, and touches only admin files for worktrees that are already
      // gone — it can never remove a live one.
      gitTry(['worktree', 'prune'], repo.checkout)
      let del = gitTry(['branch', '-d', entry.branch], repo.checkout)   // -d refuses if unmerged
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
      step('local branch deleted', del, `local branch \`${entry.branch}\` still exists`)
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
      if (!repo.githubRepo) {
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
        console.log(red(`  ${entry.branch} landed, but its cleanup left residue:`))
        for (const r of residue) console.log(red(`    · ${r}`))
        console.log(dim('    Clear it by hand; the merge itself is done and pushed.'))
      }

      entry.status = 'landed'
      entry.landedAt = nowISO()
      const q3 = loadQueue()
      q3.entries = q3.entries.filter(x => !(x.repo === entry.repo && x.branch === entry.branch))
      saveQueue(q3)
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
  } finally {
    if (!dryRun) releaseLock(key)
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

  // 6. The broad sweep, once, on the final tip. This REPORTS; it does not gate,
  //    because each entry already passed the gate on exactly its own content.
  //    A cleanup-only entry gates no lane, so in a one-lane repo `landedLanes`
  //    would miss it; the final check there runs whenever anything landed.
  const finalLanes = multiLane(repo)
    ? Object.keys(repo.lanes).filter(n => landedLanes.includes(n))
    : Object.keys(repo.lanes)
  for (const name of finalLanes) {
    const lane = repo.lanes[name]
    if (!lane.finalCheck || dryRun) continue
    console.log(`\n${bold('final check')} ${dim(lane.finalCheck)}`)
    const ok = run(lane.finalCheck, repo.checkout, lane.gateEnv || {})
    console.log(ok ? green('  final check passed') : red('  FINAL CHECK FAILED — main is landed and pushed; this is a new task, not a rollback'))
  }

  if (landed.length) {
    console.log(`\n${green(bold('landed'))} ${landed.length} branch(es) into ${key}/${repo.mainBranch}:`)
    landed.forEach(b => console.log(`  · ${b}`))
  }
  if (!stalledAtEnd.length) return { landed, refused }

  // EACH STALL, SAID AGAIN AT THE END, because the line carried on past it and
  // its first report may be hundreds of lines of gate output above.
  console.error(red(`\n${bold('stalled')} ${stalledAtEnd.length} branch(es) in ${key}:`))
  for (const e of stalledAtEnd) {
    console.error(red(`  · ${e.branch} [${queueLanesOf(repo, e).join(', ')}] — ${e.stallReason || 'stalled'}`))
    console.error(dim(`    report: ${path.join(REPORT_DIR, `${key}-${e.branch}.md`)}`))
  }
  const waiting = Object.keys(repo.lanes).filter(n => blockedLanes(repo, stalledAtEnd).has(n))
  console.error(dim(`  Entries in ${lanePhrase(waiting)} wait behind ${stalledAtEnd.length === 1 ? 'this stall' : 'these stalls'}; entries in other lanes keep landing.`))
  console.error(dim(`  Resolve each, then: local-merge-queue resume ${key}`))
  return { landed, refused, stalledOn: stalledAtEnd[0].branch }
}

function cmdResume (cfg, args) {
  return cmdLand(cfg, args, { resuming: true })
}

function cmdHelp () {
  console.log(`
${bold('local-merge-queue')} — a local merge queue for git repositories

  ${bold('local-merge-queue enqueue')} [--repo R] [--branch B] [--after DEP] [--note "…"]
      Enqueue a finished branch. Run it from the branch's worktree and
      repo/branch are detected. Refuses unpushed or uncommitted work. The entry
      sits ${dim('enqueued')} until the owner approves it — enqueuing never merges anything.

  ${bold('local-merge-queue status')} [repo]        Show the queue, each entry's state and delta.
  ${bold('local-merge-queue approve')} <branch>… | --all [--repo R]
      ${bold('The owner\'s word.')} Moves entries from enqueued to approved.
  ${bold('local-merge-queue unapprove')} <branch>… | --all [--repo R]
      Put approved entries back to enqueued. The entry keeps its place in the queue;
      nothing about the branch or its worktree moves. Refuses a stalled entry.
  ${bold('local-merge-queue order')} <branch> --first | --last | <position>
      Reorder. Land refactors early — everything behind one rebases over it anyway.
  ${bold('local-merge-queue land')} [repo] [--dry-run]
      Land every approved entry, one at a time: rebase → gate → merge --no-ff →
      push → remove worktree → delete branch → delete roster row. Stalls on the
      first conflict; nothing that shares a lane with it lands out of order.
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
const result = fn(cfg, args)
if (result && result.refused) process.exit(1)
if (result && result.stalledOn) process.exit(2)
