#!/bin/bash
# End-to-end exercise of the merge queue against a throwaway repo.
# Nothing here touches a real repo.
set -u

ROOT="$(mktemp -d /tmp/local-merge-queue-test.XXXXXX)"
export LOCAL_MERGE_QUEUE_STATE="$ROOT/state"
export LOCAL_MERGE_QUEUE_CONFIG="$ROOT/repos.json"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_MERGE_QUEUE="node $HERE/local-merge-queue.mjs"
PASS=0; FAIL=0
ok ()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
bad ()  { FAIL=$((FAIL+1)); echo "  FAIL — $1"; }
check () { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "sandbox: $ROOT"

# ── build a throwaway repo: bare origin + primary checkout + two worktrees ────
git init -q --bare "$ROOT/origin.git"
git init -q -b main "$ROOT/repo"
cd "$ROOT/repo"
git config user.email t@t.t; git config user.name T
git remote add origin "$ROOT/origin.git"
printf 'line one\nline two\nline three\n' > shared.txt
echo "base" > base.txt
mkdir -p harness && echo "prose" > harness/voice.md
git add -A && git commit -qm "base" && git push -qu origin main

mk_branch () {  # name, file, content
  git -C "$ROOT/repo" worktree add -q "$ROOT/repo-$1" -b "$1" >/dev/null 2>&1
  cd "$ROOT/repo-$1"
  printf '%s' "$3" > "$2"
  git add -A && git commit -qm "$1: touch $2" && git push -qu origin "$1" 2>/dev/null
  cd "$ROOT/repo"
}

mk_branch alpha  alpha.txt  "alpha"
mk_branch beta   beta.txt   "beta"

cat > "$ROOT/repos.json" <<JSON
{ "repos": { "t": {
  "checkout": "$ROOT/repo",
  "mainBranch": "main",
  "gate": ["test -f base.txt"],
  "finalCheck": "true",
  "protectedPaths": ["harness/"]
} } }
JSON

echo
echo "── 1. enqueue guards ─────────────────────────────────────────────"
cd "$ROOT/repo-alpha"
echo dirty > untracked-dirt.txt
out=$($LOCAL_MERGE_QUEUE enqueue 2>&1); check "refuses a dirty worktree" '[[ "$out" == *dirty* ]]'
rm untracked-dirt.txt
echo more >> alpha.txt && git add -A && git commit -qm "unpushed"
out=$($LOCAL_MERGE_QUEUE enqueue 2>&1); check "refuses unpushed commits" '[[ "$out" == *unpushed* ]]'
git push -q origin alpha
out=$($LOCAL_MERGE_QUEUE enqueue --note "the alpha branch" 2>&1)
check "accepts a clean pushed branch" '[[ "$out" == *"enqueued"* ]]'
cd "$ROOT/repo-beta" && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1

echo
echo "── 2. nothing merges without approval ───────────────────────────"
before=$(git -C "$ROOT/repo" rev-parse main)
out=$($LOCAL_MERGE_QUEUE land t 2>&1)
after=$(git -C "$ROOT/repo" rev-parse main)
check "land with nothing approved is a no-op" '[[ "$before" == "$after" && "$out" == *"nothing approved"* ]]'

echo
echo "── 3. dry run does not mutate the queue ──────────────────────────"
$LOCAL_MERGE_QUEUE approve --all >/dev/null 2>&1
q1=$(cat "$LOCAL_MERGE_QUEUE_STATE/queue.json")
$LOCAL_MERGE_QUEUE land t --dry-run >/dev/null 2>&1
q2=$(cat "$LOCAL_MERGE_QUEUE_STATE/queue.json")
main_now=$(git -C "$ROOT/repo" rev-parse main)
check "dry run leaves the queue byte-identical" '[[ "$q1" == "$q2" ]]'
check "dry run leaves main where it was" '[[ "$main_now" == "$before" ]]'

echo
echo "── 3b. unapprove puts an entry back without moving it ──────────────"
# Approval is reversible right up to the landing run, and the entry must keep its
# place: unapprove is the alternative to `dequeue`, which would take it out of the
# queue entirely and lose the order the branches were meant to land in.
order_before=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.env.LOCAL_MERGE_QUEUE_STATE+"/queue.json")).entries.map(e=>e.branch).join(","))')
$LOCAL_MERGE_QUEUE unapprove alpha >/dev/null 2>&1
st=$(node -e 'const q=JSON.parse(require("fs").readFileSync(process.env.LOCAL_MERGE_QUEUE_STATE+"/queue.json"));const e=q.entries.find(x=>x.branch=="alpha");console.log(e.status+"|"+("approved" in e))')
order_after=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.env.LOCAL_MERGE_QUEUE_STATE+"/queue.json")).entries.map(e=>e.branch).join(","))')
check "unapprove returns the entry to enqueued"        '[[ "$st" == "enqueued|false" ]]'
check "unapprove keeps its place in the queue"     '[[ "$order_before" == "$order_after" ]]'
out=$($LOCAL_MERGE_QUEUE unapprove alpha 2>&1)
check "unapproving an enqueued entry changes nothing" '[[ "$out" == *"nothing to unapprove"* ]]'
out=$($LOCAL_MERGE_QUEUE unapprove 2>&1)
check "unapprove refuses to guess a branch"        '[[ "$out" == *"name the branches"* ]]'
# beta is still approved from section 3, so clear the whole repo before asking
# whether an unapproved queue lands anything.
$LOCAL_MERGE_QUEUE unapprove --all --repo t >/dev/null 2>&1
before2=$(git -C "$ROOT/repo" rev-parse main)
out=$($LOCAL_MERGE_QUEUE land t 2>&1)
check "an unapproved branch does not land"       '[[ "$(git -C "$ROOT/repo" rev-parse main)" == "$before2" && "$out" == *"nothing approved"* ]]'
$LOCAL_MERGE_QUEUE approve --all >/dev/null 2>&1

