#!/usr/bin/env node
// drainer — a local merge queue for git repositories.
//
// Branch agents hand a finished branch off; the owner admits it; the drainer lands
// the admitted entries one at a time, rebasing each onto a main that may have
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
const CONFIG_PATH = process.env.DRAINER_CONFIG || path.join(XDG_CONFIG, 'drainer', 'repos.json')
const STATE_DIR = process.env.DRAINER_STATE || path.join(XDG_STATE, 'drainer')
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
  console.error(red(`drainer: ${msg}`))
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
        `  Write one there, or point DRAINER_CONFIG at one elsewhere.\n` +
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
    repo.gate ||= []
    repo.setup ||= []
    repo.protectedPaths ||= []
  }
  return cfg
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
// An `after` naming something nobody handed off is treated as unmet, loudly,
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

// Would this entry be picked up by THIS drain run? One predicate, used twice:
// once to choose the next entry to land, and once to ask whether anything is
// still behind the entry being landed — which is what decides whether its merge
// commit carries the skip marker (see `moreEligibleAfter`). Two copies of this
// rule would be two answers to the same question.
function eligible (cfg, entry, key, { queued, simulated, resuming, quiet = false }) {
  if (entry.repo !== key) return false
  if (simulated.has(entry.branch)) return false
  if (entry.status !== 'admitted' && !(resuming && entry.status === 'stalled')) return false
  if (entry.after && !dependencyMet(cfg, entry, queued, simulated, quiet)) return false
  return true
}

// Is there another entry this run will land after `entry`? Asked of the queue as
// it stands RIGHT NOW rather than of the snapshot taken before the gate ran,
// because a gate takes minutes and an entry can be dropped inside them — and a
// wrong answer here is what would leave production sitting on a build nobody
// asked the host to make. It is only ever a lookahead, though: the entry behind
// this one may still stall, or turn out to be cleanup-only and push nothing. The
// end-of-run settle (`settleDeploy`) is what makes those cases safe.
function moreEligibleAfter (cfg, key, entry, { queue, simulated, resuming }) {
  const q = queue || loadQueue()
  const queued = new Map(q.entries.map(e => [`${e.repo}:${e.branch}`, e]))
  return q.entries.some(e =>
    !(e.repo === entry.repo && e.branch === entry.branch) &&
    eligible(cfg, e, key, { queued, simulated, resuming, quiet: true }))
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
    console.error(yellow(`drainer: breaking a stale lock left by pid ${owner?.pid ?? '?'}`))
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
// what goes permanently wrong without it. Bounded on purpose: a drain must not
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
 * drainer's gate, minutes into a drain, dying on something that is not the
 * branch's fault. It happened three times on 2026-08-24, twice as `esbuild
 * ENOENT` out of an empty `node_modules` (`fragments-context`,
 * `tour-tray-vestige`), and each one cost a person a diagnose-install-resume
 * cycle for a queue whose whole purpose is not needing one.
 *
 * So the drainer fills the environment in itself. `setupWhen` is a probe whose
 * NONZERO exit means setup is needed, which keeps a drain of an already-working
 * worktree free: the probe runs, exits 0, and nothing else happens. Configure
 * `setup` without a probe and every drain pays for it, which is why both live
 * repos carry one.
 *
 * The commands run in the worktree with `DRAINER_CHECKOUT` pointing at the
 * primary checkout, because most of what a worktree is missing is a copy of
 * something the primary checkout already has.
 */
function ensureWorktreeSetup (repo, wt) {
  if (!repo.setup.length) return { ok: true, ran: false }
  const env = {
    DRAINER_CHECKOUT: repo.checkout,
    DRAINER_WORKTREE: wt,
    DRAINER_REPO: repo.key
  }
  if (repo.setupWhen && run(repo.setupWhen, wt, env)) return { ok: true, ran: false }
  console.log(yellow(`  this worktree has no generated environment — running ${repo.key}'s setup`))
  for (const step of repo.setup) {
    console.log(dim(`  setup: ${step}`))
    if (!run(step, wt, env)) return { ok: false, ran: true, failed: step }
  }
  console.log(dim('  setup complete — the gate has an environment to run in'))
  return { ok: true, ran: true }
}

