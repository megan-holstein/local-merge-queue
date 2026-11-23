# local-merge-queue

A local merge queue for git, for the case where several branches are in flight at once
against a `main` that moves under them. Coding agents finish a branch and enqueue it
queue instead of merging it. The owner approves the entries that should land. Then
`local-merge-queue land <repo>` lands each approved branch one at a time, putting it on top of the
`main` it will actually live on, running a gate you configure, merging `--no-ff`, pushing,
and removing the worktree and deleting the branch both locally and on the remote. Where the
gate takes minutes, an opt-in [batched mode](#batched-landing) gates several entries once.

## Why

GitHub's own merge queue is available only in public repositories owned by an organization, or in private repositories owned by organizations on GitHub Enterprise Cloud. A repository owned by a personal account cannot use it on any plan, and a private organization repository needs the Enterprise plan. local-merge-queue is a free alternative that gives any git repository the same discipline: each branch is rebased onto current `main`, gated, then merged one at a time, with the gates running on your own machine and no hosted service or GitHub App. See GitHub's documentation, [Managing a merge queue](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue).

It was written because one repository's `main` took 190 merges in 30 days. A branch
verified on Tuesday's `main` is not a branch that works on Friday's, and every sweep of
that repo turned up branches 40 and 70 commits behind whatever they would land on. The
merge queue exists so that nobody has to hold that in their head, and so that the answer to
"is this branch still good?" comes from rebasing it and running the gate rather than from
somebody's recollection.

**What it is not.** It is not a hosted service, not a GitHub App, and not a CI provider.
It runs on your machine, against your own checkouts, with your own shell, so it needs no
webhook endpoint and no control plane, it works on private repositories, and there is no
paid tier because there is no service behind it to pay for. It reads pull requests through
the `gh` CLI where you give it a repository slug, and it runs without one.

## Install

One file, Node ESM, no dependencies. Node 20 or newer.

```sh
npx github:megan-holstein/local-merge-queue --help
```

Or clone it and put the bin somewhere on your PATH.

```sh
git clone https://github.com/megan-holstein/local-merge-queue.git
ln -s "$PWD/local-merge-queue/local-merge-queue.mjs" ~/bin/local-merge-queue
```

It is deliberately not published to the npm registry.

## Quickstart

Copy `repos.example.json` to your config path and edit it to name your checkout, your
gate, and whatever a fresh worktree of yours needs before the gate can run:

```sh
mkdir -p ~/.config/local-merge-queue
curl -o ~/.config/local-merge-queue/repos.json \
  https://raw.githubusercontent.com/megan-holstein/local-merge-queue/main/repos.example.json
```

Then work a branch in its own worktree, as usual, and enqueue it from inside that
worktree when it is finished:

```sh
cd ~/code/myapp-somefeature
git push -u origin somefeature
local-merge-queue enqueue --note "what this is, in one clause"
```

Nothing has merged. The entry sits `enqueued`. Look at the queue, approve what should land, and
land:

```sh
local-merge-queue status
local-merge-queue approve somefeature
local-merge-queue land myapp --dry-run    # the order it would land in, nothing touched
local-merge-queue land myapp
```

## The lifecycle

```
 branch agent                   the owner                     the merge queue
 ────────────                   ─────────                     ───────────
 finish + verify
 push
 local-merge-queue enqueue ──►  enqueued
                                local-merge-queue approve  ──►  approved
                                local-merge-queue unapprove ◄─  (back to enqueued, any
                                                              time before the landing run)
                                                              local-merge-queue land
                                                                rebase onto origin/main
                                                                  (skipped if already on top)
                                                                set the worktree up, if unset
                                                                run the gate
                                                                merge --no-ff, push
                                                                remove worktree
                                                                delete branch, local + remote
                                                                (its PR closes itself, as merged)
                                                              ─ and, where the host builds main,
                                                                exactly one deploy, at the end
```

**Enqueuing is not merging.** An entry sits `enqueued` until the owner approves it, so a
standing rule that branches land only on the owner's word survives intact. Approval is
that word. Enqueue freely the moment a branch is genuinely ready.

**Approval is reversible right up to the merge.** `local-merge-queue unapprove` puts an approved
entry back to `enqueued`, for a change of mind or one more look before it lands, and it is
the command to reach for rather than `dequeue`, which takes the entry out of the queue
altogether and loses the order the branches were meant to land in. A landing run reads the
queue again before it publishes and again before it merges, so an entry unapproved or
dequeued while its gate runs is not landed (the output says so), and nothing the run
writes brings it back. A stalled entry is refused by `unapprove`, and `resume` or
`dequeue` govern that one instead.

**The queue is written one change at a time.** Every command that writes the queue file
(`enqueue`, `approve`, `unapprove`, `order`, `dequeue`, `land`, `resume`) takes a lock, reads
the file afresh, applies only its own change, and writes it back, so what another process
wrote meanwhile is never overwritten. A landing run takes minutes, and it is the process most
likely to meet an `enqueue` or an `approve` from a second session while it works: an entry
enqueued, approved or reordered during a run is there when the run ends, with its state and
position. A landing run also picks up an entry approved during the run, and says so. See
[Safety properties](#safety-properties-and-the-one-thing-it-will-not-protect-you-from).

## What a branch agent does

Finish the work, verify it, commit, push. Then, **from inside the branch's worktree**,
enqueue it:

```sh
local-merge-queue enqueue --note "what this is, in one clause"
```

The merge queue detects the repo and the branch from the worktree. It refuses a dirty
worktree or unpushed commits, because it will not carry unbacked-up work, **and where you
have configured a repository slug it refuses a branch with no open pull request**, on the
reasoning that the pull request list is the roster of what is in flight. Open the PR when
you first push rather than when the work is done, so that a branch nobody has heard of
cannot exist:

```sh
gh pr create --base main --head somefeature --draft \
  --title "<what it is, in one clause>" --body-file <a file you wrote>
```

The body carries scope, what is built, what is left, how to verify, and every decision
that belongs to the owner rather than to whoever wrote the branch. Keep it current with
`gh pr edit <n> --body-file`.

If the branch must land after another one, in the same repo or a different one, declare
that and the merge queue holds it back until the dependency is contained in its own `main`.

```sh
local-merge-queue enqueue --after otherrepo:some-prerequisite
```

If the branch carries history that a rebase would flatten, add `--no-rebase`; see [A branch that already contains `main` is not rebased](#a-branch-that-already-contains-main-is-not-rebased).

Then report and stop. Do not merge, do not clean up, do not touch `main`.

## What a branch agent must not do

The merge queue owns all of this, and doing any of it by hand races the queue and leaves the
pull request list disagreeing with git.

- `git merge` into any `main`
- `git worktree remove` for a landed branch
- `git branch -d` or `git push origin --delete` for a landed branch
- closing a landed branch's pull request by hand, since the merge closes it as **merged**
- rebasing an enqueued branch onto `main` to keep it fresh
- `local-merge-queue land` on the strength of approval language alone. "Approved for the merge queue"
  and "approve these" authorize `approve` and nothing more, and the landing run runs on its own
  explicit word.
- `local-merge-queue dequeue`, `local-merge-queue order`, `local-merge-queue unapprove` or `local-merge-queue resume` on an entry
  somebody else enqueued, which the next section covers

Creating a branch, its worktree and its pull request is unchanged and still the branch
agent's, and the PR is now load-bearing, since `enqueue` refuses a branch that has none.

## The queue is shared, and other agents' entries are the point

**Several agents enqueue into one queue at the same time.** That is what a queue is for. A
queue holding only your own branch is the unusual case, and one holding three branches
from three sessions you know nothing about is the ordinary one.

So an entry you did not create is not a stray, not a leak, not a fault, and not evidence
that something went wrong, and it needs no investigation and no warning in your enqueue note.
Do not dequeue it, reorder it, unapprove it, resume it, or tidy it. `dequeue`, `order`, `unapprove`
and `resume` belong to whoever enqueued the branch; using them on someone else's
entry is the same class of mistake as merging by hand, with the extra cost that dequeuing
or unapproving a branch somebody had already approved takes that approval back silently.

**The one thing a shared queue does change is the check before a landing run.** Approval is a
word given about the entries the owner was looking at, and it is not a standing
certificate for whatever has been approved since. So when the word to land arrives, read
the queue back first:

```sh
local-merge-queue status                        # what is actually queued, and in what state
local-merge-queue land <repo> --dry-run        # the order it would land in, nothing touched
```

Confirm the approved set is the set that was meant, and land then. If something is
approved that nobody mentioned, name it in one line and ask. The two failure modes are
landing it silently and treating its presence as an alarm.

## What the owner does

```sh
local-merge-queue status                        # the whole queue, with each entry's delta
local-merge-queue approve <branch> [<branch>…]    # the word
local-merge-queue approve --all --repo mysite
local-merge-queue unapprove <branch> [<branch>…]  # take the word back; the entry keeps its place
local-merge-queue unapprove --all --repo myapp
local-merge-queue order <branch> --first        # land refactors early (see below)
local-merge-queue land myapp                   # land everything approved
local-merge-queue land myapp --dry-run
local-merge-queue dequeue <branch>                 # take it back out; the branch is untouched
```

**A branch name belongs to its repo.** Two repos can each queue a branch with the same name. `order`, `dequeue`, `approve` and `unapprove` take `--repo <repo>`, or use the repo of the worktree they run in; given a name two repos share and neither, they refuse and ask for `--repo` rather than guess, because a guess can move, approve or dequeue another session's entry.

## A branch that already contains `main` is not rebased

The rebase buys exactly one thing, which is that the branch is verified against the `main`
it lands on. A branch that has *merged* current `main` into itself already has that, and
rebasing it anyway is not a harmless no-op, because it flattens. `git rebase` drops every
merge commit and replays the sides in a single line, so a branch that folded sub-branches
into itself meets its own commits stripped of the resolutions that reconciled them, and
conflicts **against itself** — in files `main` never touched.

That shape is not exotic. It is what you get whenever several pieces are developed and
tested together before any of them lands. One branch in the repo this was built for,
`frameworks`, had folded four sub-branches. On 2026-08-21 it had merged current `main`,
and it merged clean, and a plain rebase of it conflicted in **9 files on the first of 47
commits**. The merge queue would have stalled a branch with nothing wrong with it — one that
had been kept deliberately current.

So the rebase step asks `git merge-base --is-ancestor origin/<main> <branch>` first, and
where the answer is yes it reports *already on top of origin/main, no rebase needed* and
goes straight to the gate. `merge --no-ff` then lands the tree that was tested, verbatim,
which is the whole point. A queue that lands a tree nobody reviewed is a queue that cannot
be trusted, and before this it could do exactly that on any branch whose flattening
happened to resolve differently.

**`--rebase-merges` is not the fix**, and it was tried first. It re-*performs* each merge
rather than replaying its result, so any merge that somebody resolved by hand raises its
conflict again. Skipping is exact where replaying is a guess.

What this does not relax is the ordinary case. A branch that does not contain current
`main` is still rebased, still gated on the `main` it will live on, and still stalls if it
conflicts. Being behind is the case the merge queue was built for, and it is untouched.

**`enqueue --no-rebase` is for a branch that must never be rebased**, such as one that carries imported history, where a rebase would replay every commit in one line even when it conflicts nowhere. The entry records `noRebase: true`, and `status` and `land --dry-run` show `no-rebase` beside it. When `main` has moved since the branch last merged it, `land` starts no rebase. It stalls the entry with the reason `main moved under a --no-rebase branch — merge origin/<main> into it and resume`, and the stall report says the fix: in the worktree, run `git merge origin/<main>`, resolve any conflict, commit, then run `local-merge-queue resume <repo>`. A one-lane repo stops there, as for any stall, and a multi-lane repo keeps landing the entries in other lanes. `resume` never rebases such an entry. It passes only once the branch contains `origin/<main>`, and otherwise stalls it again with the same reason. An entry enqueued without the flag behaves as before.

## When it stalls

**It stalls; it does not evict.** On a rebase conflict or a gate failure the merge queue
stops where it stands, leaves the rebase in progress in that worktree, writes a report to
`<state>/reports/<repo>-<branch>.md` (a `/` in the branch name is written as `%2F`, so `feat/x` reports to `<repo>-feat%2Fx.md`), and exits 2. Nothing behind it lands out of order — which is
deliberate. Branches that are in flight together usually overlap, so landing one of them
out of order relocates a conflict rather than avoiding it.

In a repo with more than one lane, a stall holds only the lanes of the entry that stalled, and the line keeps landing entries in other lanes; see [Lanes](#lanes).

A fixer resolves it in place, in the named worktree:

```sh
cd <the worktree named in the report>
# resolve the conflict
git add -A && git rebase --continue
local-merge-queue resume <repo>
```

The line then continues from that entry. `resume` fetches first: a `main` that moved while the entry was stalled (another lane landing, or a push from outside the queue) is seen, and the entry is rebased and gated again, in a one-lane repo as well as a multi-lane one. Two things about that are worth saying out loud.

- **A gate failure after the rebase is the queue working rather than a bug.** It means the
  branch passed on the old `main` and fails on the new one, which is precisely what would
  otherwise have reached `main` broken.
- **A conflict inside a protected path is the owner's call.** You list those paths per
  repo. The report says OWNER DECISION REQUIRED and `resume` refuses until you pass
  `--owner-approved`. The paths this was written for hold prose the owner had already read
  and approved, and a rebase can rewrite prose quietly, which is the whole reason the
  escalation exists.

## Order matters, and refactors go first

Because the merge queue stalls rather than evicting, position in the queue is a commitment.
Put a refactor at the **front** of the line rather than the back. Every branch behind it
must rebase over it regardless, and first in line each one conflicts once against a
settled `main`, where last in line the refactor meets every branch's changes at once — in
one person's context, all together. A branch that rewrote a document from 178k to 30k is
the case that taught this.

```sh
local-merge-queue order the-refactor --first
```

## A worktree that arrives unset is set up rather than stalled on

**A land never stalls because a worktree lacks its generated environment.** Before the
gate runs, the merge queue asks the repo's `setupWhen` probe whether this worktree is a
working checkout, and where the answer is no it runs the repo's `setup` itself, meaning
`npm install`, the env files, the native rebuild, whatever that repo's fresh-worktree
steps happen to be.

It exists because the seam it heals is structural rather than careless. A branch whose own
work needed no build — a doc-adjacent fix, a test edit — is verified without one, so its
worktree never acquires an environment at all, and the first thing anybody notices is the
merge queue's gate dying minutes into a landing run over something that is not the branch's fault.
Three branches went that way on 2026-08-24, twice as `esbuild ENOENT` out of an empty
`node_modules`, each costing a person a diagnose-install-resume cycle for a queue whose
whole point is not needing one.

- **After the rebase, before the gate.** `npm install` then installs what the branch's own
  manifest asks for, on top of the `main` it will land on, and a branch that stalls at the
  rebase pays for no install at all.
- **The probe is what keeps it free.** A land of an already-working worktree runs one
  `test`, moves on, installs nothing, copies nothing, and prints nothing about setup.
  Configure `setup` without a `setupWhen` and every landing pays the full cost, which is
  why each probe should cover every step of its own `setup`, so that a half-set-up
  worktree is completed rather than passed over.
- **`$LOCAL_MERGE_QUEUE_CHECKOUT` names the primary checkout** inside setup steps, since most of
  what a worktree lacks is a copy of something the primary checkout already has, such as a
  prebuilt binary or a gitignored env file.

None of this relieves a branch agent of setting up its own worktree, since an agent that
builds or runs anything still needs one that works. It relieves the enqueue seam, which is
the one place nobody was looking.

**A setup failure stalls, with its own report.** It is not a gate failure and says so,
because the gate never ran and nothing about the failure is a verdict on the branch. The
report names the step that exited non-zero and, since a setup failure happens after the
rebase has finished cleanly, it does not tell the fixer to resolve a conflict. The merge queue
chooses those instructions by asking git whether a rebase is genuinely in progress, so
they can never contradict the worktree. Fix the environment in the named worktree and run
`local-merge-queue resume <repo>`, with nothing to `git rebase --continue`.

That correction reaches the gate-failure report too, which had been sending fixers to
resolve a rebase that had already finished, since the day it was written.

## One deploy per landing run rather than one per branch

**A repo whose host builds every push to `main` gets one build per landing run.** You
configure that per repo, and the merge queue stays silent about it everywhere you have not.

```json
"deploy": { "skipMarker": "[skip-deploy]" }
```

The site this was built for deploys production from `main` through Vercel's git
integration, so the push that lands each branch *is* a production build. Landing N
branches shipped N of them, and every one but the last shipped a state that existed for as
long as the next gate took. The owner's ask, 2026-08-29, was that the site should simply
redeploy at the end of the landing.

So the merge queue appends the marker to the merge commit message of every entry that has
another entry behind it, and leaves the **last merge of the run unmarked**. The site's own
ignore script, wired up as `vercel.json`'s `ignoreCommand`, reads the marker out of
`VERCEL_GIT_COMMIT_MESSAGE` and skips those builds, Vercel's documented contract being
that the ignore command's exit 0 skips the build and its exit 1 lets the build proceed.
One push, one build — and what production ends on is the state a person asked for rather
than a stopping point.

**The pushes themselves are never batched, deferred, or reordered.** An unpushed merge is
unbacked-up work, and a pull request retires itself as *merged* only because the landing
tip is reachable from `main` by the time cleanup deletes the remote branch. The push
cadence is load-bearing, and only the build per push is suppressed.

Three properties are worth knowing before changing any of it:

- **The lookahead is asked of the queue at the merge rather than before the gate.** A gate
  takes minutes and an entry can be dequeued inside them, which makes the entry being landed
  the last one after all. Re-reading is what lets that dequeue land correctly.
- **A stall does not deploy the lane it holds.** The line is expected to continue, and
  shipping the half-landed state mid-stall is the thing this exists to prevent. The `resume`
  that lands the last entry is what deploys.
- **The end of a run settles from the state rather than from memory.** The lookahead can
  still be wrong in two ways, since the entry behind this one may stall and then be
  dequeued, or may turn out to be cleanup-only and push nothing, and both leave `main` on a
  merge the host was told to ignore, with an empty queue and a healthy-looking log. So
  every run ends by asking, for each lane that has a marker and that no stalled entry holds, whether the lane's last build carries the
  marker, and publishes it with an empty commit where it does. On the ordinary path the last build
  is unmarked and this does nothing at all. `local-merge-queue status` reports the same state, for
  the stretch between the dequeue and the next landing run.

A repo with one lane and a `deploy` key behaves as this section describes. A repo with several lanes marks and settles lane by lane; the next section says how.

### Lanes and the deploy marker

**The marker is per lane.** `deploy` sits inside a lane, and a lane without a `deploy` key never writes a marker, so an entry in such a lane alone lands unmarked, as it does in a repo with no `deploy` key at all. For each of an entry's lanes that has `deploy.skipMarker`, the merge commit message carries that lane's marker when another entry that this run will land holds the same lane. An entry in another lane does not count: it builds a different host. Two lanes that share one marker string write it once. `land --dry-run` prints, for each lane of the entry that has a marker, whether the merge would carry it.

With lane `site` carrying `deploy` and lane `app` carrying none, three queued entries `site-1`, `app-1`, `site-2` land as `site-1` marked, `app-1` unmarked and `site-2` unmarked. A run of `app` entries alone writes no marker.

**The settle is per lane.** At the end of every run, for each lane that has a marker and that no stalled entry holds, `land` asks whether the lane's last build is a merge that carries the marker. A lane whose paths are `"*"` builds on every push, so its last build is the tip of `main`. For any other lane, `land` walks the first-parent history of `main` from the tip and stops at the first commit that either changes a path of the lane (its prefixes or a `shared` prefix, compared with its first parent) or changes no file at all. If that commit carries the lane's marker, the lane is undeployed.

An empty commit counts as a build of every lane, whichever lane's settle wrote it, so one unmarked empty commit settles every lane at once. A run that finds several lanes undeployed publishes one empty commit, and a second `land` over a settled `main` adds nothing. The walk follows first parents because a plain path-limited `git log` follows the branch side of a `--no-ff` merge and returns the branch's own commit, never the merge that carries the marker, and because an empty commit changes no path and would never appear in it.

**A host's path filter must still build an empty commit.** The republish changes no file. A host that skips a build when no path in its filter changed cancels the republish unless the filter lets an empty commit through. Configure the host so that a commit with no changed files builds.

A stall holds its lanes' settle. If `site-1` merges marked and `site-2` stalls on its gate, `main`'s last `site/` commit stays marked under any later `app` merges, `status` reports `main is sitting on a build the host was told to skip in lane site`, and the next `land` after the stalled entry is resolved or dequeued publishes it. The empty commit builds every lane's host, so a run that settles one lane also publishes any other lane's merge that a stall is holding back; keep the marker on the lanes whose half-landed state is safe to build.

The one thing that must never appear in that empty commit's message is the marker itself.
Naming the thing being fixed is the natural sentence to write, and it would make the commit
that exists to trigger a build the next one skipped, silently and permanently. There is an
assertion against it in the code and another in the suite.

**Verified in production on 2026-09-01**, on the first real land of a site configured this
way, three branches deep. Vercel canceled the two marked intermediate merges' builds and
ran exactly one production build, on the final unmarked commit, 60s, Ready. What had not
been verifiable locally, that Vercel actually skips on the marker, has its live
confirmation.

## The gate, and the final check

**A gate has a timeout, which the config sets.** `gateTimeoutMinutes` (a positive number, per repository, or inside a lane where it overrides the repository's) bounds each setup step, gate step and final check. A step that runs longer is ended (its process group gets `SIGTERM`, and `SIGKILL` five seconds later), the entry stalls with `gate timed out after N minutes` (or `worktree setup timed out`) and a report, and the landing lock is released when the run ends; a final check that times out is reported as `FINAL CHECK TIMED OUT`, since it never gates. Without the key a step has no limit, and a hung gate holds the lock until its holder is ended, since a live holder is never broken. The limit bounds one step, not the entry, so set it above the longest healthy step.

Each entry's **gate** runs in its own worktree, after the rebase and before the merge, on
exactly the content that will land. Make it cheap and make it narrow. The right question
is what would reach a user as a broken payment, a broken sign-in, or a missing feature —
and minutes added to a gate are paid on every single landing.

**The merge is bound to the commit the gate ran on.** After the setup, the run records the branch's commit and the worktree's status. After the gate, and again right before the merge, it checks both: an entry whose branch moved, whose worktree's HEAD moved, or whose tracked files differ from the record (an edit, a staged change, a deletion) stalls with `changed during the gate: …` and a report, and nothing is published or merged. The publish and the merge name the recorded commit and never the branch ref, so a commit made in the worktree while the gate ran cannot land ungated. An untracked file is not a change to what lands, since only commits land; cleanup is what keeps such a file safe (see [Cleanup](#cleanup-and-what-happens-when-it-fails)). `resume` gates the entry again.

**A gate that modifies tracked files** (an install that rewrites a lockfile, a generator that rewrites a checked-in file) would stall every entry for ever, since its change looks like a change during the gate. A lane names the paths its gate may modify with `gateModifies`, an array of path prefixes relative to the repository root, empty by default: a tracked change under one of them, in a lane the entry gated, is the gate's own and is not counted. The `changed during the gate` stall lists the changed paths and names the key. The gate's rewrite is never part of what lands, since only the gated commit merges.

The **final check** runs once, in the primary checkout, after the whole batch has landed, and under the landing lock, so a second `land` cannot fast-forward that checkout beneath it.
It reports rather than gates, because each entry already passed the gate on its own
content. A repo whose full test sweep takes minutes puts the sweep in the gate, where a red
result stalls the entry and leaves `main` untouched, and keeps the final check to a fast
tripwire. A failure there is a new task rather than a rollback, since `main` is already
pushed by design, so that a stall never leaves landed work sitting unbacked-up on the
machine.

## Batched landing

**Opt-in.** Landing one entry at a time costs one gate per entry, and a gate that takes minutes (or an hour, on a loaded machine) makes N reviewed entries cost N gates. In the pattern of [GitLab merge trains](https://docs.gitlab.com/ee/ci/pipelines/merge_trains.html), GitHub's merge queue and [bors](https://bors.tech), a batch builds the candidate `main` that landing the entries one by one would have built, gates its tip once, and pushes that tip.

```json
"batch": { "max": 5, "keep": ["node_modules"] }
```

- **Per repository**: the `batch` key on the repo's entry (a repo-level key, never a lane's). Absent means off, and a repo without it behaves exactly as it did before this existed. `max` is an integer of at least 2, and **only a `max` turns batching on for every run**: a `batch` key with `keep` (and `lockfiles`) but no `max` configures the batch worktree for the runs that pass `--batch`, which use a maximum of 5, and leaves every other run unbatched. `keep` and `lockfiles` are described under [the batch worktree](#the-batch-worktree).
- **Per run**: `local-merge-queue land <repo> --batch` turns it on (a maximum of 5 where the repo has no `batch` key), and `--no-batch` turns it off for one run. Both flags together are refused. `resume` accepts them too.
- Batching is tested against `git` 2.38 and newer and refuses an older one (`local-merge-queue: batched landing needs git 2.38 or newer`). A run without batching has no such floor.

**How a batch forms.** At the entry the run is on, the batch is that entry plus the entries that follow it in queue order, up to `max`, stopping before the first entry that:

- is not eligible to land now (not approved, held behind a stall, or waiting on an `after` that has not landed);
- is enqueued with `--no-rebase`;
- is already contained in `main` (a cleanup-only entry);
- carries merge commits that are not in `main`, which is how a branch that merged `main` into itself looks. Such a branch is not rebased when it is current, and a batch rebases, so it is landed on its own as it always was;
- carries different lanes from the first entry (below).

**What the queue builds.** In [the batch worktree](#the-batch-worktree), on a detached `HEAD`: each entry is rebased onto the previous result, or left as it is when it already contains it, exactly as `land` decides for a single entry; its lanes are worked out as `land` works them out (on the rebased branch, before its `BRANCH.md` is removed); its `BRANCH.md` is removed; and it is merged `--no-ff` with the message `land` would write, its note and its deploy marker included. No entry's own branch moves and nothing is pushed.

**One gate, on the candidate's tip.** The batch runs the setup and the gate of its lanes, each gate once, in the batch worktree.

**A batch lands atomically.** With the gate green, the queue checks again, before anything is pushed, that the worktree still holds the candidate it gated, that `origin/<main>` is still the commit the candidate was built on, and that every entry is still approved and its branch (local and remote), its worktree's `HEAD` and its worktree's cleanliness are what they were when the candidate was built. A branch pushed to during the gate therefore never lands ungated. Then it publishes each entry's rebased tip (a `--force-with-lease` against the remote value it recorded), reads the queue **again** (an entry unapproved or dequeued while the tips were being pushed fails the batch), and pushes `main` **once**, to the commit that was gated. Only after that push does each entry's cleanup run, as for an entry landed alone: the branch moves to its published tip only if its worktree is still on the commit the batch was built from with nothing changed (`git reset --keep`, never `--hard`, so no work in an entry's worktree is discarded), and otherwise the worktree and the branch stay (`WORKTREE KEPT`); then the worktree removed, the branch deleted, a pull request stacked on it retargeted, the remote branch deleted once its pull request reads `MERGED`. The final check runs once at the end of the run, as it always did.

What this means for what reaches `origin`: the batch's **final tree was gated**; the merges between the entries (the first entry's merge alone, say) **were not gated on their own, and never reach origin as a `main` tip**, because `main` moves from the old tip to the final one in a single push. The merge commits are the same ones landing the entries one at a time would write; they arrive together, after one gate. A set of entries that is red alone and green together (two halves of one change) therefore lands as a batch and stalls as single entries.

**Red, a conflict, a rejected push, or any error before that push: fall back.** If building the candidate conflicts, the gate fails, a setup fails, `main` moves, an entry changes or is withdrawn, or `origin` rejects a push, **nothing has landed**: no entry's own branch was moved, no worktree touched, and `main` was never pushed. The queue drops the candidate, prints `BATCH FAILED: <why>` and `Falling back to landing <entries> one at a time`, and lands those entries one at a time, so the entry that actually fails is the one that stalls, with its own report, and the entries before it land. A conflict in a protected path is named as the owner's call in that line, and the entry's stall report says so as it always did. The batch is not retried for those entries in the same run. Entry branches already published as rebased tips stay published (the same content, and the next landing force-pushes with a lease again), and the `BATCH FAILED` message says so: "The remote branches of … already carry their rebased tips: origin's copy was rewritten". The local branches did not move.

**Lanes.** A batch holds only entries that carry the same lanes, a lane that an entry only reached through its imports counting separately from one it changed. That keeps the per-lane rules as they are: an entry in a docs-only lane never waits for the gate of an app lane it does not carry, because it is never gated together with an entry that does. In a repo with one lane every entry shares it. A run over a queue of `a`, `a`, `b`, `a` entries batches the first two and lands the others alone.

**The known-red allow-list, protected paths, `--owner-approved`, the deploy marker and the report files work as before.** The candidate's gate sees the allow-list through `$LOCAL_MERGE_QUEUE_KNOWN_RED` like any gate. The first entries of a batch carry the deploy marker and the last does not (the last when no other entry that shares its lane follows the batch); the end-of-run settle is unchanged. A conflict in the batch falls back, and a stall happens in the one-at-a-time path.

**The batch worktree.** `<state>/batch/<repo>` (for example `~/.local/state/local-merge-queue/batch/<repo>`), a `git worktree` of the repo's primary checkout on a detached `HEAD`, kept between batches because it carries the installed dependencies and rebuilding them for every batch would cost more than the batch saves. It is therefore not a fresh worktree, and before every batch it is made to behave like one, apart from the directories the config names:

- a rebase, merge or cherry-pick left in progress is aborted, and the tree is hard-reset to the commit the candidate is built on;
- every untracked and ignored file is removed (`git clean -fdx`) except the directories in `batch.keep` (relative paths such as `"node_modules"` or `"site/node_modules"`; with none named, nothing survives and the repo's setup runs every batch);
- the repo's lockfiles are hashed and the hash is recorded beside the worktree (`<state>/batch/<repo>.json`). `batch.lockfiles` names them; without it they are the usual names (`package-lock.json`, `npm-shrinkwrap.json`, `yarn.lock`, `pnpm-lock.yaml`, `Cargo.lock`, `poetry.lock`, `Gemfile.lock`, `go.sum`) at the root and beside each `keep` directory, read at the candidate's tip. When the hash differs from the last successful setup, the `keep` directories are removed and the lane's setup steps run again whatever the probe says;
- it is `git worktree lock`ed, so `git worktree prune` never reaps it;
- if it cannot be used (a stale `index.lock`, a broken registration, a missing `.git`), it is rebuilt from scratch, once, and the run says `the batch worktree … is unusable — rebuilding it from scratch`; a rebuild that fails too fails the batch, which falls back.

**What it shows.** `land --dry-run` prints each batch it would form, its entries and the gate steps it would run once, without building anything (the rebase results are not known until the run). A live run prints `batch gated once` and, after the push, `landed N entries on main in one push`, and `status` shows `gated together with: <entries>` on each entry of a batch from the moment the candidate is built until the entry lands or the run ends (only while the run is alive; a dead run's marks are not shown and the next run clears them). The final summary lists the batches.

**What a batch trades away.** One gate verdict covers several entries, so a red candidate costs the batch's gate and then each entry's own gate (a failed batch is slower than not batching), and the intermediate merges are not gated alone. Batching pays where entries mostly pass, which is when the gate is slow and the entries have been reviewed already. An entry that fails is found by the fallback, never skipped.

## When origin's `main` moves during the gate

A gate takes minutes, and on a loaded machine most of an hour, and `main` on origin can move meanwhile through a push from outside the queue (a scheduled bot, a person). The push of `main` is then rejected as a non-fast-forward. Paying for the whole gate again would be the safe answer and a wasteful one, since a commit in one lane says nothing about the gate of another. On 2026-11-22 a 54-minute gate passed and was lost this way, to one bot commit that changed one data file outside every lane the gate covered. The rule:

- When the push is rejected, the run fetches. If `origin/<main>` is where the run left it, the push failed for another reason: the merge is rolled back and the run stops, as before.
- If it moved, local `main` goes back to `origin/<main>` and **the merge is redone on the new `main`, at most twice.** What merges is still the gated commit, and the binding checks (above) hold before each redo. Each new commit is read by its own changes (against each parent, for a merge), never by the net diff of the range, so a change a later commit reverts still counts.
- **Only the gates of the lanes the new commits touch run again.** The redone merge is checked out in the entry's worktree for the run (detached, then the worktree goes back on its branch), the touched lanes' setup probes and gates run on it in the entry's lane order, and then it is pushed. A commit that touches no lane the entry gated runs no gate. A path belongs to a lane by the lanes' own rules (`paths`, `shared` and the `"*"` lane): a path under `shared` touches every lane, a path under a lane's prefix touches that lane, and a path no named lane claims touches the `"*"` lane, so a lane that takes `"*"` is touched only by a path no other lane claims. A gated lane with a `reach` rule is also asked about the commit's paths, since a path outside the lane can be one its tests read. A path that matches no lane at all (a repo with no `"*"` lane) touches none.
- **Why that is enough.** Lanes are independent by the queue's own definition: each has its own paths, setup and gate, and a lane that code outside it can break says so with `shared` or `reach`, both of which are asked here. A gate that passed on a lane no new commit touches or reaches has nothing new to say about it, the same assumption the queue makes for every entry it lands, so re-running the lanes the commits touched gives the coverage a full re-run would. What it cannot see is a dependency no lane declares (a symlink created outside every lane that points into a gated lane, say), which the lanes' own path rules cannot see either.
- The entry stalls when origin's history was rewritten (it no longer descends from the commit the gate ran against), when `main` moved again after two redos, when the merge does not redo cleanly, when a gate that runs again fails or times out, or when the binding no longer holds. The stall reason is `main moved under a passing gate: <sha subject>, … — <why>`, the report lists each new commit with its files and the lanes it touches, local `main` is reset to `origin/<main>`, nothing of the entry reached `main`, and `resume` rebases the entry onto the new `main` and gates it again.
- A one-lane repo has one lane that takes every path, so any commit on `origin/<main>` during the gate runs that lane's gate again.

## The already-merged backlog

A branch that is **already contained in `main`**, merged by hand before the merge queue
existed with its worktree and its row still standing, is handled by handing it off and
landing it like anything else. The merge queue notices that the branch is an ancestor of
`main`, skips the rebase, the gate and the merge, and does the cleanup alone; that is the
right way to clear a row nobody wants to resolve by hand.

## Configuration

The config is a JSON registry of repos. `repos.example.json`, beside this file, is the
reference example; copy it and edit it rather than writing one from this description.

The merge queue resolves the config path as `$LOCAL_MERGE_QUEUE_CONFIG`, else
`$XDG_CONFIG_HOME/local-merge-queue/repos.json`, else `~/.config/local-merge-queue/repos.json`. It resolves
its state directory as `$LOCAL_MERGE_QUEUE_STATE`, else `$XDG_STATE_HOME/local-merge-queue`, else
`~/.local/state/local-merge-queue`. State means the queue, the locks and the stall reports, all of
which are per-machine and volatile, and none of which belongs in a repository.

Each repo entry names its primary checkout, its main branch where that is not `main`, its
fresh-worktree setup as a `setupWhen` probe plus a list of `setup` steps, its `gate` steps,
any `gateEnv` those steps and the final check need in their environment, its `finalCheck`,
its `protectedPaths`, its `githubRepo` slug, and, where its host builds every push to
`main`, its `deploy.skipMarker`. A repo that holds several deployables declares those per-lane keys inside `lanes` instead; see [Lanes](#lanes).

`githubRepo` is `owner/name`. Omit it and both pull request checks, the enqueue step
requirement and the post-landing verification, skip silently, which is what lets the test
suite run against a bare local repo and what lets you use the merge queue on a repo that has
no forge behind it at all.

## Lanes

Lanes let one repository hold two deployables, a site and an app say, under one merge queue. A lane is a named set of paths with its own setup, gate and final check. The queue works out which lanes each entry touches and records them on the entry.

A repo declares lanes in its config entry. `repos.example.json` has a worked monorepo with a `site` lane and an `app` lane.

```json
"monorepo": {
  "checkout": "monorepo",
  "shared": ["packages/"],
  "lanes": {
    "site": { "paths": ["site/"], "gate": ["npm run lint --workspace site"] },
    "app":  { "paths": ["app/"],  "gate": ["npm run typecheck --workspace app"] },
    "other": { "paths": "*" }
  }
}
```

- `paths` is an array of path prefixes, or the string `"*"` for the lane that takes every path no other lane claims. At most one lane may be `"*"`; a repo without one is valid, and then `enqueue` and `land` refuse an entry that changes an unclaimed path, naming the path.
- A lane may carry `setupWhen`, `setup`, `gate`, `gateEnv`, `gateModifies`, `finalCheck`, `protectedPaths` and `deploy`, with the meanings those keys have at repo level. The deploy marker is per lane; see [Lanes and the deploy marker](#lanes-and-the-deploy-marker).
- `shared` is a repo-level array of path prefixes that count as belonging to every lane.
- `checkout`, `mainBranch` and `githubRepo` stay at repo level.
- When a repo declares `lanes`, a repo-level `setupWhen`, `setup`, `gate`, `gateEnv`, `finalCheck`, `protectedPaths` or `deploy` is a config error. `loadConfig` names the key and exits, so there is one answer to which gate ran.

`enqueue` and `land` compute an entry's lanes from `git diff --name-only` between the merge base of the main branch and the branch, and from nothing else. A path under a lane's prefix belongs to that lane, a path under `shared` belongs to every lane, and any other path belongs to the `"*"` lane. An entry whose diff is empty, such as a cleanup-only entry, has no lanes. The lanes come back in config order, once each. `enqueue` stores them on the entry, and `land` computes them again after the rebase and stores that answer, since resolving a conflict can touch a file the first diff never saw.

For a repo with more than one lane, `status` prints the lanes after each branch name (`[site]`, `[app, site]`), and `land --dry-run` prints each entry's lanes and the gate steps of each lane. For a repo with one lane the brackets and the extra dry-run lines are left out.

### Setup, gate and final check, lane by lane

For each lane an entry touches, in config order, `land` runs that lane's `setupWhen` probe and `setup` steps (skipping the steps when the probe passes, with the same environment variables as a repo-level setup), then that lane's `gate` steps with that lane's `gateEnv`. An entry under `shared` therefore runs every lane's setup and gate. The first step that fails stalls the entry, and in a repo with more than one lane the stall reason and the report name the lane: `gate failed after rebase in lane app`, `worktree setup failed in lane site: npm ci`.

A lane's `finalCheck` runs once, at the end of the run, in the primary checkout, and only if an entry in that lane landed. An entry that stalls at its gate lands nothing, so its lane's final check does not run for it. `land` runs the final checks in config order.

The check that makes a rebase conflict the owner's call reads every lane's `protectedPaths`, whichever lanes the entry touches, because protected content is the owner's whatever lane it sits in.

### Reach: a lane that code outside it can break

Lanes are sorted by folder, and a folder does not say what a test imports. A test in the `app` lane may bundle a file from `site/`, so a branch that touches only `site/` can break `app` and never run its gate. A lane says so with `reach`:

```json
"app": {
  "paths": "*",
  "gate": ["npm run typecheck", "bash test/smoke.sh"],
  "reach": { "when": "bash test/lane-reach.sh", "gate": ["SMOKE_ONLY=pure bash test/smoke.sh"] }
}
```

- `when` is a command run in the branch's worktree, with the changed paths on stdin, one per line. Exit 0 means the change reaches this lane, exit 1 means it does not. Any other exit (a missing script, a crash) counts the lane as reached and says so in red, because a lane's tests are not skipped on a failure to ask.
- It is asked only of a lane the diff did not already hit, and never of an entry with an empty diff.
- A reached lane joins the entry's lanes at `enqueue` and again after the rebase at `land`, so the entry also holds that lane in a stall and runs that lane's setup. `status` marks it `app~`, and `land --dry-run` says so.
- The entry runs the lane's `reach.gate` for it, or the lane's `gate` when `reach` has none. An entry that changes the lane's own paths runs the full `gate`.
- A reached lane's `finalCheck` and `deploy` marker are not owed, since the entry changed nothing in it.

The rule for what a lane reaches belongs to the repo, not to this tool: the example above reads a list of files and uses the same decision function as the repo's change-based test selection.

### The known-red allow-list

A gate that runs a whole test sweep before the merge stalls an entry on any red suite, so a suite one session broke and is fixing stalls every session's entries. A repo can list such a suite for a few days:

```json
"knownRedRefuse": "test/data-safety.txt",
"knownRed": [
  { "suite": "test/sync-first-push-resume.test.mjs", "issue": "owner/repo#1700", "expires": "2026-11-25", "why": "one clause" }
]
```

- `issue` and `expires` are required. An entry past its date is `EXPIRED` and not honored, so the suite blocks again. An expiry more than 30 days out is `INVALID`, and at most 5 entries count.
- `knownRedRefuse` names a file in the primary checkout (one suite path per line, `#` comments) of suites the list may never name. An entry that names one is `REFUSED`; a list whose refuse file is missing refuses every entry.
- `land`, `land --dry-run`, `resume` and `status` print every entry with its state, and `land` prints it again after the gate output.
- The file is written once the landing lock is held, so a second `land` that is refused never touches the file the running holder's gates read.
- The honored entries are written to `<state>/known-red/<repo>.tsv` (suite, issue, expiry, tab-separated) and the file's path reaches every setup step, gate step and final check as `$LOCAL_MERGE_QUEUE_KNOWN_RED`; it is unset when nothing is honored. The repo's test runner decides what a listed suite's failure means: the queue only says what is allowed and for how long.

### A stall holds only its own lanes

In a repo with more than one lane, a stall does not end the landing run. `land` records the stall, writes the report, and goes on to the next entry it can land. An entry waits while any stalled entry of its repo shares a lane with it; an entry in other lanes lands as usual, and an entry with no lanes, such as a cleanup-only entry, never waits. Within a lane, nothing lands out of order.

- `land` refuses only when every lane of the repo is held by some stalled entry, with the same message a one-lane repo prints. While only some lanes are held, `land` says which lanes wait behind which stall and lands the rest.
- The report names the lanes that stalled and says that entries in other lanes keep landing. At the end of the run, `land` prints each stalled entry with its lanes, its reason and its report.
- A run that ends with any entry of the repo stalled exits 2. It settles the deploy marker of every lane no stalled entry holds, and leaves the held lanes for the next run; see [Lanes and the deploy marker](#lanes-and-the-deploy-marker).

`resume` retries every stalled entry of the repo in queue order, and lands the approved entries their lanes held behind them. A stalled entry whose rebase is still in progress, or whose conflict needs `--owner-approved` and did not get it, gets the same message a one-lane repo prints, stays stalled, and the run goes on with the others; the run then exits 1. Because the other lanes keep landing during a stall, `main` can move under an entry after its fixer resolved the rebase. `resume` then rebases that entry again onto the new `main`, and a conflict there stalls it again.

A repo with one lane keeps the behaviour it always had: its every entry, a cleanup-only one included, shares the one lane, so the first stall ends the run, and `resume` refuses an unready entry by exiting 1 at once. The lock stays one per repo whatever its lanes.

A repo with no `lanes` key behaves exactly as before. `loadConfig` gives it one implicit lane, named after the repo, with `paths: "*"` and the repo-level keys moved onto it, and everything after loading reads lanes only.

## Safety properties, and the one thing it will not protect you from

- One land per repo at a time, enforced by an atomic `mkdir` lock. A lock whose holder
  died is broken automatically, and the merge queue says so when it breaks one.
- Both locks (the repo's landing lock and the queue file's) are directories created whole: the directory and its `owner.json` (pid, a unique token, start time) are built beside the lock and renamed into place, so there is never a lock with no owner. A lock whose holder process is gone is debris and is broken, by one breaker at a time, which moves the lock aside only if it is exactly the lock it judged stale and otherwise puts it back. **A lock whose holder is alive is never broken, however long it has been held**: `status` shows `LOCKED by pid N since T (age)`, and a command that waits on it (30 seconds for the queue file) fails naming the pid and the age. A release removes the lock only if its token is still the releaser's own, so a process whose lock was broken never deletes its successor's. The queue file's lock is held for milliseconds around each read-modify-write; a lock with no owner file (left by an older version, or a holder killed mid-create) is debris after five seconds.
- The queue file is replaced by a rename of a flushed temporary file, and the copy it replaced is kept as `queue.json.prev`. A queue file that exists and cannot be parsed stops the command, names `queue.json.prev` and prints the exact `cp` that restores it; nothing is restored silently, because the copy is one write older than the file. Temporary files of a killed writer (`queue.json.tmp-<pid>`, `queue.lock.new-…`) older than an hour are removed by exact name pattern.
- **Interruption.** `SIGINT`, `SIGTERM` and `SIGHUP` stop the run's gate (each gate step runs in a process group of its own, which receives `SIGTERM`, then `SIGKILL` after five seconds), release the landing lock and the queue lock, clear the run's batch marks and exit 130, 143 or 129. `SIGKILL` runs nothing: it leaves a lock whose holder is dead (and possibly an orphaned gate); `status` reports a dead run's lock as such, never as `LOCKED`, and the next command that needs the lock breaks it. **A dead run's gate cannot overlap a second gate**: the landing lock's owner record holds the process group of the gate that is running, and a lock whose run is dead but whose gate group is alive stays held. A second `land` or `resume` is refused with the group named, `status` says so, and the lock is broken once the gate has ended. The message tells the operator to look at what the group is before ending anything (`ps -o pid,pgid,etime,command -g <group>`), since a process group id can be reused by an unrelated process once the gate's own group is gone; a gate is waited for or ended with `kill -TERM -- -<group>`, and a lock whose group is not a gate is released by hand, once the operator has confirmed that nothing of the repository is running, with the `rm -rf <state>/locks/<repo>` the message prints. Any other way out (a `die`, a failed push) releases the same things.
- It refuses to land a repo whose primary checkout is dirty or off `main`, naming what is
  dirty, so that another session's in-flight edit is never swept into a landing.
- **Local `main` equals `origin/main` before every entry starts.** The run fetches, fast-forwards a `main` that is behind, and stops, naming the commits, when `main` has commits `origin/main` does not (what a run killed between its merge and its push leaves behind). "Already in main" is asked of `origin/main`, so a merge that exists only in the primary checkout is never read as a landed branch and its entry is never cleaned up. Nothing is reset for you, since those commits may be somebody's own; the message prints the `reset --hard origin/main` that discards a killed run's leftovers. **The run records local `main` when that sync finishes and checks it again before the merge and before each redo** (see below): a pull, or a stray commit in the primary checkout, during the gate would otherwise move `main` under the rebase the gate ran on (and a stray commit would be pushed ungated), so the entry stalls with `local main moved during the gate`, and `resume` rebases and gates it again.
- A push failure rolls the local merge back rather than leaving `main` ahead of `origin`.
- `git branch -d` rather than `-D` does the deletion, so an unmerged branch survives.

It does not verify that the merged result is what anybody wanted. It verifies that the
result builds and that the named guards hold. Judgment about whether the work is right
stays with whoever was going to make that judgment anyway.

## Scaffolding never lands

**The merge queue deletes the branch's `BRANCH.md` itself**, as a commit on the rebased
branch, after the rebase and before the gate, so that the gate's claim to have run on
exactly what will land stays a fact rather than a sentence.

The rule it replaced said that a branch's `BRANCH.md` is deleted in the last commit before
the merge. Nothing enforced that, so a branch that forgot leaked its working notes into
`main`, and then the next branch to land, carrying scaffolding of its own, collided with it
and stalled the whole line over a file nothing shipped reads. One branch leaked a
`BRANCH.md` that the next one quietly cleaned up, and another leaked one that stalled a
third. Two hand-resolutions in a day, for a rule a machine can simply keep.

That whole failure mode is now designed out upstream, since branch documentation belongs in
the pull request body, and a PR body is not a tracked file, so it cannot leak into `main`,
collide with another branch's, or stall the line. The sweep stays anyway, because worktrees
cut before the switch still carry a `BRANCH.md` and because a branch agent may still write
one as a scratch file.

## Cleanup, and what happens when it fails

Landing a branch ends in three cleanup steps, removing the worktree and deleting the branch
locally and on the remote, plus a read-back of its pull request, and the merge queue does all
of them so that nobody has to remember to. **A step that fails says so in red and leaves a
residue line**, rather than reporting failure in the same dim grey as success at the end of
a landing run whose last two hundred lines are gate output. Three branches in a row landed on
2026-08-19 leaving their local ref behind, and it took a hand sweep to notice.

Three things guard the branch deletion. `git worktree prune` runs between the removal and
the deletion, because `git branch -d` refuses a branch git still believes is checked out
somewhere. The deletion retries once after fetching `main`, the other way `-d` refuses
being to read a branch as unmerged. **And where it still refuses, the merge queue asks the
question `-d` is asking and answers it directly.** Is the branch tip an ancestor of
`origin/main`? Where it is, the ref points at nothing that is not already landed, and `-D`
destroys nothing, which is the whole guarantee `-d` exists to provide, verified rather than
inferred from whatever made `-d` refuse. It is `-D` gated on a proof — and the proof is the
point.

**The remote branch goes only once its pull request reads MERGED** (2026-08-25). Deleting
the remote branch is what *closes* the PR, and GitHub decides merged versus abandoned
asynchronously from whether the head is reachable from the base. Publishing the rebased tip
and pushing `main` make that reachability true, and they do not make GitHub have noticed it
yet. Delete inside that window and the PR closes as **abandoned, permanently**, and there is no
API to flip it afterwards.

One branch landed that way on 2026-08-25. Its tip was published, its head genuinely
reachable from `main`, and its PR read CLOSED while the three entries either side of it
read MERGED, seconds apart. Since the roster *is* the record, a false entry in it is worse
than a branch left behind — one being a lie nobody can correct, the other a line of
cleanup. So the merge queue polls briefly, deletes only on MERGED, and otherwise keeps the
branch, says why in red, and prints the one command that finishes the job. It skips all of
that where a repo configures no `githubRepo`.

**A pull request stacked on the landing branch is moved onto `main` first** (2026-09-05).
Work arrives in chains — each branch cut from the one before it, each PR based on its
predecessor rather than on `main` — and GitHub closes a pull request the moment its *base*
branch is deleted. That close is permanent in both directions: `gh pr reopen` answers
"Could not open the pull request" and `gh pr edit --base` answers "Cannot change the base
branch of a closed pull request", so a live branch ends up recorded as abandoned in the one
list that is the record, and the only repair is opening a replacement PR by hand. That is
what happened to #91 when `templates-rename` landed underneath it. So between the merge and
the deletion the merge queue asks `gh pr list --base <branch> --state open` and retargets each
answer onto `main`, naming every one it moves. The placement is the point: after the merge
is pushed, so a retargeted PR's diff is the stack minus what just landed, and before the
branch goes, which is the act that would have closed it. **A retarget that fails never
stops a landing** — it is said in red, and the merge, the worktree removal and both branch
deletions carry on, a missed retarget being a defect in the roster rather than in the code.

**Cleanup destroys only what it can show is landed** (the independent re-check, 2026-11-21). The worktree is removed only if its HEAD is the landed commit and its status shows nothing that appeared after the gate ended: the run records the worktree's status, ignored files included, the moment the gate passes, and whatever the gate or the setup left (a temp folder, build output, ignored caches) is the gate's own and goes with the worktree. A file made after that point (an untracked one, an uncommitted edit, an ignored one) or a commit made after the merge keeps the worktree and the local branch: the run says `WORKTREE KEPT` in red with the files found and since when, prints the command that looks at the worktree and the one that finishes the job (`worktree remove --force`, then `branch -d`), leaves a residue line, and exits 3. `status` names every kept worktree, with the same two commands, until it is gone, though the entry itself has landed and left the queue. For an entry the run did not gate in its own worktree (a cleanup-only or batched entry) the baseline is the clean worktree it was when enqueued, and its ignored files (dependencies) are expected. Before any removal, the worktree's ignored files and folders are named in the output, since `git worktree remove --force` deletes them and no ordinary status line shows them. The remote branch is deleted only if its tip on origin is the landed tip, so a commit somebody pushed to it after the publish is not deleted with it (`REMOTE BRANCH KEPT`).

**Exit status.** 0: everything asked landed and cleaned up. 1: refused or failed (a die, a `resume` that found an entry unready). 2: an entry stalled. 3: the entries landed but a cleanup step left something behind (a kept worktree or remote branch, a branch that would not delete), said in red above.

**The merge is done either way.** Cleanup residue is untidiness rather than a reason to
stall the line, and the branch is on `main` and pushed before any of this runs.

**What was not established, recorded so that the next person does not assume it was.** The
2026-08-19 failure could not be reproduced. `git branch -d` took all three branches cleanly
minutes later, and `git worktree prune` in that repo removed nothing, so the stale-admin
cause the prune guards against was not the one that actually bit. The prune and the retry
are cheap guards against plausible causes, and **the change that earns its place is the
reporting**, which is what will make the next occurrence diagnosable instead of another
silent one.

**`local-merge-queue status` reports residue even when the queue is empty**, which is exactly when
nobody is looking. It looks for a local ref that is fully merged into `main`, has no
worktree, and belongs to no queue entry. It names those and never deletes them, because a
shelf branch is fully merged by construction, given that it preserves code removed from
`main`, so it looks identical from here and is the one branch that must never go. Branches
whose names carry `shelf` or `shelved` are excluded outright, and the report says to check
before deleting anything.

## Prior art, surveyed 2026-09-05

Whether something off the shelf should replace this was asked and answered once, at some
length. Here is the field, and where this tool sits in it.

Four of the merge queue's behaviours have no counterpart in anything surveyed. Protected paths
that hard-stop a rebase and refuse to resume without the owner's word, deploy coalescing so
that a landing run of N branches triggers one host build, the rule against rebasing a branch that
already merged `main`, and the enqueue-then-approve lifecycle with a reversible approval.
Whether you need any of those is the question worth asking, because if you do not, several
of the tools below are better maintained than this one.

Merge trains are not among them. GitLab's merge trains, GitHub's merge queue (which groups up
to a configured number of pull requests per check run) and bors batch several changes behind
one run of the checks, and [batched landing](#batched-landing) here is the same idea: build the
candidate `main` the changes would make one after another, run the gate on its tip once, land
them in order on green, and bisect by falling back on red. This tool falls back to one at a time
rather than bisecting, because a stall in a named entry's worktree, with a report for its author,
is the thing it exists to give. Where the others batch across everything the checks cover, this
one batches only entries that carry the same lanes.

The field splits three ways:

- **Hosted queues gate on CI check runs and require a GitHub App.** [Graphite](https://graphite.dev)
  ($20/user/month before the queue appears), [Aviator](https://www.aviator.co),
  [Mergify](https://mergify.com), [Kodiak](https://kodiakhq.com). Their gate is the forge
  reporting green checks, never arbitrary shell in the branch's own worktree. Mergify's
  free tier does cover a solo developer on private repos, at the cost of a hosted control
  plane and a webhook endpoint.
- **Local branch tools land one branch, with no queue and no gate.**
  [git-town](https://www.git-town.com)'s `ship` merges a completed branch and deletes it,
  and documents no test step. [worktrunk](https://github.com/max-sixty/worktrunk)'s
  `wt merge` squashes and rebases unconditionally.
- **The 2026 crop of agent merge queues assumes the agent lands its own work.** A dozen
  entrants, nearly all under six months old, under 150 stars, and single-repo. The most
  popular, [funador/claude-code-local-merge-queue](https://github.com/funador/claude-code-local-merge-queue),
  states its design directly. "No human reviews any of this before it lands. `checkCommand`
  passing is the only gate." That is the assumption approval exists to refuse, and if you
  do not share the objection, that tool is a smaller thing to adopt than this one.

Two specific findings worth keeping:

- **[yongjip/mergetrain](https://github.com/yongjip/mergetrain)** is the nearest thing in
  architecture, a local-first merge train for coding-agent worktrees, MIT, thoroughly
  documented. It deliberately gives up the pull request, in its own words removing the
  ceremony at the price of the forge's review surface. Its offered accommodation is one PR
  for a whole train, which would collapse a chain of branches into a single
  undifferentiated diff and leave the per-branch owner decisions nowhere to live, so it
  suits a workflow where nobody reads the branches individually. It has no protected-path
  concept and no worktree bootstrap, its `enqueue` refusing an unclean worktree rather than
  setting it up, and its multi-repo support is read-only. It does have crash recovery
  through write-ahead markers and gate-result caching, neither of which this tool has, and
  those are the two ideas worth taking.
- **[max-sixty/worktrunk](https://github.com/max-sixty/worktrunk)** (6.8k stars,
  MIT/Apache-2.0, active) is the most mature tool in the survey and is not a queue. It
  solves worktree *creation*, meaning path derivation, post-start setup hooks and
  build-cache sharing. That is the same seam `setup` and `setupWhen` cover from the landing
  end, and the two compose well. Its `wt merge` is the part that overlaps, and it is not
  what this tool does.

Also checked and set aside for reasons that may not be yours. bors-ng (archived 2024),
uber/submitqueue (speculative, so it evicts where this stalls), detent (delegates to
GitHub's native queue where one exists, and arrives welded to a Projects board that
dispatches its own agents), jjq (Jujutsu rather than git), agcoord (Linux only), DeployBot
(no worktree model), and a cluster of GitHub Actions implementations, which are not local
by definition.

## Verification

`test-local-merge-queue.sh`, kept with this tool, builds a throwaway repo with a bare origin and
worktrees, and exercises the whole of it end to end. Enqueue guards, approval gating,
dry-run purity, a clean two-branch land with full cleanup, a conflict stall with the
follower held back, resume, the protected-path escalation, a failing gate, the
dirty-checkout refusal, the already-merged cleanup path, the scaffolding strip, the
proven-contained force-delete, the residue report, the pre-merge publish that lets a pull
request close as merged, a branch that folded two sub-branches and caught up to `main`
landing as it was tested rather than being reflattened, and the fresh-worktree setup in all
three of its states, run when the probe fails, skipped entirely when it passes, and
stalling on its own terms with a report that does not invent a rebase. Then the
one-deploy-per-land marker across every path it has, meaning a repo with no `deploy` key
behaving byte-identically, a three-branch land marking all but the last, a single-entry
land marking nothing, a stall on the final entry leaving `main` undeployed until `resume`
lands it, the trailing entry dequeued *during* the gate ahead of it, and the trailing entry
dequeued after a stall, where the next landing run republishes the tip with an empty commit
carrying no marker. Then the stacked-PR retarget, against a `gh` stubbed on `PATH` so that
nothing here reaches GitHub: the PR moved onto `main` by a real `gh pr edit --base` argv,
that call landing *before* the branch deletion rather than after it, and a `gh` that refuses
the query leaving the branch landed and the worktree cleaned up regardless. Then lanes, on a second fixture repo with two lanes and a `shared` prefix: an entry in one lane, in both, in all of them through `shared`, in the `"*"` lane through an unclaimed path, and with none when it is cleanup-only; `status` and `--dry-run` showing them; `land` computing them again after the rebase; the gate of each touched lane running and no other; and the config errors, a repo-level gate key beside `lanes`, two `"*"` lanes, and an unclaimed path in a repo with no `"*"` lane. Then stalls on a third fixture repo with lanes `a` and `b`: an `a`-lane entry stalling on a rebase conflict while the `b`-lane entries queued behind it land in the same run and exit 2; the `a`-lane, both-lane and `shared` entries behind it held, and a cleanup-only entry landing past it; each lane's setup and final check running only for a lane that landed; a gate failure naming its lane; `land` refusing once every lane is held; `resume` reporting an entry still mid-rebase, leaving it stalled and landing the fixed stall in the other lane; and, once the fixer resolves, `resume` rebasing the entry again onto the `main` that moved under it and landing the held entries in queue order, with both gates of a two-lane or `shared` entry running in config order. Then the deploy marker lane by lane, on a fourth fixture repo where lane `a` carries `deploy` and lane `b` does not: three entries in the order `a1`, `b1`, `a2` landing as marked, unmarked, unmarked, with `--dry-run` naming the lane; a run of `b` entries alone writing no marker and no republish; an `a` entry stalling behind a marked `a` merge while a `b` merge lands over it, `status` reporting the undeployed lane, and the next `land` after the dequeue republishing with one empty commit that carries no marker; a second `land` and a later `b` merge adding no further republish; a marker shared by two lanes written once; and an entry in two lanes with their own markers carrying both, with one empty commit settling both lanes. Then `--no-rebase` on the first fixture repo: the flag recorded and shown by `status` and `--dry-run`; a branch that merged current `main` landing with its own merge commit and the `--no-ff` landing merge; `main` moving under a second branch stalling the run with the reason, no rebase started and the branch unmoved, and a report that says to merge; `resume` stalling it again until the fixer runs `git merge origin/main`, then landing it. Then lane reach on a fifth fixture (a site file a test of the app bundles putting the app lane in the entry as reached, `status` marking it, the reach gate and not the full gate running for it, a reach command that cannot answer counting the lane as reached, a reach with no `when` refused) and the known-red allow-list on a sixth (the print, the file handed to the gate steps, and the expired, refused, invalid, missing-refuse-file and over-limit states). Then the queue file, on a seventh fixture with a gate the test holds open: an entry enqueued, approved and reordered from a second process while a run is gated is still there with its state and position when the run stalls, and when it lands (where the entry approved behind it is picked up and the output says so); an entry unapproved or dequeued while the run is on it is not landed and not revived; six enqueues and six approvals racing leave all six; a previous copy of the queue is kept, an unreadable queue file stops the command naming that copy and the `cp` that restores it, and stale temporary files go by exact name. Then the locks: a planted dead-holder lock with 16 concurrent approvals, 100 trials, loses no write and leaves no lock; a release does not delete a lock another process took over (the queue's and the repo's); a live holder's lock is never broken however old, and the message names its pid and age; a dead landing lock is not shown as `LOCKED` and the next land breaks it; `dequeue` and `order` resolve a name without the queue lock. Then batched landing on the same fixture: off by default, `--no-batch` over the config, `--batch` where the config has no key, both flags refused, a `max` below 2 refused, git below 2.38 refused; a green batch of three landing three merge commits in order with one gate run and one push of `main`, and a `--dry-run` that shows it and runs nothing; a pair of entries that is red alone and green together landing as a batch with only gated states ever reaching origin; a batch whose second entry fails the gate falling back, landing the first, stalling the second and leaving the third approved, with nothing of it pushed first; a rejected push of `main` falling back with nothing landed, and every push rejected leaving no lock, no batch mark and the entries approved; a branch pushed to during the gate, and a gate that moves the batch worktree, each failing the batch; a conflict between two entries, and in a protected path; `max`, a non-approved entry, a `--no-rebase` entry and a branch carrying merge commits each ending a batch; an entry unapproved while the batch is gated failing it; lanes worked out as `land` works them out (a `BRANCH.md` counts); the deploy marker on a batch; and, on a lanes config, entries in different lanes batching only with their own kind. Then interruption: `SIGTERM` and `SIGHUP` end the run with exit 143 and 129, the gate's process group, the locks and the batch marks gone; after `SIGKILL` the lock is left, `status` says its holder died, and the next land breaks it. Then the batch worktree: stale untracked files removed, the kept dependency directory surviving, a changed lockfile removing it and setting up again, a rebase or a merge left in progress aborted, and a stale `index.lock` or a missing `.git` rebuilding the worktree with a message. Then the fixes after the independent re-check, each in a repository of its own with a test that fails without the change: a commit or a tracked-file edit made in a worktree during the gate stalling the entry, and what merges being the gated commit; a run killed (`SIGKILL`) between its merge and its push no longer letting the next run clean up the entry, and a `main` that moved while an entry was stalled being seen by `resume`; a gate orphaned by a killed run blocking a second gate until it ends; a stall on a branch named `feat/x`; a gate timeout (a gate that ignores `SIGTERM`, a lane's override, a hung setup step, a hung final check); the known-red file untouched by a refused second `land` and the final check running under the lock; cleanup keeping a worktree with files made after the gate and a remote branch that gained a commit after the publish; the four batching guards (worktree clean, remote branch unchanged, `main` unmoved, each tip published), approval re-read before the push of `main`, no `reset --hard` in an entry's worktree, the failed-batch message, and each of the two lock-release guards pinned by its own test; and origin's `main` moving under a passing gate (redone without a new gate when only paths outside every gated lane changed, stalled when a gated lane's path or a `reach` rule is touched, when history was rewritten, or after two redos). 473 assertions.
Run it before changing anything.

```sh
bash test-local-merge-queue.sh
```

## Status and support

This is a personal tool, published because it may be useful to somebody else. It runs
daily against real repositories and the behaviour described here is the behaviour it has.
Issues and pull requests are welcome. No support, no roadmap, and no backwards
compatibility are promised, and the version you clone is the contract you get.

## License

MIT. See [LICENSE](LICENSE).