echo
echo "── 4. a clean land lands both, and cleans up ────────────────────"
out=$($LOCAL_MERGE_QUEUE land t 2>&1)
cd "$ROOT/repo"
check "main gained two merge commits"      '[[ $(git rev-list --count --merges main) == 2 ]]'
check "alpha.txt landed"                   '[[ -f "$ROOT/repo/alpha.txt" ]]'
check "beta.txt landed"                    '[[ -f "$ROOT/repo/beta.txt" ]]'
check "origin/main matches local main"     '[[ $(git rev-parse main) == $(git rev-parse origin/main) ]]'
check "alpha worktree removed"             '[[ ! -d "$ROOT/repo-alpha" ]]'
check "beta worktree removed"              '[[ ! -d "$ROOT/repo-beta" ]]'
check "local alpha branch deleted"         '! git rev-parse --verify -q refs/heads/alpha >/dev/null'
check "remote alpha branch deleted"        '! git -C "$ROOT/origin.git" rev-parse --verify -q refs/heads/alpha >/dev/null'
# THE PULL REQUEST IS THE ROSTER (2026-08-19), and it retires itself only if the
# landing tip reaches origin BEFORE the merge. A rebase rewrites every SHA, so
# without that push the commits that land are ones origin/<branch> never held,
# GitHub cannot see the PR head as reachable from main, and the cleanup's
# `push origin --delete` closes a cleanly-landed branch as ABANDONED.
# Matched on "tip published" rather than "rebased tip published": a branch
# already on top of origin/main is NOT rebased (see local-merge-queue.mjs step 2), and the
# publish matters just as much for it — the assertion is about the ORDER, and
# must not quietly stop testing anything the day a branch arrives current.
check "the landing tip is published pre-merge" '[[ "$out" == *"tip published"* ]]'
check "publishing precedes the merge"          '[[ "${out%%landed on main*}" == *"tip published"* ]]'
# This sandbox has no githubRepo configured, which is the documented escape
# hatch: both PR checks skip rather than failing a landing.
check "no githubRepo ⇒ the PR check is skipped" '[[ "$out" == *"no github repo configured"* ]]'
check "queue is empty again"               '[[ $(node -e "console.log(JSON.parse(require(\"fs\").readFileSync(\"$LOCAL_MERGE_QUEUE_STATE/queue.json\")).entries.length)") == 0 ]]'

echo
echo "── 5. conflict stalls, and does not land anything behind it ──────"
mk_branch conflictor shared.txt $'line one\nCONFLICTING\nline three\n'
mk_branch follower   follower.txt "follower"
# main moves underneath conflictor, touching the same line
cd "$ROOT/repo"
printf 'line one\nMAIN MOVED\nline three\n' > shared.txt
git commit -qam "main touches shared.txt" && git push -q origin main
cd "$ROOT/repo-conflictor" && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1
cd "$ROOT/repo-follower"   && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1
$LOCAL_MERGE_QUEUE approve --all >/dev/null 2>&1
main_before=$(git -C "$ROOT/repo" rev-parse main)
$LOCAL_MERGE_QUEUE land t >/dev/null 2>&1; rc=$?
main_after=$(git -C "$ROOT/repo" rev-parse main)
check "land exits 2 on a stall"           '[[ $rc == 2 ]]'
check "main did not move"                  '[[ "$main_before" == "$main_after" ]]'
check "follower did NOT land out of order" '[[ ! -f "$ROOT/repo/follower.txt" ]]'
check "a stall report was written"         '[[ -f "$LOCAL_MERGE_QUEUE_STATE/reports/t-conflictor.md" ]]'
# The report's instructions are chosen by asking git whether a rebase is actually
# sitting there (2026-08-24). This is the yes case, and it must keep saying so:
# a conflict stall is the ONE kind where resolve-and-continue is the right advice.
check "…telling the fixer to finish the rebase" 'grep -q "git rebase --continue" "$LOCAL_MERGE_QUEUE_STATE/reports/t-conflictor.md"'
check "the rebase is left in progress"     '[[ -d "$ROOT/repo/.git/worktrees/repo-conflictor/rebase-merge" || -d "$ROOT/repo/.git/worktrees/repo-conflictor/rebase-apply" ]]'
out=$($LOCAL_MERGE_QUEUE land t 2>&1)
check "a second land refuses while stalled" '[[ "$out" == *stalled* ]]'

echo
echo "── 6. resume after the fixer resolves ────────────────────────────"
cd "$ROOT/repo-conflictor"
printf 'line one\nRESOLVED\nline three\n' > shared.txt
git add -A && GIT_EDITOR=true git rebase --continue >/dev/null 2>&1
$LOCAL_MERGE_QUEUE resume t >/dev/null 2>&1
cd "$ROOT/repo"
check "conflictor landed after resume"     'grep -q RESOLVED "$ROOT/repo/shared.txt"'
check "follower landed behind it, in order" '[[ -f "$ROOT/repo/follower.txt" ]]'
check "queue empty after resume"           '[[ $(node -e "console.log(JSON.parse(require(\"fs\").readFileSync(\"$LOCAL_MERGE_QUEUE_STATE/queue.json\")).entries.length)") == 0 ]]'

echo
echo "── 7. a protected path escalates to the owner ────────────────────"
mk_branch prosefix harness/voice.md "branch prose"
cd "$ROOT/repo"
echo "main prose" > harness/voice.md && git commit -qam "main touches harness" && git push -q origin main
cd "$ROOT/repo-prosefix" && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1
$LOCAL_MERGE_QUEUE approve --all >/dev/null 2>&1
out=$($LOCAL_MERGE_QUEUE land t 2>&1)
check "protected conflict is flagged as owner's call" '[[ "$out" == *"A conflicted path is protected"* ]]'
check "report says OWNER DECISION REQUIRED" 'grep -q "OWNER DECISION REQUIRED" "$LOCAL_MERGE_QUEUE_STATE/reports/t-prosefix.md"'
cd "$ROOT/repo-prosefix"
echo "resolved prose" > harness/voice.md
git add -A && GIT_EDITOR=true git rebase --continue >/dev/null 2>&1
out=$($LOCAL_MERGE_QUEUE resume t 2>&1)
check "resume refuses without --owner-approved" '[[ "$out" == *owner-approved* ]]'
$LOCAL_MERGE_QUEUE resume t --owner-approved >/dev/null 2>&1
check "resume lands it once approved" 'grep -q "resolved prose" "$ROOT/repo/harness/voice.md"'