// ─── one deploy per drain, not one per branch ───────────────────────────────

/**
 * A REPO WHOSE HOST BUILDS EVERY PUSH TO `main` GETS ONE BUILD PER DRAIN RUN,
 * NOT ONE PER BRANCH.
 *
 * One site here deploys production from `main` through Vercel's git
 * integration, so the push at step 4 IS a production deploy. Draining N branches
 * therefore shipped N builds, and every one but the last shipped a state that
 * existed for about ninety seconds while the queue was still moving. The owner's
 * ask, 2026-08-29: *"main should just redeploy at the end of the draining."*
 *
 * The mechanism is Vercel's own `ignoreCommand` (vercel.json), whose contract is
 * that exit 0 ignores the build and exit 1 lets it proceed, reading the commit
 * message out of the documented `VERCEL_GIT_COMMIT_MESSAGE`. So the drainer
 * appends `deploy.skipMarker` to the merge commit message of every entry that
 * has another entry behind it, and leaves the LAST merge of the run unmarked.
 * One push, one build, the state a person actually asked for.
 *
 * WHAT IS NOT DONE, AND WHY: the pushes themselves are not batched or deferred.
 * An unpushed merge is unbacked-up work, and the pull request retires itself
 * only because the landing tip is reachable from `main` at cleanup time. The
 * push cadence is load-bearing; only the BUILD per push is suppressed.
 *
 * `settleDeploy` is the safety net under the lookahead, and it is what makes the
 * messy paths correct rather than merely usual. The lookahead can be wrong in
 * two ways — the entry behind this one may stall and then be dropped, or it may
 * turn out to be cleanup-only and push nothing — and both leave `main` sitting
 * on a merge the host was told to ignore, with production serving the build from
 * before the drain. So at the end of every run that did not stall, the drainer
 * asks the state rather than its own memory: does the tip of `main` carry the
 * marker? If it does, an empty commit publishes it. On the ordinary path the tip
 * is unmarked and this does nothing at all.
 *
 * A stall deliberately does NOT settle. The line is expected to continue, and
 * shipping the half-drained state mid-stall is the thing this whole feature
 * exists to stop; the resume that lands the last entry deploys it.
 */
