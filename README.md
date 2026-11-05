# local-merge-queue

A local merge queue for git, for the case where several branches are in flight at once
against a `main` that moves under them. Coding agents finish a branch and hand it to the
queue instead of merging it. The owner admits the entries that should land. Then
`local-merge-queue drain <repo>` lands each admitted branch one at a time, putting it on top of the
`main` it will actually live on, running a gate you configure, merging `--no-ff`, pushing,
and removing the worktree and deleting the branch both locally and on the remote.

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

Then work a branch in its own worktree, as usual, and hand it over from inside that
worktree when it is finished:

```sh
cd ~/code/myapp-somefeature
git push -u origin somefeature
local-merge-queue handoff --note "what this is, in one clause"
```

Nothing has merged. The entry sits `held`. Look at the queue, admit what should land, and
drain:

```sh
local-merge-queue status
local-merge-queue admit somefeature
local-merge-queue drain myapp --dry-run    # the order it would land in, nothing touched
local-merge-queue drain myapp
```

## The lifecycle

```
 branch agent                   the owner                     the merge queue
 ────────────                   ─────────                     ───────────
 finish + verify
 push
 local-merge-queue handoff ──►  held
                                local-merge-queue admit  ──►  admitted
                                local-merge-queue unadmit ◄─  (back to held, any
                                                              time before the drain)
                                                              local-merge-queue drain
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

**Handing off is not merging.** An entry sits `held` until the owner admits it, so a
standing rule that branches land only on the owner's word survives intact. Admission is
that word. Hand off freely the moment a branch is genuinely ready.

**Admission is reversible right up to the drain.** `local-merge-queue unadmit` puts an admitted
entry back to `held`, for a change of mind or one more look before it lands, and it is
the command to reach for rather than `drop`, which takes the entry out of the queue
altogether and loses the order the branches were meant to land in. Once a branch is
actually landing, unadmit stops applying. A stalled entry is refused, and `resume` or
`drop` govern that one instead.

## What a branch agent does

Finish the work, verify it, commit, push. Then, **from inside the branch's worktree**,
hand it over:

```sh
local-merge-queue handoff --note "what this is, in one clause"
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
local-merge-queue handoff --after otherrepo:some-prerequisite
```

Then report and stop. Do not merge, do not clean up, do not touch `main`.

## What a branch agent must not do

The merge queue owns all of this, and doing any of it by hand races the queue and leaves the
pull request list disagreeing with git.

- `git merge` into any `main`
- `git worktree remove` for a landed branch
- `git branch -d` or `git push origin --delete` for a landed branch
- closing a landed branch's pull request by hand, since the merge closes it as **merged**
- rebasing a handed-off branch onto `main` to keep it fresh
- `local-merge-queue drain` on the strength of approval language alone. "Approved for the merge queue"
  and "admit these" authorize `admit` and nothing more, and the drain runs on its own
  explicit word.
- `local-merge-queue drop`, `local-merge-queue order`, `local-merge-queue unadmit` or `local-merge-queue resume` on an entry
  somebody else handed off, which the next section covers

Creating a branch, its worktree and its pull request is unchanged and still the branch
agent's, and the PR is now load-bearing, since `handoff` refuses a branch that has none.

## The queue is shared, and other agents' entries are the point

**Several agents hand off to one queue at the same time.** That is what a queue is for. A
queue holding only your own branch is the unusual case, and one holding three branches
from three sessions you know nothing about is the ordinary one.

So an entry you did not create is not a stray, not a leak, not a fault, and not evidence
that something went wrong, and it needs no investigation and no warning in your hand-off.
Do not drop it, reorder it, unadmit it, resume it, or tidy it. `drop`, `order`, `unadmit`
and `resume` belong to whoever handed the branch off; using them on someone else's
entry is the same class of mistake as merging by hand, with the extra cost that dropping
or unadmitting a branch somebody had already approved takes that approval back silently.

**The one thing a shared queue does change is the check before a drain.** Admission is a
word given about the entries the owner was looking at, and it is not a standing
certificate for whatever has been admitted since. So when the word to drain arrives, read
the queue back first:

```sh
local-merge-queue status                        # what is actually queued, and in what state
local-merge-queue drain <repo> --dry-run        # the order it would land in, nothing touched
```

Confirm the admitted set is the set that was meant, and drain then. If something is
admitted that nobody mentioned, name it in one line and ask. The two failure modes are
landing it silently and treating its presence as an alarm.

## What the owner does

```sh
local-merge-queue status                        # the whole queue, with each entry's delta
local-merge-queue admit <branch> [<branch>…]    # the word
local-merge-queue admit --all --repo mysite
local-merge-queue unadmit <branch> [<branch>…]  # take the word back; the entry keeps its place
local-merge-queue unadmit --all --repo myapp
local-merge-queue order <branch> --first        # land refactors early (see below)
local-merge-queue drain myapp                   # land everything admitted
local-merge-queue drain myapp --dry-run
local-merge-queue drop <branch>                 # take it back out; the branch is untouched
```

**A branch name belongs to its repo.** Two repos can each queue a branch with the same name. `order`, `drop`, `admit` and `unadmit` take `--repo <repo>`, or use the repo of the worktree they run in; given a name two repos share and neither, they refuse and ask for `--repo` rather than guess, because a guess can move, admit or drop another session's entry.

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

## When it stalls

**It stalls; it does not evict.** On a rebase conflict or a gate failure the merge queue
stops where it stands, leaves the rebase in progress in that worktree, writes a report to
`<state>/reports/<repo>-<branch>.md`, and exits 2. Nothing behind it lands out of order — which is
deliberate. Branches that are in flight together usually overlap, so landing one of them
out of order relocates a conflict rather than avoiding it.

A fixer resolves it in place, in the named worktree:

```sh
cd <the worktree named in the report>
# resolve the conflict
git add -A && git rebase --continue
local-merge-queue resume <repo>
```

The line then continues from that entry. Two things about that are worth saying out loud.

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

**A drain never stalls because a worktree lacks its generated environment.** Before the
gate runs, the merge queue asks the repo's `setupWhen` probe whether this worktree is a
working checkout, and where the answer is no it runs the repo's `setup` itself, meaning
`npm install`, the env files, the native rebuild, whatever that repo's fresh-worktree
steps happen to be.

It exists because the seam it heals is structural rather than careless. A branch whose own
work needed no build — a doc-adjacent fix, a test edit — is verified without one, so its
worktree never acquires an environment at all, and the first thing anybody notices is the
merge queue's gate dying minutes into a drain over something that is not the branch's fault.
Three branches went that way on 2026-08-24, twice as `esbuild ENOENT` out of an empty
`node_modules`, each costing a person a diagnose-install-resume cycle for a queue whose
whole point is not needing one.

- **After the rebase, before the gate.** `npm install` then installs what the branch's own
  manifest asks for, on top of the `main` it will land on, and a branch that stalls at the
  rebase pays for no install at all.
- **The probe is what keeps it free.** A drain of an already-working worktree runs one
  `test`, moves on, installs nothing, copies nothing, and prints nothing about setup.
  Configure `setup` without a `setupWhen` and every landing pays the full cost, which is
  why each probe should cover every step of its own `setup`, so that a half-set-up
  worktree is completed rather than passed over.
- **`$LOCAL_MERGE_QUEUE_CHECKOUT` names the primary checkout** inside setup steps, since most of
  what a worktree lacks is a copy of something the primary checkout already has, such as a
  prebuilt binary or a gitignored env file.

None of this relieves a branch agent of setting up its own worktree, since an agent that
builds or runs anything still needs one that works. It relieves the handoff seam, which is
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

## One deploy per drain rather than one per branch

**A repo whose host builds every push to `main` gets one build per drain run.** You
configure that per repo, and the merge queue stays silent about it everywhere you have not.

```json
"deploy": { "skipMarker": "[skip-deploy]" }
```

The site this was built for deploys production from `main` through Vercel's git
integration, so the push that lands each branch *is* a production build. Draining N
branches shipped N of them, and every one but the last shipped a state that existed for as
long as the next gate took. The owner's ask, 2026-08-29, was that the site should simply
redeploy at the end of the draining.

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
  takes minutes and an entry can be dropped inside them, which makes the entry being landed
  the last one after all. Re-reading is what lets that drop land correctly.
- **A stall does not deploy.** The line is expected to continue, and shipping the
  half-drained state mid-stall is the thing this exists to prevent. The `resume` that lands
  the last entry is what deploys.
- **The end of a run settles from the state rather than from memory.** The lookahead can
  still be wrong in two ways, since the entry behind this one may stall and then be
  dropped, or may turn out to be cleanup-only and push nothing, and both leave `main` on a
  merge the host was told to ignore, with an empty queue and a healthy-looking log. So
  every run that does not stall ends by asking whether the tip of `main` carries the
  marker, and publishes it with an empty commit where it does. On the ordinary path the tip
  is unmarked and this does nothing at all. `local-merge-queue status` reports the same state, for
  the stretch between the drop and the next drain.

The one thing that must never appear in that empty commit's message is the marker itself.
Naming the thing being fixed is the natural sentence to write, and it would make the commit
that exists to trigger a build the next one skipped, silently and permanently. There is an
assertion against it in the code and another in the suite.

**Verified in production on 2026-09-01**, on the first real drain of a site configured this
way, three branches deep. Vercel canceled the two marked intermediate merges' builds and
ran exactly one production build, on the final unmarked commit, 60s, Ready. What had not
been verifiable locally, that Vercel actually skips on the marker, has its live
confirmation.

## The gate, and the final check

Each entry's **gate** runs in its own worktree, after the rebase and before the merge, on
exactly the content that will land. Make it cheap and make it narrow. The right question
is what would reach a user as a broken payment, a broken sign-in, or a missing feature —
and minutes added to a gate are paid on every single landing.

The **final check** runs once, in the primary checkout, after the whole batch has landed.
It reports rather than gates, because each entry already passed the gate on its own
content. A failure there is a new task rather than a rollback, since `main` is already
pushed by design, so that a stall never leaves landed work sitting unbacked-up on the
machine.

## The already-merged backlog

A branch that is **already contained in `main`**, merged by hand before the merge queue
existed with its worktree and its row still standing, is handled by handing it off and
draining it like anything else. The merge queue notices that the branch is an ancestor of
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
`main`, its `deploy.skipMarker`.

`githubRepo` is `owner/name`. Omit it and both pull request checks, the handoff
requirement and the post-landing verification, skip silently, which is what lets the test
suite run against a bare local repo and what lets you use the merge queue on a repo that has
no forge behind it at all.

## Safety properties, and the one thing it will not protect you from

- One drain per repo at a time, enforced by an atomic `mkdir` lock. A lock whose holder
  died is broken automatically, and the merge queue says so when it breaks one.
- It refuses to drain a repo whose primary checkout is dirty or off `main`, naming what is
  dirty, so that another session's in-flight edit is never swept into a landing.
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
a drain whose last two hundred lines are gate output. Three branches in a row landed on
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
that a drain of N branches triggers one host build, the rule against rebasing a branch that
already merged `main`, and the held-until-admitted lifecycle with a reversible admission.
Whether you need any of those is the question worth asking, because if you do not, several
of the tools below are better maintained than this one.

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
  passing is the only gate." That is the assumption admission exists to refuse, and if you
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
worktrees, and exercises the whole of it end to end. Handoff guards, admission gating,
dry-run purity, a clean two-branch drain with full cleanup, a conflict stall with the
follower held back, resume, the protected-path escalation, a failing gate, the
dirty-checkout refusal, the already-merged cleanup path, the scaffolding strip, the
proven-contained force-delete, the residue report, the pre-merge publish that lets a pull
request close as merged, a branch that folded two sub-branches and caught up to `main`
landing as it was tested rather than being reflattened, and the fresh-worktree setup in all
three of its states, run when the probe fails, skipped entirely when it passes, and
stalling on its own terms with a report that does not invent a rebase. Then the
one-deploy-per-drain marker across every path it has, meaning a repo with no `deploy` key
behaving byte-identically, a three-branch drain marking all but the last, a single-entry
drain marking nothing, a stall on the final entry leaving `main` undeployed until `resume`
lands it, the trailing entry dropped *during* the gate ahead of it, and the trailing entry
dropped after a stall, where the next drain republishes the tip with an empty commit
carrying no marker. Then the stacked-PR retarget, against a `gh` stubbed on `PATH` so that
nothing here reaches GitHub: the PR moved onto `main` by a real `gh pr edit --base` argv,
that call landing *before* the branch deletion rather than after it, and a `gh` that refuses
the query leaving the branch landed and the worktree cleaned up regardless. 133 assertions.
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