echo
echo "── 8. a failing gate stalls instead of landing ───────────────────"
mk_branch gatebreaker base.txt "x"
cd "$ROOT/repo-gatebreaker" && git rm -q base.txt && git commit -qm "remove base.txt" && git push -q origin gatebreaker
$LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1
$LOCAL_MERGE_QUEUE approve --all >/dev/null 2>&1
main_before=$(git -C "$ROOT/repo" rev-parse main)
$LOCAL_MERGE_QUEUE land t >/dev/null 2>&1; rc=$?
check "failing gate exits 2"        '[[ $rc == 2 ]]'
check "failing gate does not land"  '[[ "$main_before" == $(git -C "$ROOT/repo" rev-parse main) ]]'
check "base.txt still on main"      '[[ -f "$ROOT/repo/base.txt" ]]'

echo
echo "── 9. preflight refuses a dirty primary checkout ─────────────────"
$LOCAL_MERGE_QUEUE dequeue gatebreaker >/dev/null 2>&1
echo dirt > "$ROOT/repo/dirt.txt"
out=$($LOCAL_MERGE_QUEUE land t 2>&1)
check "refuses to merge onto a dirty main" '[[ "$out" == *"uncommitted changes"* ]]'
rm "$ROOT/repo/dirt.txt"

echo
echo "── 10. an already-merged branch is cleaned up, not re-merged ─────"
mk_branch leftover leftover.txt "leftover"
cd "$ROOT/repo"
git merge -q --no-ff -m "merged by hand, as the old workflow did" leftover && git push -q origin main
merges_before=$(git rev-list --count --merges main)
cd "$ROOT/repo-leftover" && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1
$LOCAL_MERGE_QUEUE approve --all >/dev/null 2>&1
out=$($LOCAL_MERGE_QUEUE land t 2>&1)
cd "$ROOT/repo"
check "recognised as already in main"   '[[ "$out" == *"cleanup only"* ]]'
check "no second merge commit made"     '[[ $(git rev-list --count --merges main) == $merges_before ]]'
check "leftover worktree removed"       '[[ ! -d "$ROOT/repo-leftover" ]]'
check "leftover branch deleted"         '! git rev-parse --verify -q refs/heads/leftover >/dev/null'
# The cleanup-only path never rebases and never merges, so it must NOT claim to
# have published anything.
check "cleanup-only path publishes nothing" '[[ "$out" != *"rebased tip published"* ]]'

echo
echo "── 11. a branch's BRANCH.md never reaches main ───────────────────"
# The roster rule always said scaffolding is deleted before the merge; nothing
# enforced it, so a branch that forgot leaked it into main and the NEXT branch
# to land collided with it. Two hand-resolutions on 2026-08-19.
mk_branch scaffolded scaffold.txt "scaffolded"
cat > "$ROOT/repo-scaffolded/BRANCH.md" <<'MD'
# scaffolded — working notes that must never land
MD
cd "$ROOT/repo-scaffolded" && git add -A && git commit -qm "branch notes" && git push -q origin scaffolded
$LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1
$LOCAL_MERGE_QUEUE approve --all >/dev/null 2>&1
$LOCAL_MERGE_QUEUE land t >/dev/null 2>&1
cd "$ROOT/repo"
check "the branch's work landed"            '[[ -f "$ROOT/repo/scaffold.txt" ]]'
check "its BRANCH.md did NOT land"          '[[ ! -f "$ROOT/repo/BRANCH.md" ]]'
check "…and main has no record of one"      '! git cat-file -e main:BRANCH.md 2>/dev/null'
# The removal is a real commit on the branch, so history says what happened.
# Asserted on the SUBJECT rather than on `log -- BRANCH.md`: both the add and the
# delete sit on the branch side of a --no-ff merge, and main's tree never differs
# for that path, so git's history simplification prunes the whole side away and a
# pathspec log comes back empty on a perfectly correct result.
check "the removal is a commit, not a wipe" 'git log --oneline main | grep -q "BRANCH.md goes"'

echo
echo "── 12. a proven-contained ref is deleted even if -d balks ────────"
# `-d` is a safety check — is this work reachable from elsewhere? When it refuses
# for a reason we cannot reproduce (four branches on 2026-08-19), the merge queue
# answers that question directly instead of leaving the ref behind.
mk_branch stubborn stubborn.txt "stubborn"
cd "$ROOT/repo-stubborn" && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1
$LOCAL_MERGE_QUEUE approve --all >/dev/null 2>&1
$LOCAL_MERGE_QUEUE land t >/dev/null 2>&1
cd "$ROOT/repo"
check "stubborn landed"                 '[[ -f "$ROOT/repo/stubborn.txt" ]]'
check "its local ref is gone"           '! git rev-parse --verify -q refs/heads/stubborn >/dev/null'
check "and status reports no residue"   '[[ "$($LOCAL_MERGE_QUEUE status t 2>&1)" != *"stubborn"* ]]'

echo
echo "── 13. status names the residue a failed cleanup leaves ──────────"
# The failure this covers is silent by nature: a cleanup step fails at the end
# of a landing run whose last two hundred lines are gate output, and the only trace is
# a local ref nobody looks at. Three accumulated in one repo here in one day
# (2026-08-19) before a roster sweep found them.
# SCOPED TO THE SANDBOX REPO (`status t`). Unscoped, it reports every repo the
# config names, so an assertion about what the output does NOT contain would
# answer to whatever branches happen to be lying around in another repo today.
cd "$ROOT/repo"
git branch -q residue-branch main
out=$($LOCAL_MERGE_QUEUE status t 2>&1)
check "status names a landed branch whose ref survived" '[[ "$out" == *"residue-branch"* ]]'
check "…and says how to clear it"                       '[[ "$out" == *"branch -d"* ]]'
check "…and says to check before deleting"              '[[ "$out" == *"Check first"* ]]'
# A SHELF is fully merged BY CONSTRUCTION — it preserves code removed from main —
# so it looks exactly like residue and is the one branch that must never be
# suggested for deletion. Both spellings in use across the repos are covered.
git branch -q keep-me-shelf main
git branch -q analytics-page-shelved main
out=$($LOCAL_MERGE_QUEUE status t 2>&1)
check "a -shelf branch is never called residue"    '[[ "$out" != *"keep-me-shelf"* ]]'
check "nor is a -shelved one"                      '[[ "$out" != *"analytics-page-shelved"* ]]'
git branch -qD residue-branch keep-me-shelf analytics-page-shelved
out=$($LOCAL_MERGE_QUEUE status t 2>&1)
check "and a cleared ref stops being reported"     '[[ "$out" != *"residue-branch"* ]]'