function settleDeploy (repo, dryRun) {
  const marker = repo.deploy?.skipMarker
  if (!marker || dryRun) return
  gitTry(['fetch', 'origin', repo.mainBranch], repo.checkout)
  const ff = gitTry(['merge', '--ff-only', `origin/${repo.mainBranch}`], repo.checkout)
  if (!ff.ok) {
    console.log(yellow(`  ${repo.mainBranch} could not fast-forward to origin, so the deploy state was not checked`))
    return
  }
  const tip = gitTry(['log', '-1', '--format=%B', repo.mainBranch], repo.checkout)
  if (!tip.ok || !tip.out.includes(marker)) return

  // THE MESSAGE MUST NOT CONTAIN THE MARKER. Interpolating it here — naming the
  // thing being fixed, which is the natural sentence to write — would make the
  // commit that exists to trigger a build the next one skipped, permanently and
  // silently. Asserted rather than trusted.
  const msg = `Redeploy ${repo.mainBranch}: the drain ended on a merge the host was told not to build`
  if (msg.includes(marker)) die('the redeploy commit message carries the skip marker — refusing to push a commit that cancels itself')

  console.log(yellow(`  ${repo.mainBranch} is sitting on a skipped build — publishing it`))
  const cm = gitTry(['commit', '--allow-empty', '-m', msg], repo.checkout)
  if (!cm.ok) {
    console.log(red(`  THE REDEPLOY COMMIT FAILED: ${cm.err || '(no stderr)'}`))
    console.log(red('  Production is still serving the build from before this drain.'))
    return
  }
  const push = gitTry(['push', 'origin', repo.mainBranch], repo.checkout)
  if (!push.ok) {
    gitTry(['reset', '--hard', `origin/${repo.mainBranch}`], repo.checkout)
    console.log(red(`  THE REDEPLOY PUSH FAILED: ${push.err || '(no stderr)'}`))
    console.log(red(`  Rolled it back. Production is still serving the build from before this drain;`))
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
  const body = `# Drain stalled — ${repo.key} / \`${entry.branch}\`

**When:** ${nowISO()}
**Why:** ${kind}
**Worktree:** \`${entry.worktree}\`
${ownerCall ? '\n> **OWNER DECISION REQUIRED.** The conflict touches a protected path, so the\n> resolution is protected content that is the owner\'s call, not an agent\'s.\n> Resolve nothing without the owner\'s word, then resume with `--owner-approved`.\n' : ''}
## Detail

\`\`\`
${detail}
\`\`\`
${conflicted.length ? `\n## Conflicted paths\n\n${conflicted.map(p => `- \`${p}\``).join('\n')}\n` : ''}
## How to clear it

${clearIt}

Then hand the line back to the drainer:

\`\`\`sh
drainer resume ${repo.key}${ownerCall ? ' --owner-approved' : ''}
\`\`\`

Everything queued behind this entry is still waiting; nothing was landed out of
order. If this branch should leave the queue instead, \`drainer drop ${entry.branch}\`
(that returns the branch to its worktree untouched${midRebase ? ', aborting the rebase' : ''}).
`
  fs.writeFileSync(file, body)
  return file
}

// ─── commands ───────────────────────────────────────────────────────────────

function cmdHandoff (cfg, args) {
  const q = loadQueue()
  const here = detectHere(cfg)
  const repoKey = args['--repo'] || here?.repo.key
  const branch = args['--branch'] || here?.branch
  if (!repoKey || !branch) {
    die('run this from inside the branch worktree, or pass --repo and --branch')
  }
  const repo = repoOf(cfg, repoKey)
  if (branch === repo.mainBranch) die(`"${branch}" is the main branch; there is nothing to hand off`)

  const worktree = worktreeFor(repo, branch)
  if (!worktree) die(`no worktree holds "${branch}" in ${repo.key} — the drainer lands branches from their worktrees`)

  // Unpushed work is unbacked-up work; the drainer will not carry it.
  const upstream = gitTry(['rev-parse', '--abbrev-ref', `${branch}@{upstream}`], worktree)
  if (!upstream.ok) die(`"${branch}" has no upstream — push it first (git push -u origin ${branch})`)
  const ahead = git(['rev-list', '--count', `${upstream.out}..${branch}`], worktree)
  if (ahead !== '0') die(`"${branch}" has ${ahead} unpushed commit(s) — push before handing off`)
  const dirty = git(['status', '--porcelain'], worktree)
  if (dirty) die(`"${branch}"'s worktree is dirty — commit or discard before handing off`)

  // A branch with no pull request is a branch with no record. Since 2026-08-19
  // the PR IS the roster — what the branch is, what is open on it, whose call is
  // outstanding — so handing off without one queues work that `gh pr list` cannot
  // see. Refuse, and say exactly how to fix it. This checks only that a PR
  // exists; whether it is draft is deliberately not policed, because "not ready
  // to land" is a judgement the person admitting it makes, not this tool.
  if (repo.githubRepo) {
    const pr = prFor(repo, branch)
    if (!pr) {
      die(`"${branch}" has no open pull request, and the pull request is the roster.\n` +
          `  Open one from its worktree, then hand off again:\n\n` +
          `    cd ${worktree}\n` +
          `    gh pr create --base ${repo.mainBranch} --head ${branch} --draft \\\n` +
          `      --title "<what it is, in one clause>" --body-file <(…)\n\n` +
          `  The body carries what BRANCH.md used to: scope, what is done, what is left,\n` +
          `  how to verify, and any decision that is the owner's rather than an agent's.`)
    }
    console.log(dim(`  pull request: #${pr.number}${pr.isDraft ? ' (draft)' : ''}`))
  }

  const existing = q.entries.find(e => e.repo === repo.key && e.branch === branch)
  if (existing) {
    existing.worktree = worktree
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
    status: 'held',                 // held → admitted (the owner's word) → landed
    handedOff: nowISO()
  })
  saveQueue(q)
  console.log(`${green('handed off')} ${repo.key}/${branch}`)
  console.log(dim('  Waiting for the owner\'s word. Nothing merges until it is admitted.'))
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
      const mark = e.status === 'admitted' ? green('admitted')
        : e.status === 'stalled' ? red('STALLED')
          : dim('held')
      let delta = ''
      try {
        const lr = git(['rev-list', '--left-right', '--count', `${repo.mainBranch}...${e.branch}`], repo.checkout)
        const [behind, ahead] = lr.split(/\s+/)
        delta = dim(`+${ahead} −${behind}`)
      } catch { delta = dim('(delta unknown)') }
      console.log(`  ${String(i + 1).padStart(2)}. ${e.branch.padEnd(28)} ${mark.padEnd(18)} ${delta}`)
      if (e.after) console.log(dim(`      after: ${e.after}`))
      if (e.note) console.log(dim(`      ${e.note}`))
      if (e.stallReason) console.log(red(`      ${e.stallReason}`))
    })
  }
  if (!any) console.log(dim('the queue is empty'))
  else {
    // THE QUEUE IS SHARED, AND THAT IS THE POINT. Several agents hand off at once,
    // so an agent reading `status` routinely finds branches it never handed off —
    // and has read that as a fault worth investigating or warning about (learned
    // 2026-08-28). Said here rather than only in the README because this listing,
    // not a doc read at the start of a session, is what is in front of it.
    console.log(dim('Several agents hand off to this queue; entries you did not create are expected.'))
    console.log(dim('Before draining, confirm the admitted set is the one the owner meant: drainer drain <repo> --dry-run'))
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
 * healthy, and production is serving the build from before the drain. It arises
 * when the last entry of a run is dropped rather than landed, and it is cleared
 * by the next drain of that repo (`settleDeploy`), which is what this says.
 * Silent for every repo that configures no `deploy`.
 */
function reportUndeployedTip (key, repo) {
  const marker = repo.deploy?.skipMarker
  if (!marker) return
  const tip = gitTry(['log', '-1', '--format=%B', repo.mainBranch], repo.checkout)
  if (!tip.ok || !tip.out.includes(marker)) return
  console.log(yellow(`${key}: ${repo.mainBranch} is sitting on a build the host was told to skip`))
  console.log(dim(`  Production still serves what it served before that merge.`))
  console.log(dim(`  The next drain of this repo publishes it:  drainer drain ${key}`))
  console.log('')
}

/**
 * Branches this repo has LANDED and not finished putting away: a local ref that
 * is fully merged into `main`, has no worktree, and is in no queue entry.
 *
 * `status` reports it because an empty queue was the one place the drainer said
 * nothing at all, and residue from a failed cleanup is invisible precisely when
 * there is nothing left to look at. Three branches accumulated this way in a day
 * (2026-08-19) and it took a roster sweep to notice. Reported, never deleted:
 * a ref that survived cleanup may be the one thing pointing at work somebody
 * still wants, and the drainer has no business guessing which.
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
  console.log(dim(`  If they are residue from a drain, clear them:`))
  console.log(dim(`    git -C ${repo.checkout} branch -d ${stale.join(' ')}`))
  console.log(dim(`  Check first — a branch preserving removed code looks identical from here.`))
  console.log('')
}

// One named entry, scoped to its repo. Branch names are unique within a repo,
// not across the queue: two repos can each hand off a branch called
// "fitness-functions". The repo comes from --repo, or from the worktree the
// command runs in; with neither, a name two repos share is refused rather
// than guessed, because a guess can move or drop another session's entry.
function entryNamed (cfg, q, name, args) {
  const key = args['--repo'] || detectHere(cfg)?.repo.key
  const hits = q.entries.filter(x => x.branch === name && (!key || x.repo === key))
  if (!hits.length) die(`"${name}" is not in the queue${key ? ` for ${key}` : ''}`)
  if (hits.length > 1) {
    die(`"${name}" is queued in ${hits.map(x => x.repo).join(' and ')} — pass --repo <repo>`)
  }
  return hits[0]
}

// A name given to admit or unadmit without --repo must not reach two repos.
function refuseAmbiguous (q, names, args) {
  if (args['--repo']) return
  for (const name of names) {
    const repos = [...new Set(q.entries.filter(x => x.branch === name).map(x => x.repo))]
    if (repos.length > 1) die(`"${name}" is queued in ${repos.join(' and ')} — pass --repo <repo>`)
  }
}

function cmdAdmit (cfg, args) {
  const q = loadQueue()
  const all = args['--all']
  const names = args._
  if (!all && !names.length) die('name the branches to admit, or pass --all')
  refuseAmbiguous(q, names, args)
  let n = 0
  for (const e of q.entries) {
    if (e.status !== 'held') continue
    if (args['--repo'] && e.repo !== args['--repo']) continue
    if (all || names.includes(e.branch)) { e.status = 'admitted'; e.admitted = nowISO(); n++ }
  }
  saveQueue(q)
  console.log(`${green('admitted')} ${n} branch(es). Land them with: drainer drain <repo>`)
}

// The inverse of admit, and it exists because an admitted entry is a state
// the owner may want to take back — a change of mind, a branch that needs one more
// look — without dropping it out of the queue and losing its place. It reaches
// only as far as the drain: once a branch is landing, `drop` and `resume` are
// what govern it.
function cmdUnadmit (cfg, args) {
  const q = loadQueue()
  const all = args['--all']
  const names = args._
  if (!all && !names.length) die('name the branches to unadmit, or pass --all')
  refuseAmbiguous(q, names, args)
  const wanted = e => (all || names.includes(e.branch)) &&
    (!args['--repo'] || e.repo === args['--repo'])
  // A stalled entry is mid-drain: its worktree holds a rebase in progress, so
  // moving it back to held would leave the queue describing a state the disk
  // does not. Say so rather than half-doing it.
  const stalled = q.entries.filter(e => e.status === 'stalled' && wanted(e))
  for (const e of stalled) {
    console.log(yellow(`${e.repo}/${e.branch} is STALLED mid-drain — unadmit will not touch it.`))
    console.log(dim(`  Resolve it and ${bold('drainer resume')} ${e.repo}, or ${bold('drainer drop')} ${e.branch}.`))
  }
  let n = 0
  for (const e of q.entries) {
    if (e.status !== 'admitted') continue
    if (!wanted(e)) continue
    e.status = 'held'
    delete e.admitted
    n++
  }
  saveQueue(q)
  if (!n) {
    console.log(dim('nothing to unadmit — no matching entry was admitted'))
    return
  }
  console.log(`${yellow('held')} ${n} branch(es) again. The branch, its worktree and its place in the queue are untouched.`)
  console.log(dim('  Re-admit with: drainer admit <branch>'))
}

function cmdDrop (cfg, args) {
  const q = loadQueue()
  const name = args._[0]
  if (!name) die('name the branch to drop')
  const e = entryNamed(cfg, q, name, args)
  // If it stalled mid-rebase, put the worktree back as it was.
  if (e.status === 'stalled' && e.worktree && fs.existsSync(path.join(e.worktree, '.git'))) {
    gitTry(['rebase', '--abort'], e.worktree)
  }
  q.entries = q.entries.filter(x => x !== e)
  saveQueue(q)
  console.log(`${yellow('dropped')} ${e.repo}/${e.branch} — the branch and its worktree are untouched`)
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
function cmdDrain (cfg, args, { resuming = false } = {}) {
  const key = args._[0] || detectHere(cfg)?.repo.key
  if (!key) die('name the repo to drain (or run from inside one of its worktrees)')
  const repo = repoOf(cfg, key)
  const dryRun = !!args['--dry-run']

  const q = loadQueue()
  const stalled = q.entries.find(e => e.repo === key && e.status === 'stalled')
  if (stalled && !resuming) {
    die(`${key} is stalled on "${stalled.branch}" — resolve it, then: drainer resume ${key}\n` +
        `  report: ${path.join(REPORT_DIR, `${key}-${stalled.branch}.md`)}`)
  }

  const problems = preflight(repo)
  if (problems.length) {
    die(`${key} is not ready to drain:\n  - ${problems.join('\n  - ')}`)
  }

  const lock = dryRun ? true : acquireLock(key)
  if (!lock) {
    const owner = readJSON(path.join(LOCK_DIR, key, 'owner.json'), null)
    die(`${key} is being drained already (pid ${owner?.pid ?? '?'}, since ${owner?.since ?? '?'})`)
  }

  const landed = []
  const simulated = new Set()          // dry-run only; the real queue is never written
  try {
    while (true) {
      const q2 = loadQueue()
      const queued = new Map(q2.entries.map(e => [`${e.repo}:${e.branch}`, e]))
      const entry = q2.entries.find(e => eligible(cfg, e, key, { queued, simulated, resuming }))
      if (!entry) break

      console.log(`\n${bold('──')} ${bold(entry.branch)} ${dim(entry.worktree)}`)
      if (dryRun) {
        console.log(dim('  (dry run — would rebase, gate, merge --no-ff, push, clean up)'))
        if (repo.deploy?.skipMarker) {
          console.log(dim(moreEligibleAfter(cfg, key, entry, { queue: q2, simulated, resuming })
            ? `  (dry run — its merge would carry ${repo.deploy.skipMarker}; the host skips that build)`
            : '  (dry run — its merge would be unmarked; this is the one the host builds)'))
        }
        simulated.add(entry.branch)
        landed.push(entry.branch)
        continue
      }

      const wt = entry.worktree
      if (!fs.existsSync(wt)) {
        die(`the worktree for "${entry.branch}" is gone (${wt}) — drop the entry or repair the worktree`)
      }

      // A branch already contained in main needs cleanup, not a merge. This is
      // where the roster's "merged; delete the worktree and this row" backlog
      // lands — the state that accumulates when a merge and its cleanup were
      // two separate acts by two different people.
      const alreadyIn = gitTry(['merge-base', '--is-ancestor', entry.branch, repo.mainBranch], repo.checkout).ok
      // Set at step 2 below; read again at the pre-merge publish, which is why it
      // is declared out here rather than beside its use.
      let current = false

      if (alreadyIn) {
        console.log(dim(`  already contained in ${repo.mainBranch} — cleanup only, no merge`))
      } else {
        // 1. Bring main and the branch up to date.
        if (entry.status !== 'stalled') {
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
            const ownerCall = conflicted.some(p => repo.protectedPaths.some(pp => p.startsWith(pp)))
            entry.status = 'stalled'
            entry.ownerCall = ownerCall
            entry.stallReason = `rebase conflict in ${conflicted.length} file(s)${ownerCall ? ' — OWNER DECISION REQUIRED' : ''}`
            saveQueue(q2)
            const file = writeStallReport(repo, entry, 'rebase conflict', rb.err || rb.out, conflicted, ownerCall)
            console.error(red(`\n  STALLED — rebase conflict on ${entry.branch}`))
            console.error(`  ${conflicted.length} conflicted file(s); the rebase is left in progress for you to resolve.`)
            if (ownerCall) console.error(red('  A conflicted path is protected — this one is the owner\'s call, not an agent\'s.'))
            console.error(`  report: ${file}`)
            console.error(dim('  Nothing behind it was landed. Resolve, then: drainer resume ' + key))
            return { landed, stalledOn: entry.branch }
          }
        } else {
          // Resuming: the fixer finished the rebase in place. A setup or gate
          // stall leaves no rebase at all, so this passes for those without
          // asking anything of the fixer.
          if (rebaseInProgress(wt)) die(`the rebase in ${wt} is still in progress — finish it (git rebase --continue) before resuming`)
          if (entry.ownerCall && !args['--owner-approved']) {
            die(`"${entry.branch}" stalled on a protected path — resume with --owner-approved once the owner has read the resolution`)
          }
          const anc = gitTry(['merge-base', '--is-ancestor', `origin/${repo.mainBranch}`, entry.branch], repo.checkout)
          if (!anc.ok) die(`"${entry.branch}" is not on top of origin/${repo.mainBranch} — rebase it before resuming`)
          entry.status = 'admitted'
          delete entry.stallReason
          saveQueue(q2)
        }

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
        const setup = ensureWorktreeSetup(repo, wt)
        if (!setup.ok) {
          entry.status = 'stalled'
          entry.stallReason = `worktree setup failed: ${setup.failed}`
          saveQueue(q2)
          const file = writeStallReport(repo, entry, 'worktree setup failed',
            `This worktree lacked its generated environment — \`${repo.setupWhen || '(no probe configured)'}\` said so —\n` +
            `and the setup step that fills it in exited non-zero:\n\n` +
            `    ${setup.failed}\n\n` +
            `Its output is above, in the drain log. The gate never ran; nothing here is a\n` +
            `verdict on the branch.`,
            [], false, [setup.failed])
          console.error(red(`\n  STALLED — worktree setup failed on ${entry.branch}`))
          console.error(`  the step that failed: ${setup.failed}`)
          console.error(dim('  The rebase is complete — there is no conflict to resolve, and the gate'))
          console.error(dim('  has not run. Fix the environment in that worktree, then: drainer resume ' + key))
          console.error(`  report: ${file}`)
          return { landed, stalledOn: entry.branch }
        }

        // 3. The gate: what would break a writer, run on exactly what will land.
        let gateOK = true
        let gateFailed = null
        for (const step of repo.gate) {
          console.log(dim(`  gate: ${step}`))
          if (!run(step, wt, repo.gateEnv || {})) { gateOK = false; gateFailed = step; break }
        }
        if (!gateOK) {
          entry.status = 'stalled'
          entry.stallReason = 'gate failed after rebase'
          saveQueue(q2)
          const file = writeStallReport(repo, entry, 'gate failed after rebase',
            `The gate step \`${gateFailed}\` exited non-zero. Its output is above, in the drain log.`,
            [], false, [gateFailed])
          console.error(red(`\n  STALLED — the gate failed on ${entry.branch} after rebasing.`))
          console.error(dim('  This is the queue working: it passed on the old main and fails on the new one.'))
          console.error(`  report: ${file}`)
          return { landed, stalledOn: entry.branch }
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
        //     should — somebody pushed to the branch after the drain began.
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
        //    takes minutes, and an entry can be dropped inside them, which would
        //    make this the last merge after all. See `settleDeploy` for the rest
        //    of the design and for what happens when this lookahead is wrong.
        console.log(dim(`  merging into ${repo.mainBranch}…`))
        const marker = repo.deploy?.skipMarker
        const more = marker
          ? moreEligibleAfter(cfg, key, entry, { queue: null, simulated, resuming: false })
          : false
        if (marker) {
          console.log(dim(more
            ? `  marked ${marker} — another branch is queued behind it, so the host skips this build`
            : '  unmarked — the last of this run, so the host builds it'))
        }
        const msg = `Merge ${entry.branch}${entry.note ? ` — ${entry.note}` : ''}${more ? ` ${marker}` : ''}`
        const mg = gitTry(['merge', '--no-ff', '-m', msg, entry.branch], repo.checkout)
        if (!mg.ok) die(`merge failed unexpectedly after a clean rebase: ${mg.err}`)

        const push = gitTry(['push', 'origin', repo.mainBranch], repo.checkout)
        if (!push.ok) {
          gitTry(['reset', '--hard', `origin/${repo.mainBranch}`], repo.checkout)
          die(`push to origin/${repo.mainBranch} failed, so the merge was rolled back locally:\n${push.err}`)
        }
        console.log(green(`  landed on ${repo.mainBranch} and pushed`))
      }

      // 5. Cleanup — the lifecycle the roster rule asks for, done by the thing
      //    that did the merge rather than by whoever remembers.
      //
      // A CLEANUP STEP THAT FAILS SAYS SO IN RED AND LEAVES A RESIDUE LINE.
      // It used to report every failure in dim, the same weight as a success,
      // at the very end of a drain whose last two hundred lines are gate output.
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
      // said once, plainly, where the person running the drain will read it.
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
      resuming = false
    }

    // The line ran to the end without stalling. If `main` is nevertheless
    // sitting on a merge the host was told to ignore — the lookahead above can
    // be wrong, and an entry dropped between two drains leaves exactly this —
    // publish it. On the ordinary path the last merge was unmarked and this does
    // nothing. Deliberately reached even when this run landed nothing, because
    // "the final entry was dropped" is the case where nothing lands and the
    // undeployed tip is somebody else's leftover.
    settleDeploy(repo, dryRun)
  } finally {
    if (!dryRun) releaseLock(key)
  }

  if (!landed.length) {
    console.log(dim('\nnothing admitted to drain'))
    return { landed }
  }

  // 6. The broad sweep, once, on the final tip. This REPORTS; it does not gate,
  //    because each entry already passed the gate on exactly its own content.
  if (repo.finalCheck && !dryRun) {
    console.log(`\n${bold('final check')} ${dim(repo.finalCheck)}`)
    const ok = run(repo.finalCheck, repo.checkout, repo.gateEnv || {})
    console.log(ok ? green('  final check passed') : red('  FINAL CHECK FAILED — main is landed and pushed; this is a new task, not a rollback'))
  }

  console.log(`\n${green(bold('drained'))} ${landed.length} branch(es) into ${key}/${repo.mainBranch}:`)
  landed.forEach(b => console.log(`  · ${b}`))
  return { landed }
}

function cmdResume (cfg, args) {
  return cmdDrain(cfg, args, { resuming: true })
}

function cmdHelp () {
  console.log(`
${bold('drainer')} — a local merge queue for git repositories

  ${bold('drainer handoff')} [--repo R] [--branch B] [--after DEP] [--note "…"]
      Hand a finished branch to the queue. Run it from the branch's worktree and
      repo/branch are detected. Refuses unpushed or uncommitted work. The entry
      sits ${dim('held')} until the owner admits it — handing off never merges anything.

  ${bold('drainer status')} [repo]        Show the queue, each entry's state and delta.
  ${bold('drainer admit')} <branch>… | --all [--repo R]
      ${bold('The owner\'s word.')} Moves entries from held to admitted.
  ${bold('drainer unadmit')} <branch>… | --all [--repo R]
      Put admitted entries back to held. The entry keeps its place in the queue;
      nothing about the branch or its worktree moves. Refuses a stalled entry.
  ${bold('drainer order')} <branch> --first | --last | <position>
      Reorder. Land refactors early — everything behind one rebases over it anyway.
  ${bold('drainer drain')} [repo] [--dry-run]
      Land every admitted entry, one at a time: rebase → gate → merge --no-ff →
      push → remove worktree → delete branch → delete roster row. Stalls on the
      first conflict; nothing behind it lands out of order.
  ${bold('drainer resume')} [repo] [--owner-approved]
      Continue after a stall has been resolved in the worktree.
  ${bold('drainer drop')} <branch>       Remove an entry; the branch is left untouched.

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
  handoff: cmdHandoff,
  status: cmdStatus,
  admit: cmdAdmit,
  unadmit: cmdUnadmit,
  drain: cmdDrain,
  resume: cmdResume,
  drop: cmdDrop,
  order: cmdOrder
}
const fn = commands[cmd]
if (!fn) { console.error(red(`drainer: unknown command "${cmd}"`)); cmdHelp(); process.exit(1) }

const result = fn(cfg, args)
if (result && result.stalledOn) process.exit(2)