echo
echo "── 14. a branch that folded sub-branches lands as it was tested ───"
# THE REGRESSION THIS GUARDS. The owner asks for pieces developed and tested
# TOGETHER, which produces a branch that folded several sub-branches into itself
# — one branch here folded four. A plain `git rebase` DROPS those
# merge commits and replays the sides in one line, so the branch meets its own
# commits stripped of the resolutions that reconciled them and conflicts against
# ITSELF, in files main never touched. The merge queue would stall on a branch that
# merges clean. Built here the same way: two sides editing one line, reconciled
# by hand in the fold.
cd "$ROOT/repo"
git checkout -qb fold main
git checkout -qb side-one fold
printf 'ONE\nline two\nline three\n' > shared.txt
git commit -qam "side-one: claim line one"
git checkout -qb side-two fold
printf 'TWO\nline two\nline three\n' > shared.txt
git commit -qam "side-two: claim line one differently"
git checkout -q fold
git merge -q --no-ff side-one -m "fold: take side-one" >/dev/null 2>&1
git merge --no-ff side-two -m "fold: take side-two" >/dev/null 2>&1
printf 'ONE AND TWO\nline two\nline three\n' > shared.txt   # the hand resolution
git add -A && git commit -qm "fold: reconcile both sides on line one" >/dev/null 2>&1
# main moves underneath it, and the branch is brought current the way an agent
# brings one current — by merging main in and RE-TESTING the result. That merge
# is what makes the branch honest, and what a flattening rebase would throw away.
git checkout -q main && echo "main moved" >> base.txt
git commit -qam "main: moves under the branch" && git push -q origin main
git checkout -q fold && git merge -q --no-ff main -m "fold: catch up to main" >/dev/null 2>&1
git checkout -q main
git worktree add -q "$ROOT/repo-fold" fold >/dev/null 2>&1
cd "$ROOT/repo-fold" && git push -qu origin fold 2>/dev/null
tested=$(git rev-parse HEAD^{tree})
tested_shared=$(cat shared.txt)
$LOCAL_MERGE_QUEUE enqueue --note "four folded branches" >/dev/null 2>&1
$LOCAL_MERGE_QUEUE approve --all >/dev/null 2>&1
out=$($LOCAL_MERGE_QUEUE land t 2>&1)
[[ -n "${LOCAL_MERGE_QUEUE_TEST_DEBUG:-}" ]] && { echo "--- land output ---"; echo "$out"; echo "---"; }
cd "$ROOT/repo"
check "a folded branch does not stall on itself" '[[ "$out" != *STALLED* ]]'
check "…it lands"                                'git merge-base --is-ancestor origin/fold main 2>/dev/null || [[ "$out" == *landed* ]]'
landed_shared=$(git show main:shared.txt)
check "…carrying the tree that was TESTED, not a reflattened one" \
  '[[ "$landed_shared" == "$tested_shared" ]]'
# The structure survives too: both sides are reachable, so history still says
# which piece each commit came from.
check "…and both folded sides are in main's history" \
  '[[ -n "$(git log main --oneline --grep="side-one: claim" )" && -n "$(git log main --oneline --grep="side-two: claim")" ]]'

echo
echo "── 15. a worktree with no generated environment is set up, not stalled on ─"
# THE REGRESSION THIS GUARDS. An agent whose own work needed no build never runs
# the repo's fresh-worktree setup, so the gate is the first thing to meet the
# empty node_modules — minutes into a landing run, dying on something that is not the
# branch's fault. Three times on 2026-08-24, twice as `esbuild ENOENT`, each one
# costing a person a diagnose-install-resume cycle.
#
# The config is rewritten from here on: every section above ran against a repo
# with no setup configured, which is still the case the `t` repo covered.
cat > "$ROOT/repos.json" <<JSON
{ "repos": { "t": {
  "checkout": "$ROOT/repo",
  "mainBranch": "main",
  "setupWhen": "test -f .setup-done",
  "setup": [
    "echo ran >> $ROOT/setup.log",
    "echo \$LOCAL_MERGE_QUEUE_CHECKOUT > $ROOT/checkout-seen",
    "touch .setup-done"
  ],
  "gate": ["test -f base.txt", "test -f .setup-done"],
  "finalCheck": "true",
  "protectedPaths": ["harness/"]
} } }
JSON
mk_branch unset-env unset-env.txt "unset"
cd "$ROOT/repo-unset-env" && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1
$LOCAL_MERGE_QUEUE approve --all >/dev/null 2>&1
out=$($LOCAL_MERGE_QUEUE land t 2>&1)
cd "$ROOT/repo"
check "the landing run says it is setting the worktree up" '[[ "$out" == *"no generated environment"* ]]'
check "the setup commands ran"                       '[[ -f "$ROOT/setup.log" && $(grep -c ran "$ROOT/setup.log") == 1 ]]'
# The gate step `test -f .setup-done` can only pass on a worktree setup reached
# first, so this asserts the ORDER as well as the fact.
check "setup precedes the gate"                      '[[ "${out%%gate: test -f base.txt*}" == *"setup: touch .setup-done"* ]]'
check "…and the branch lands"                        '[[ -f "$ROOT/repo/unset-env.txt" ]]'
# Both live repos copy their missing pieces out of the primary checkout, so the
# setup commands are useless without knowing where it is.
check "LOCAL_MERGE_QUEUE_CHECKOUT names the primary checkout" \
  '[[ "$(cat "$ROOT/checkout-seen")" == "$(cd "$ROOT/repo" && pwd -P)" ]]'

echo
echo "── 16. an already-set-up worktree pays for no setup ──────────────"
# The probe is what keeps this free: a landing run of a working worktree runs one
# `test` and nothing else. Without it every landing would pay a full npm install.
mk_branch already-set already-set.txt "already"
cd "$ROOT/repo-already-set" && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1
# AFTER the enqueue: the marker is untracked, and enqueue refuses a dirty
# worktree — which is the guard working, and is why setup runs during a landing run
# rather than being something a branch agent leaves lying in the tree.
touch "$ROOT/repo-already-set/.setup-done"
$LOCAL_MERGE_QUEUE approve --all >/dev/null 2>&1
out=$($LOCAL_MERGE_QUEUE land t 2>&1)
check "and it lands as normal"              '[[ -f "$ROOT/repo/already-set.txt" ]]'
check "the probe short-circuits the setup"  '[[ "$out" != *"no generated environment"* ]]'
check "…no setup step is even printed"      '[[ "$out" != *"setup: "* ]]'
check "…and none ran a second time"         '[[ $(grep -c ran "$ROOT/setup.log") == 1 ]]'

echo
echo "── 17. a failing setup stalls, and the report does not invent a rebase ──"
cat > "$ROOT/repos.json" <<JSON
{ "repos": { "t": {
  "checkout": "$ROOT/repo",
  "mainBranch": "main",
  "setupWhen": "test -f .setup-done",
  "setup": ["echo 'no npm here' >&2; exit 1"],
  "gate": ["test -f base.txt"],
  "finalCheck": "true",
  "protectedPaths": ["harness/"]
} } }
JSON
mk_branch bad-setup bad-setup.txt "bad"
cd "$ROOT/repo-bad-setup" && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1
$LOCAL_MERGE_QUEUE approve --all >/dev/null 2>&1
main_before=$(git -C "$ROOT/repo" rev-parse main)
out=$($LOCAL_MERGE_QUEUE land t 2>&1); rc=$?
check "a failing setup exits 2"        '[[ $rc == 2 ]]'
check "…and lands nothing"             '[[ "$main_before" == $(git -C "$ROOT/repo" rev-parse main) ]]'
check "…naming the step that failed"   '[[ "$out" == *"the step that failed"* ]]'
REPORT="$LOCAL_MERGE_QUEUE_STATE/reports/t-bad-setup.md"
check "a stall report was written"     '[[ -f "$REPORT" ]]'
check "the stall kind is its own"      'grep -q "worktree setup failed" "$REPORT"'
# THE MISDIRECTION THIS FIXES. Every report used to end in "the rebase is left in
# progress — resolve, then git rebase --continue", which is true of a conflict
# stall and of nothing else. A setup failure happens after the rebase has
# finished cleanly, so a fixer sent looking for a conflict starts by working out
# what it broke.
check "the report denies a rebase to resolve" 'grep -q "no rebase to continue" "$REPORT"'
check "…and never says rebase --continue"     '! grep -q "rebase --continue" "$REPORT"'
check "…and says what to actually run"        'grep -q "no npm here" "$REPORT"'
check "the queue records the setup stall" \
  '[[ "$(node -e "console.log(JSON.parse(require(\"fs\").readFileSync(\"$LOCAL_MERGE_QUEUE_STATE/queue.json\")).entries.find(e=>e.branch===\"bad-setup\").stallReason)")" == *"worktree setup failed"* ]]'
# The gate must not have run: a setup failure is no verdict on the branch.
check "the gate never ran"             '[[ "$out" != *"gate: test -f base.txt"* ]]'

echo
echo "── 18. resume clears a setup stall with no rebase to finish ──────"
# `resume` refuses a rebase still in progress. A setup stall leaves none, so the
# fixer owes nothing but the fix itself.
touch "$ROOT/repo-bad-setup/.setup-done"
out=$($LOCAL_MERGE_QUEUE resume t 2>&1)
check "resume does not demand a finished rebase" '[[ "$out" != *"still in progress"* ]]'
check "the fixed branch lands"                   '[[ -f "$ROOT/repo/bad-setup.txt" ]]'
check "queue empty after the setup stall clears" '[[ $(node -e "console.log(JSON.parse(require(\"fs\").readFileSync(\"$LOCAL_MERGE_QUEUE_STATE/queue.json\")).entries.length)") == 0 ]]'

echo
echo "── 19. with no deploy config, nothing about a landing run changes ──────"
# INVARIANT: the skip marker is per-repo configuration, never a global change of
# behaviour. Another repo lands through this same queue and its main is not a
# deploy trigger; a marker in its merge messages would be noise at best and a
# thing somebody has to explain at worst. Sections 1–18 all ran without a
# `deploy` key; this asserts the consequence rather than assuming it.
cat > "$ROOT/repos.json" <<JSON
{ "repos": { "t": {
  "checkout": "$ROOT/repo",
  "mainBranch": "main",
  "gate": ["test -f base.txt"],
  "finalCheck": "true",
  "protectedPaths": ["harness/"]
} } }
JSON
subj_for () { git -C "$ROOT/repo" log main --format=%s | grep -m1 -E "^Merge $1( |\$)"; }
markers ()  { git -C "$ROOT/repo" log main --format=%s | grep -cF '[skip-deploy]'; }
mk_branch nodeploy-one nodeploy-one.txt "one"
mk_branch nodeploy-two nodeploy-two.txt "two"
cd "$ROOT/repo-nodeploy-one" && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1
cd "$ROOT/repo-nodeploy-two" && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1
$LOCAL_MERGE_QUEUE approve --all >/dev/null 2>&1
$LOCAL_MERGE_QUEUE land t >/dev/null 2>&1
cd "$ROOT/repo"
check "both land as they always did"        '[[ -f "$ROOT/repo/nodeploy-one.txt" && -f "$ROOT/repo/nodeploy-two.txt" ]]'
check "no merge message carries a marker"   '[[ $(markers) == 0 ]]'
check "and no redeploy commit was invented" '[[ -z "$(git log main --format=%s --grep="^Redeploy")" ]]'

echo
echo "── 20. one build per landing run: every merge but the last is marked ───"
# The owner's ask, 2026-08-29: "main should just redeploy at the end of the
# landing." That site's production deploy IS the push to main, so a
# land of three branches shipped three builds and two of them were states that
# existed for as long as the next gate took.
cat > "$ROOT/repos.json" <<JSON
{ "repos": { "t": {
  "checkout": "$ROOT/repo",
  "mainBranch": "main",
  "deploy": { "skipMarker": "[skip-deploy]" },
  "gate": ["test -f base.txt"],
  "finalCheck": "true",
  "protectedPaths": ["harness/"]
} } }
JSON
before_markers=$(markers)
mk_branch deploy-a deploy-a.txt "a"
mk_branch deploy-b deploy-b.txt "b"
mk_branch deploy-c deploy-c.txt "c"
for b in deploy-a deploy-b deploy-c; do (cd "$ROOT/repo-$b" && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1); done
$LOCAL_MERGE_QUEUE approve --all >/dev/null 2>&1
out=$($LOCAL_MERGE_QUEUE land t --dry-run 2>&1)
check "a dry run says which one the host would build" \
  '[[ "$out" == *"its merge would be unmarked"* && "$out" == *"the host skips that build"* ]]'
check "…and still leaves main where it was" '[[ $(markers) == $before_markers ]]'
$LOCAL_MERGE_QUEUE land t >/dev/null 2>&1
cd "$ROOT/repo"
check "all three landed"                     '[[ -f "$ROOT/repo/deploy-a.txt" && -f "$ROOT/repo/deploy-b.txt" && -f "$ROOT/repo/deploy-c.txt" ]]'
check "the first merge is marked"            '[[ "$(subj_for deploy-a)" == *"[skip-deploy]"* ]]'
check "the middle merge is marked"           '[[ "$(subj_for deploy-b)" == *"[skip-deploy]"* ]]'
check "THE LAST MERGE IS NOT"                '[[ "$(subj_for deploy-c)" != *"[skip-deploy]"* ]]'
# THE INVARIANT ITSELF: whatever happened during the run, what a person's host
# sees last is a commit it will build.
check "the tip of main is a deploying commit" '[[ "$(git log -1 --format=%B main)" != *"[skip-deploy]"* ]]'
check "exactly two merges were marked"        '[[ $(markers) == $((before_markers + 2)) ]]'
# The marker belongs to the merge queue's own merge commits and to nothing else. A
# branch agent's commit carrying one would skip a build nobody asked to skip.
check "no branch commit carries the marker" \
  '[[ -z "$(git log main --format=%s --no-merges | grep -F "[skip-deploy]")" ]]'
check "no redeploy commit was needed"         '[[ -z "$(git log main --format=%s --grep="^Redeploy")" ]]'

echo
echo "── 21. a single-entry land deploys normally, marker-free ────────"
before_markers=$(markers)
mk_branch deploy-solo deploy-solo.txt "solo"
cd "$ROOT/repo-deploy-solo" && $LOCAL_MERGE_QUEUE enqueue --note "on its own" >/dev/null 2>&1
$LOCAL_MERGE_QUEUE approve --all >/dev/null 2>&1
out=$($LOCAL_MERGE_QUEUE land t 2>&1)
cd "$ROOT/repo"
check "it lands"                          '[[ -f "$ROOT/repo/deploy-solo.txt" ]]'
check "its merge is unmarked"             '[[ "$(subj_for deploy-solo)" != *"[skip-deploy]"* ]]'
check "the landing run says so"                 '[[ "$out" == *"the last of this run, so the host builds it"* ]]'
check "no marker was written at all"      '[[ $(markers) == $before_markers ]]'
check "and no redeploy commit"            '[[ -z "$(git log main --format=%s --grep="^Redeploy")" ]]'

echo
echo "── 22. a stall on the final entry: no deploy until resume lands it ─"
# The half-landed state is the thing this feature exists to keep off
# production, so a stall deliberately does NOT publish. The resume that lands
# the last entry is what deploys.
mk_branch dep-first dep-first.txt "first"
mk_branch dep-stall shared.txt $'line one\nBRANCH CLAIMS THIS\nline three\n'
cd "$ROOT/repo"
printf 'line one\nMAIN CLAIMS THIS\nline three\n' > shared.txt
git commit -qam "main touches shared.txt again" && git push -q origin main
cd "$ROOT/repo-dep-first" && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1
cd "$ROOT/repo-dep-stall" && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1
$LOCAL_MERGE_QUEUE approve --all >/dev/null 2>&1
$LOCAL_MERGE_QUEUE land t >/dev/null 2>&1; rc=$?
cd "$ROOT/repo"
check "the landing run stalls"                       '[[ $rc == 2 ]]'
check "the entry ahead of it landed, marked"   '[[ "$(subj_for dep-first)" == *"[skip-deploy]"* ]]'
check "main is left NOT deploying, on purpose" '[[ "$(git log -1 --format=%B main)" == *"[skip-deploy]"* ]]'
check "no redeploy commit papered over it"     '[[ -z "$(git log main --format=%s --grep="^Redeploy")" ]]'
# The one state nobody would otherwise look for: queue quiet, log healthy,
# production serving what it served yesterday.
out=$($LOCAL_MERGE_QUEUE status t 2>&1)
check "status names the undeployed tip"        '[[ "$out" == *"told to skip"* ]]'
cd "$ROOT/repo-dep-stall"
printf 'line one\nRECONCILED\nline three\n' > shared.txt
git add -A && GIT_EDITOR=true git rebase --continue >/dev/null 2>&1
$LOCAL_MERGE_QUEUE resume t >/dev/null 2>&1
cd "$ROOT/repo"
check "the resumed entry lands"                'grep -q RECONCILED "$ROOT/repo/shared.txt"'
check "…unmarked, being the last of the run"   '[[ "$(subj_for dep-stall)" != *"[skip-deploy]"* ]]'
check "THE TIP DEPLOYS AFTER THE RESUME"       '[[ "$(git log -1 --format=%B main)" != *"[skip-deploy]"* ]]'
check "…without needing a redeploy commit"     '[[ -z "$(git log main --format=%s --grep="^Redeploy")" ]]'
out=$($LOCAL_MERGE_QUEUE status t 2>&1)
check "status stops reporting an undeployed tip" '[[ "$out" != *"told to skip"* ]]'

echo
echo "── 23. the last entry dequeued MID-LANDING: the new last one deploys ─"
# The lookahead is asked of the queue as it stands at the merge, not of the
# snapshot taken before the gate — a gate takes minutes and an entry can leave
# inside them. Simulated exactly: a gate step dequeues the trailing entry while the
# middle one is being gated, so the middle one becomes the last of the run and
# must be the one the host builds.
cat > "$ROOT/dequeue-last.sh" <<SH
#!/bin/bash
[[ "\$PWD" == *repo-dequeue-mid ]] && $LOCAL_MERGE_QUEUE dequeue dequeue-last >/dev/null 2>&1
exit 0
SH
cat > "$ROOT/repos.json" <<JSON
{ "repos": { "t": {
  "checkout": "$ROOT/repo",
  "mainBranch": "main",
  "deploy": { "skipMarker": "[skip-deploy]" },
  "gate": ["test -f base.txt", "bash $ROOT/dequeue-last.sh"],
  "finalCheck": "true",
  "protectedPaths": ["harness/"]
} } }
JSON
mk_branch dequeue-head dequeue-head.txt "head"
mk_branch dequeue-mid  dequeue-mid.txt  "mid"
mk_branch dequeue-last dequeue-last.txt "last"
for b in dequeue-head dequeue-mid dequeue-last; do (cd "$ROOT/repo-$b" && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1); done
$LOCAL_MERGE_QUEUE approve --all >/dev/null 2>&1
$LOCAL_MERGE_QUEUE land t >/dev/null 2>&1
cd "$ROOT/repo"
check "the head merge is marked"                '[[ "$(subj_for dequeue-head)" == *"[skip-deploy]"* ]]'
check "the dequeued entry never landed"          '[[ ! -f "$ROOT/repo/dequeue-last.txt" ]]'
check "THE NEW LAST ENTRY IS UNMARKED"          '[[ "$(subj_for dequeue-mid)" != *"[skip-deploy]"* ]]'
check "so the tip deploys"                      '[[ "$(git log -1 --format=%B main)" != *"[skip-deploy]"* ]]'

echo
echo "── 24. an entry dequeued AFTER a stall: the tip is republished ─────"
# The lookahead cannot see this one coming: the trailing entry is still queued
# when the entry ahead of it merges, and only afterwards does a person decide to
# dequeue it rather than fix it. main is then landed, pushed, and sitting on a
# build the host was told to ignore, with an empty queue and a healthy-looking
# log. The next landing run settles it from the state rather than from memory.
cat > "$ROOT/repos.json" <<JSON
{ "repos": { "t": {
  "checkout": "$ROOT/repo",
  "mainBranch": "main",
  "deploy": { "skipMarker": "[skip-deploy]" },
  "gate": ["test -f base.txt"],
  "finalCheck": "true",
  "protectedPaths": ["harness/"]
} } }
JSON
mk_branch res-first res-first.txt "first"
mk_branch res-stall shared.txt $'line one\nBRANCH AGAIN\nline three\n'
cd "$ROOT/repo"
printf 'line one\nMAIN AGAIN\nline three\n' > shared.txt
git commit -qam "main touches shared.txt once more" && git push -q origin main
cd "$ROOT/repo-res-first" && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1
cd "$ROOT/repo-res-stall" && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1
$LOCAL_MERGE_QUEUE approve --all >/dev/null 2>&1
$LOCAL_MERGE_QUEUE land t >/dev/null 2>&1
cd "$ROOT/repo"
check "main is left on a skipped build"    '[[ "$(git log -1 --format=%B main)" == *"[skip-deploy]"* ]]'
$LOCAL_MERGE_QUEUE dequeue res-stall >/dev/null 2>&1
tip_before=$(git rev-parse main)
out=$($LOCAL_MERGE_QUEUE land t 2>&1)
check "the landing run says it is publishing"    '[[ "$out" == *"sitting on a skipped build"* ]]'
check "a redeploy commit was pushed"       '[[ -n "$(git log main --format=%s --grep="^Redeploy")" ]]'
check "…on top of the merge, landing nothing else" '[[ "$(git rev-parse main~1)" == "$tip_before" ]]'
# THE SELF-CANCELLING COMMIT. The natural sentence to write in that message
# names the marker, which would make the commit that exists to trigger a build
# the next one skipped — silently, and forever.
check "THE REDEPLOY COMMIT CARRIES NO MARKER" '[[ "$(git log -1 --format=%B main)" != *"[skip-deploy]"* ]]'
check "origin has it too"                     '[[ "$(git rev-parse main)" == "$(git rev-parse origin/main)" ]]'
out=$($LOCAL_MERGE_QUEUE status t 2>&1)
check "status is quiet again"                 '[[ "$out" != *"told to skip"* ]]'
# And it is idempotent: a second land over a deploying tip changes nothing.
tip_after=$(git rev-parse main)
$LOCAL_MERGE_QUEUE land t >/dev/null 2>&1
check "a landing run over a deploying tip adds nothing" '[[ "$(git rev-parse main)" == "$tip_after" ]]'

echo
echo "── 25. a PR stacked on the landing branch is retargeted, not closed ─"
# Work arrives in chains: each branch cut from the one before it, each PR based
# on its predecessor. GitHub closes a pull request the instant its BASE branch
# is deleted, and nothing reopens or retargets it afterwards — which is how #91
# was lost on 2026-09-05 when `templates-rename` landed underneath it. So every
# open PR based on the landing branch moves onto main BEFORE the remote branch
# goes.
#
# `gh` is STUBBED on PATH rather than called: this suite must never reach
# GitHub. The stub answers a --head query (the merged-state poll) with MERGED so
# the deletion proceeds, answers a --base query with one stacked PR, and logs
# every invocation so the retarget can be asserted as an argv rather than as a
# printed sentence.
mkdir -p "$ROOT/bin"
export GH_STUB_LOG="$ROOT/gh-calls.log"
cat > "$ROOT/bin/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "$GH_STUB_LOG"
head=""; base=""; prev=""
for a in "$@"; do
  case "$prev" in --head) head="$a" ;; --base) base="$a" ;; esac
  prev="$a"
done
if [[ "$1 $2" == "pr list" ]]; then
  if [[ -n "$head" ]]; then echo '[{"number":90,"state":"MERGED","isDraft":false}]'
  elif [[ -n "$base" ]]; then echo '[{"number":91,"headRefName":"stacked-on-it"}]'
  else echo '[]'; fi
  exit 0
fi
[[ "$1 $2" == "pr edit" ]] && exit 0
exit 1
STUB
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"
cat > "$ROOT/repos.json" <<JSON
{ "repos": { "t": {
  "checkout": "$ROOT/repo",
  "mainBranch": "main",
  "githubRepo": "acme/thing",
  "gate": ["test -f base.txt"],
  "finalCheck": "true",
  "protectedPaths": ["harness/"]
} } }
JSON
mk_branch based-on based-on.txt "based on"
cd "$ROOT/repo-based-on" && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1
$LOCAL_MERGE_QUEUE approve --all >/dev/null 2>&1
: > "$GH_STUB_LOG"
out=$($LOCAL_MERGE_QUEUE land t 2>&1)
cd "$ROOT/repo"
check "the branch still lands"          '[[ -f "$ROOT/repo/based-on.txt" ]]'
check "the stacked PR is retargeted"    '[[ "$out" == *"pr #91 (stacked-on-it) retargeted from based-on onto main"* ]]'
check "…by a real gh pr edit --base"    '[[ "$(grep -c -- "pr edit 91 -R acme/thing --base main" "$GH_STUB_LOG")" == 1 ]]'
# THE ORDER IS THE WHOLE POINT. Retargeting after the delete retargets nothing:
# the PR is already closed and closed is permanent.
check "the retarget PRECEDES the delete" '[[ "${out%%remote branch deleted*}" == *"retargeted"* ]]'
check "the remote branch went"           '! git -C "$ROOT/origin.git" rev-parse --verify -q refs/heads/based-on >/dev/null'
# A FAILURE TO RETARGET IS A ROSTER DEFECT, NOT A CODE DEFECT: it is said in red
# and the landing carries on, worktree and refs cleaned up as usual.
cat > "$ROOT/bin/gh" <<'STUB'
#!/bin/bash
head=""; for a in "$@"; do [[ "$prev" == "--head" ]] && head="$a"; prev="$a"; done
if [[ "$1 $2" == "pr list" && -n "$head" ]]; then echo '[{"number":92,"state":"MERGED","isDraft":false}]'; exit 0; fi
[[ "$1 $2" == "pr list" ]] && { echo "gh: could not query" >&2; exit 1; }
exit 1
STUB
mk_branch based-on-two based-on-two.txt "two"
cd "$ROOT/repo-based-on-two" && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1
$LOCAL_MERGE_QUEUE approve --all >/dev/null 2>&1
out=$($LOCAL_MERGE_QUEUE land t 2>&1)
cd "$ROOT/repo"
check "a failed retarget says so"        '[[ "$out" == *"COULD NOT LIST THE PULL REQUESTS BASED ON based-on-two"* ]]'
check "…and lands the branch anyway"     '[[ -f "$ROOT/repo/based-on-two.txt" ]]'
check "…and still cleans the worktree"   '[[ ! -d "$ROOT/repo-based-on-two" ]]'
rm -f "$ROOT/bin/gh"

# ── a branch name two repos share (2026-09-26) ──────────────────────────────
# `order fitness-functions --first` moved the website's entry when the app's was
# meant, because order and dequeue took the first entry with that name anywhere in
# the queue. They now scope by --repo or the worktree, and refuse to guess.
cd "$ROOT"
cp "$LOCAL_MERGE_QUEUE_STATE/queue.json" "$ROOT/queue.saved"
cat > "$LOCAL_MERGE_QUEUE_STATE/queue.json" <<'QJSON'
{"entries":[
 {"repo":"r1","branch":"first","status":"enqueued"},
 {"repo":"r1","branch":"shared","status":"enqueued"},
 {"repo":"r2","branch":"other","status":"enqueued"},
 {"repo":"r2","branch":"shared","status":"enqueued"}
]}
QJSON
qorder () { node -e 'console.log(JSON.parse(require("fs").readFileSync(process.env.LOCAL_MERGE_QUEUE_STATE+"/queue.json")).entries.map(e=>e.repo+"/"+e.branch).join(","))'; }
out=$($LOCAL_MERGE_QUEUE order shared --first 2>&1)
check "order refuses a name two repos share"   '[[ "$out" == *"queued in r1 and r2"* && "$(qorder)" == "r1/first,r1/shared,r2/other,r2/shared" ]]'
$LOCAL_MERGE_QUEUE order shared --first --repo r2 >/dev/null 2>&1
check "order --repo moves the entry in that repo"   '[[ "$(qorder)" == "r2/shared,r1/first,r1/shared,r2/other" ]]'
out=$($LOCAL_MERGE_QUEUE dequeue shared 2>&1)
check "dequeue refuses a name two repos share"    '[[ "$out" == *"is queued in r2 and r1"* && "$(qorder)" == "r2/shared,r1/first,r1/shared,r2/other" ]]'
out=$($LOCAL_MERGE_QUEUE approve shared 2>&1)
check "approve refuses a name two repos share"   '[[ "$out" == *"is queued in r2 and r1"* ]]'
$LOCAL_MERGE_QUEUE approve shared --repo r1 >/dev/null 2>&1
st=$(node -e 'const q=JSON.parse(require("fs").readFileSync(process.env.LOCAL_MERGE_QUEUE_STATE+"/queue.json"));console.log(q.entries.filter(e=>e.branch=="shared").map(e=>e.repo+":"+e.status).join(","))')
check "approve --repo approves the entry in that repo only" '[[ "$st" == "r2:enqueued,r1:approved" ]]'
$LOCAL_MERGE_QUEUE dequeue shared --repo r1 >/dev/null 2>&1
check "dequeue --repo dequeues the entry in that repo only"   '[[ "$(qorder)" == "r2/shared,r1/first,r2/other" ]]'
cp "$ROOT/queue.saved" "$LOCAL_MERGE_QUEUE_STATE/queue.json"
cd "$ROOT/repo"

echo
echo "════════════════════════════════════════════════════════════════"
echo "  passed $PASS   failed $FAIL"
echo "  sandbox left at $ROOT"
[[ $FAIL == 0 ]]
