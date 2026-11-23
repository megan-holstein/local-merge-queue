#!/bin/bash
# End-to-end exercise of the merge queue against a throwaway repo.
# Nothing here touches a real repo.
set -u

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/local-merge-queue-test.XXXXXX")"
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
echo "── 14b. --no-rebase: a branch that must never be rebased ────────────"
# THE REGRESSION THIS GUARDS. A branch that carries imported history (the
# repository fold) must land with its merge commits intact. Even a rebase that
# conflicts nowhere would replay every one of its commits in one line, so a
# --no-rebase entry whose branch lacks current main stalls and asks for
# `git merge origin/main` in its worktree. It never starts a rebase.
cd "$ROOT/repo"
git checkout -q main
# nr1 merged current main, so it lands as it is, merge commit included.
git worktree add -q "$ROOT/repo-nr1" -b nr1 main >/dev/null 2>&1
( cd "$ROOT/repo-nr1" && echo nr1 > nr1.txt && git add -A && git commit -qm "nr1: its own work" )
echo "main moves before nr1" >> base.txt
git commit -qam "main: moves before nr1 merges it" && git push -q origin main
cd "$ROOT/repo-nr1"
git merge -q --no-ff main -m "nr1: merge main in" >/dev/null 2>&1
git push -qu origin nr1 2>/dev/null
merges_before=$(git -C "$ROOT/repo" rev-list --count --merges main)
nr1_head=$(git rev-parse HEAD)
$LOCAL_MERGE_QUEUE enqueue --no-rebase --note "nr1" >/dev/null 2>&1
nr_flag () { node -e 'const q=JSON.parse(require("fs").readFileSync(process.env.LOCAL_MERGE_QUEUE_STATE+"/queue.json"));console.log(q.entries.find(x=>x.branch==process.argv[1]).noRebase)' "$1"; }
check "enqueue --no-rebase records the flag on the entry"        '[[ "$(nr_flag nr1)" == true ]]'
out=$($LOCAL_MERGE_QUEUE status t 2>&1)
check "status shows no-rebase beside the entry"                  '[[ "$out" == *"no-rebase"* ]]'
$LOCAL_MERGE_QUEUE approve nr1 >/dev/null 2>&1
out=$($LOCAL_MERGE_QUEUE land t --dry-run 2>&1)
check "land --dry-run shows no-rebase"                           '[[ "$out" == *"no-rebase"* ]]'
out=$($LOCAL_MERGE_QUEUE land t 2>&1)
cd "$ROOT/repo"
check "a --no-rebase branch that merged main lands"              '[[ "$out" != *STALLED* ]] && git merge-base --is-ancestor "$nr1_head" main'
check "…with its own merge commit and the --no-ff landing merge on main" \
  '[[ -n "$(git log main --merges --oneline --grep="nr1: merge main in")" && $(git rev-list --count --merges main) == $((merges_before + 2)) ]]'

# nr2 merged main, then main moved again: the queue must stall, not rebase.
git worktree add -q "$ROOT/repo-nr2" -b nr2 main >/dev/null 2>&1
( cd "$ROOT/repo-nr2" && echo nr2 > nr2.txt && git add -A && git commit -qm "nr2: its own work" )
echo "main moves before nr2" >> base.txt
git commit -qam "main: moves before nr2 merges it" && git push -q origin main
cd "$ROOT/repo-nr2"
git merge -q --no-ff main -m "nr2: merge main in" >/dev/null 2>&1
git push -qu origin nr2 2>/dev/null
$LOCAL_MERGE_QUEUE enqueue --no-rebase --note "nr2" >/dev/null 2>&1
$LOCAL_MERGE_QUEUE approve nr2 >/dev/null 2>&1
cd "$ROOT/repo"
echo "main moves under nr2" >> base.txt
git commit -qam "main: moves under nr2" && git push -q origin main
wt2="$ROOT/repo-nr2"
nr2_head=$(git -C "$wt2" rev-parse HEAD)
out=$($LOCAL_MERGE_QUEUE land t 2>&1); rc=$?
st=$($LOCAL_MERGE_QUEUE status t 2>&1)
no_rebase_dir () { [[ ! -e "$(git -C "$wt2" rev-parse --path-format=absolute --git-path rebase-merge)" && ! -e "$(git -C "$wt2" rev-parse --path-format=absolute --git-path rebase-apply)" ]]; }
check "main moved under a --no-rebase branch: the run stalls and exits 2" '[[ "$out" == *STALLED* && $rc == 2 ]]'
check "…status gives the reason" \
  '[[ "$st" == *"main moved under a --no-rebase branch — merge origin/main into it and resume"* ]]'
check "…no rebase was started in the worktree"                   'no_rebase_dir'
check "…and the branch did not move"                             '[[ "$(git -C "$wt2" rev-parse HEAD)" == "$nr2_head" ]]'
report=$(find "$LOCAL_MERGE_QUEUE_STATE" -name 't-nr2.md' | head -1)
check "…and the report says to merge, not to continue a rebase" \
  '[[ -n "$report" && "$(cat "$report")" == *"git merge origin/main"* && "$(cat "$report")" != *"left in progress"* && "$(cat "$report")" != *"rebase --continue"* ]]'
out=$($LOCAL_MERGE_QUEUE resume t 2>&1)
check "resume without the merge stalls it again, still unrebased" \
  '[[ "$out" == *STALLED* && "$(git -C "$wt2" rev-parse HEAD)" == "$nr2_head" ]] && no_rebase_dir'
( cd "$wt2" && git merge -q --no-ff origin/main -m "nr2: merge main in again" >/dev/null 2>&1 && git push -q origin nr2 2>/dev/null )
nr2_head=$(git -C "$wt2" rev-parse HEAD)
out=$($LOCAL_MERGE_QUEUE resume t 2>&1)
cd "$ROOT/repo"
check "after git merge origin/main in the worktree, resume lands it" \
  '[[ "$out" != *STALLED* ]] && git merge-base --is-ancestor "$nr2_head" main'
check "…with the merge commit from the worktree on main" \
  '[[ -n "$(git log main --merges --oneline --grep="nr2: merge main in again")" ]]'

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
echo "── lanes: one repo, two deployables, one queue ──────────────────────"
# A second fixture repo declares lanes `a` and `b` (plus `rest`, which takes "*")
# and a `shared/` prefix that belongs to every lane. The earlier sections ran
# with no `lanes` key at all; these exercise the model itself.
SAVED_CONFIG="$LOCAL_MERGE_QUEUE_CONFIG"; SAVED_STATE="$LOCAL_MERGE_QUEUE_STATE"
export LOCAL_MERGE_QUEUE_CONFIG="$ROOT/lanes-repos.json"
export LOCAL_MERGE_QUEUE_STATE="$ROOT/lanes-state"
git init -q --bare "$ROOT/lorigin.git"
git init -q -b main "$ROOT/lrepo"
cd "$ROOT/lrepo"
git config user.email t@t.t; git config user.name T
git remote add origin "$ROOT/lorigin.git"
mkdir -p a b shared && echo a > a/base.txt && echo b > b/base.txt && echo s > shared/base.txt && echo r > root.txt
git add -A && git commit -qm "base" && git push -qu origin main
lane_branch () {  # name, then file=content pairs; no pairs makes a branch with no diff
  local name="$1"; shift
  git -C "$ROOT/lrepo" worktree add -q "$ROOT/lrepo-$name" -b "$name" >/dev/null 2>&1
  cd "$ROOT/lrepo-$name"
  local pair
  for pair in "$@"; do mkdir -p "$(dirname "${pair%%=*}")"; printf '%s' "${pair#*=}" > "${pair%%=*}"; done
  if [[ $# -gt 0 ]]; then git add -A && git commit -qm "$name"; fi
  git push -qu origin "$name" 2>/dev/null
  cd "$ROOT/lrepo"
}
write_lanes_config () {  # the `rest` lane's paths: "*" or a prefix
  cat > "$ROOT/lanes-repos.json" <<JSON
{ "repos": { "m": {
  "checkout": "$ROOT/lrepo",
  "shared": ["shared/"],
  "lanes": {
    "a":    { "paths": ["a/"], "gate": ["echo gate-a >> $ROOT/lanes.log"], "finalCheck": "echo final-a >> $ROOT/lanes.log" },
    "b":    { "paths": ["b/"], "gate": ["echo gate-b >> $ROOT/lanes.log"], "finalCheck": "echo final-b >> $ROOT/lanes.log" },
    "rest": { "paths": $1, "gate": ["echo gate-rest >> $ROOT/lanes.log"] }
  }
} } }
JSON
}
write_lanes_config '"*"'
lane_branch only-a   a/new.txt=x
lane_branch only-b   b/new.txt=x
lane_branch both     a/two.txt=x b/two.txt=x
lane_branch via-shared shared/new.txt=x
lane_branch loose    root.txt=changed
lane_branch cleanup
for b in only-a only-b both via-shared loose cleanup; do
  (cd "$ROOT/lrepo-$b" && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1)
done
lanes_of () { node -e 'const q=JSON.parse(require("fs").readFileSync(process.env.LOCAL_MERGE_QUEUE_STATE+"/queue.json"));console.log(JSON.stringify(q.entries.find(e=>e.branch==process.argv[1]).lanes))' "$1"; }
check "an entry touching a/ is in [a]"                       '[[ "$(lanes_of only-a)" == "[\"a\"]" ]]'
check "an entry touching b/ is in [b]"                       '[[ "$(lanes_of only-b)" == "[\"b\"]" ]]'
check "an entry touching both is in [a, b], in config order" '[[ "$(lanes_of both)" == "[\"a\",\"b\"]" ]]'
check "a path under shared/ is in every lane"                '[[ "$(lanes_of via-shared)" == "[\"a\",\"b\",\"rest\"]" ]]'
check "an unclaimed path goes to the * lane"                 '[[ "$(lanes_of loose)" == "[\"rest\"]" ]]'
check "a cleanup-only entry has no lanes"                    '[[ "$(lanes_of cleanup)" == "[]" ]]'

out=$($LOCAL_MERGE_QUEUE status m 2>&1)
check "status shows the lanes after the branch name"         '[[ "$out" == *"only-a [a]"* && "$out" == *"both [a, b]"* && "$out" == *"cleanup []"* ]]'
$LOCAL_MERGE_QUEUE approve --all --repo m >/dev/null 2>&1
out=$($LOCAL_MERGE_QUEUE land m --dry-run 2>&1)
check "--dry-run shows each entry's lanes"                   '[[ "$out" == *"lanes: [a, b]"* && "$out" == *"lanes: [b]"* && "$out" == *"lanes: []"* ]]'
check "--dry-run shows the gate steps lane by lane"          '[[ "$out" == *"gate [a]: echo gate-a"* && "$out" == *"gate [b]: echo gate-b"* && "$out" == *"gate [rest]: echo gate-rest"* ]]'
check "--dry-run runs no gate"                               '[[ ! -e "$ROOT/lanes.log" ]]'

# `land` recomputes the lanes after the rebase and runs the gates of those lanes.
# Corrupt the stored lanes of `only-a` and check the landing run trusts the diff.
node -e 'const f=process.env.LOCAL_MERGE_QUEUE_STATE+"/queue.json";const fs=require("fs");const q=JSON.parse(fs.readFileSync(f));q.entries.forEach(e=>{if(e.branch!="only-a")e.status="enqueued"});q.entries.find(e=>e.branch=="only-a").lanes=["b"];fs.writeFileSync(f,JSON.stringify(q))'
out=$($LOCAL_MERGE_QUEUE land m 2>&1)
check "land recomputes the lanes after the rebase"           '[[ "$(grep -c . "$ROOT/lanes.log")" == 2 && "$(sed -n 1p "$ROOT/lanes.log")" == gate-a && "$(sed -n 2p "$ROOT/lanes.log")" == final-a ]]'
check "a lane's final check runs only when it landed"        '[[ "$(cat "$ROOT/lanes.log")" != *final-b* ]]'
: > "$ROOT/lanes.log"
$LOCAL_MERGE_QUEUE approve --all --repo m >/dev/null 2>&1
out=$($LOCAL_MERGE_QUEUE land m 2>&1); rc=$?
check "the remaining entries land"                           '[[ $rc == 0 && "$(git -C "$ROOT/lrepo" rev-list --count --merges main)" == 5 ]]'
check "each entry ran the gates of its own lanes"            '[[ "$(grep -c gate-a "$ROOT/lanes.log")" == 2 && "$(grep -c gate-b "$ROOT/lanes.log")" == 3 && "$(grep -c gate-rest "$ROOT/lanes.log")" == 2 ]]'
cd "$ROOT/lrepo"

# Config errors name the key.
echo '{ "repos": { "m": { "checkout": "'"$ROOT"'/lrepo", "gate": ["true"], "lanes": { "a": { "paths": ["a/"] } } } } }' > "$ROOT/bad1.json"
out=$(LOCAL_MERGE_QUEUE_CONFIG="$ROOT/bad1.json" $LOCAL_MERGE_QUEUE status 2>&1); rc=$?
check "lanes plus a repo-level gate is a config error naming the key" '[[ $rc != 0 && "$out" == *"\"gate\""* ]]'
echo '{ "repos": { "m": { "checkout": "'"$ROOT"'/lrepo", "deploy": {"skipMarker":"x"}, "lanes": { "a": { "paths": "*" } } } } }' > "$ROOT/bad2.json"
out=$(LOCAL_MERGE_QUEUE_CONFIG="$ROOT/bad2.json" $LOCAL_MERGE_QUEUE status 2>&1); rc=$?
check "…and the same for every other gate-family key"                '[[ $rc != 0 && "$out" == *"\"deploy\""* ]]'
echo '{ "repos": { "m": { "checkout": "'"$ROOT"'/lrepo", "lanes": { "a": { "paths": "*" }, "b": { "paths": "*" } } } } }' > "$ROOT/bad3.json"
out=$(LOCAL_MERGE_QUEUE_CONFIG="$ROOT/bad3.json" $LOCAL_MERGE_QUEUE status 2>&1); rc=$?
check "two * lanes are a config error"                               '[[ $rc != 0 && "$out" == *"both take"* ]]'

# A lanes repo with no * lane loads; the unclaimed path is refused at enqueue and at land.
write_lanes_config '["rest/"]'
lane_branch strays stray.txt=x
out=$(cd "$ROOT/lrepo-strays" && $LOCAL_MERGE_QUEUE enqueue 2>&1); rc=$?
check "a lanes repo with no * lane loads, and enqueue refuses an unclaimed path by name" '[[ $rc != 0 && "$out" == *"stray.txt"* ]]'
write_lanes_config '"*"'
(cd "$ROOT/lrepo-strays" && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1) && $LOCAL_MERGE_QUEUE approve strays --repo m >/dev/null 2>&1
write_lanes_config '["rest/"]'
out=$($LOCAL_MERGE_QUEUE land m 2>&1); rc=$?
check "land refuses an unclaimed path by name"                       '[[ $rc != 0 && "$out" == *"stray.txt"* ]]'

echo
echo "── lanes: a stall holds only its own lanes ──────────────────────────"
# A third fixture repo with lanes `a` and `b` and a `shared/` prefix. Each lane's
# setup, gate and final check append a line naming the lane (and, for setup and
# gate, the worktree) to a log, so the test reads back what ran and in what
# order. Lane b's gate also fails on any branch that carries b/broken.txt.
export LOCAL_MERGE_QUEUE_CONFIG="$ROOT/stall-repos.json"
export LOCAL_MERGE_QUEUE_STATE="$ROOT/stall-state"
SLOG="$ROOT/stall-lanes.log"
git init -q --bare "$ROOT/sorigin.git"
git init -q -b main "$ROOT/srepo"
cd "$ROOT/srepo"
git config user.email t@t.t; git config user.name T
git remote add origin "$ROOT/sorigin.git"
mkdir -p a b shared && echo a > a/base.txt && echo b > b/base.txt && echo s > shared/base.txt
printf 'one\ntwo\nthree\n' > a/conflict.txt
git add -A && git commit -qm "base" && git push -qu origin main
cat > "$ROOT/stall-repos.json" <<JSON
{ "repos": { "s": {
  "checkout": "$ROOT/srepo",
  "shared": ["shared/"],
  "lanes": {
    "a": { "paths": ["a/"],
           "setupWhen": "test -f .setup-a", "setup": ["echo setup-a \$(basename \$PWD) >> $SLOG", "touch .setup-a"],
           "gate": ["echo gate-a \$(basename \$PWD) >> $SLOG"],
           "finalCheck": "echo final-a >> $SLOG" },
    "b": { "paths": ["b/"],
           "setupWhen": "test -f .setup-b", "setup": ["echo setup-b \$(basename \$PWD) >> $SLOG", "touch .setup-b"],
           "gate": ["echo gate-b \$(basename \$PWD) >> $SLOG", "test ! -e b/broken.txt"],
           "finalCheck": "echo final-b >> $SLOG" }
  }
} } }
JSON
stall_branch () {  # name, then file=content pairs
  local name="$1"; shift
  git -C "$ROOT/srepo" worktree add -q "$ROOT/srepo-$name" -b "$name" >/dev/null 2>&1
  cd "$ROOT/srepo-$name"
  local pair
  for pair in "$@"; do mkdir -p "$(dirname "${pair%%=*}")"; printf '%s' "${pair#*=}" > "${pair%%=*}"; done
  git add -A && git commit -qm "$name" && git push -qu origin "$name" 2>/dev/null
  cd "$ROOT/srepo"
}
sstatus () { node -e 'const q=JSON.parse(require("fs").readFileSync(process.env.LOCAL_MERGE_QUEUE_STATE+"/queue.json"));const e=q.entries.find(e=>e.branch==process.argv[1]);console.log(e?e.status:"gone")' "$1"; }
sreason () { node -e 'const q=JSON.parse(require("fs").readFileSync(process.env.LOCAL_MERGE_QUEUE_STATE+"/queue.json"));const e=q.entries.find(e=>e.branch==process.argv[1]);console.log(e&&e.stallReason||"")' "$1"; }
stall_branch a-conflict a/conflict.txt=$'one\nBRANCH\nthree\n'
stall_branch b-first    b/first.txt=x
stall_branch a-behind   a/behind.txt=x
stall_branch both       a/both.txt=x b/both.txt=x
stall_branch via-shared shared/new.txt=x
stall_branch leftover   a/leftover.txt=x
stall_branch b-second   b/second.txt=x
# main moves under a-conflict, on the line it changes, and takes leftover by
# hand, which makes leftover a cleanup-only entry with no lanes.
printf 'one\nMAIN\nthree\n' > a/conflict.txt
git commit -qam "main touches a/conflict.txt"
git merge -q --no-ff -m "merged by hand" leftover && git push -q origin main
for b in a-conflict b-first a-behind both via-shared leftover b-second; do
  (cd "$ROOT/srepo-$b" && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1)
done
$LOCAL_MERGE_QUEUE approve --all --repo s >/dev/null 2>&1
out=$($LOCAL_MERGE_QUEUE land s 2>&1); rc=$?
check "a stall in lane a exits 2"                                    '[[ $rc == 2 ]]'
check "…and the b-lane entries queued behind it land in the same run" '[[ -f "$ROOT/srepo/b/first.txt" && -f "$ROOT/srepo/b/second.txt" ]]'
check "…while main does not carry the stalled entry"                 '! grep -q BRANCH "$ROOT/srepo/a/conflict.txt"'
check "the stalled entry stays stalled"                              '[[ "$(sstatus a-conflict)" == stalled ]]'
check "an a-lane entry behind the stall is held"                     '[[ ! -f "$ROOT/srepo/a/behind.txt" && "$(sstatus a-behind)" == approved ]]'
check "an entry in both lanes is held"                               '[[ ! -f "$ROOT/srepo/a/both.txt" && "$(sstatus both)" == approved ]]'
check "a shared/ entry is held"                                      '[[ ! -f "$ROOT/srepo/shared/new.txt" && "$(sstatus via-shared)" == approved ]]'
check "a cleanup-only entry is never held"                           '[[ "$(sstatus leftover)" == gone && ! -d "$ROOT/srepo-leftover" ]]'
check "a lane's setup runs only for an entry in that lane"           '[[ "$(grep -c "^setup-b" "$SLOG")" == 2 && "$(grep -c "^setup-a" "$SLOG")" == 0 ]]'
check "a lane's final check runs only when its lane landed"          'grep -qx final-b "$SLOG" && ! grep -q final-a "$SLOG"'
SREPORT="$LOCAL_MERGE_QUEUE_STATE/reports/s-a-conflict.md"
check "the stall report names the lanes that stalled"                'grep -q "Lanes stalled:\*\* a$" "$SREPORT"'
check "…and says entries in other lanes keep landing"                'grep -q "Entries in other lanes keep landing" "$SREPORT"'
check "the run ends by printing each stall with its lanes"           '[[ "$out" == *"a-conflict [a] — rebase conflict in 1 file(s)"* && "$out" == *"entries in other lanes keep landing"* ]]'

# A gate failure in lane b names the lane, and then every lane is held.
stall_branch b-broken b/broken.txt=x b/real.txt=x
(cd "$ROOT/srepo-b-broken" && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1)
$LOCAL_MERGE_QUEUE approve b-broken --repo s >/dev/null 2>&1
out=$($LOCAL_MERGE_QUEUE land s 2>&1); rc=$?
check "land says which lanes wait behind an earlier stall"           '[[ "$out" == *"lane a waits behind the stall on \"a-conflict\""* ]]'
check "a gate failure in lane b stalls, exits 2, and names the lane" '[[ $rc == 2 && "$(sreason b-broken)" == "gate failed after rebase in lane b" ]]'
check "…in the report as well"                                       'grep -q "gate failed after rebase in lane b" "$LOCAL_MERGE_QUEUE_STATE/reports/s-b-broken.md"'
check "a lane gated but not landed runs no final check"              '[[ "$(grep -cx final-b "$SLOG")" == 1 ]]'
out=$($LOCAL_MERGE_QUEUE land s 2>&1); rc=$?
check "land refuses with today's message when every lane is blocked" '[[ $rc == 1 && "$out" == *"s is stalled on \"a-conflict\" — resolve it, then: local-merge-queue resume s"* ]]'

# resume retries each stalled entry in queue order. a-conflict is still
# mid-rebase, so resume reports it in today's words and goes on to b-broken.
(cd "$ROOT/srepo-b-broken" && git rm -q b/broken.txt && git commit -qm "b-broken: drop the file the gate refuses")
out=$($LOCAL_MERGE_QUEUE resume s 2>&1); rc=$?
check "resume reports a stall whose rebase is still in progress"      '[[ "$out" == *"is still in progress — finish it (git rebase --continue) before resuming"* ]]'
check "…leaves it stalled and exits nonzero"                         '[[ $rc != 0 && "$(sstatus a-conflict)" == stalled ]]'
check "…and lands the fixed stall in the other lane"                  '[[ -f "$ROOT/srepo/b/real.txt" && "$(sstatus b-broken)" == gone ]]'
check "…while the a-lane entries stay held"                          '[[ ! -f "$ROOT/srepo/a/behind.txt" ]]'

# The fixer resolves a-conflict onto the main of the stall; main has moved since,
# so resume rebases it again before it lands.
cd "$ROOT/srepo-a-conflict"
printf 'one\nRESOLVED\nthree\n' > a/conflict.txt
git add -A && GIT_EDITOR=true git rebase --continue >/dev/null 2>&1
cd "$ROOT/srepo"
: > "$SLOG"
out=$($LOCAL_MERGE_QUEUE resume s 2>&1); rc=$?
check "resume rebases a stall that main moved under"                 '[[ $rc == 0 && "$out" == *"main moved while a-conflict was stalled — rebasing it again"* ]]'
check "the resolved entry lands"                                     'grep -q RESOLVED "$ROOT/srepo/a/conflict.txt"'
check "the held entries land behind it, in queue order" \
  '[[ "$(git -C "$ROOT/srepo" log --merges --reverse --format=%s main | tail -4 | tr "\n" " ")" == "Merge a-conflict Merge a-behind Merge both Merge via-shared " ]]'
check "the queue empties"                                            '[[ $(node -e "console.log(JSON.parse(require(\"fs\").readFileSync(\"$LOCAL_MERGE_QUEUE_STATE/queue.json\")).entries.length)") == 0 ]]'
check "an entry touching both lanes runs both gates, in config order" '[[ "$(grep "^gate-. srepo-both$" "$SLOG" | tr "\n" " ")" == "gate-a srepo-both gate-b srepo-both " ]]'
check "a shared/ path runs both gates, in config order"              '[[ "$(grep "^gate-. srepo-via-shared$" "$SLOG" | tr "\n" " ")" == "gate-a srepo-via-shared gate-b srepo-via-shared " ]]'
check "a lane's setup runs when an entry in that lane lands"         'grep -qx "setup-a srepo-a-conflict" "$SLOG"'
check "each lane that landed runs its final check once"              '[[ "$(grep -cx final-a "$SLOG")" == 1 && "$(grep -cx final-b "$SLOG")" == 1 ]]'

echo
echo "── lanes: the deploy marker and the settle are per lane ─────────────"
# A fourth fixture repo with lanes `a` and `b`. Lane a carries a `deploy`
# key and lane b does not, so a b-lane entry never writes a marker and never
# needs a settle. Lane a's gate refuses any branch that carries a/broken.txt,
# and lane b's gate refuses b/broken.txt.
export LOCAL_MERGE_QUEUE_CONFIG="$ROOT/deploy-repos.json"
export LOCAL_MERGE_QUEUE_STATE="$ROOT/deploy-state"
git init -q --bare "$ROOT/dorigin.git"
git init -q -b main "$ROOT/drepo"
cd "$ROOT/drepo"
git config user.email t@t.t; git config user.name T
git remote add origin "$ROOT/dorigin.git"
mkdir -p a b && echo a > a/base.txt && echo b > b/base.txt
git add -A && git commit -qm "base" && git push -qu origin main
write_deploy_config () {  # lane a's marker, then lane b's deploy object or nothing
  local bdeploy=""
  [[ -n "${2:-}" ]] && bdeploy=", \"deploy\": { \"skipMarker\": \"$2\" }"
  cat > "$ROOT/deploy-repos.json" <<JSON
{ "repos": { "d": {
  "checkout": "$ROOT/drepo",
  "lanes": {
    "a": { "paths": ["a/"], "gate": ["test ! -e a/broken.txt"], "deploy": { "skipMarker": "$1" } },
    "b": { "paths": ["b/"], "gate": ["test ! -e b/broken.txt"]$bdeploy }
  }
} } }
JSON
}
write_deploy_config "[skip-a]"
dbranch () {  # name, then file=content pairs
  local name="$1"; shift
  git -C "$ROOT/drepo" worktree add -q "$ROOT/drepo-$name" -b "$name" >/dev/null 2>&1
  cd "$ROOT/drepo-$name"
  local pair
  for pair in "$@"; do mkdir -p "$(dirname "${pair%%=*}")"; printf '%s' "${pair#*=}" > "${pair%%=*}"; done
  git add -A && git commit -qm "$name" && git push -qu origin "$name" 2>/dev/null
  cd "$ROOT/drepo"
}
denqueue () { for b in "$@"; do (cd "$ROOT/drepo-$b" && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1); done; $LOCAL_MERGE_QUEUE approve --all --repo d >/dev/null 2>&1; }
dsubj () { git -C "$ROOT/drepo" log main --first-parent --format=%s | grep -m1 -E "^Merge $1( |\$)"; }
dredeploys () { git -C "$ROOT/drepo" log main --format=%s | grep -c '^Redeploy'; }
dstatus () { node -e 'const q=JSON.parse(require("fs").readFileSync(process.env.LOCAL_MERGE_QUEUE_STATE+"/queue.json"));const e=q.entries.find(e=>e.branch==process.argv[1]);console.log(e?e.status:"gone")' "$1"; }

# Three entries: the a-lane entry with another a-lane entry behind it is marked;
# the b-lane entry between them is not, since lane b has no deploy key; the last
# a-lane entry is not, since nothing is behind it.
dbranch a1 a/1.txt=x
dbranch b1 b/1.txt=x
dbranch a2 a/2.txt=x
denqueue a1 b1 a2
out=$($LOCAL_MERGE_QUEUE land d --dry-run 2>&1)
check "--dry-run says the first a-lane merge would carry the marker, naming the lane" '[[ "$out" == *"would carry [skip-a] for lane a"* ]]'
check "--dry-run says the last a-lane merge would be unmarked, naming the lane"       '[[ "$out" == *"would be unmarked for lane a"* ]]'
check "--dry-run prints nothing about a marker for a b-lane entry"                    '[[ "$(grep -c "dry run — its merge would" <<<"$out")" == 2 ]]'
out=$($LOCAL_MERGE_QUEUE land d 2>&1); rc=$?
check "the three entries land"                                                        '[[ $rc == 0 && -f "$ROOT/drepo/a/1.txt" && -f "$ROOT/drepo/b/1.txt" && -f "$ROOT/drepo/a/2.txt" ]]'
check "a1, with a2 behind it in lane a, is marked"                                    '[[ "$(dsubj a1)" == *"[skip-a]"* ]]'
check "b1, in a lane with no deploy key, is unmarked"                                 '[[ "$(dsubj b1)" != *"[skip-a]"* ]]'
check "a2, the last in lane a, is unmarked"                                           '[[ "$(dsubj a2)" != *"[skip-a]"* ]]'
check "no redeploy commit was needed"                                                 '[[ "$(dredeploys)" == 0 ]]'
check "the run says which lane each marked merge waited in"                           '[[ "$out" == *"marked [skip-a] — another branch in lane a is queued behind it"* ]]'

# A run of b-lane entries alone writes no marker and no republish.
dbranch b2 b/2.txt=x
dbranch b3 b/3.txt=x
denqueue b2 b3
before=$(git -C "$ROOT/drepo" rev-list --count main)
$LOCAL_MERGE_QUEUE land d >/dev/null 2>&1
check "two b-lane entries land as two merges and nothing else"                        '[[ "$(git -C "$ROOT/drepo" rev-list --count main)" == $((before + 4)) && "$(dredeploys)" == 0 ]]'
check "…and neither merge carries a marker"                                           '[[ "$(dsubj b2)" != *"[skip-"* && "$(dsubj b3)" != *"[skip-"* ]]'

# a3 is marked because a4 waits behind it; a4 stalls on its gate. b4 lands
# unmarked in lane b, which the stall does not hold. `main`'s last a/ commit is
# then the marked a3 merge, buried under an unmarked b-lane merge, so a plain
# `git log -- a/` (which follows the branch's own commit) would never find it.
dbranch a3 a/3.txt=x
dbranch a4 a/4.txt=x a/broken.txt=x
dbranch b4 b/4.txt=x
denqueue a3 a4 b4
out=$($LOCAL_MERGE_QUEUE land d 2>&1); rc=$?
check "a4 stalls on its gate, a3 and b4 land"                                         '[[ $rc == 2 && "$(dstatus a4)" == stalled && -f "$ROOT/drepo/a/3.txt" && -f "$ROOT/drepo/b/4.txt" ]]'
check "a3 carries the marker, being followed by a4 at its merge"                      '[[ "$(dsubj a3)" == *"[skip-a]"* && "$(dsubj b4)" != *"[skip-"* ]]'
check "the stall holds lane a, so the run does not settle it"                         '[[ "$(dredeploys)" == 0 ]]'
out=$($LOCAL_MERGE_QUEUE status d 2>&1)
check "status reports the undeployed lane tip, naming the lane"                       '[[ "$out" == *"told to skip in lane a"* ]]'
$LOCAL_MERGE_QUEUE dequeue a4 --repo d >/dev/null 2>&1
tip_before=$(git -C "$ROOT/drepo" rev-parse main)
out=$($LOCAL_MERGE_QUEUE land d 2>&1)
check "the next land says it is publishing lane a"                                    '[[ "$out" == *"sitting on a skipped build in lane a — publishing it"* ]]'
check "…with one empty commit on top of main"                                         '[[ "$(dredeploys)" == 1 && "$(git -C "$ROOT/drepo" rev-parse main~1)" == "$tip_before" && -z "$(git -C "$ROOT/drepo" diff --name-only main~1 main)" ]]'
check "THE REPUBLISH CARRIES NO MARKER"                                               '[[ "$(git -C "$ROOT/drepo" log -1 --format=%B main)" != *"[skip-"* ]]'
check "origin has it too"                                                             '[[ "$(git -C "$ROOT/drepo" rev-parse main)" == "$(git -C "$ROOT/drepo" rev-parse origin/main)" ]]'
out=$($LOCAL_MERGE_QUEUE status d 2>&1)
check "status is quiet again"                                                         '[[ "$out" != *"told to skip"* ]]'
# THE SECOND FAILURE MODE: the republish is an empty commit that no path-limited
# log lists, so a settle that looked only at path history would republish again
# on every later land.
tip_after=$(git -C "$ROOT/drepo" rev-parse main)
$LOCAL_MERGE_QUEUE land d >/dev/null 2>&1
check "a second land does not republish again"                                        '[[ "$(git -C "$ROOT/drepo" rev-parse main)" == "$tip_after" && "$(dredeploys)" == 1 ]]'
dbranch b5 b/5.txt=x
denqueue b5
$LOCAL_MERGE_QUEUE land d >/dev/null 2>&1
check "…nor after a later b-lane merge lands over the republish"                       '[[ "$(dredeploys)" == 1 ]]'

# Two lanes that share one marker write it once.
write_deploy_config "[skip-deploy]" "[skip-deploy]"
dbranch both a/both.txt=x b/both.txt=x
dbranch after-a a/after.txt=x
denqueue both after-a
$LOCAL_MERGE_QUEUE land d >/dev/null 2>&1
check "a marker shared by two lanes is written once"                                  '[[ "$(dsubj both | grep -o -F "[skip-deploy]" | wc -l | tr -d " ")" == 1 ]]'

# Each lane has its own marker; an entry in both lanes carries both. Both
# lanes' follow-on entries stall and are dequeued, so main sits on a merge that
# skipped both builds, and one empty commit publishes both lanes.
write_deploy_config "[skip-a]" "[skip-b]"
dbranch both2 a/both2.txt=x b/both2.txt=x
dbranch after-a2 a/after2.txt=x a/broken.txt=y
dbranch after-b2 b/after2.txt=x b/broken.txt=y
denqueue both2 after-a2 after-b2
$LOCAL_MERGE_QUEUE land d >/dev/null 2>&1
check "an entry in both lanes carries both markers when both lanes have entries behind it" '[[ "$(dsubj both2)" == *"[skip-a]"* && "$(dsubj both2)" == *"[skip-b]"* ]]'
check "both follow-on entries stall"                                                  '[[ "$(dstatus after-a2)" == stalled && "$(dstatus after-b2)" == stalled ]]'
out=$($LOCAL_MERGE_QUEUE status d 2>&1)
check "status names both undeployed lanes"                                            '[[ "$out" == *"told to skip in lanes a, b"* ]]'
$LOCAL_MERGE_QUEUE dequeue after-a2 --repo d >/dev/null 2>&1
$LOCAL_MERGE_QUEUE dequeue after-b2 --repo d >/dev/null 2>&1
before=$(dredeploys)
out=$($LOCAL_MERGE_QUEUE land d 2>&1)
check "a run that finds two lanes undeployed publishes once"                          '[[ "$(dredeploys)" == $((before + 1)) && "$out" == *"in lanes a, b — publishing it"* ]]'
check "…and that one commit settles both"                                             '[[ "$($LOCAL_MERGE_QUEUE status d 2>&1)" != *"told to skip"* ]]'
cd "$ROOT/drepo"

export LOCAL_MERGE_QUEUE_CONFIG="$SAVED_CONFIG" LOCAL_MERGE_QUEUE_STATE="$SAVED_STATE"
cd "$ROOT/repo"

echo
echo "── lanes: reach, a lane a test in another lane can break ─────────────"
# A fifth fixture repo with lanes `site` and `app` (the "*" lane). A test of the
# app bundles one file of the site, so the app lane declares `reach`: its `when`
# command reads the changed paths on stdin and exits 0 when the app lane is
# reached. A site entry that changes the bundled file carries the app lane too
# and runs the app's `reach.gate`; one that does not, and a docs-only entry,
# do not. A cleanup-only entry has no lanes, so the command is never asked.
export LOCAL_MERGE_QUEUE_CONFIG="$ROOT/reach-repos.json"
export LOCAL_MERGE_QUEUE_STATE="$ROOT/reach-state"
git init -q --bare "$ROOT/rorigin.git"
git init -q -b main "$ROOT/rrepo"
cd "$ROOT/rrepo"
git config user.email t@t.t; git config user.name T
git remote add origin "$ROOT/rorigin.git"
mkdir -p site/lib app docs scripts
echo s > site/base.txt; echo a > app/base.txt; echo d > docs/base.txt
# The table: site paths an app test bundles. Exit 0 when any changed path matches.
cat > scripts/reach.sh <<'SH'
#!/bin/bash
grep -qE '^site/lib/proof/' 
SH
git add -A && git commit -qm "base" && git push -qu origin main
cat > "$ROOT/reach-repos.json" <<JSON
{ "repos": { "r": {
  "checkout": "$ROOT/rrepo",
  "lanes": {
    "site": { "paths": ["site/"], "gate": ["echo SITE-GATE"] },
    "docs": { "paths": ["docs/"], "gate": ["echo DOCS-GATE"] },
    "app": {
      "paths": "*",
      "reach": { "when": "bash scripts/reach.sh", "gate": ["echo APP-REACH-GATE"] },
      "gate": ["echo APP-FULL-GATE"],
      "finalCheck": "echo APP-FINAL-CHECK"
    }
  }
} } }
JSON
rbranch () {  # name, then file=content pairs
  local name="$1"; shift
  git -C "$ROOT/rrepo" worktree add -q "$ROOT/rrepo-$name" -b "$name" >/dev/null 2>&1
  cd "$ROOT/rrepo-$name"
  local pair
  for pair in "$@"; do mkdir -p "$(dirname "${pair%%=*}")"; printf '%s' "${pair#*=}" > "${pair%%=*}"; done
  git add -A && git commit -qm "$name" && git push -qu origin "$name" 2>/dev/null
  cd "$ROOT/rrepo"
}
renqueue () { for b in "$@"; do (cd "$ROOT/rrepo-$b" && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1); done; $LOCAL_MERGE_QUEUE approve --all --repo r >/dev/null 2>&1; }
rlanes () { node -e 'const q=JSON.parse(require("fs").readFileSync(process.env.LOCAL_MERGE_QUEUE_STATE+"/queue.json"));const e=q.entries.find(e=>e.branch==process.argv[1]);console.log(e?e.lanes.join(",")+"|"+(e.reached||[]).join(","):"gone")' "$1"; }

rbranch site-proof site/lib/proof/merkle.ts=x
rbranch site-plain site/lib/other.ts=y
rbranch docs-only  docs/note.md=z
rbranch app-own    app/new.txt=w
rbranch site-and-docs site/lib/proof/b.ts=x docs/n2.md=q
for b in site-proof site-plain docs-only app-own site-and-docs; do (cd "$ROOT/rrepo-$b" && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1); done
check "a site file the app's tests bundle puts the app lane in the entry, as reached"   '[[ "$(rlanes site-proof)" == "site,app|app" ]]'
check "a site file nothing in the app bundles leaves the app lane out"                  '[[ "$(rlanes site-plain)" == "site|" ]]'
check "a docs-only entry keeps its one light lane"                                      '[[ "$(rlanes docs-only)" == "docs|" ]]'
check "an entry that changes the app's own paths is not reached, it is in the lane"     '[[ "$(rlanes app-own)" == "app|" ]]'
check "an entry in site and docs that also reaches the app carries all three"           '[[ "$(rlanes site-and-docs)" == "site,docs,app|app" ]]'
out=$($LOCAL_MERGE_QUEUE status r 2>&1)
check "status marks a reached lane with ~"                                              '[[ "$out" == *"site-proof [site, app~]"* && "$out" == *"site-plain [site]"* ]]'
$LOCAL_MERGE_QUEUE approve --all --repo r >/dev/null 2>&1
out=$($LOCAL_MERGE_QUEUE land r --dry-run 2>&1)
check "--dry-run shows the reached lane's reach.gate, not its full gate, for site-proof" '[[ "$out" == *"gate [app]: echo APP-REACH-GATE"* && "$out" == *"gate [app]: echo APP-FULL-GATE"* ]]'
out=$($LOCAL_MERGE_QUEUE land r 2>&1); rc=$?
check "all five land"                                                                   '[[ $rc == 0 && -f "$ROOT/rrepo/site/lib/proof/merkle.ts" && -f "$ROOT/rrepo/docs/note.md" && -f "$ROOT/rrepo/app/new.txt" ]]'
check "the reached entry ran the reach gate and its site gate, and not the full app gate for itself" '[[ "$(grep -c "gate: echo APP-REACH-GATE" <<<"$out")" == 2 ]]'
check "the entry that changed the app ran the full app gate"                            '[[ "$(grep -c "gate: echo APP-FULL-GATE" <<<"$out")" == 1 ]]'
check "docs-only ran only its docs gate"                                                '[[ "$(grep -c "gate: echo DOCS-GATE" <<<"$out")" == 2 ]]'
check "the app final check ran once, for the entry that changed the app"                '[[ "$(grep -c "^.*final check.*APP-FINAL-CHECK" <<<"$out")" == 1 ]]'

# A reach command that cannot answer counts the lane as reached: tests are not
# skipped because the question failed.
cat > "$ROOT/reach-repos.json" <<JSON
{ "repos": { "r": {
  "checkout": "$ROOT/rrepo",
  "lanes": {
    "site": { "paths": ["site/"] },
    "app": { "paths": "*", "reach": { "when": "bash scripts/no-such-script.sh" } }
  }
} } }
JSON
rbranch site-broken-reach site/lib/x.ts=x
(cd "$ROOT/rrepo-site-broken-reach" && out=$($LOCAL_MERGE_QUEUE enqueue 2>&1); echo "$out" > "$ROOT/reach-enqueue.out")
check "a reach command that cannot answer counts the lane as reached, and says so"     '[[ "$(rlanes site-broken-reach)" == "site,app|app" && "$(cat "$ROOT/reach-enqueue.out")" == *"counting the lane as reached"* ]]'
cat > "$ROOT/reach-repos.json" <<JSON
{ "repos": { "r": { "checkout": "$ROOT/rrepo", "lanes": { "app": { "paths": "*", "reach": {} } } } } }
JSON
out=$($LOCAL_MERGE_QUEUE status r 2>&1)
check "a reach with no when is a config error"                                          '[[ "$out" == *"needs a \"when\" command"* ]]'

echo
echo "── the known-red allow-list ─────────────────────────────────────────"
# A repo-level `knownRed` list: each entry a suite, an issue and an expiry. The
# queue prints it in every run, hands the honored entries to the gate steps in
# $LOCAL_MERGE_QUEUE_KNOWN_RED, and never honors an expired entry, an invalid
# one, one over the limit, or one named in the file `knownRedRefuse` points at.
export LOCAL_MERGE_QUEUE_CONFIG="$ROOT/kr-repos.json"
export LOCAL_MERGE_QUEUE_STATE="$ROOT/kr-state"
git init -q --bare "$ROOT/korigin.git"
git init -q -b main "$ROOT/krepo"
cd "$ROOT/krepo"
git config user.email t@t.t; git config user.name T
git remote add origin "$ROOT/korigin.git"
mkdir -p test && echo x > base.txt
printf '# suites that are never allowed to be red\ntest/page-write.test.mjs\n' > test/data-safety.txt
git add -A && git commit -qm "base" && git push -qu origin main
export LOCAL_MERGE_QUEUE_TODAY=2026-11-18
write_kr () {  # the knownRed JSON array
  cat > "$ROOT/kr-repos.json" <<JSON
{ "repos": { "k": {
  "checkout": "$ROOT/krepo",
  "knownRedRefuse": "test/data-safety.txt",
  "gate": ["echo KR_FILE=\${LOCAL_MERGE_QUEUE_KNOWN_RED:-unset}; test -z \"\${LOCAL_MERGE_QUEUE_KNOWN_RED:-}\" || cat \"\$LOCAL_MERGE_QUEUE_KNOWN_RED\""],
  "knownRed": $1
} } }
JSON
}
kbranch () {
  git -C "$ROOT/krepo" worktree add -q "$ROOT/krepo-$1" -b "$1" >/dev/null 2>&1
  cd "$ROOT/krepo-$1"; echo "$1" > "$1.txt"
  git add -A && git commit -qm "$1" && git push -qu origin "$1" 2>/dev/null
  cd "$ROOT/krepo"
  (cd "$ROOT/krepo-$1" && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1)
  $LOCAL_MERGE_QUEUE approve "$1" --repo k >/dev/null 2>&1
}
write_kr '[{"suite":"test/sync-first-push-resume.test.mjs","issue":"megan-holstein/proselon#1700","expires":"2026-11-25","why":"storage-epic-2 is fixing it"}]'
kbranch kr1
out=$($LOCAL_MERGE_QUEUE land k --dry-run 2>&1)
check "a dry run prints the entry, its issue, its expiry and the days left"            '[[ "$out" == *"test/sync-first-push-resume.test.mjs — megan-holstein/proselon#1700, expires 2026-11-25 (7 days)"* ]]'
check "a dry run writes nothing for the gate to read"                                   '[[ ! -e "$LOCAL_MERGE_QUEUE_STATE/known-red/k.tsv" ]]'
out=$($LOCAL_MERGE_QUEUE land k 2>&1); rc=$?
check "the land prints the list at the start and again at the end"                      '[[ $rc == 0 && "$(grep -c "known red" <<<"$out")" == 2 ]]'
check "the gate step sees the honored entries through \$LOCAL_MERGE_QUEUE_KNOWN_RED"   '[[ "$out" == *"KR_FILE=$ROOT/kr-state/known-red/k.tsv"* && "$out" == *$'"'"'test/sync-first-push-resume.test.mjs\tmegan-holstein/proselon#1700\t2026-11-25'"'"'* ]]'

# Every state that is not honored is printed, and the gate sees none of them.
write_kr '[{"suite":"test/old.test.mjs","issue":"o/r#1","expires":"2026-11-10"},{"suite":"test/page-write.test.mjs","issue":"o/r#2","expires":"2026-11-20"},{"suite":"test/far.test.mjs","issue":"o/r#3","expires":"2027-03-01"},{"suite":"test/noissue.test.mjs","expires":"2026-11-20"}]'
kbranch kr2
out=$($LOCAL_MERGE_QUEUE land k 2>&1); rc=$?
check "an expired entry is printed EXPIRED and not honored"                             '[[ "$out" == *"test/old.test.mjs — EXPIRED"* ]]'
check "a suite on the refuse list is printed REFUSED and not honored"                   '[[ "$out" == *"test/page-write.test.mjs — REFUSED"* ]]'
check "an expiry more than 30 days out is INVALID"                                      '[[ "$out" == *"test/far.test.mjs — INVALID: expiry is more than 30 days out"* ]]'
check "an entry with no issue is INVALID"                                               '[[ "$out" == *"test/noissue.test.mjs — INVALID"* ]]'
check "the gate sees no allow-list when nothing is honored"                             '[[ "$out" == *"KR_FILE=unset"* && ! -e "$ROOT/kr-state/known-red/k.tsv" ]]'
write_kr '[{"suite":"test/a.mjs","issue":"o/r#1","expires":"2026-11-20"},{"suite":"test/b.mjs","issue":"o/r#1","expires":"2026-11-20"},{"suite":"test/c.mjs","issue":"o/r#1","expires":"2026-11-20"},{"suite":"test/d.mjs","issue":"o/r#1","expires":"2026-11-20"},{"suite":"test/e.mjs","issue":"o/r#1","expires":"2026-11-20"},{"suite":"test/f.mjs","issue":"o/r#1","expires":"2026-11-20"}]'
# A refuse list that cannot be read refuses every entry, since nothing can be checked against it.
mv "$ROOT/krepo/test/data-safety.txt" "$ROOT/krepo/test/data-safety.txt.away"
write_kr '[{"suite":"test/a.mjs","issue":"o/r#1","expires":"2026-11-20"}]'
kbranch kr4
out=$($LOCAL_MERGE_QUEUE status k 2>&1)
check "a refuse list that is missing makes every entry INVALID"                         '[[ "$out" == *"test/a.mjs — INVALID: test/data-safety.txt is not in"* ]]'
mv "$ROOT/krepo/test/data-safety.txt.away" "$ROOT/krepo/test/data-safety.txt"
write_kr '[{"suite":"test/a.mjs","issue":"o/r#1","expires":"2026-11-20"},{"suite":"test/b.mjs","issue":"o/r#1","expires":"2026-11-20"},{"suite":"test/c.mjs","issue":"o/r#1","expires":"2026-11-20"},{"suite":"test/d.mjs","issue":"o/r#1","expires":"2026-11-20"},{"suite":"test/e.mjs","issue":"o/r#1","expires":"2026-11-20"},{"suite":"test/f.mjs","issue":"o/r#1","expires":"2026-11-20"}]'
kbranch kr3
out=$($LOCAL_MERGE_QUEUE status k 2>&1)
check "status prints the list; a sixth entry is over the limit"                         '[[ "$out" == *"test/e.mjs — o/r#1, expires 2026-11-20 (2 days)"* && "$out" == *"test/f.mjs — OVER-LIMIT"* ]]'
unset LOCAL_MERGE_QUEUE_TODAY

export LOCAL_MERGE_QUEUE_CONFIG="$SAVED_CONFIG" LOCAL_MERGE_QUEUE_STATE="$SAVED_STATE"
cd "$ROOT/repo"

echo
echo "── the queue file: a write is its own change, never a copy of the whole ──"
# THE DEFECT THIS GUARDS (2026-11-21). Two entries were enqueued and approved while
# `land` ran in another process; when the run ended they were gone, because the
# run had read the queue before its gate and wrote that copy back after it. A
# landing run takes minutes, so every command that writes the queue must re-read it
# under a lock and apply only its own change. A fifth fixture repo, `b`, with a
# gate that a test can hold open and then fail or pass.
SAVED_CONFIG="$LOCAL_MERGE_QUEUE_CONFIG"; SAVED_STATE="$LOCAL_MERGE_QUEUE_STATE"
export LOCAL_MERGE_QUEUE_CONFIG="$ROOT/b-repos.json"
export LOCAL_MERGE_QUEUE_STATE="$ROOT/b-state"
BLOG="$ROOT/b-gate.log"
git init -q --bare "$ROOT/borigin.git"
git init -q -b main "$ROOT/brepo"
cd "$ROOT/brepo"
git config user.email t@t.t; git config user.name T
git remote add origin "$ROOT/borigin.git"
printf 'one\ntwo\nthree\n' > shared.txt
echo base > base.txt
mkdir -p harness a b && echo prose > harness/voice.md && echo a > a/base.txt && echo b > b/base.txt
git add -A && git commit -qm "base" && git push -qu origin main
bb () {  # name, then file=content pairs (a name already used is an error of the test)
  local name="$1"; shift
  git -C "$ROOT/brepo" worktree add -q "$ROOT/brepo-$name" -b "$name" >/dev/null 2>&1
  cd "$ROOT/brepo-$name"
  local pair
  for pair in "$@"; do mkdir -p "$(dirname "${pair%%=*}")"; printf '%s' "${pair#*=}" > "${pair%%=*}"; done
  git add -A && git commit -qm "$name" && git push -qu origin "$name" 2>/dev/null
  cd "$ROOT/brepo"
}
bq () { (cd "$ROOT/brepo-$1" && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1); }
bapprove () { $LOCAL_MERGE_QUEUE approve "$@" --repo b >/dev/null 2>&1; }
# A gate that records its runs and, in the worktree named by $HOLD_MATCH, waits for
# $ROOT/gate-release (and fails if $ROOT/gate-fail exists), so a test can act on the
# queue while a gate is running.
cat > "$ROOT/hold-gate.sh" <<SH
#!/bin/bash
echo "gate-run \$(basename "\$PWD")" >> "$BLOG"
if [[ -n "\${HOLD_MATCH:-}" && "\$PWD" == *"\$HOLD_MATCH" ]]; then
  echo \$\$ > "$ROOT/gate-pid"
  touch "$ROOT/gate-started"
  for i in \$(seq 1 300); do [[ -e "$ROOT/gate-release" ]] && break; sleep 0.2; done
  [[ -e "$ROOT/gate-fail" ]] && exit 1
fi
test -f base.txt && test ! -e bad.txt && test ! -e stale.txt
SH
write_b_config () {  # extra top-level keys, e.g. '"batch": {"max": 5},'
  cat > "$ROOT/b-repos.json" <<JSON
{ "repos": { "b": {
  $1
  "checkout": "$ROOT/brepo",
  "mainBranch": "main",
  "gate": ["bash $ROOT/hold-gate.sh"],
  "finalCheck": "true",
  "protectedPaths": ["harness/"]
} } }
JSON
}
write_b_config ''
# The remote counts every push to main, and can be told to reject the next one (or every one).
cat > "$ROOT/borigin.git/hooks/pre-receive" <<SH
#!/bin/bash
while read old new ref; do
  if [ "\$ref" = refs/heads/main ]; then
    echo "\$new" >> "$ROOT/main-pushes.log"
    if [ -e "$ROOT/reject-all" ]; then echo "REJECTED BY TEST HOOK" >&2; exit 1; fi
    if [ -e "$ROOT/reject-next" ]; then rm -f "$ROOT/reject-next"; echo "REJECTED BY TEST HOOK" >&2; exit 1; fi
  fi
done
SH
chmod +x "$ROOT/borigin.git/hooks/pre-receive"
main_pushes () { local n; n=$(grep -c . "$ROOT/main-pushes.log" 2>/dev/null); echo "${n:-0}"; }
wait_for () {  # a file, for up to 40 s
  local i; for i in $(seq 1 200); do [[ -e "$1" ]] && return 0; sleep 0.2; done; return 1
}
qinfo () { node -e 'const q=JSON.parse(require("fs").readFileSync(process.env.LOCAL_MERGE_QUEUE_STATE+"/queue.json"));console.log(q.entries.map(e=>e.branch+":"+e.status).join(","))'; }
gates () { local n; n=$(grep -c '^gate-run' "$BLOG" 2>/dev/null); echo "${n:-0}"; }
clear_hold () { rm -f "$ROOT/gate-started" "$ROOT/gate-release" "$ROOT/gate-fail"; }
merge_subjects () { git -C "$ROOT/brepo" log main --merges --reverse --format=%s | sed 's/ — .*//' | tr '\n' ',' ; }

# 1. A run that STALLS while entries are enqueued, approved and ordered from another process.
bb slow-a slow-a.txt=a
bq slow-a; bapprove slow-a
HOLD_MATCH=brepo-slow-a; export HOLD_MATCH
clear_hold; : > "$BLOG"
$LOCAL_MERGE_QUEUE land b > "$ROOT/b-land.out" 2>&1 &
BG=$!
check "the held gate started" 'wait_for "$ROOT/gate-started"'
bb late-x late-x.txt=x; bb late-y late-y.txt=y
bq late-x; bapprove late-x
bq late-y
$LOCAL_MERGE_QUEUE order late-y --first --repo b >/dev/null 2>&1
touch "$ROOT/gate-fail" "$ROOT/gate-release"
wait $BG; rc=$?
check "the run stalls on the failed gate and exits 2"            '[[ $rc == 2 ]]'
check "the entry enqueued during the run is still in the queue"  '[[ "$(qinfo)" == *late-y:enqueued* ]]'
check "…with its position (ordered first)"                       '[[ "$(qinfo)" == late-y:enqueued,slow-a:stalled,late-x:approved ]]'
check "the entry approved during the run keeps its approval"     '[[ "$(qinfo)" == *late-x:approved ]]'
check "the stalled entry is recorded as stalled"                 '[[ "$(qinfo)" == *slow-a:stalled* ]]'
$LOCAL_MERGE_QUEUE dequeue slow-a --repo b >/dev/null 2>&1
$LOCAL_MERGE_QUEUE dequeue late-x --repo b >/dev/null 2>&1
$LOCAL_MERGE_QUEUE dequeue late-y --repo b >/dev/null 2>&1

# 2. A run that LANDS while the same happens, and picks up the entry approved behind it.
bb slow-c slow-c.txt=c
bq slow-c; bapprove slow-c
HOLD_MATCH=brepo-slow-c
clear_hold; : > "$BLOG"
$LOCAL_MERGE_QUEUE land b > "$ROOT/b-land.out" 2>&1 &
BG=$!
wait_for "$ROOT/gate-started"
bb pick-x pick-x.txt=x; bb pick-y pick-y.txt=y
bq pick-x; bapprove pick-x
bq pick-y
$LOCAL_MERGE_QUEUE order pick-y --first --repo b >/dev/null 2>&1
touch "$ROOT/gate-release"
wait $BG; rc=$?
out=$(cat "$ROOT/b-land.out")
check "the run ends clean"                                       '[[ $rc == 0 ]]'
check "the entry it was on landed"                               '[[ -f "$ROOT/brepo/slow-c.txt" ]]'
check "an entry approved during the run, behind it, landed too"  '[[ -f "$ROOT/brepo/pick-x.txt" ]]'
check "…and the output says it was picked up"                    '[[ "$out" == *"pick-x was approved during this run — picking it up"* ]]'
check "an entry only enqueued during the run stays, first, enqueued" '[[ "$(qinfo)" == pick-y:enqueued ]]'
$LOCAL_MERGE_QUEUE dequeue pick-y --repo b >/dev/null 2>&1

# 3. An entry unapproved or dequeued DURING the run is not landed.
bb wd-a wd-a.txt=a; bb wd-b wd-b.txt=b; bb wd-c wd-c.txt=c
for b in wd-a wd-b wd-c; do bq $b; done; bapprove wd-a wd-b wd-c
HOLD_MATCH=brepo-wd-a
clear_hold; : > "$BLOG"
$LOCAL_MERGE_QUEUE land b > "$ROOT/b-land.out" 2>&1 &
BG=$!
wait_for "$ROOT/gate-started"
$LOCAL_MERGE_QUEUE unapprove wd-b --repo b >/dev/null 2>&1
$LOCAL_MERGE_QUEUE dequeue wd-c --repo b >/dev/null 2>&1
touch "$ROOT/gate-release"
wait $BG
check "the entry on its gate still lands"                        '[[ -f "$ROOT/brepo/wd-a.txt" ]]'
check "an entry unapproved during the run is not landed"         '[[ ! -f "$ROOT/brepo/wd-b.txt" && "$(qinfo)" == wd-b:enqueued ]]'
check "an entry dequeued during the run is not landed or revived" '[[ ! -f "$ROOT/brepo/wd-c.txt" && "$(qinfo)" != *wd-c* ]]'
$LOCAL_MERGE_QUEUE dequeue wd-b --repo b >/dev/null 2>&1
# …and the entry being gated itself.
bb wd-d wd-d.txt=d; bb wd-e wd-e.txt=e
bq wd-d; bq wd-e; bapprove wd-d wd-e
HOLD_MATCH=brepo-wd-d
clear_hold
tip_before=$(git -C "$ROOT/brepo" rev-parse main)
$LOCAL_MERGE_QUEUE land b > "$ROOT/b-land.out" 2>&1 &
BG=$!
wait_for "$ROOT/gate-started"
$LOCAL_MERGE_QUEUE dequeue wd-d --repo b >/dev/null 2>&1
touch "$ROOT/gate-release"
wait $BG
out=$(cat "$ROOT/b-land.out")
check "the entry dequeued while gated is not landed"             '[[ ! -f "$ROOT/brepo/wd-d.txt" && "$out" == *"wd-d was dequeued during this run — not landing it"* ]]'
check "…and the entry behind it still lands"                     '[[ -f "$ROOT/brepo/wd-e.txt" ]]'
bb wd-f wd-f.txt=f; bq wd-f; bapprove wd-f
HOLD_MATCH=brepo-wd-f
clear_hold
$LOCAL_MERGE_QUEUE land b > "$ROOT/b-land.out" 2>&1 &
BG=$!
wait_for "$ROOT/gate-started"
$LOCAL_MERGE_QUEUE unapprove wd-f --repo b >/dev/null 2>&1
touch "$ROOT/gate-release"
wait $BG
out=$(cat "$ROOT/b-land.out")
check "the entry unapproved while gated is not landed, and stays enqueued" '[[ ! -f "$ROOT/brepo/wd-f.txt" && "$(qinfo)" == wd-f:enqueued && "$out" == *"wd-f was unapproved during this run"* ]]'
$LOCAL_MERGE_QUEUE dequeue wd-f --repo b >/dev/null 2>&1
unset HOLD_MATCH; clear_hold

# 4. Several processes enqueue at once: none is lost.
for n in 1 2 3 4 5 6; do bb par$n par$n.txt=$n; done
for n in 1 2 3 4 5 6; do bq par$n & done
wait
check "six enqueues racing leave six entries"                    '[[ "$(qinfo | tr "," "\n" | grep -c "^par")" == 6 ]]'
for n in 1 2 3 4 5 6; do $LOCAL_MERGE_QUEUE approve par$n --repo b >/dev/null 2>&1 & done
wait
check "…and six racing approvals approve all six"                '[[ "$(qinfo | tr "," "\n" | grep -c "^par.*:approved")" == 6 ]]'
$LOCAL_MERGE_QUEUE land b >/dev/null 2>&1
check "…and all six land"                                        '[[ "$(qinfo)" == "" && -f "$ROOT/brepo/par6.txt" ]]'

# 5. A lock whose holder is dead cannot keep the queue.
mkdir -p "$LOCAL_MERGE_QUEUE_STATE"
bb lock-a lock-a.txt=a; bq lock-a
dead=$(sh -c 'echo $$')
mkdir "$LOCAL_MERGE_QUEUE_STATE/queue.lock"
echo "{\"pid\":$dead,\"since\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\"}" > "$LOCAL_MERGE_QUEUE_STATE/queue.lock/owner.json"
out=$($LOCAL_MERGE_QUEUE approve lock-a --repo b 2>&1); rc=$?
check "a lock held by a dead process is broken, and the command runs" '[[ $rc == 0 && "$out" == *"broke a stale queue lock"* && "$(qinfo)" == lock-a:approved ]]'
check "…and the lock is released afterwards"                     '[[ ! -e "$LOCAL_MERGE_QUEUE_STATE/queue.lock" ]]'
$LOCAL_MERGE_QUEUE unapprove lock-a --repo b >/dev/null 2>&1
mkdir "$LOCAL_MERGE_QUEUE_STATE/queue.lock"; touch -t 202001010000 "$LOCAL_MERGE_QUEUE_STATE/queue.lock"
out=$($LOCAL_MERGE_QUEUE approve lock-a --repo b 2>&1); rc=$?
check "a lock with no owner file, long untouched, is broken"     '[[ $rc == 0 && "$(qinfo)" == lock-a:approved ]]'
$LOCAL_MERGE_QUEUE unapprove lock-a --repo b >/dev/null 2>&1
mkdir "$LOCAL_MERGE_QUEUE_STATE/queue.lock"
echo "{\"pid\":$$,\"since\":\"2020-01-01T00:00:00.000Z\"}" > "$LOCAL_MERGE_QUEUE_STATE/queue.lock/owner.json"
out=$(LOCAL_MERGE_QUEUE_LOCK_WAIT_MS=700 $LOCAL_MERGE_QUEUE approve lock-a --repo b 2>&1); rc=$?
check "a lock a LIVE process has held for hours is never broken; the message names its pid and age" '[[ $rc != 0 && "$out" == *"stayed locked"*"pid $$, alive and holding it for"* && -d "$LOCAL_MERGE_QUEUE_STATE/queue.lock" && "$(qinfo)" == lock-a:enqueued ]]'
rm -r "$LOCAL_MERGE_QUEUE_STATE/queue.lock"
mkdir "$LOCAL_MERGE_QUEUE_STATE/queue.lock"
echo "{\"pid\":$$,\"since\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\"}" > "$LOCAL_MERGE_QUEUE_STATE/queue.lock/owner.json"
out=$(LOCAL_MERGE_QUEUE_LOCK_WAIT_MS=700 $LOCAL_MERGE_QUEUE approve lock-a --repo b 2>&1); rc=$?
check "a fresh lock held by a live process is respected, not broken" '[[ $rc != 0 && "$out" == *"stayed locked"* && -d "$LOCAL_MERGE_QUEUE_STATE/queue.lock" && "$(qinfo)" == lock-a:enqueued ]]'
rm -r "$LOCAL_MERGE_QUEUE_STATE/queue.lock"
# A queue file that cannot be read stops the command; it is never read as empty.
cp "$LOCAL_MERGE_QUEUE_STATE/queue.json" "$ROOT/b-queue.saved"
echo '{ not json' > "$LOCAL_MERGE_QUEUE_STATE/queue.json"
out=$($LOCAL_MERGE_QUEUE approve lock-a --repo b 2>&1); rc=$?
check "an unreadable queue file is refused, not replaced"        '[[ $rc != 0 && "$out" == *"cannot be read"* && "$(cat "$LOCAL_MERGE_QUEUE_STATE/queue.json")" == "{ not json" && ! -e "$LOCAL_MERGE_QUEUE_STATE/queue.lock" ]]'
cp "$ROOT/b-queue.saved" "$LOCAL_MERGE_QUEUE_STATE/queue.json"
$LOCAL_MERGE_QUEUE dequeue lock-a --repo b >/dev/null 2>&1

echo
echo "── batched landing: one gate for several entries ───────────────────────"
# The mode is opt-in (`"batch": {"max": N}` on the repo, `--batch` / `--no-batch`
# on the run). The sections above ran with it off; these exercise it.
write_b_config ''
bb off-1 off-1.txt=1; bb off-2 off-2.txt=2
bq off-1; bq off-2; bapprove off-1 off-2
: > "$BLOG"
out=$($LOCAL_MERGE_QUEUE land b 2>&1)
check "batching is off by default: two entries, two gate runs"    '[[ "$(gates)" == 2 && "$out" != *batch* ]]'

write_b_config '"batch": {"max": 5},'
bb nb-1 nb-1.txt=1; bb nb-2 nb-2.txt=2
bq nb-1; bq nb-2; bapprove nb-1 nb-2
: > "$BLOG"
out=$($LOCAL_MERGE_QUEUE land b --no-batch 2>&1)
check "--no-batch overrides the config: two gate runs"           '[[ "$(gates)" == 2 && "$out" != *"batch gated"* ]]'

write_b_config ''
bb fl-1 fl-1.txt=1; bb fl-2 fl-2.txt=2
bq fl-1; bq fl-2; bapprove fl-1 fl-2
: > "$BLOG"
out=$($LOCAL_MERGE_QUEUE land b --batch 2>&1)
check "--batch turns it on where the config has no batch key"    '[[ "$(gates)" == 1 && "$out" == *"gated together in one batch, landed in one push: fl-1, fl-2"* ]]'
out=$($LOCAL_MERGE_QUEUE land b --batch --no-batch 2>&1); rc=$?
check "--batch with --no-batch is refused"                       '[[ $rc != 0 && "$out" == *"not both"* ]]'
write_b_config '"batch": {"max": 1},'
out=$($LOCAL_MERGE_QUEUE status 2>&1); rc=$?
check "a batch max below 2 is a config error naming the key"     '[[ $rc != 0 && "$out" == *"\"batch\""* ]]'

# A green batch of three: three merge commits in order, one gate run.
write_b_config '"batch": {"max": 5},'
bb g-1 g-1.txt=1; bb g-2 g-2.txt=2; bb g-3 g-3.txt=3
for b in g-1 g-2 g-3; do (cd "$ROOT/brepo-$b" && $LOCAL_MERGE_QUEUE enqueue --note "note of $b" >/dev/null 2>&1); done
bapprove g-1 g-2 g-3
merges_before=$(git -C "$ROOT/brepo" rev-list --count --merges main)
o_before=$(git -C "$ROOT/borigin.git" rev-parse main)
: > "$BLOG"
dry=$($LOCAL_MERGE_QUEUE land b --dry-run 2>&1)
check "--dry-run shows the batch it would form and the gates it would run" '[[ "$dry" == *"batch"*"3 entries gated together, one gate run: g-1, g-2, g-3"* && "$dry" == *"gate [b]: bash "*hold-gate.sh* ]]'
check "--dry-run runs no gate and moves nothing"                 '[[ "$(gates)" == 0 && "$(git -C "$ROOT/brepo" rev-parse main)" == "$o_before" ]]'
out=$($LOCAL_MERGE_QUEUE land b 2>&1); rc=$?
[[ -n "${LOCAL_MERGE_QUEUE_TEST_DEBUG:-}" ]] && { echo "--- batch land output ---"; echo "$out"; echo "---"; }
cd "$ROOT/brepo"
check "a green batch of three exits 0"                           '[[ $rc == 0 ]]'
check "…runs the gate once"                                      '[[ "$(gates)" == 1 ]]'
check "…lands three merge commits"                               '[[ $(git rev-list --count --merges main) == $((merges_before + 3)) ]]'
check "…in queue order"                                          '[[ "$(merge_subjects)" == *"Merge g-1,Merge g-2,Merge g-3," ]]'
check "…each carrying its own note, as when landed singly"       '[[ "$(git log main --merges -3 --format=%s)" == *"Merge g-1 — note of g-1"* ]]'
check "…with all three files on main, and origin matching"       '[[ -f g-1.txt && -f g-2.txt && -f g-3.txt && "$(git rev-parse main)" == "$(git -C "$ROOT/borigin.git" rev-parse main)" ]]'
check "…and every worktree and branch cleaned up"                '[[ ! -d "$ROOT/brepo-g-1" && ! -d "$ROOT/brepo-g-3" ]] && ! git rev-parse --verify -q refs/heads/g-2 >/dev/null && ! git -C "$ROOT/borigin.git" rev-parse --verify -q refs/heads/g-3 >/dev/null'
check "…the output says which entries were gated together, and that they landed in one push" '[[ "$out" == *"gated together in one batch, landed in one push: g-1, g-2, g-3"* && "$out" == *"landed 3 entries on main in one push"* ]]'
check "…and says the intermediate merges were not gated on their own" '[[ "$out" == *"final tree was gated once"*"not gated on their own"* ]]'
check "…and the final check ran once"                            '[[ "$(grep -c "final check passed" <<<"$out")" == 1 ]]'
check "…and the queue is empty"                                  '[[ "$(qinfo)" == "" ]]'
check "the batch changed exactly the three files, and nothing else" '[[ "$(git -C "$ROOT/brepo" diff --name-only "$o_before" main | tr "\n" " ")" == "g-1.txt g-2.txt g-3.txt " ]]'
check "the batch left no mark behind on the queue"               '! grep -q "\"batch\"" "$LOCAL_MERGE_QUEUE_STATE/queue.json"'

# A batch whose second entry fails the gate: falls back, lands the first, stalls the second, leaves the third approved.
write_b_config '"batch": {"max": 5},'
bb f-1 f-1.txt=1; bb f-2 f-2.txt=2 bad.txt=x; bb f-3 f-3.txt=3
for b in f-1 f-2 f-3; do bq $b; done; bapprove f-1 f-2 f-3
f2o=$(git -C "$ROOT/borigin.git" rev-parse refs/heads/f-2); f3o=$(git -C "$ROOT/borigin.git" rev-parse refs/heads/f-3)
: > "$BLOG"
out=$($LOCAL_MERGE_QUEUE land b 2>&1); rc=$?
cd "$ROOT/brepo"
check "a red candidate says the batch failed and the run fell back" '[[ "$out" == *"BATCH FAILED: the gate failed on the candidate"* && "$out" == *"Falling back to landing f-1, f-2, f-3 one at a time"* ]]'
check "…the entry before the failure landed"                     '[[ -f f-1.txt ]]'
check "…the failing entry is the one that stalled, and exit is 2" '[[ $rc == 2 && "$(qinfo)" == "f-2:stalled,f-3:approved" ]]'
check "…the entry after it was left approved and unlanded"       '[[ ! -f f-3.txt && ! -f f-2.txt ]]'
check "…nothing of the failed batch was pushed first"            '[[ "$(git -C "$ROOT/borigin.git" rev-parse refs/heads/f-2)" == "$f2o" && "$(git -C "$ROOT/borigin.git" rev-parse refs/heads/f-3)" == "$f3o" ]]'
check "…the gate ran on the candidate, then on each entry alone" '[[ "$(gates)" == 3 ]]'
check "…and the stall report names the gate"                     'grep -q "gate failed after rebase" "$LOCAL_MERGE_QUEUE_STATE/reports/b-f-2.md"'
$LOCAL_MERGE_QUEUE dequeue f-2 --repo b >/dev/null 2>&1
: > "$BLOG"
$LOCAL_MERGE_QUEUE land b >/dev/null 2>&1
check "the third lands alone once the stall is cleared"          '[[ -f "$ROOT/brepo/f-3.txt" && "$(gates)" == 1 ]]'

# A conflict between two entries of a batch: nothing gated, nothing pushed, fallback, the second stalls.
bb k-1 shared.txt=$'one\nFIRST\nthree\n'; bb k-2 shared.txt=$'one\nSECOND\nthree\n'; bb k-3 k-3.txt=3
for b in k-1 k-2 k-3; do bq $b; done; bapprove k-1 k-2 k-3
: > "$BLOG"
out=$($LOCAL_MERGE_QUEUE land b 2>&1); rc=$?
cd "$ROOT/brepo"
check "a conflict inside the batch fails it before any gate"     '[[ "$out" == *"BATCH FAILED: k-2 conflicts with the entries before it in shared.txt"* ]]'
check "…the first lands one at a time, the second stalls on the conflict" '[[ $rc == 2 && "$(grep -c FIRST shared.txt)" == 1 && "$(qinfo)" == "k-2:stalled,k-3:approved" ]]'
check "…the gate ran only for the entry that landed"             '[[ "$(gates)" == 1 ]]'
check "…and the report tells the fixer to finish the rebase"     'grep -q "git rebase --continue" "$LOCAL_MERGE_QUEUE_STATE/reports/b-k-2.md"'
$LOCAL_MERGE_QUEUE dequeue k-2 --repo b >/dev/null 2>&1; $LOCAL_MERGE_QUEUE dequeue k-3 --repo b >/dev/null 2>&1
# …and a conflict in a protected path is still the owner's call.
bb p-1 harness/voice.md=$'first prose\n'; bb p-2 harness/voice.md=$'second prose\n'
bq p-1; bq p-2; bapprove p-1 p-2
out=$($LOCAL_MERGE_QUEUE land b 2>&1); rc=$?
check "a protected-path conflict in a batch names the owner's call" '[[ "$out" == *"a protected path: the owner"* ]]'
check "…and the fallback stall still says OWNER DECISION REQUIRED" '[[ $rc == 2 ]] && grep -q "OWNER DECISION REQUIRED" "$LOCAL_MERGE_QUEUE_STATE/reports/b-p-2.md"'
$LOCAL_MERGE_QUEUE dequeue p-2 --repo b >/dev/null 2>&1

# A batch stops at an entry that is not approved, is --no-rebase, or is capped by max.
write_b_config '"batch": {"max": 2},'
bb m-1 m-1.txt=1; bb m-2 m-2.txt=2; bb m-3 m-3.txt=3
for b in m-1 m-2 m-3; do bq $b; done; bapprove m-1 m-2 m-3
: > "$BLOG"
out=$($LOCAL_MERGE_QUEUE land b 2>&1)
check "max caps a batch: three entries with max 2 run two gates" '[[ "$(gates)" == 2 && "$out" == *"gated together in one batch, landed in one push: m-1, m-2"* && -f "$ROOT/brepo/m-3.txt" ]]'
write_b_config '"batch": {"max": 5},'
bb s-1 s-1.txt=1; bb s-2 s-2.txt=2; bb s-3 s-3.txt=3
for b in s-1 s-2 s-3; do bq $b; done; bapprove s-1 s-3
: > "$BLOG"
out=$($LOCAL_MERGE_QUEUE land b 2>&1)
check "a batch stops at an entry that is not approved"           '[[ "$(gates)" == 2 && -f "$ROOT/brepo/s-1.txt" && -f "$ROOT/brepo/s-3.txt" && "$out" != *"batch gated"* ]]'
$LOCAL_MERGE_QUEUE dequeue s-2 --repo b >/dev/null 2>&1
bb r-1 r-1.txt=1; bb r-2 r-2.txt=2; bb r-3 r-3.txt=3
bq r-1; (cd "$ROOT/brepo-r-2" && $LOCAL_MERGE_QUEUE enqueue --no-rebase >/dev/null 2>&1); bq r-3; bapprove r-1 r-2 r-3
: > "$BLOG"
out=$($LOCAL_MERGE_QUEUE land b 2>&1)
check "a batch stops at a --no-rebase entry, which is then handled as today" '[[ "$out" != *"batch gated"* && "$out" == *"main moved under a --no-rebase branch"* && "$(qinfo)" == "r-2:stalled,r-3:approved" ]]'
$LOCAL_MERGE_QUEUE dequeue r-2 --repo b >/dev/null 2>&1; $LOCAL_MERGE_QUEUE dequeue r-3 --repo b >/dev/null 2>&1
# A branch that already merged main into itself is not batched, and not rebased.
bb mm-1 mm-1.txt=1; bb mm-2 mm-2.txt=2
( cd "$ROOT/brepo" && echo "moved" >> base.txt && git commit -qam "main moves" && git push -q origin main )
( cd "$ROOT/brepo-mm-2" && git fetch -q origin && git merge -q --no-ff origin/main -m "mm-2 merges main" >/dev/null 2>&1 && git push -q origin mm-2 2>/dev/null )
bq mm-1; bq mm-2; bapprove mm-1 mm-2
out=$($LOCAL_MERGE_QUEUE land b --dry-run 2>&1)
check "a branch that carries merge commits is not batched"       '[[ "$out" != *"gated together"* ]]'
$LOCAL_MERGE_QUEUE land b >/dev/null 2>&1

# An entry unapproved while the batch is gated is not landed; the entry behind it is gated on its own.
bb u-1 u-1.txt=1; bb u-2 u-2.txt=2; bb u-3 u-3.txt=3
for b in u-1 u-2 u-3; do bq $b; done; bapprove u-1 u-2 u-3
HOLD_MATCH=/batch/b; export HOLD_MATCH
clear_hold; : > "$BLOG"
$LOCAL_MERGE_QUEUE land b > "$ROOT/b-land.out" 2>&1 &
BG=$!
check "the batch gate started in the batch worktree" 'wait_for "$ROOT/gate-started"'
check "the queue says which entries are gated together" '[[ "$($LOCAL_MERGE_QUEUE status b 2>&1)" == *"gated together with: u-2, u-3"* ]]'
$LOCAL_MERGE_QUEUE unapprove u-2 --repo b >/dev/null 2>&1
touch "$ROOT/gate-release"
wait $BG
out=$(cat "$ROOT/b-land.out")
unset HOLD_MATCH; clear_hold
check "an entry unapproved while its batch is gated fails the batch (nothing landed)" '[[ "$out" == *"BATCH FAILED: u-2 was unapproved while the batch was gated"* ]]'
check "…and is not landed, and stays enqueued"                   '[[ ! -f "$ROOT/brepo/u-2.txt" && "$(qinfo)" == u-2:enqueued ]]'
check "…while the other two are gated one at a time and land"    '[[ -f "$ROOT/brepo/u-1.txt" && -f "$ROOT/brepo/u-3.txt" && "$(gates)" == 3 ]]'
$LOCAL_MERGE_QUEUE dequeue u-2 --repo b >/dev/null 2>&1

# The deploy marker still follows the batch: all merges but the last carry it.
write_b_config '"batch": {"max": 5}, "deploy": { "skipMarker": "[skip-deploy]" },'
bb d-1 d-1.txt=1; bb d-2 d-2.txt=2; bb d-3 d-3.txt=3
for b in d-1 d-2 d-3; do bq $b; done; bapprove d-1 d-2 d-3
: > "$BLOG"
$LOCAL_MERGE_QUEUE land b >/dev/null 2>&1
dsub () { git -C "$ROOT/brepo" log main --format=%s | grep -m1 -E "^Merge $1( |\$)"; }
check "a batch of three: one gate, first two merges marked, last unmarked" '[[ "$(gates)" == 1 && "$(dsub d-1)" == *"[skip-deploy]"* && "$(dsub d-2)" == *"[skip-deploy]"* && "$(dsub d-3)" != *"[skip-deploy]"* ]]'
check "…and no redeploy commit was needed"                       '[[ -z "$(git -C "$ROOT/brepo" log main --format=%s --grep="^Redeploy")" ]]'

echo
echo "── batched landing across lanes: only entries with the same lanes batch ──"
# Lane a and lane b each have their own gate; `rest` takes the rest. An entry in b
# must not wait for a gate of lane a it does not carry, so a batch holds only
# entries whose lanes (and reached lanes) are the same as the first entry's.
cat > "$ROOT/b-repos.json" <<JSON
{ "repos": { "b": {
  "checkout": "$ROOT/brepo",
  "batch": { "max": 5 },
  "lanes": {
    "a":    { "paths": ["a/"], "gate": ["echo gate-a >> $BLOG"] },
    "b":    { "paths": ["b/"], "gate": ["echo gate-b >> $BLOG"] },
    "rest": { "paths": "*",    "gate": ["echo gate-rest >> $BLOG"] }
  }
} } }
JSON
bb la-1 a/la-1.txt=1; bb la-2 a/la-2.txt=2; bb lb-1 b/lb-1.txt=1; bb la-3 a/la-3.txt=3; bb lb-2 b/lb-2.txt=2
for b in la-1 la-2 lb-1 la-3 lb-2; do bq $b; done; bapprove la-1 la-2 lb-1 la-3 lb-2
: > "$BLOG"
dry=$($LOCAL_MERGE_QUEUE land b --dry-run 2>&1)
check "--dry-run batches la-1 and la-2 and stops at the b entry" '[[ "$dry" == *"2 entries gated together, one gate run: la-1, la-2"* && "$dry" != *"la-1, la-2, lb-1"* ]]'
check "…showing only lane a's gate for that batch"               '[[ "$(grep -A2 "gated together" <<<"$dry" | grep -c "gate \[")" == 1 ]]'
out=$($LOCAL_MERGE_QUEUE land b 2>&1); rc=$?
check "the run lands all five"                                   '[[ $rc == 0 && "$(qinfo)" == "" && -f "$ROOT/brepo/a/la-3.txt" && -f "$ROOT/brepo/b/lb-2.txt" ]]'
check "the a-lane batch ran lane a's gate once; b entries ran only lane b's" '[[ "$(sed -n 1p "$BLOG")" == gate-a && "$(grep -c gate-a "$BLOG")" == 2 && "$(grep -c gate-b "$BLOG")" == 2 && "$(grep -c gate-rest "$BLOG")" == 0 ]]'
check "…five entries cost four gates, none of them a lane the entry lacks" '[[ "$(grep -c . "$BLOG")" == 4 ]]'
check "…and la-1 and la-2 were gated together"                   '[[ "$out" == *"gated together in one batch, landed in one push: la-1, la-2"* ]]'

echo
echo "── the locks: owned by a token, created whole, never broken under a live holder ──"
# THE DEFECT (reviewer, 2026-11-21): two processes judge a dead holder's lock stale;
# one breaks it and takes a new lock; the other then renames the NEW lock away and
# deletes it, and a release deleted whichever lock was there. 7 of 60 trials of 16
# concurrent approvals lost writes. A lock now carries a token: a release removes
# only its own, a breaker removes only the lock it judged stale, and a live holder
# is never broken.
LR_STATE="$ROOT/lr-state"
lr_queue () {  # N entries, all enqueued
  node -e 'const n=+process.argv[1];const e=[];for(let i=0;i<n;i++)e.push({repo:"b",branch:"lr"+i,worktree:"/x",status:"enqueued",lanes:[],reached:[]});require("fs").writeFileSync(process.argv[2],JSON.stringify({entries:e},null,2))' "$1" "$LR_STATE/queue.json"
}
lr_approved () { node -e 'const q=require(process.argv[1]);console.log(q.entries.filter(e=>e.status==="approved").length+"/"+q.entries.length)' "$LR_STATE/queue.json"; }
lost=0; trials=100
for t in $(seq 1 $trials); do
  rm -rf "$LR_STATE"; mkdir -p "$LR_STATE"; lr_queue 16
  dead=$(sh -c 'echo $$')
  mkdir "$LR_STATE/queue.lock"
  if (( t % 2 )); then tok=''; else tok=',"token":"dead-holder-token"'; fi
  echo "{\"pid\":$dead$tok,\"since\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\"}" > "$LR_STATE/queue.lock/owner.json"
  for i in $(seq 0 15); do LOCAL_MERGE_QUEUE_STATE="$LR_STATE" $LOCAL_MERGE_QUEUE approve lr$i --repo b >/dev/null 2>&1 & done
  wait
  [[ "$(lr_approved)" == 16/16 && ! -e "$LR_STATE/queue.lock" ]] || { lost=$((lost + 1)); echo "    trial $t: $(lr_approved), lock: $(ls "$LR_STATE" | tr '\n' ' ')"; }
done
check "a planted dead-holder lock and 16 concurrent approvals, 100 trials: no write lost, no lock left" '[[ $lost == 0 ]]'

# A release never deletes a lock that is not its own.
rm -rf "$LR_STATE"; mkdir -p "$LR_STATE"; lr_queue 1
rm -f "$ROOT/pause-release"
LOCAL_MERGE_QUEUE_STATE="$LR_STATE" LOCAL_MERGE_QUEUE_TEST_PAUSE_IN_LOCK="$ROOT/pause-release" $LOCAL_MERGE_QUEUE approve lr0 --repo b >/dev/null 2>&1 &
BG=$!
for i in $(seq 1 100); do [[ -f "$LR_STATE/queue.lock/owner.json" ]] && break; sleep 0.1; done
check "a held queue lock records its holder's token" 'grep -q "\"token\":\"$BG-" "$LR_STATE/queue.lock/owner.json"'
# …somebody else now holds the lock (its holder was judged gone and broken, and another took over).
echo "{\"pid\":$$,\"token\":\"someone-elses-token\",\"since\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\"}" > "$LR_STATE/queue.lock/owner.json"
touch "$ROOT/pause-release"; wait $BG
check "a release does not delete the lock another process took over" '[[ -d "$LR_STATE/queue.lock" ]] && grep -q someone-elses-token "$LR_STATE/queue.lock/owner.json"'
rm -rf "$LR_STATE/queue.lock" "$ROOT/pause-release"

# The repository's landing lock is the same lock: whole, token-owned, and left alone when it is not ours.
write_b_config ''
bb tk-a tk-a.txt=a; bq tk-a; bapprove tk-a
HOLD_MATCH=brepo-tk-a; export HOLD_MATCH; clear_hold
$LOCAL_MERGE_QUEUE land b > "$ROOT/b-land.out" 2>&1 &
BG=$!
wait_for "$ROOT/gate-started"
check "the landing lock records pid and token"                    'grep -q "\"pid\":$BG" "$LOCAL_MERGE_QUEUE_STATE/locks/b/owner.json" && grep -q "\"token\":\"$BG-" "$LOCAL_MERGE_QUEUE_STATE/locks/b/owner.json"'
out=$($LOCAL_MERGE_QUEUE status b 2>&1)
check "status shows LOCKED for a live holder, with its pid and age" '[[ "$out" == *"LOCKED by pid $BG"* ]]'
out=$($LOCAL_MERGE_QUEUE land b 2>&1); rc=$?
check "a second land is refused while the holder is alive"        '[[ $rc != 0 && "$out" == *"being landed already (pid $BG"* ]]'
echo "{\"pid\":$$,\"token\":\"someone-elses-token\",\"since\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\"}" > "$LOCAL_MERGE_QUEUE_STATE/locks/b/owner.json"
touch "$ROOT/gate-release"; wait $BG
unset HOLD_MATCH; clear_hold
check "the landing run does not delete a landing lock it no longer owns" '[[ -d "$LOCAL_MERGE_QUEUE_STATE/locks/b" ]] && grep -q someone-elses-token "$LOCAL_MERGE_QUEUE_STATE/locks/b/owner.json"'
rm -rf "$LOCAL_MERGE_QUEUE_STATE/locks/b"
# A landing lock whose holder is dead is debris: status does not call it LOCKED, and the next land clears it.
dead=$(sh -c 'echo $$')
mkdir -p "$LOCAL_MERGE_QUEUE_STATE/locks/b"
echo "{\"pid\":$dead,\"since\":\"2026-01-01T00:00:00.000Z\"}" > "$LOCAL_MERGE_QUEUE_STATE/locks/b/owner.json"
bb tk-b tk-b.txt=b; bq tk-b; bapprove tk-b
out=$($LOCAL_MERGE_QUEUE status b 2>&1)
check "status does not show LOCKED for a lock whose holder is dead" '[[ "$out" != *LOCKED* && "$out" == *"died holding the lock"* ]]'
out=$($LOCAL_MERGE_QUEUE land b 2>&1)
check "the next land breaks it and lands"                         '[[ "$out" == *"breaking a stale lock left by pid $dead"* && -f "$ROOT/brepo/tk-b.txt" && ! -e "$LOCAL_MERGE_QUEUE_STATE/locks/b" ]]'
# dequeue and order resolve the name before taking the lock: a name that is not there answers at once, with the lock held.
mkdir "$LOCAL_MERGE_QUEUE_STATE/queue.lock"
echo "{\"pid\":$$,\"token\":\"held-for-the-test\",\"since\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\"}" > "$LOCAL_MERGE_QUEUE_STATE/queue.lock/owner.json"
out=$(LOCAL_MERGE_QUEUE_LOCK_WAIT_MS=700 $LOCAL_MERGE_QUEUE dequeue no-such-branch --repo b 2>&1)
check "dequeue resolves the name without the queue lock"         '[[ "$out" == *"is not in the queue"* && "$out" != *"stayed locked"* ]]'
out=$(LOCAL_MERGE_QUEUE_LOCK_WAIT_MS=700 $LOCAL_MERGE_QUEUE order no-such-branch --first --repo b 2>&1)
check "order resolves the name without the queue lock"           '[[ "$out" == *"is not in the queue"* && "$out" != *"stayed locked"* ]]'
rm -rf "$LOCAL_MERGE_QUEUE_STATE/queue.lock"

echo
echo "── the queue file: a previous copy, a flushed write, no stale temporaries ──"
bb pv-a pv-a.txt=a; bq pv-a
check "a write keeps the copy it replaced as queue.json.prev"    '[[ -f "$LOCAL_MERGE_QUEUE_STATE/queue.json.prev" ]] && node -e "JSON.parse(require(\"fs\").readFileSync(\"$LOCAL_MERGE_QUEUE_STATE/queue.json.prev\"))"'
bapprove pv-a
check "…and it is the copy before the last write"                '[[ "$(node -e "console.log(JSON.parse(require(\"fs\").readFileSync(\"$LOCAL_MERGE_QUEUE_STATE/queue.json.prev\")).entries.map(e=>e.status).join())")" == enqueued ]]'
cp "$LOCAL_MERGE_QUEUE_STATE/queue.json" "$ROOT/b-queue.good"
echo '{ broken' > "$LOCAL_MERGE_QUEUE_STATE/queue.json"
out=$($LOCAL_MERGE_QUEUE approve pv-a --repo b 2>&1); rc=$?
check "an unreadable queue names the previous copy and the exact command to restore it, and restores nothing" '[[ $rc != 0 && "$out" == *"previous good copy is $LOCAL_MERGE_QUEUE_STATE/queue.json.prev"* && "$out" == *"cp \"$LOCAL_MERGE_QUEUE_STATE/queue.json.prev\" \"$LOCAL_MERGE_QUEUE_STATE/queue.json\""* && "$(cat "$LOCAL_MERGE_QUEUE_STATE/queue.json")" == "{ broken" ]]'
cp "$ROOT/b-queue.good" "$LOCAL_MERGE_QUEUE_STATE/queue.json"
echo x > "$LOCAL_MERGE_QUEUE_STATE/queue.json.tmp-99999"; touch -t 202001010000 "$LOCAL_MERGE_QUEUE_STATE/queue.json.tmp-99999"
echo x > "$LOCAL_MERGE_QUEUE_STATE/queue.json.tmp-99998"
mkdir "$LOCAL_MERGE_QUEUE_STATE/queue.lock.new-1-ab"; touch -t 202001010000 "$LOCAL_MERGE_QUEUE_STATE/queue.lock.new-1-ab"
echo x > "$LOCAL_MERGE_QUEUE_STATE/unrelated.tmp-99997"; touch -t 202001010000 "$LOCAL_MERGE_QUEUE_STATE/unrelated.tmp-99997"
$LOCAL_MERGE_QUEUE unapprove pv-a --repo b >/dev/null 2>&1
check "a temporary file older than an hour is removed, by exact pattern" '[[ ! -e "$LOCAL_MERGE_QUEUE_STATE/queue.json.tmp-99999" && ! -e "$LOCAL_MERGE_QUEUE_STATE/queue.lock.new-1-ab" ]]'
check "…a recent one and a file of another name are left alone"  '[[ -e "$LOCAL_MERGE_QUEUE_STATE/queue.json.tmp-99998" && -e "$LOCAL_MERGE_QUEUE_STATE/unrelated.tmp-99997" ]]'
rm -f "$LOCAL_MERGE_QUEUE_STATE/queue.json.tmp-99998" "$LOCAL_MERGE_QUEUE_STATE/unrelated.tmp-99997"
$LOCAL_MERGE_QUEUE dequeue pv-a --repo b >/dev/null 2>&1

echo
echo "── a batch lands atomically: one gate, one push, and the failures that leave nothing ──"
write_b_config '"batch": {"max": 5},'
# THE PAIR: the gate is red for a without b (they depend on each other). Landed
# one at a time the first would fail. In a batch the gate sees both, and the remote
# never sees a state with a and not b, because main is pushed once.
cat > "$ROOT/pair-gate.sh" <<SH
#!/bin/bash
echo "gate-run \$(basename "\$PWD")" >> "$BLOG"
if [ -f pair-a.txt ] && [ ! -f pair-b.txt ]; then echo "GATE RED: a without b"; exit 1; fi
test -f base.txt
SH
cat > "$ROOT/b-repos.json" <<JSON
{ "repos": { "b": { "checkout": "$ROOT/brepo", "batch": {"max": 5}, "gate": ["bash $ROOT/pair-gate.sh"], "finalCheck": "true" } } }
JSON
bb pair-a pair-a.txt=a; bb pair-b pair-b.txt=b
bq pair-a; bq pair-b; bapprove pair-a pair-b
: > "$BLOG"; : > "$ROOT/main-pushes.log"
before=$(git -C "$ROOT/borigin.git" rev-parse main)
out=$($LOCAL_MERGE_QUEUE land b 2>&1); rc=$?
check "a pair that is red alone and green together lands as a batch" '[[ $rc == 0 && -f "$ROOT/brepo/pair-a.txt" && -f "$ROOT/brepo/pair-b.txt" && "$out" != *"GATE RED"* ]]'
check "…the gate ran once, on both"                              '[[ "$(gates)" == 1 ]]'
check "…and main was pushed to origin exactly once"              '[[ "$(main_pushes)" == 1 ]]'
check "…so every state origin ever held as main has both a and b"  'while read c; do git -C "$ROOT/borigin.git" ls-tree -r --name-only $c | grep -q pair-a && git -C "$ROOT/borigin.git" ls-tree -r --name-only $c | grep -q pair-b || exit 1; done < "$ROOT/main-pushes.log"'
check "…the pushed commit is the one the gate ran on"            '[[ "$(git -C "$ROOT/borigin.git" rev-parse main)" == "$(git -C "$ROOT/brepo" rev-parse main)" && "$(tail -1 "$ROOT/main-pushes.log")" == "$(git -C "$ROOT/borigin.git" rev-parse main)" ]]'

# The origin rejects the batch's push: nothing has landed, and the run falls back.
cat > "$ROOT/b-repos.json" <<JSON
{ "repos": { "b": { "checkout": "$ROOT/brepo", "batch": {"max": 5}, "gate": ["bash $ROOT/hold-gate.sh"], "finalCheck": "true" } } }
JSON
bb rj-1 rj-1.txt=1; bb rj-2 rj-2.txt=2; bb rj-3 rj-3.txt=3
for b in rj-1 rj-2 rj-3; do bq $b; done; bapprove rj-1 rj-2 rj-3
: > "$BLOG"; : > "$ROOT/main-pushes.log"; touch "$ROOT/reject-next"
out=$($LOCAL_MERGE_QUEUE land b 2>&1); rc=$?
check "a rejected push of main fails the batch with nothing landed, and says so" '[[ "$out" == *"BATCH FAILED: origin rejected the push of main, so nothing has landed"* && "$out" == *"Falling back to landing rj-1, rj-2, rj-3 one at a time"* ]]'
check "…the entries then land one at a time (the rejected push, then one push each)" '[[ $rc == 0 && -f "$ROOT/brepo/rj-1.txt" && -f "$ROOT/brepo/rj-3.txt" && "$(main_pushes)" == 4 && "$(gates)" == 4 ]]'
check "…leaving no batch mark and no lock"                       '! grep -q "\"batch\"" "$LOCAL_MERGE_QUEUE_STATE/queue.json" && [[ ! -e "$LOCAL_MERGE_QUEUE_STATE/locks/b" && ! -e "$LOCAL_MERGE_QUEUE_STATE/queue.lock" ]]'

# THE EXIT PATH (reviewer, ruling 3): the origin rejects EVERY push, so the
# fallback's own push fails and the run dies. Marks and the landing lock must not survive it.
bb px-1 px-1.txt=1; bb px-2 px-2.txt=2; bb px-3 px-3.txt=3
for b in px-1 px-2 px-3; do bq $b; done; bapprove px-1 px-2 px-3
touch "$ROOT/reject-all"
out=$($LOCAL_MERGE_QUEUE land b 2>&1); rc=$?
rm -f "$ROOT/reject-all"
check "when every push is rejected the run dies, and says the merge was rolled back" '[[ $rc != 0 && "$out" == *"BATCH FAILED: origin rejected the push"* && "$out" == *"push to origin/main failed, so the merge was rolled back locally"* ]]'
st=$($LOCAL_MERGE_QUEUE status b 2>&1)
check "…the landing lock is released"                            '[[ ! -e "$LOCAL_MERGE_QUEUE_STATE/locks/b" && "$st" != *LOCKED* ]]'
check "…no entry keeps a batch mark, in the file or in status"   '! grep -q "\"batch\"" "$LOCAL_MERGE_QUEUE_STATE/queue.json" && [[ "$st" != *"gated together"* ]]'
check "…the entries are still approved and nothing landed"       '[[ "$(qinfo)" == px-1:approved,px-2:approved,px-3:approved && ! -f "$ROOT/brepo/px-1.txt" ]]'
check "…and the rolled-back main matches origin"                 '[[ "$(git -C "$ROOT/brepo" rev-parse main)" == "$(git -C "$ROOT/borigin.git" rev-parse main)" ]]'
for b in px-1 px-2 px-3; do $LOCAL_MERGE_QUEUE dequeue $b --repo b >/dev/null 2>&1; done

# A branch that is pushed to while the batch is gated is not landed ungated.
bb mv-1 mv-1.txt=1; bb mv-2 mv-2.txt=2; bb mv-3 mv-3.txt=3
for b in mv-1 mv-2 mv-3; do bq $b; done; bapprove mv-1 mv-2 mv-3
HOLD_MATCH=/batch/b; export HOLD_MATCH; clear_hold; : > "$BLOG"
$LOCAL_MERGE_QUEUE land b > "$ROOT/b-land.out" 2>&1 &
BG=$!
wait_for "$ROOT/gate-started"
( cd "$ROOT/brepo-mv-2" && echo late > mv-late.txt && git add -A && git commit -qm "late commit on mv-2" && git push -q origin mv-2 )
touch "$ROOT/gate-release"; wait $BG
out=$(cat "$ROOT/b-land.out"); unset HOLD_MATCH; clear_hold
check "a branch pushed to during the gate fails the batch: the gate did not see what would land" '[[ "$out" == *"BATCH FAILED: mv-2 changed while the batch was gated"* ]]'
check "…every entry is then gated on its own (one batch gate, three single gates)" '[[ "$(gates)" == 4 && -f "$ROOT/brepo/mv-1.txt" && -f "$ROOT/brepo/mv-2.txt" && -f "$ROOT/brepo/mv-late.txt" && -f "$ROOT/brepo/mv-3.txt" ]]'

# A gate that moves the batch worktree off the candidate (it commits) has not vouched for the candidate.
cat > "$ROOT/commit-gate.sh" <<SH
#!/bin/bash
if [[ "\$PWD" == */batch/b && -e "$ROOT/gate-commit" ]]; then git -c user.email=t@t.t -c user.name=T commit -q --allow-empty -m "a gate that commits"; fi
exit 0
SH
cat > "$ROOT/b-repos.json" <<JSON
{ "repos": { "b": { "checkout": "$ROOT/brepo", "batch": {"max": 5}, "gate": ["bash $ROOT/hold-gate.sh", "bash $ROOT/commit-gate.sh"], "finalCheck": "true" } } }
JSON
bb gm-1 gm-1.txt=1; bb gm-2 gm-2.txt=2; bq gm-1; bq gm-2; bapprove gm-1 gm-2
touch "$ROOT/gate-commit"; : > "$BLOG"
out=$($LOCAL_MERGE_QUEUE land b 2>&1)
rm -f "$ROOT/gate-commit"
check "a gate that moves the batch worktree off the candidate fails the batch before the push" '[[ "$out" == *"BATCH FAILED: the gate moved the batch worktree off the candidate"* && "$(gates)" == 3 && -f "$ROOT/brepo/gm-1.txt" && -f "$ROOT/brepo/gm-2.txt" ]]'

# A batch's lanes are worked out as `land` works them out for one entry: before BRANCH.md is removed.
cat > "$ROOT/b-repos.json" <<JSON
{ "repos": { "b": {
  "checkout": "$ROOT/brepo",
  "batch": { "max": 5 },
  "lanes": {
    "a":    { "paths": ["a/"], "gate": ["echo gate-a >> $BLOG"] },
    "rest": { "paths": "*",    "gate": ["echo gate-rest >> $BLOG"] }
  }
} } }
JSON
bb sc-1 a/sc-1.txt=1 BRANCH.md=notes; bb sc-2 a/sc-2.txt=2 BRANCH.md=notes2
bq sc-1; bq sc-2; bapprove sc-1 sc-2
: > "$BLOG"
out=$($LOCAL_MERGE_QUEUE land b 2>&1)
check "two entries that add a BRANCH.md batch, carrying the lanes land computes (a and rest)" '[[ "$out" == *"gated together in one batch, landed in one push: sc-1, sc-2"* && "$(grep -c gate-a "$BLOG")" == 1 && "$(grep -c gate-rest "$BLOG")" == 1 ]]'
check "…and the scaffolding did not land"                        '[[ ! -f "$ROOT/brepo/BRANCH.md" ]]'

# git older than 2.38 is refused for batching.
mkdir -p "$ROOT/oldgit"
cat > "$ROOT/oldgit/git" <<SH
#!/bin/bash
[[ "\$1" == "--version" ]] && { echo "git version 2.30.0"; exit 0; }
exec $(command -v git) "\$@"
SH
chmod +x "$ROOT/oldgit/git"
write_b_config '"batch": {"max": 5},'
out=$(PATH="$ROOT/oldgit:$PATH" $LOCAL_MERGE_QUEUE land b --batch --dry-run 2>&1); rc=$?
check "--batch is refused below git 2.38 with a clear message"   '[[ $rc != 0 && "$out" == *"batched landing needs git 2.38 or newer, and this is git 2.30"* ]]'
out=$(PATH="$ROOT/oldgit:$PATH" $LOCAL_MERGE_QUEUE land b --no-batch --dry-run 2>&1); rc=$?
check "…and a run without batching is not affected"              '[[ $rc == 0 ]]'

echo
echo "── interruption: SIGTERM stops the gate and releases everything; SIGKILL leaves a dead lock ──"
write_b_config '"batch": {"max": 5},'
bb sg-1 sg-1.txt=1; bb sg-2 sg-2.txt=2
bq sg-1; bq sg-2; bapprove sg-1 sg-2
HOLD_MATCH=/batch/b; export HOLD_MATCH; clear_hold; rm -f "$ROOT/gate-pid"
$LOCAL_MERGE_QUEUE land b > "$ROOT/b-land.out" 2>&1 &
BG=$!
wait_for "$ROOT/gate-started"
gpid=$(cat "$ROOT/gate-pid")
check "the gate is running, in the batch worktree"               'kill -0 $gpid 2>/dev/null && grep -q "gated together with" <<<"$($LOCAL_MERGE_QUEUE status b 2>&1)"'
kill -TERM $BG
wait $BG; rc=$?
sleep 0.5
check "SIGTERM ends the run with exit status 143"                '[[ $rc == 143 ]]'
check "…and the gate's whole process group is gone"              '! kill -0 $gpid 2>/dev/null'
check "…the landing lock is released"                            '[[ ! -e "$LOCAL_MERGE_QUEUE_STATE/locks/b" && ! -e "$LOCAL_MERGE_QUEUE_STATE/queue.lock" ]]'
check "…no batch mark is left"                                   '! grep -q "\"batch\"" "$LOCAL_MERGE_QUEUE_STATE/queue.json"'
check "…the entries are still approved, nothing landed, nothing pushed" '[[ "$(qinfo)" == sg-1:approved,sg-2:approved && ! -f "$ROOT/brepo/sg-1.txt" ]]'
check "…and the next command works at once"                      '[[ "$($LOCAL_MERGE_QUEUE status b 2>&1)" != *LOCKED* ]]'
# SIGHUP as well (a closed terminal).
clear_hold; rm -f "$ROOT/gate-pid"
$LOCAL_MERGE_QUEUE land b > "$ROOT/b-land.out" 2>&1 &
BG=$!
wait_for "$ROOT/gate-started"; gpid=$(cat "$ROOT/gate-pid")
kill -HUP $BG; wait $BG; rc=$?; sleep 0.5
check "SIGHUP stops the gate and the run as well (exit status 129)" '[[ $rc == 129 ]] && ! kill -0 $gpid 2>/dev/null && [[ ! -e "$LOCAL_MERGE_QUEUE_STATE/locks/b" ]]'
# SIGKILL runs nothing: the lock is left, its holder is dead, and the next command clears it.
clear_hold; rm -f "$ROOT/gate-pid"
$LOCAL_MERGE_QUEUE land b > "$ROOT/b-land.out" 2>&1 &
BG=$!
wait_for "$ROOT/gate-started"; gpid=$(cat "$ROOT/gate-pid")
kill -KILL $BG; wait $BG 2>/dev/null; sleep 0.3
st=$($LOCAL_MERGE_QUEUE status b 2>&1)
check "after SIGKILL the lock is left, and status says its run died (and that its gate is still running) instead of LOCKED" '[[ -d "$LOCAL_MERGE_QUEUE_STATE/locks/b" && "$st" == *"a landing run died"* && "$st" == *"the gate it started is still running"* && "$st" != *LOCKED* && "$st" != *"gated together"* ]]'
# The orphaned gate of a SIGKILLed run ends on its own once released; the lock stays held until it has (see the round-3 section).
touch "$ROOT/gate-release"; for i in $(seq 1 100); do kill -0 $gpid 2>/dev/null || break; sleep 0.2; done; unset HOLD_MATCH; clear_hold
: > "$BLOG"
out=$($LOCAL_MERGE_QUEUE land b 2>&1); rc=$?
check "…and the next land breaks the dead lock and clears the marks" '[[ $rc == 0 && "$out" == *"breaking a stale lock left by pid $BG"* && -f "$ROOT/brepo/sg-1.txt" && -f "$ROOT/brepo/sg-2.txt" ]]'

echo
echo "── the batch worktree is made fresh before every batch ──────────────────────"
# Dependencies survive between batches (node_modules is named in `batch.keep`) as long
# as the lockfile is unchanged; everything else a gate or an earlier batch left behind goes.
echo '{}' > "$ROOT/brepo/package-lock.json"
( cd "$ROOT/brepo" && git add package-lock.json && git commit -qm "lockfile" && git push -q origin main )
rm -f "$ROOT/setup.log"
write_b_config '"batch": {"max": 5, "keep": ["node_modules"]}, "setupWhen": "test -f node_modules/marker", "setup": ["echo run >> '"$ROOT"'/setup.log", "mkdir -p node_modules", "echo built > node_modules/marker"],'
BW="$LOCAL_MERGE_QUEUE_STATE/batch/b"
bw_batch () {  # two fresh entries, one batch; prints nothing, leaves $out
  local n="$1"; bb hy-$n-1 hy-$n-1.txt=1; bb hy-$n-2 hy-$n-2.txt=2; bq hy-$n-1; bq hy-$n-2; bapprove hy-$n-1 hy-$n-2
  out=$($LOCAL_MERGE_QUEUE land b 2>&1)
}
bw_batch 1
check "the first batch builds the worktree, sets it up once, and locks it" '[[ "$out" == *"gated together in one batch, landed in one push: hy-1-1, hy-1-2"* && "$(grep -c run "$ROOT/setup.log")" == 1 && -f "$BW/node_modules/marker" ]] && git -C "$ROOT/brepo" worktree list --porcelain | grep -A3 "batch/b" | grep -q locked'
# An untracked file an earlier gate left behind is not there for the next batch.
echo "left by an earlier gate" > "$BW/stale.txt"; echo kept > "$BW/node_modules/survivor.txt"
bw_batch 2
check "stale untracked files are removed: a gate that refuses stale.txt passes" '[[ "$out" == *"gated together in one batch, landed in one push: hy-2-1, hy-2-2"* && ! -e "$BW/stale.txt" ]]'
check "…the named dependency directory survives, and setup does not run again" '[[ -f "$BW/node_modules/survivor.txt" && "$(grep -c run "$ROOT/setup.log")" == 1 ]]'
# A changed lockfile: the kept directory is removed and setup runs again, even though its probe would pass.
( cd "$ROOT/brepo" && echo '{"changed": true}' > package-lock.json && git commit -qam "lockfile changes" && git push -q origin main )
bw_batch 3
check "a changed lockfile removes the kept dependencies and runs setup again" '[[ "$out" == *"lockfiles differ from the last setup"* && ! -e "$BW/node_modules/survivor.txt" && -f "$BW/node_modules/marker" && "$(grep -c run "$ROOT/setup.log")" == 2 ]]'
# A rebase left in progress (a killed run) is aborted: without that the next rebase refuses to start.
bb cx-1 shared.txt=$'one\nX1\nthree\n'; bb cx-2 shared.txt=$'one\nX2\nthree\n'
git -C "$BW" checkout -q --detach "$(git -C "$ROOT/brepo" rev-parse refs/heads/cx-1)"
git -C "$BW" -c core.hooksPath=/dev/null rebase "$(git -C "$ROOT/brepo" rev-parse refs/heads/cx-2)" >/dev/null 2>&1
check "(setup of the test) the batch worktree is stuck mid-rebase"  '[[ -d "$(git -C "$BW" rev-parse --absolute-git-dir)/rebase-merge" || -d "$(git -C "$BW" rev-parse --absolute-git-dir)/rebase-apply" ]]'
( cd "$ROOT/brepo" && echo main-moves >> base.txt && git commit -qam "main moves" && git push -q origin main )
bw_batch 4
check "a rebase left in progress is aborted before the next batch (and the batch needs a rebase)" '[[ "$out" == *"gated together in one batch, landed in one push: hy-4-1, hy-4-2"* && "$out" != *"BATCH FAILED"* ]]'
# A merge left in progress, with a conflicted tree, is aborted and reset.
git -C "$BW" checkout -q --detach "$(git -C "$ROOT/brepo" rev-parse refs/heads/cx-1)"
git -C "$BW" -c core.hooksPath=/dev/null merge --no-ff --no-commit "$(git -C "$ROOT/brepo" rev-parse refs/heads/cx-2)" >/dev/null 2>&1
check "(setup of the test) the batch worktree is stuck mid-merge, conflicted" '[[ -f "$(git -C "$BW" rev-parse --absolute-git-dir)/MERGE_HEAD" ]]'
( cd "$ROOT/brepo" && echo main-moves-again >> base.txt && git commit -qam "main moves again" && git push -q origin main )
bw_batch 5
check "a merge left in progress is aborted before the next batch"  '[[ "$out" == *"gated together in one batch, landed in one push: hy-5-1, hy-5-2"* && "$out" != *"BATCH FAILED"* ]]'
# A worktree that cannot be used (a stale index.lock) is rebuilt once, and the run says so.
touch "$(git -C "$BW" rev-parse --absolute-git-dir)/index.lock"
( cd "$ROOT/brepo" && echo main-moves-3 >> base.txt && git commit -qam "main moves 3" && git push -q origin main )
bw_batch 6
check "a stale index.lock makes the run rebuild the batch worktree once, and say so" '[[ "$out" == *"is unusable — rebuilding it from scratch"* && "$out" == *"gated together in one batch, landed in one push: hy-6-1, hy-6-2"* && -f "$BW/node_modules/marker" ]]'
check "…and the rebuilt worktree is locked again"                  'git -C "$ROOT/brepo" worktree list --porcelain | grep -A3 "batch/b" | grep -q locked'
# A broken registration (the .git file gone) is rebuilt the same way.
rm -f "$BW/.git"
( cd "$ROOT/brepo" && echo main-moves-4 >> base.txt && git commit -qam "main moves 4" && git push -q origin main )
bw_batch 7
check "a worktree with no .git is rebuilt, not silently abandoned"  '[[ "$out" == *"is unusable — rebuilding it from scratch"* && "$out" == *"gated together in one batch, landed in one push: hy-7-1, hy-7-2"* ]]'
git -C "$ROOT/brepo" branch -q -D cx-1 cx-2 2>/dev/null; git -C "$ROOT/borigin.git" branch -q -D cx-1 cx-2 2>/dev/null

export LOCAL_MERGE_QUEUE_CONFIG="$SAVED_CONFIG" LOCAL_MERGE_QUEUE_STATE="$SAVED_STATE"
cd "$ROOT/repo"

# ROUND3-BEGIN
echo
echo "════ round 3: the fixes after the independent re-check ════════════════"
# Each block below builds a repository of its own (a bare origin, a primary checkout and a
# second clone that stands for a bot or another session) and points the tool at a state
# directory and a config of its own, so no block depends on another's leftovers.
export ROOT
r3_wait () { local i; for i in $(seq 1 300); do [[ -e "$1" ]] && return 0; sleep 0.2; done; return 1; }
r3_env () { export LOCAL_MERGE_QUEUE_STATE="$ROOT/$1-state" LOCAL_MERGE_QUEUE_CONFIG="$ROOT/$1-repos.json"; }
r3_init () {  # name: origin, primary checkout (lanes' folders a/, b/, other/), a second clone
  local n="$1"
  git init -q --bare "$ROOT/$n-origin.git"
  git init -q -b main "$ROOT/$n"
  ( cd "$ROOT/$n" && git config user.email t@t.t && git config user.name T && git remote add origin "$ROOT/$n-origin.git" \
    && mkdir -p a b other && printf 'ign/\n*.scratch\n' > .gitignore && echo base > base.txt && echo a > a/f.txt && echo b > b/f.txt && echo o > other/f.txt \
    && git add -A && git commit -qm base && git push -qu origin main )
  git clone -q "$ROOT/$n-origin.git" "$ROOT/$n-other" 2>/dev/null
  git -C "$ROOT/$n-other" config user.email t@t.t; git -C "$ROOT/$n-other" config user.name T
  r3_env "$n"
}
r3_config () {  # name, then the rest of the repo entry as JSON members (no braces)
  local n="$1"; shift
  printf '{ "repos": { "%s": { "checkout": "%s", %s } } }\n' "$n" "$ROOT/$n" "$1" > "$ROOT/$n-repos.json"
}
r3_wt () { echo "$ROOT/$1-${2//\//-}"; }
r3_branch () {  # repo, branch, file=content ...  (the worktree is $ROOT/<repo>-<branch, with / as ->)
  local n="$1" b="$2"; shift 2
  local wt; wt="$(r3_wt "$n" "$b")"
  git -C "$ROOT/$n" worktree add -q "$wt" -b "$b" >/dev/null 2>&1
  local pair; for pair in "$@"; do mkdir -p "$(dirname "$wt/${pair%%=*}")"; printf '%s' "${pair#*=}" > "$wt/${pair%%=*}"; done
  ( cd "$wt" && git add -A && git commit -qm "$b" && git push -qu origin "$b" 2>/dev/null )
}
r3_queue () {  # repo, branch...: enqueue each from its worktree, then approve them
  local n="$1"; shift; local b
  for b in "$@"; do ( cd "$(r3_wt "$n" "$b")" && $LOCAL_MERGE_QUEUE enqueue >/dev/null 2>&1 ); done
  $LOCAL_MERGE_QUEUE approve "$@" --repo "$n" >/dev/null 2>&1
}
r3_outside () {  # repo, file=content, message: a commit pushed to origin's main by somebody else (the second clone)
  local n="$1" pair="$2" msg="$3"
  ( cd "$ROOT/$n-other" && git pull -q origin main 2>/dev/null; mkdir -p "$(dirname "${pair%%=*}")"; printf '%s' "${pair#*=}" > "${pair%%=*}"; git add -A && git commit -qm "$msg" && git push -q origin main )
}
r3_qinfo () { node -e 'const q=JSON.parse(require("fs").readFileSync(process.env.LOCAL_MERGE_QUEUE_STATE+"/queue.json"));console.log(q.entries.map(e=>e.branch+":"+e.status).join(","))'; }
r3_gates () { local n; n=$(grep -c '^gate-run' "$ROOT/$1-gate.log" 2>/dev/null); echo "${n:-0}"; }
r3_main_eq () { [[ "$(git -C "$ROOT/$1" rev-parse main)" == "$(git -C "$ROOT/$1-origin.git" rev-parse main)" ]]; }
# A gate that records its runs. While <repo>-hold exists it announces itself (<repo>-gate-started,
# <repo>-gate-pid) and waits for <repo>-release; it fails while <repo>-fail exists.
cat > "$ROOT/r3-gate.sh" <<'SH'
#!/bin/bash
n="$1"; lane="${2:-}"
echo "gate-run $(basename "$PWD") $lane" >> "$ROOT/$n-gate.log"
if [ -e "$ROOT/$n-hold" ]; then
  echo $$ > "$ROOT/$n-gate-pid"; touch "$ROOT/$n-gate-started"
  for i in $(seq 1 600); do [ -e "$ROOT/$n-release" ] && break; sleep 0.2; done
fi
# <repo>-fail-after-first: every run after the first one fails
if [ -e "$ROOT/$n-fail-after-first" ] && [ "$(grep -c '^gate-run' "$ROOT/$n-gate.log")" -gt 1 ]; then exit 1; fi
[ ! -e "$ROOT/$n-fail" ]
SH
r3_hold () { rm -f "$ROOT/$1-release" "$ROOT/$1-gate-started" "$ROOT/$1-gate-pid" "$ROOT/$1-fail"; touch "$ROOT/$1-hold"; }
r3_unhold () { rm -f "$ROOT/$1-hold" "$ROOT/$1-release" "$ROOT/$1-gate-started" "$ROOT/$1-fail"; }
r3_gate_step () { echo "bash $ROOT/r3-gate.sh $1 ${2:-}"; }
r3_lane_gates () { local n; n=$(grep -c "^gate-run .* $2\$" "$ROOT/$1-gate.log" 2>/dev/null); echo "${n:-0}"; }
# The origin's pre-receive hook: it logs every ref pushed (<repo>-refs.log) and, when
# <repo>-hook.sh exists, runs it with the ref and the new value, so a test can act at a chosen push.
r3_hook () {  # repo
  cat > "$ROOT/$1-origin.git/hooks/pre-receive" <<SH
#!/bin/bash
while read old new ref; do
  echo "\$ref \$new" >> "$ROOT/$1-refs.log"
  [ -e "$ROOT/$1-hook.sh" ] && . "$ROOT/$1-hook.sh"
done
exit 0
SH
  chmod +x "$ROOT/$1-origin.git/hooks/pre-receive"
}

echo
echo "── round 3 · the merge is bound to the commit the gate ran on ──────────────"
# THE DEFECT (reviewer, finding 1): the merge took whatever the branch ref held when it ran, so
# a commit made in the worktree during the gate landed without the gate having seen it.
r3_init c1
r3_config c1 "\"gate\": [\"$(r3_gate_step c1)\"], \"finalCheck\": \"true\""
r3_branch c1 sneak sneak.txt=gated
r3_queue c1 sneak
before=$(git -C "$ROOT/c1-origin.git" rev-parse main)
r3_hold c1; : > "$ROOT/c1-gate.log"
$LOCAL_MERGE_QUEUE land c1 > "$ROOT/c1-land.out" 2>&1 &
BG=$!
r3_wait "$ROOT/c1-gate-started"
( cd "$(r3_wt c1 sneak)" && echo ungated > sneaky.txt && git add -A && git commit -qm "made while the gate ran" )
touch "$ROOT/c1-release"; wait $BG; rc=$?
out=$(cat "$ROOT/c1-land.out"); r3_unhold c1
check "a commit made in the worktree during the gate stalls the entry (exit 2)"       '[[ $rc == 2 && "$out" == *"changed during the gate"* && "$(r3_qinfo)" == sneak:stalled ]]'
check "…and neither the gated work nor the ungated commit reached main or origin"     '[[ "$(git -C "$ROOT/c1" rev-parse main)" == "$before" && "$(git -C "$ROOT/c1-origin.git" rev-parse main)" == "$before" && ! -e "$ROOT/c1/sneaky.txt" && ! -e "$ROOT/c1/sneak.txt" ]]'
check "…and the worktree, with the commit, is left for its author"                    '[[ -f "$(r3_wt c1 sneak)/sneaky.txt" ]] && git -C "$ROOT/c1" rev-parse --verify -q refs/heads/sneak >/dev/null'
check "…and the stall report says the gate did not see what would land"               'grep -q "did not see what would land" "$LOCAL_MERGE_QUEUE_STATE/reports/c1-sneak.md"'
# The author takes the commit out, the entry resumes, is gated again, and lands the gated content.
( cd "$(r3_wt c1 sneak)" && git reset -q --hard HEAD~1 )
: > "$ROOT/c1-gate.log"
$LOCAL_MERGE_QUEUE resume c1 >/dev/null 2>&1; rc=$?
check "resume gates the entry again and lands it"                                      '[[ $rc == 0 && "$(r3_gates c1)" == 1 && -f "$ROOT/c1/sneak.txt" && ! -e "$ROOT/c1/sneaky.txt" ]]'
# An uncommitted edit of a tracked file made during the gate is a change too.
r3_branch c1 edited edited.txt=gated
r3_queue c1 edited
r3_hold c1; : > "$ROOT/c1-gate.log"
$LOCAL_MERGE_QUEUE land c1 > "$ROOT/c1-land.out" 2>&1 &
BG=$!
r3_wait "$ROOT/c1-gate-started"
echo "edited while the gate ran" >> "$(r3_wt c1 edited)/edited.txt"
touch "$ROOT/c1-release"; wait $BG; rc=$?
out=$(cat "$ROOT/c1-land.out"); r3_unhold c1
check "an uncommitted edit of a tracked file during the gate stalls the entry too"    '[[ $rc == 2 && "$out" == *"changed during the gate"* && ! -e "$ROOT/c1/edited.txt" ]]'
# What merges is the gated commit itself: the second parent of the merge is the tip that was published.
$LOCAL_MERGE_QUEUE dequeue edited --repo c1 >/dev/null 2>&1
r3_hook c1; : > "$ROOT/c1-refs.log"
r3_branch c1 plain plain.txt=gated
r3_queue c1 plain
$LOCAL_MERGE_QUEUE land c1 >/dev/null 2>&1
check "the merge's second parent is the tip the run published, which is the commit the gate ran on" '[[ -n "$(grep "^refs/heads/plain " "$ROOT/c1-refs.log")" && "$(git -C "$ROOT/c1" rev-parse main^2)" == "$(grep "^refs/heads/plain " "$ROOT/c1-refs.log" | grep -v " 0000000" | tail -1 | cut -d" " -f2)" ]]'

echo
echo "── round 3 · local main must equal origin's before an entry starts ─────────"
# THE DEFECT (reviewer, finding 2): a run killed between its local merge and its push left main
# ahead of origin, and the next run read the entry as already landed, deleted its worktree and
# its branch (local and remote) and dropped it, with the merge existing in the primary checkout only.
r3_init c2
r3_config c2 "\"gate\": [\"$(r3_gate_step c2)\"], \"finalCheck\": \"true\""
r3_hook c2
r3_branch c2 alpha alpha.txt=alpha
r3_branch c2 beta beta.txt=beta
r3_queue c2 alpha beta
cat > "$ROOT/c2-hook.sh" <<'SH'
if [ "$ref" = refs/heads/main ]; then
  touch "$ROOT/c2-push-started"
  for i in $(seq 1 100); do [ -e "$ROOT/c2-kill-done" ] && break; sleep 0.2; done
  echo "REJECTED BY TEST HOOK" >&2; exit 1
fi
SH
origin_before=$(git -C "$ROOT/c2-origin.git" rev-parse main)
$LOCAL_MERGE_QUEUE land c2 > "$ROOT/c2-land.out" 2>&1 &
BG=$!
r3_wait "$ROOT/c2-push-started"
kill -KILL $BG; wait $BG 2>/dev/null
touch "$ROOT/c2-kill-done"; sleep 1; rm -f "$ROOT/c2-hook.sh"
check "(setup of the test) the killed run left main ahead of origin by one merge and its branch commit, and origin untouched" '[[ "$(git -C "$ROOT/c2" rev-list --count origin/main..main)" == 2 && "$(git -C "$ROOT/c2-origin.git" rev-parse main)" == "$origin_before" ]]'
out=$($LOCAL_MERGE_QUEUE land c2 2>&1); rc=$?
check "the next run refuses, naming the commits main is ahead by and the command that discards it" '[[ $rc != 0 && "$out" == *"has 2 commit(s) that origin/main does not"* && "$out" == *"Merge alpha"* && "$out" == *"reset --hard origin/main"* ]]'
check "…and cleans nothing up: the worktrees, the local and the remote branches stay"  '[[ -d "$(r3_wt c2 alpha)" && -d "$(r3_wt c2 beta)" ]] && git -C "$ROOT/c2" rev-parse --verify -q refs/heads/alpha >/dev/null && git -C "$ROOT/c2-origin.git" rev-parse --verify -q refs/heads/alpha >/dev/null'
check "…the entries are still approved, and nothing reached origin"                     '[[ "$(r3_qinfo)" == alpha:approved,beta:approved && "$(git -C "$ROOT/c2-origin.git" rev-parse main)" == "$origin_before" ]]'
git -C "$ROOT/c2" reset -q --hard origin/main
: > "$ROOT/c2-gate.log"
out=$($LOCAL_MERGE_QUEUE land c2 2>&1); rc=$?
check "once the leftover is discarded, both entries land as gated entries"              '[[ $rc == 0 && -f "$ROOT/c2/alpha.txt" && -f "$ROOT/c2/beta.txt" ]] && r3_main_eq c2'
check "…and each was gated"                                                             '[[ "$(r3_gates c2)" == 2 ]]'
# A main that is merely behind is fast-forwarded, as it always was.
r3_outside c2 other/bot.txt=bot "outside push"
r3_branch c2 gamma gamma.txt=gamma; r3_queue c2 gamma
out=$($LOCAL_MERGE_QUEUE land c2 2>&1); rc=$?
check "a main that is only behind origin is fast-forwarded, and the entry lands on it"  '[[ $rc == 0 && -f "$ROOT/c2/other/bot.txt" && -f "$ROOT/c2/gamma.txt" ]] && r3_main_eq c2'

# RESUME FETCHES BEFORE IT GATES (nit): a main that moved while the entry was stalled is seen,
# and the entry is rebased and gated again, in a one-lane repo as well.
r3_branch c2 stalled stalled.txt=s
r3_queue c2 stalled
touch "$ROOT/c2-fail"; : > "$ROOT/c2-gate.log"
$LOCAL_MERGE_QUEUE land c2 >/dev/null 2>&1; rc=$?
rm -f "$ROOT/c2-fail"
check "(setup of the test) the entry stalls on its gate"                                '[[ $rc == 2 && "$(r3_qinfo)" == stalled:stalled ]]'
r3_outside c2 other/more.txt=more "outside push while stalled"
: > "$ROOT/c2-gate.log"
out=$($LOCAL_MERGE_QUEUE resume c2 2>&1); rc=$?
check "resume sees a main that moved while the entry was stalled, rebases and gates again, and lands" '[[ $rc == 0 && "$out" == *"moved while stalled was stalled — rebasing it again"* && "$(r3_gates c2)" == 1 && -f "$ROOT/c2/other/more.txt" && -f "$ROOT/c2/stalled.txt" ]] && r3_main_eq c2'

echo
echo "── round 3 · a hard-killed run's gate cannot overlap a second gate ─────────"
# THE REGRESSION (reviewer, finding 3): the gate runs in a process group of its own, so killing the
# land process with SIGKILL no longer killed its gate, and the stale lock then admitted a second
# gate in the same worktree while the first was still running.
r3_init c3
r3_config c3 "\"gate\": [\"$(r3_gate_step c3)\"], \"finalCheck\": \"true\""
r3_branch c3 held held.txt=h
r3_queue c3 held
r3_hold c3; : > "$ROOT/c3-gate.log"
$LOCAL_MERGE_QUEUE land c3 > "$ROOT/c3-land.out" 2>&1 &
BG=$!
r3_wait "$ROOT/c3-gate-started"
gpid=$(cat "$ROOT/c3-gate-pid"); pgid=$(ps -o pgid= -p "$gpid" | tr -d ' ')
check "the landing lock records the gate's process group"                              '[[ -n "$pgid" ]] && grep -q "\"gatePgid\":$pgid[,}]" "$LOCAL_MERGE_QUEUE_STATE/locks/c3/owner.json"'
kill -KILL $BG; wait $BG 2>/dev/null; sleep 0.3
check "(setup of the test) the land process is dead and its gate is still running"      '! kill -0 $BG 2>/dev/null && kill -0 -- -$pgid 2>/dev/null'
st=$($LOCAL_MERGE_QUEUE status c3 2>&1)
check "status says the dead run's gate is still running, and not LOCKED"                '[[ "$st" == *"gate it started is still running"* && "$st" == *"$pgid"* && "$st" != *LOCKED* ]]'
out=$($LOCAL_MERGE_QUEUE land c3 2>&1); rc=$?
check "a second land is refused while the orphaned gate runs, and names its process group"  '[[ $rc != 0 && "$out" == *"still running"* && "$out" == *"$pgid"* && "$out" != *"breaking a stale lock"* ]]'
check "…the message says to look at the group first (the exact ps command) and how to release the lock by hand if it is not a gate" '[[ "$out" == *"ps -o pid,pgid,etime,command -g $pgid"* && "$out" == *"rm -rf $LOCAL_MERGE_QUEUE_STATE/locks/c3"* && "$out" == *"unrelated process"* ]]'
check "…and status carries the same hint"                                                 '[[ "$($LOCAL_MERGE_QUEUE status c3 2>&1)" == *"ps -o pid,pgid,etime,command -g $pgid"* ]]'
check "…and no second gate started"                                                      '[[ "$(r3_gates c3)" == 1 ]]'
out=$($LOCAL_MERGE_QUEUE resume c3 2>&1); rc=$?
check "resume is refused the same way"                                                   '[[ $rc != 0 && "$out" == *"still running"* && "$(r3_gates c3)" == 1 ]]'
touch "$ROOT/c3-release"
for i in $(seq 1 100); do kill -0 -- -$pgid 2>/dev/null || break; sleep 0.2; done
r3_unhold c3
check "(setup of the test) the orphaned gate has ended"                                   '! kill -0 -- -$pgid 2>/dev/null'
out=$($LOCAL_MERGE_QUEUE land c3 2>&1); rc=$?
check "once the gate has ended the next land breaks the stale lock and lands the entry"  '[[ $rc == 0 && "$out" == *"breaking a stale lock left by pid $BG"* && -f "$ROOT/c3/held.txt" ]] && r3_main_eq c3'
# A recycled group id: the dead run's recorded group is now some unrelated live process (here, this
# test's own group). The lock cannot tell, so it is held; the message's hand release is the way out.
r3_branch c3 recycled recycled.txt=1; r3_queue c3 recycled
dead=$(sh -c 'echo $$'); mypg=$(ps -o pgid= -p $$ | tr -d ' ')
rm -rf "$LOCAL_MERGE_QUEUE_STATE/locks/c3"; mkdir -p "$LOCAL_MERGE_QUEUE_STATE/locks/c3"
echo "{\"pid\":$dead,\"token\":\"dead-run\",\"since\":\"2026-01-01T00:00:00.000Z\",\"gatePgid\":$mypg}" > "$LOCAL_MERGE_QUEUE_STATE/locks/c3/owner.json"
out=$($LOCAL_MERGE_QUEUE land c3 2>&1); rc=$?
check "a lock whose recorded group is now an unrelated live process refuses, as it cannot tell"      '[[ $rc != 0 && "$out" == *"ps -o pid,pgid,etime,command -g $mypg"* ]]'
eval "$(grep -o 'rm -rf [^ ]*locks/c3' <<<"$out" | head -1)"
out=$($LOCAL_MERGE_QUEUE land c3 2>&1); rc=$?
check "…and the hand release the message prints clears it: the next land goes ahead"                 '[[ $rc == 0 && -f "$ROOT/c3/recycled.txt" ]]'

echo
echo "── round 3 · a branch name with a slash does not crash the stall report ────"
# THE DEFECT (reviewer, finding 4): the report path was built from the branch name without creating
# the folder the slash implies, so a stall threw ENOENT, exited 1 and left no report.
r3_init c4
r3_config c4 '"gate": ["false"], "finalCheck": "true"'
r3_branch c4 feat/x x.txt=1
r3_queue c4 feat/x
out=$($LOCAL_MERGE_QUEUE land c4 2>&1); rc=$?
check "a stall on a branch named feat/x exits 2, not with an uncaught exception"         '[[ $rc == 2 && "$out" != *ENOENT* && "$out" == *STALLED* ]]'
check "…the report exists, under a file name with no slash in it"                        '[[ -f "$LOCAL_MERGE_QUEUE_STATE/reports/c4-feat%2Fx.md" && "$out" == *"c4-feat%2Fx.md"* ]]'
check "…and the entry is recorded as stalled"                                            '[[ "$(r3_qinfo)" == "feat/x:stalled" ]]'
out=$($LOCAL_MERGE_QUEUE land c4 2>&1)
check "a second land names the same report"                                              '[[ "$out" == *"c4-feat%2Fx.md"* ]]'

echo
echo "── round 3 · a gate has a timeout the config sets, and a hung gate stalls its entry ──"
# THE GAP (reviewer, finding 5): a hung gate held the landing lock forever, since a live holder is
# never broken. gateTimeoutMinutes (per repository, or per lane) ends a step that runs longer:
# its process group gets SIGTERM, and SIGKILL after five seconds.
r3_init c5
cat > "$ROOT/c5-hung.sh" <<'SH'
#!/bin/bash
# ignores SIGTERM, so only the escalation to SIGKILL ends it
trap '' TERM
echo $$ > "$ROOT/c5-hung-pid"
while true; do sleep 1; done
SH
r3_config c5 "\"gateTimeoutMinutes\": 0.03, \"gate\": [\"bash $ROOT/c5-hung.sh\"], \"finalCheck\": \"true\""
r3_branch c5 hangs hangs.txt=1
r3_queue c5 hangs
start=$SECONDS
out=$(gtimeout 120 $LOCAL_MERGE_QUEUE land c5 2>&1); rc=$?
hpid=$(cat "$ROOT/c5-hung-pid")
check "a gate that runs past gateTimeoutMinutes stalls its entry (exit 2) with a timeout message"  '[[ $rc == 2 && "$out" == *"timed out after"* && "$(r3_qinfo)" == hangs:stalled ]]'
check "…the hung gate, which ignores SIGTERM, was ended (SIGKILL after five seconds) in bounded time" '! kill -0 $hpid 2>/dev/null && (( SECONDS - start < 60 ))'
check "…and a limit under a minute is said in seconds, not as 0.03 minutes"               '[[ "$out" == *"timed out after 2 seconds"* && "$out" != *"0.03 minutes"* ]]'
check "…the landing lock was released, and nothing landed"                               '[[ ! -e "$LOCAL_MERGE_QUEUE_STATE/locks/c5" && ! -e "$ROOT/c5/hangs.txt" ]]'
check "…and the stall report says the gate timed out"                                    'grep -q "timed out" "$LOCAL_MERGE_QUEUE_STATE/reports/c5-hangs.md"'
$LOCAL_MERGE_QUEUE dequeue hangs --repo c5 >/dev/null 2>&1
# A lane's own gateTimeoutMinutes wins over the repository's.
cat > "$ROOT/c5-repos.json" <<JSON
{ "repos": { "c5": { "checkout": "$ROOT/c5", "gateTimeoutMinutes": 100,
  "lanes": { "a": { "paths": ["a/"], "gateTimeoutMinutes": 0.03, "gate": ["sleep 60"] }, "rest": { "paths": "*", "gate": ["true"] } } } } }
JSON
r3_branch c5 lane-a a/new.txt=1
r3_queue c5 lane-a
out=$(gtimeout 120 $LOCAL_MERGE_QUEUE land c5 2>&1); rc=$?
check "a lane's gateTimeoutMinutes overrides the repository's, and the message names the lane" '[[ $rc == 2 && "$out" == *"timed out after"* && "$out" == *"lane a"* ]]'
$LOCAL_MERGE_QUEUE dequeue lane-a --repo c5 >/dev/null 2>&1
# A hung setup step stalls the entry the same way, and says it was the setup.
r3_config c5 '"gateTimeoutMinutes": 0.03, "setupWhen": "false", "setup": ["sleep 60"], "gate": ["true"], "finalCheck": "true"'
r3_branch c5 sets sets.txt=1
r3_queue c5 sets
out=$(gtimeout 120 $LOCAL_MERGE_QUEUE land c5 2>&1); rc=$?
check "a hung setup step is ended and stalls the entry, saying it was the setup"          '[[ $rc == 2 && "$out" == *"worktree setup timed out"* && ! -e "$LOCAL_MERGE_QUEUE_STATE/locks/c5" ]]'
$LOCAL_MERGE_QUEUE dequeue sets --repo c5 >/dev/null 2>&1
# A hung final check is ended and reported; the run still ends.
r3_config c5 '"gateTimeoutMinutes": 0.03, "gate": ["true"], "finalCheck": "sleep 60"'
r3_branch c5 fin fin.txt=1
r3_queue c5 fin
out=$(gtimeout 120 $LOCAL_MERGE_QUEUE land c5 2>&1); rc=$?
check "a hung final check is ended and reported as timed out, after the entry landed"     '[[ $rc == 0 && "$out" == *"FINAL CHECK TIMED OUT"* && -f "$ROOT/c5/fin.txt" && ! -e "$LOCAL_MERGE_QUEUE_STATE/locks/c5" ]]'
# The key is validated.
r3_config c5 '"gateTimeoutMinutes": -3, "gate": ["true"]'
out=$($LOCAL_MERGE_QUEUE status c5 2>&1); rc=$?
check "a gateTimeoutMinutes that is not a positive number is refused"                     '[[ $rc != 0 && "$out" == *gateTimeoutMinutes* ]]'

echo
echo "── round 3 · the known-red file is written under the lock; the final check runs under it ──"
# THE NIT (reviewer, finding 7): a second land about to be refused deleted and rewrote the file the
# running holder's gates read, and the final check ran after the lock was released.
r3_init c6
soon=$(node -e 'const d=new Date(Date.now()+5*86400000);console.log(d.toISOString().slice(0,10))')
cat > "$ROOT/c6-final.sh" <<'SH'
#!/bin/bash
[ -d "$LOCAL_MERGE_QUEUE_STATE/locks/c6" ] && echo held > "$ROOT/c6-final-under-lock"
exit 0
SH
r3_config c6 "\"gate\": [\"$(r3_gate_step c6)\"], \"finalCheck\": \"bash $ROOT/c6-final.sh\", \"knownRed\": [{\"suite\": \"test/x.test.mjs\", \"issue\": \"o/r#1\", \"expires\": \"$soon\"}]"
r3_branch c6 kr kr.txt=1
r3_queue c6 kr
r3_hold c6; : > "$ROOT/c6-gate.log"
$LOCAL_MERGE_QUEUE land c6 > "$ROOT/c6-land.out" 2>&1 &
BG=$!
r3_wait "$ROOT/c6-gate-started"
kr="$LOCAL_MERGE_QUEUE_STATE/known-red/c6.tsv"
check "(setup of the test) the running holder wrote the known-red file"                  '[[ -f "$kr" ]]'
echo "SENTINEL-written-by-the-test" >> "$kr"
out=$($LOCAL_MERGE_QUEUE land c6 2>&1); rc=$?
check "(setup of the test) a second land is refused while the first holds the lock"      '[[ $rc != 0 && "$out" == *"being landed already"* ]]'
check "a refused second land does not delete or rewrite the file the holder's gates read" 'grep -q SENTINEL-written-by-the-test "$kr"'
touch "$ROOT/c6-release"; wait $BG; r3_unhold c6
check "the final check runs while the landing lock is still held"                        '[[ -f "$ROOT/c6-final-under-lock" ]]'
check "…and the lock is released when the run ends"                                      '[[ ! -e "$LOCAL_MERGE_QUEUE_STATE/locks/c6" ]]'

echo
echo "── round 3 · cleanup keeps what the gate did not see, and deletes only the landed tip ──"
# THE NIT (reviewer, finding 8): cleanup ran `git worktree remove --force` and deleted the remote
# branch whatever it held, so files made in the worktree after the gate were destroyed, and a commit
# pushed to the remote branch after the publish was deleted with it. The origin's hook holds the
# push of main until the test says go, which is the window those things happen in.
r3_init c7
r3_hook c7
r3_config c7 "\"gate\": [\"$(r3_gate_step c7)\"], \"finalCheck\": \"true\""
cat > "$ROOT/c7-hook.sh" <<'SH'
if [ "$ref" = refs/heads/main ] && [ -e "$ROOT/c7-hold-main" ]; then
  touch "$ROOT/c7-push-started"
  for i in $(seq 1 150); do [ -e "$ROOT/c7-go" ] && break; sleep 0.2; done
fi
SH
c7_window () {  # runs a landing run whose push of main is held; the caller acts in the window, then it is released
  rm -f "$ROOT/c7-push-started" "$ROOT/c7-go"; touch "$ROOT/c7-hold-main"
  $LOCAL_MERGE_QUEUE land c7 > "$ROOT/c7-land.out" 2>&1 &
  BG=$!
  r3_wait "$ROOT/c7-push-started"
}
c7_release () { touch "$ROOT/c7-go"; wait $BG; rc=$?; rm -f "$ROOT/c7-hold-main"; out=$(cat "$ROOT/c7-land.out"); }

# 1. Work made in the worktree after the gate survives the cleanup.
r3_branch c7 late late.txt=gated
r3_queue c7 late
c7_window
echo "work in progress" > "$(r3_wt c7 late)/notes.txt"
echo "an edit made after the gate" >> "$(r3_wt c7 late)/late.txt"
c7_release
check "an entry is landed, whatever was made in its worktree meanwhile (exit 3: a cleanup left residue)" '[[ $rc == 3 && "$(r3_qinfo)" == "" && "$(git -C "$ROOT/c7" show main:late.txt)" == gated ]]'
check "…the untracked file and the uncommitted edit made after the gate survive: the worktree is kept" '[[ -f "$(r3_wt c7 late)/notes.txt" && "$(cat "$(r3_wt c7 late)/late.txt")" == *"an edit made after the gate"* ]]'
check "…the branch stays with its worktree, and the run says why, in red, as residue"    'git -C "$ROOT/c7" rev-parse --verify -q refs/heads/late >/dev/null && [[ "$out" == *"WORKTREE KEPT"* && "$out" == *notes.txt* ]]'
rm -rf "$(r3_wt c7 late)"; git -C "$ROOT/c7" worktree prune; git -C "$ROOT/c7" branch -q -D late; git -C "$ROOT/c7-origin.git" branch -q -D late 2>/dev/null

# 2. A commit pushed to the remote branch after the publish is not deleted with it.
r3_branch c7 foreign foreign.txt=gated
r3_queue c7 foreign
c7_window
( cd "$ROOT/c7-other" && git fetch -q origin foreign && git checkout -q -B foreign origin/foreign && echo theirs > theirs.txt && git add -A && git commit -qm "pushed by somebody else after the publish" && git push -q origin foreign && git checkout -q main )
theirs=$(git -C "$ROOT/c7-other" rev-parse foreign)
c7_release
check "an entry whose remote branch gained a commit after the publish still lands (exit 3)" '[[ $rc == 3 && "$(git -C "$ROOT/c7" show main:foreign.txt)" == gated ]]'
check "…and the remote branch is kept, with the commit somebody else pushed"             '[[ "$(git -C "$ROOT/c7-origin.git" rev-parse refs/heads/foreign)" == "$theirs" && "$out" == *"REMOTE BRANCH KEPT"* && "$out" == *"is not the landed tip"* ]]'
check "…while the clean worktree and the local branch are removed as before"              '[[ ! -d "$(r3_wt c7 foreign)" ]] && ! git -C "$ROOT/c7" rev-parse --verify -q refs/heads/foreign >/dev/null'

# 3. A branch merged by hand, whose worktree holds a file made after the enqueue, is cleaned up without that file.
r3_branch c7 byhand byhand.txt=1
r3_queue c7 byhand
git -C "$ROOT/c7" merge -q --no-ff -m "merged by hand" byhand && git -C "$ROOT/c7" push -q origin main
echo "scratch" > "$(r3_wt c7 byhand)/scratch.txt"
out=$($LOCAL_MERGE_QUEUE land c7 2>&1)
check "a cleanup-only entry keeps a worktree that holds an untracked file, and says so"   '[[ "$out" == *"cleanup only"* && -f "$(r3_wt c7 byhand)/scratch.txt" && "$out" == *"WORKTREE KEPT"* ]]'
# …and a clean one is removed, local and remote branches included, as it always was (tests 10 and 12 above pin the rest).
r3_branch c7 byhand2 byhand2.txt=1
r3_queue c7 byhand2
git -C "$ROOT/c7" merge -q --no-ff -m "merged by hand again" byhand2 && git -C "$ROOT/c7" push -q origin main
out=$($LOCAL_MERGE_QUEUE land c7 2>&1)
check "a clean cleanup-only entry is removed entirely: worktree, local and remote branch" '[[ ! -d "$(r3_wt c7 byhand2)" ]] && ! git -C "$ROOT/c7" rev-parse --verify -q refs/heads/byhand2 >/dev/null && ! git -C "$ROOT/c7-origin.git" rev-parse --verify -q refs/heads/byhand2 >/dev/null'

echo
echo "── round 3 · batched landing: the guards the re-check found unpinned ────────"
# The re-check removed each guard in turn and found that nothing failed. Each test here fails when
# the guard it names is taken out, because it asserts the guard's own message (or its effect).
export HERE
r3_init c8
r3_hook c8
r3_config c8 "\"batch\": {\"max\": 5}, \"gate\": [\"$(r3_gate_step c8)\"], \"finalCheck\": \"true\""
cat > "$ROOT/c8-hook.sh" <<'SH'
if [ "$ref" = refs/heads/main ] && [ -e "$ROOT/c8-hold-main" ]; then
  touch "$ROOT/c8-push-started"
  for i in $(seq 1 150); do [ -e "$ROOT/c8-go" ] && break; sleep 0.2; done
fi
if [ "$ref" = refs/heads/main ] && [ -e "$ROOT/c8-reject-main" ]; then echo "REJECTED BY TEST HOOK" >&2; exit 1; fi
if [ -e "$ROOT/c8-unapprove-on" ] && [ "$ref" = "refs/heads/$(cat "$ROOT/c8-unapprove-on")" ]; then node "$HERE/local-merge-queue.mjs" unapprove "$(cat "$ROOT/c8-unapprove")" --repo c8 >/dev/null 2>&1; fi
SH
c8_pair () {  # a prefix: two entries, approved
  r3_branch c8 "$1-1" "$1-1.txt=1"; r3_branch c8 "$1-2" "$1-2.txt=2"; r3_queue c8 "$1-1" "$1-2"
}
c8_gated () {  # a land run whose batch gate is held; the caller acts, then it is released
  r3_hold c8; : > "$ROOT/c8-gate.log"
  $LOCAL_MERGE_QUEUE land c8 > "$ROOT/c8-land.out" 2>&1 &
  BG=$!
  r3_wait "$ROOT/c8-gate-started"
}
c8_release () { touch "$ROOT/c8-release"; wait $BG; rc=$?; out=$(cat "$ROOT/c8-land.out"); r3_unhold c8; }

# 1. Guard: an entry's worktree must still be clean.
c8_pair wc
c8_gated
echo "left by somebody" > "$(r3_wt c8 wc-2)/scratch.txt"
c8_release
check "an untracked file made in an entry's worktree during the batch gate fails the batch" '[[ "$out" == *"BATCH FAILED: wc-2 changed while the batch was gated"* ]]'
check "…and the entries still land, one at a time"                                         '[[ -f "$ROOT/c8/wc-1.txt" && -f "$ROOT/c8/wc-2.txt" ]]'

# 2. Guard: the entry's remote branch is compared with what it was. Nothing is published before it fails.
c8_pair rb
c8_gated
( cd "$ROOT/c8-other" && git fetch -q origin rb-2 && git checkout -q -B rb-2 origin/rb-2 && echo theirs > rb-theirs.txt && git add -A && git commit -qm "pushed to the remote branch during the gate" && git push -q origin rb-2 && git checkout -q main )
: > "$ROOT/c8-refs.log"
c8_release
check "a push to an entry's remote branch during the batch gate fails the batch with that message" '[[ "$out" == *"BATCH FAILED: rb-2 changed while the batch was gated"* ]]'

# 3. Guard: origin's main moved while the candidate was gated.
c8_pair mv
c8_gated
r3_outside c8 other/moved.txt=1 "pushed to main during the batch gate"
: > "$ROOT/c8-refs.log"
c8_release
check "main moving during the batch gate fails the batch with the stale-gate message, not at the push" '[[ "$out" == *"BATCH FAILED: main moved while the candidate was gated, so the gate result is stale"* ]]'
check "…and before any entry's tip was published for the batch"                              '[[ "$out" != *"BATCH FAILED: origin rejected"* ]]'

# 4. Guard: each entry's rebased tip is published before main is pushed, so its pull request can retire as merged.
c8_pair pb
: > "$ROOT/c8-refs.log"
$LOCAL_MERGE_QUEUE land c8 > "$ROOT/c8-land.out" 2>&1; rc=$?
out=$(cat "$ROOT/c8-land.out")
second=$(grep "^refs/heads/pb-2 " "$ROOT/c8-refs.log" | grep -v " 0000000" | head -1 | cut -d" " -f2)
check "(setup of the test) the pair landed as one batch"                                      '[[ $rc == 0 && "$out" == *"gated together in one batch, landed in one push: pb-1, pb-2"* ]]'
check "the second entry's rebased tip was pushed to its own branch on origin, before main"     '[[ -n "$second" && "$(grep -n "^refs/heads/pb-2 $second" "$ROOT/c8-refs.log" | head -1 | cut -d: -f1)" -lt "$(grep -n "^refs/heads/main " "$ROOT/c8-refs.log" | head -1 | cut -d: -f1)" ]]'
check "…and that tip is reachable from main (which is what lets its pull request close as merged)" '[[ -n "$second" ]] && git -C "$ROOT/c8-origin.git" merge-base --is-ancestor $second main'

# 5. Approval is re-checked after the tips are pushed and before main is.
c8_pair ap
echo ap-2 > "$ROOT/c8-unapprove-on"; echo ap-1 > "$ROOT/c8-unapprove"
: > "$ROOT/c8-refs.log"
out=$($LOCAL_MERGE_QUEUE land c8 2>&1)
rm -f "$ROOT/c8-unapprove-on" "$ROOT/c8-unapprove"
check "an entry unapproved while the tips are being pushed fails the batch before main is pushed" '[[ "$out" == *"BATCH FAILED: ap-1 was unapproved"* ]]'
check "…and the unapproved entry does not land (it stays enqueued), while the other does"      '[[ ! -f "$ROOT/c8/ap-1.txt" && -f "$ROOT/c8/ap-2.txt" && "$(r3_qinfo)" == ap-1:enqueued ]]'
$LOCAL_MERGE_QUEUE dequeue ap-1 --repo c8 >/dev/null 2>&1

# 6. No `reset --hard` discards work in an entry's worktree after the push.
c8_pair rs
rm -f "$ROOT/c8-push-started" "$ROOT/c8-go"; touch "$ROOT/c8-hold-main"
$LOCAL_MERGE_QUEUE land c8 > "$ROOT/c8-land.out" 2>&1 &
BG=$!
r3_wait "$ROOT/c8-push-started"
echo "an edit made after the final check" >> "$(r3_wt c8 rs-1)/rs-1.txt"
echo "a new file" > "$(r3_wt c8 rs-1)/notes.txt"
touch "$ROOT/c8-go"; wait $BG; rc=$?; rm -f "$ROOT/c8-hold-main"; out=$(cat "$ROOT/c8-land.out")
check "(setup of the test) the batch landed both entries (exit 3: the kept worktree is residue)" '[[ $rc == 3 && "$(git -C "$ROOT/c8" show main:rs-1.txt)" == 1 && -f "$ROOT/c8/rs-2.txt" ]]'
check "an uncommitted edit and a new file made in an entry's worktree after the final check survive" '[[ "$(cat "$(r3_wt c8 rs-1)/rs-1.txt")" == *"an edit made after the final check"* && -f "$(r3_wt c8 rs-1)/notes.txt" ]]'
check "…the entry's worktree and branch are kept, and the run says why"                        '[[ "$out" == *"WORKTREE KEPT"* ]] && git -C "$ROOT/c8" rev-parse --verify -q refs/heads/rs-1 >/dev/null'

# 7. A failed batch says the remote tips were rewritten.
c8_pair fm
touch "$ROOT/c8-reject-main"
out=$($LOCAL_MERGE_QUEUE land c8 2>&1)
rm -f "$ROOT/c8-reject-main"
check "the failed-batch message says the entries' remote tips were already rewritten"          '[[ "$out" == *"BATCH FAILED: origin rejected the push of main, so nothing has landed"* && "$out" == *"remote branch"*"fm-1, fm-2"*"already"*"rebased tips"* && "$out" == *"Falling back to landing fm-1, fm-2 one at a time"* ]]'

echo
echo "── round 3 · both guards of a lock's release are kept, and each is pinned ───"
# lockRelease removes a lock only if it is ours, and checks that again after moving it aside (and puts
# it back if it was not). The re-check found the first guard removable with every test still green, and
# the second insufficient alone under contention (demonstrated), so each must be pinned by a test
# that fails without it. The seam LOCAL_MERGE_QUEUE_TEST_RELEASE_SEAM=<prefix> writes <prefix>.checked
# when a release gets past the first guard, and waits there for <prefix>.go.
LG="$ROOT/c8b-state"
printf '{ "repos": { "x": { "checkout": "%s" } } }\n' "$ROOT" > "$ROOT/c8b-repos.json"; export LOCAL_MERGE_QUEUE_CONFIG="$ROOT/c8b-repos.json"
c8b_queue () { rm -rf "$LG"; mkdir -p "$LG"; node -e 'require("fs").writeFileSync(process.argv[1]+"/queue.json",JSON.stringify({entries:[{repo:"x",branch:"x1",worktree:"/x",status:"enqueued",lanes:[],reached:[]}]}))' "$LG"; rm -f "$ROOT/c8b-seam".* "$ROOT/c8b-pause"; }
# Guard 1: a release of a lock that is not ours never moves it aside.
c8b_queue
touch "$ROOT/c8b-seam.go"
LOCAL_MERGE_QUEUE_STATE="$LG" LOCAL_MERGE_QUEUE_TEST_PAUSE_IN_LOCK="$ROOT/c8b-pause" LOCAL_MERGE_QUEUE_TEST_RELEASE_SEAM="$ROOT/c8b-seam" $LOCAL_MERGE_QUEUE approve x1 --repo x >/dev/null 2>&1 &
BG=$!
for i in $(seq 1 100); do [[ -f "$LG/queue.lock/owner.json" ]] && break; sleep 0.1; done
echo "{\"pid\":$$,\"token\":\"someone-elses-token\",\"since\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\"}" > "$LG/queue.lock/owner.json"
touch "$ROOT/c8b-pause"; wait $BG
check "a release whose lock is not its own stops at the first guard: it never moves the lock aside" '[[ ! -e "$ROOT/c8b-seam.checked" ]] && grep -q someone-elses-token "$LG/queue.lock/owner.json"'
# Guard 2: the lock changed hands between the first guard and the rename, so what was moved aside is put back.
c8b_queue
LOCAL_MERGE_QUEUE_STATE="$LG" LOCAL_MERGE_QUEUE_TEST_RELEASE_SEAM="$ROOT/c8b-seam" $LOCAL_MERGE_QUEUE approve x1 --repo x >/dev/null 2>&1 &
BG=$!
r3_wait "$ROOT/c8b-seam.checked"
rm -rf "$LG/queue.lock"; mkdir "$LG/queue.lock"
echo "{\"pid\":$$,\"token\":\"took-over-meanwhile\",\"since\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\"}" > "$LG/queue.lock/owner.json"
touch "$ROOT/c8b-seam.go"; wait $BG
check "a release that finds another process's lock where its own was puts that lock back untouched" '[[ -f "$LG/queue.lock/owner.json" ]] && grep -q took-over-meanwhile "$LG/queue.lock/owner.json" && ! ls "$LG" | grep -q "gone-"'
rm -rf "$LG" "$ROOT/c8b-seam".* "$ROOT/c8b-pause"

echo
echo "── round 3 · main moved under a passing gate: redo the merge, and gate again only the lanes that moved ──"
# THE LOSS (2026-11-22): a 54-minute gate passed, and the push of main was rejected as non-fast-forward
# because a scheduled bot had pushed one commit to origin/main during the gate, changing one data file
# outside every lane the gate covered. The run rolled the merge back and exited, and the gate had to be
# paid again. The remedy is conservative: when the push is rejected because origin/main moved, fetch; if
# every new commit changes only paths that belong to no lane this entry gated (by the lanes' own path
# rules; a path that matches no lane at all counts as outside), redo the merge on the new main without a
# new gate, at most twice. When the commits touch one or more of the entry's gated lanes the merge is
# redone too, and only the gates of the lanes those commits touch run again (lanes are independent by
# the queue's own definition); a rewritten history, a third move or a failing gate stalls the entry.
r3_init c9
r3_hook c9
cat > "$ROOT/c9-hook.sh" <<'SH'
# a bot: while c9-bot-left holds a positive number, each push of main makes another clone push one
# commit to origin's main first (so the push is rejected, and origin has moved)
if [ "$ref" = refs/heads/main ] && [ -e "$ROOT/c9-bot-left" ] && [ -z "${IN_BOT:-}" ]; then
  n=$(cat "$ROOT/c9-bot-left")
  if [ "$n" -gt 0 ]; then
    echo $((n-1)) > "$ROOT/c9-bot-left"
    d=$(cat "$ROOT/c9-bot-dir" 2>/dev/null || echo other)
    ( unset GIT_DIR GIT_QUARANTINE_PATH GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES; export IN_BOT=1
      cd "$ROOT/c9-other" && git pull -q origin main && mkdir -p $d && echo $n > $d/bot-$n.txt && git add -A \
        && git commit -qm "bot commit $n" && git push -q origin main ) >/dev/null 2>&1
    echo "REJECTED: main moved" >&2; exit 1
  fi
fi
SH
cfg_lanes () { r3_config c9 "\"lanes\": { \"a\": { \"paths\": [\"a/\"], \"gate\": [\"$(r3_gate_step c9 a)\"]$1 }, \"b\": { \"paths\": [\"b/\"], \"gate\": [\"$(r3_gate_step c9 b)\"] } }"; }
cfg_lanes ''
c9_gated () {  # branch: a land run whose gate is held; the caller acts, then c9_release
  r3_hold c9; : > "$ROOT/c9-gate.log"
  $LOCAL_MERGE_QUEUE land c9 > "$ROOT/c9-land.out" 2>&1 &
  BG=$!
  r3_wait "$ROOT/c9-gate-started"
}
c9_release () { touch "$ROOT/c9-release"; wait $BG; rc=$?; out=$(cat "$ROOT/c9-land.out"); r3_unhold c9; }

# 1. A commit whose path belongs to no lane at all counts as outside: the merge is redone, with no new gate.
r3_branch c9 s1 a/s1.txt=1; r3_queue c9 s1
c9_gated
r3_outside c9 other/data.json=1 "bot: refresh data"
bot=$(git -C "$ROOT/c9-other" rev-parse HEAD)
c9_release
check "a commit on a path that belongs to no lane does not cost a second gate: the entry lands"  '[[ $rc == 0 && "$(r3_gates c9)" == 1 && -f "$ROOT/c9/a/s1.txt" && -f "$ROOT/c9/other/data.json" ]] && r3_main_eq c9'
check "…the merge was redone on the bot's commit, and merges the gated commit"                    '[[ "$(git -C "$ROOT/c9" rev-parse main^1)" == "$bot" && "$out" == *"redoing the merge"* ]]'
check "…and no stall was recorded"                                                                '[[ "$(r3_qinfo)" == "" ]]'

# 2. A commit on another lane's path, not gated for this entry, is outside too.
r3_branch c9 s2 a/s2.txt=1; r3_queue c9 s2
c9_gated
r3_outside c9 b/data.json=1 "bot: refresh b"
c9_release
check "a commit that touches only a lane this entry did not gate is redone without a new gate"  '[[ $rc == 0 && "$(r3_gates c9)" == 1 && -f "$ROOT/c9/a/s2.txt" && -f "$ROOT/c9/b/data.json" ]] && r3_main_eq c9'

# 3. A commit that touches a gated lane's path must not merge without a gate: the merge is redone and that lane is gated again.
r3_branch c9 s3 a/s3.txt=1; r3_queue c9 s3
c9_gated
r3_outside c9 a/bot.txt=1 "bot: touches the gated lane"
bot=$(git -C "$ROOT/c9-other" rev-parse HEAD)
c9_release
check "a commit that touches a gated lane's path is not merged without a gate: the lane's gate runs again (two runs in all) and the entry lands" '[[ $rc == 0 && "$(r3_gates c9)" == 2 && "$(r3_lane_gates c9 a)" == 2 && -f "$ROOT/c9/a/s3.txt" && -f "$ROOT/c9/a/bot.txt" ]] && r3_main_eq c9'
check "…the merge was redone on the bot's commit, and says which lane runs again"                  '[[ "$(git -C "$ROOT/c9" rev-parse main^1)" == "$bot" && "$out" == *"redoing the merge"* && "$out" == *"lane a"* && "$out" == *"gate runs again and no other"* ]]'
check "…the second gate ran on the merged tree, in the entry's worktree, and the worktree is cleaned up" '[[ ! -d "$(r3_wt c9 s3)" && "$(r3_qinfo)" == "" ]]'
# …and a second gate that fails stalls the entry, with main reset to origin's.
r3_branch c9 s3b a/s3b.txt=1; r3_queue c9 s3b
touch "$ROOT/c9-fail-after-first"
c9_gated
r3_outside c9 a/bot2.txt=1 "bot: touches the gated lane again"
before=$(git -C "$ROOT/c9-origin.git" rev-parse main)
c9_release
rm -f "$ROOT/c9-fail-after-first"
check "a gate that fails on the moved main stalls the entry, naming the lane and the moved main"    '[[ $rc == 2 && "$out" == *"main moved under a passing gate"* && "$out" == *"failed on the new main"* && "$(r3_qinfo)" == s3b:stalled ]]'
check "…nothing of the entry reached main or origin, local main equals origin again, and the worktree is back on its branch" '[[ "$(git -C "$ROOT/c9-origin.git" rev-parse main)" == "$before" && ! -f "$ROOT/c9/a/s3b.txt" ]] && r3_main_eq c9 && [[ "$(git -C "$(r3_wt c9 s3b)" rev-parse --abbrev-ref HEAD)" == s3b ]]'
: > "$ROOT/c9-gate.log"
$LOCAL_MERGE_QUEUE resume c9 >/dev/null 2>&1; rc=$?
check "resume rebases it onto the new main, gates it, and lands it"                                '[[ $rc == 0 && -f "$ROOT/c9/a/s3b.txt" && -f "$ROOT/c9/a/bot2.txt" ]] && r3_main_eq c9'

# 4. History that was rewritten (not a fast-forward of the commit the run built on) is never redone.
r3_branch c9 s4 a/s4.txt=1; r3_queue c9 s4
c9_gated
( cd "$ROOT/c9-other" && git pull -q origin main 2>/dev/null; git commit -q --amend -m "rewritten tip" && git push -q --force origin main )
c9_release
check "a rewritten origin/main stalls the entry instead of being merged onto"                     '[[ $rc == 2 && "$out" == *"main moved under a passing gate"* && "$out" == *"was rewritten: it no longer descends"* && "$(r3_qinfo)" == s4:stalled ]]'
$LOCAL_MERGE_QUEUE dequeue s4 --repo c9 >/dev/null 2>&1

# 5. A bot that moves main again at every push: redone at most twice, then stalled.
r3_branch c9 s5 a/s5.txt=1; r3_queue c9 s5
echo 5 > "$ROOT/c9-bot-left"; : > "$ROOT/c9-gate.log"
out=$(gtimeout 180 $LOCAL_MERGE_QUEUE land c9 2>&1); rc=$?
left=$(cat "$ROOT/c9-bot-left"); rm -f "$ROOT/c9-bot-left"
check "main that moves at every push is redone at most twice (three pushes in all), then the entry stalls" '[[ $rc == 2 && "$left" == 2 && "$out" == *"main moved under a passing gate"* && "$out" == *"after 2 redos"* && "$(r3_gates c9)" == 1 && "$(r3_qinfo)" == s5:stalled ]]'
check "…leaving local main equal to origin's"                                                      'r3_main_eq c9'
$LOCAL_MERGE_QUEUE dequeue s5 --repo c9 >/dev/null 2>&1
# …and one move followed by a quiet push lands after a single redo.
r3_branch c9 s6 a/s6.txt=1; r3_queue c9 s6
echo 1 > "$ROOT/c9-bot-left"; : > "$ROOT/c9-gate.log"
out=$(gtimeout 180 $LOCAL_MERGE_QUEUE land c9 2>&1); rc=$?
rm -f "$ROOT/c9-bot-left"
check "one move during the push is redone once and lands, still on one gate"                       '[[ $rc == 0 && "$(r3_gates c9)" == 1 && -f "$ROOT/c9/a/s6.txt" && -f "$ROOT/c9/other/bot-1.txt" ]] && r3_main_eq c9'

# 6. A push that is rejected while origin has NOT moved is the old failure: rolled back, the run dies.
r3_branch c9 s7 a/s7.txt=1; r3_queue c9 s7
cat > "$ROOT/c9-hook.sh" <<'SH'
if [ "$ref" = refs/heads/main ] && [ -e "$ROOT/c9-reject" ]; then echo "REJECTED BY TEST HOOK" >&2; exit 1; fi
SH
touch "$ROOT/c9-reject"
out=$($LOCAL_MERGE_QUEUE land c9 2>&1); rc=$?
rm -f "$ROOT/c9-reject"
check "a rejection with no move of main is still rolled back and fatal (entry stays approved)"     '[[ $rc != 0 && "$out" == *"push to origin/main failed, so the merge was rolled back locally"* && "$(r3_qinfo)" == s7:approved ]] && r3_main_eq c9'
$LOCAL_MERGE_QUEUE dequeue s7 --repo c9 >/dev/null 2>&1

# 7. A lane that REACHES the commit's paths (the lane's own reach rule) is gated again.
cfg_lanes ', "reach": { "when": "grep -q ^other/" }'
r3_branch c9 s8 a/s8.txt=1; r3_queue c9 s8
c9_gated
r3_outside c9 other/read-by-a.txt=1 "bot: a file the gated lane reads"
c9_release
check "a commit that reaches the gated lane by its reach rule gets that lane's gate run again, and lands" '[[ $rc == 0 && "$(r3_gates c9)" == 2 && "$out" == *"lane a"* ]] && r3_main_eq c9'

# 8. One lane: every path belongs to the one lane, so the one lane's gate runs again.
r3_config c9 "\"gate\": [\"$(r3_gate_step c9)\"], \"finalCheck\": \"true\""
r3_branch c9 s9 a/s9.txt=1; r3_queue c9 s9
c9_gated
r3_outside c9 other/anything.txt=1 "bot: anything"
c9_release
check "in a one-lane repo any commit on origin's main during the gate gets the gate run again, and lands" '[[ $rc == 0 && "$(r3_gates c9)" == 2 ]] && r3_main_eq c9'

# 9. Only the lanes the commits touch are gated again: an entry that gated two lanes re-runs the cheap one alone.
cfg_lanes ''
r3_branch c9 t1 a/t1.txt=1 b/t1.txt=1; r3_queue c9 t1
c9_gated
r3_outside c9 b/moved.txt=1 "bot: touches lane b only"
c9_release
check "an upstream commit in lane b re-runs lane b's gate only: a once, b twice"                  '[[ $rc == 0 && "$(r3_lane_gates c9 a)" == 1 && "$(r3_lane_gates c9 b)" == 2 && -f "$ROOT/c9/b/moved.txt" && -f "$ROOT/c9/a/t1.txt" ]] && r3_main_eq c9'

# 10. A lane that takes "*" is touched only by a path no other lane claims.
r3_config c9 "\"lanes\": { \"a\": { \"paths\": [\"a/\"], \"gate\": [\"$(r3_gate_step c9 a)\"] }, \"rest\": { \"paths\": \"*\", \"gate\": [\"$(r3_gate_step c9 rest)\"] } }"
r3_branch c9 t2 a/t2.txt=1 misc/t2.txt=1; r3_queue c9 t2
c9_gated
r3_outside c9 elsewhere/data.json=1 "bot: a path no named lane claims"
c9_release
check "an upstream path no named lane claims falls to the catch-all lane: its gate runs again, the other lane's does not" '[[ $rc == 0 && "$(r3_lane_gates c9 a)" == 1 && "$(r3_lane_gates c9 rest)" == 2 ]] && r3_main_eq c9'
r3_branch c9 t3 a/t3.txt=1 misc/t3.txt=1; r3_queue c9 t3
c9_gated
r3_outside c9 a/other-bot.txt=1 "bot: a path lane a claims"
c9_release
check "a path a named lane claims does not touch the catch-all lane: only that lane's gate runs again" '[[ $rc == 0 && "$(r3_lane_gates c9 a)" == 2 && "$(r3_lane_gates c9 rest)" == 1 ]] && r3_main_eq c9'

# 11. A third move stalls: the merge is redone (and the touched lane gated again) at most twice.
cfg_lanes ''
cat > "$ROOT/c9-hook.sh" <<'SH'
if [ "$ref" = refs/heads/main ] && [ -e "$ROOT/c9-bot-left" ] && [ -z "${IN_BOT:-}" ]; then
  n=$(cat "$ROOT/c9-bot-left")
  if [ "$n" -gt 0 ]; then
    echo $((n-1)) > "$ROOT/c9-bot-left"
    d=$(cat "$ROOT/c9-bot-dir" 2>/dev/null || echo other)
    ( unset GIT_DIR GIT_QUARANTINE_PATH GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES; export IN_BOT=1
      cd "$ROOT/c9-other" && git pull -q origin main && mkdir -p $d && echo $n > $d/bot-$n.txt && git add -A \
        && git commit -qm "bot commit $n" && git push -q origin main ) >/dev/null 2>&1
    echo "REJECTED: main moved" >&2; exit 1
  fi
fi
SH
r3_branch c9 u1 a/u1.txt=1; r3_queue c9 u1
echo a > "$ROOT/c9-bot-dir"; echo 5 > "$ROOT/c9-bot-left"; : > "$ROOT/c9-gate.log"
out=$(gtimeout 300 $LOCAL_MERGE_QUEUE land c9 2>&1); rc=$?
left=$(cat "$ROOT/c9-bot-left"); rm -f "$ROOT/c9-bot-left" "$ROOT/c9-bot-dir"
check "a main that moves at every push, in the gated lane: redone twice with the lane gated each time (three gate runs), then the entry stalls" '[[ $rc == 2 && "$left" == 2 && "$out" == *"after 2 redos"* && "$(r3_gates c9)" == 3 && "$(r3_qinfo)" == u1:stalled ]] && r3_main_eq c9'

echo
echo "── round 3 · batch.keep without a max leaves batching off; a dry run does not say it landed ──"
# The config can now name the batch worktree's kept dependency directories (batch.keep) without
# turning batching on for every run: only a "max" does that. --batch turns it on for one run.
r3_init c10
r3_config c10 '"batch": {"keep": ["node_modules"]}, "gate": ["true"], "finalCheck": "true"'
r3_branch c10 k1 k1.txt=1; r3_branch c10 k2 k2.txt=2; r3_queue c10 k1 k2
out=$($LOCAL_MERGE_QUEUE land c10 --dry-run 2>&1); rc=$?
check "a batch key with keep and no max is accepted, and batching stays off for a run without --batch" '[[ $rc == 0 && "$out" != *"gated together, one gate run"* ]]'
out=$($LOCAL_MERGE_QUEUE land c10 --dry-run --batch 2>&1); rc=$?
check "--batch turns it on for the run, with the default maximum"                         '[[ $rc == 0 && "$out" == *"gated together, one gate run: k1, k2"* ]]'
check "a dry run says it would land the entries, not that it landed them"                  '[[ "$out" == *"would land"* && "$out" != *"landed"*"branch(es) into"* ]]'
r3_config c10 '"batch": {"max": 5, "keep": ["node_modules"]}, "gate": ["true"], "finalCheck": "true"'
out=$($LOCAL_MERGE_QUEUE land c10 --dry-run 2>&1)
check "a max in the config still turns batching on for every run"                         '[[ "$out" == *"gated together, one gate run: k1, k2"* ]]'
r3_config c10 '"batch": {"keep": "node_modules"}, "gate": ["true"]'
out=$($LOCAL_MERGE_QUEUE status c10 2>&1); rc=$?
check "a keep that is not an array of relative paths is still refused"                      '[[ $rc != 0 && "$out" == *batch.keep* ]]'

echo
echo "── round 3 · cleanup: what the gate leaves is the gate's; what appears after it is kept, and said truly ──"
# THE DEFECT (reviewer): cleanup's baseline was taken before the gate, so a gate that leaves any
# non-ignored file (a temp folder, build output) made every landing end in WORKTREE KEPT, with a
# cure that failed on exactly that case and no trace in status.
r3_init c11
r3_hook c11
cat > "$ROOT/c11-gate.sh" <<'SH'
#!/bin/bash
mkdir -p tmpout ign && echo x > tmpout/junk && echo y > ign/cache
SH
r3_config c11 "\"gate\": [\"bash $ROOT/c11-gate.sh\"], \"finalCheck\": \"true\""
r3_branch c11 leaves leaves.txt=1
r3_queue c11 leaves
out=$($LOCAL_MERGE_QUEUE land c11 2>&1); rc=$?
check "a gate that leaves a non-ignored folder and an ignored one does not keep the worktree: the entry lands and is cleaned up, exit 0" '[[ $rc == 0 && "$out" != *"WORKTREE KEPT"* && ! -d "$(r3_wt c11 leaves)" ]] && ! git -C "$ROOT/c11" rev-parse --verify -q refs/heads/leaves >/dev/null'
check "…and the ignored files that went with the worktree were named before they went"    '[[ "$out" == *"ignored files go with the worktree: ign/"* ]]'

cat > "$ROOT/c11-hook.sh" <<'SH'
if [ "$ref" = refs/heads/main ] && [ -e "$ROOT/c11-hold-main" ]; then
  touch "$ROOT/c11-push-started"
  for i in $(seq 1 150); do [ -e "$ROOT/c11-go" ] && break; sleep 0.2; done
fi
SH
c11_window () {  # branch, then the commands to run in the worktree while the push of main is held
  local b="$1"; shift
  rm -f "$ROOT/c11-push-started" "$ROOT/c11-go"; touch "$ROOT/c11-hold-main"
  $LOCAL_MERGE_QUEUE land c11 > "$ROOT/c11-land.out" 2>&1 &
  BG=$!
  r3_wait "$ROOT/c11-push-started"
  ( cd "$(r3_wt c11 $b)" && eval "$@" )
  touch "$ROOT/c11-go"; wait $BG; rc=$?; rm -f "$ROOT/c11-hold-main"; out=$(cat "$ROOT/c11-land.out")
}
r3_branch c11 late late.txt=1; r3_queue c11 late
c11_window late 'echo mine > notes.txt; echo mine > later.scratch'
check "files made after the gate (an untracked one and an ignored one) keep the worktree; the entry still lands" '[[ -f "$ROOT/c11/late.txt" && -f "$(r3_wt c11 late)/notes.txt" && -f "$(r3_wt c11 late)/later.scratch" ]]'
check "…the message says what was found and that it appeared after the gate ended, not what the gate made" '[[ "$out" == *"WORKTREE KEPT: it holds files that appeared after the gate ended"* && "$out" == *"?? notes.txt"* && "$out" == *"!! later.scratch"* && "$out" != *"tmpout"* ]]'
check "…the run exits 3, which says a cleanup left something"                              '[[ $rc == 3 ]]'
st=$($LOCAL_MERGE_QUEUE status c11 2>&1)
check "status names the kept worktree, its reason and the way to finish it"                '[[ "$st" == *"left a worktree kept"* && "$st" == *"late"* && "$st" == *"Look first: git -C"* && "$st" == *"worktree remove --force"* && "$st" == *"notes.txt"* ]]'
cure=$(grep -m1 "Then, once you have kept what you want: " <<<"$st" | perl -pe 's/\e\[[0-9;]*m//g; s/.*what you want: //')
bash -c "$cure" >/dev/null 2>&1; crc=$?
check "the cure that is printed works on this case: it removes the worktree and the branch"  '[[ $crc == 0 && ! -d "$(r3_wt c11 late)" ]] && ! git -C "$ROOT/c11" rev-parse --verify -q refs/heads/late >/dev/null'
check "…and status stops naming it once it is gone"                                         '[[ "$($LOCAL_MERGE_QUEUE status c11 2>&1)" != *"left a worktree kept"* ]]'
# An ignored file alone, made after the gate, keeps the worktree too: it is deleted by --force and no status line shows it.
r3_branch c11 ignoredlate ignoredlate.txt=1; r3_queue c11 ignoredlate
c11_window ignoredlate 'echo mine > only.scratch'
check "an ignored file made after the gate keeps the worktree"                              '[[ "$out" == *"WORKTREE KEPT"* && "$out" == *"!! only.scratch"* && -f "$(r3_wt c11 ignoredlate)/only.scratch" && $rc == 3 ]]'

echo
echo "── round 3 · local main is re-checked before the merge (review item 2) ───────"
# THE DEFECT (reviewer, finding 2): the unbatched path synced local main once, gated for minutes,
# then merged onto whatever local main was. (a) A pull in the primary checkout during the gate moved
# main to a commit the gate never saw, and the redo rule's lane test was bypassed, since the push was
# not rejected. (b) A stray commit on local main in the primary checkout was pushed ungated by the merge.
r3_init c12
r3_hook c12
r3_config c12 "\"gate\": [\"$(r3_gate_step c12)\"], \"finalCheck\": \"true\""
c12_gated () {
  r3_hold c12; : > "$ROOT/c12-gate.log"
  $LOCAL_MERGE_QUEUE land c12 > "$ROOT/c12-land.out" 2>&1 &
  BG=$!
  r3_wait "$ROOT/c12-gate-started"
}
c12_release () { touch "$ROOT/c12-release"; wait $BG; rc=$?; out=$(cat "$ROOT/c12-land.out"); r3_unhold c12; }
# (a) a pulled commit
r3_branch c12 pulled pulled.txt=1; r3_queue c12 pulled
c12_gated
r3_outside c12 a/changed-meanwhile.txt=1 "pushed to origin during the gate"
git -C "$ROOT/c12" pull -q --ff-only origin main
theirs=$(git -C "$ROOT/c12-origin.git" rev-parse main)
c12_release
check "a pull in the primary checkout during the gate stalls the entry before the merge"      '[[ $rc == 2 && "$out" == *"local main moved during the gate"* && "$(r3_qinfo)" == pulled:stalled ]]'
check "…nothing was merged or pushed: origin's main is still the pulled commit"              '[[ "$(git -C "$ROOT/c12-origin.git" rev-parse main)" == "$theirs" && ! -e "$ROOT/c12/pulled.txt" ]]'
: > "$ROOT/c12-gate.log"
$LOCAL_MERGE_QUEUE resume c12 >/dev/null 2>&1; rc=$?
check "resume rebases it onto the current main, gates it again, and lands it"                '[[ $rc == 0 && "$(r3_gates c12)" == 1 && -f "$ROOT/c12/pulled.txt" && -f "$ROOT/c12/a/changed-meanwhile.txt" ]] && r3_main_eq c12'
# (b) a stray local commit
r3_branch c12 stray stray-entry.txt=1; r3_queue c12 stray
c12_gated
( cd "$ROOT/c12" && echo oops > stray.txt && git add stray.txt && git commit -qm "a stray commit in the primary checkout" )
origin_before=$(git -C "$ROOT/c12-origin.git" rev-parse main)
c12_release
check "a stray commit on local main during the gate stalls the entry, and is not pushed ungated" '[[ $rc == 2 && "$out" == *"local main moved during the gate"* && "$(git -C "$ROOT/c12-origin.git" rev-parse main)" == "$origin_before" ]]'
out=$($LOCAL_MERGE_QUEUE resume c12 2>&1); rc=$?
check "resume then refuses, because main is ahead of origin, naming the stray commit"       '[[ $rc != 0 && "$out" == *"a stray commit in the primary checkout"* ]]'
git -C "$ROOT/c12" reset -q --hard origin/main
$LOCAL_MERGE_QUEUE resume c12 >/dev/null 2>&1; rc=$?
check "…and once the stray commit is moved away it lands"                                    '[[ $rc == 0 && -f "$ROOT/c12/stray-entry.txt" && ! -e "$ROOT/c12/stray.txt" ]]'

echo
echo "── round 3 · a gate that modifies tracked files: the stall names the paths and the key; gateModifies exempts them ──"
# A gate (or a generator it runs) may rewrite a tracked file, a lockfile for instance. The commit
# binding would then stall every entry for ever, so a lane can name the paths its gate may modify.
r3_init c13
cat > "$ROOT/c13-gate.sh" <<'SH'
#!/bin/bash
echo "rewritten by the gate" >> a/f.txt
SH
r3_config c13 "\"gate\": [\"bash $ROOT/c13-gate.sh\"], \"finalCheck\": \"true\""
r3_branch c13 rewrites rewrites.txt=1; r3_queue c13 rewrites
out=$($LOCAL_MERGE_QUEUE land c13 2>&1); rc=$?
check "a gate that modifies a tracked file stalls the entry, listing the changed path"       '[[ $rc == 2 && "$out" == *"changed during the gate"* && "$out" == *"M a/f.txt"* ]]'
check "…and the message names the key that exempts it"                                         '[[ "$out" == *gateModifies* ]] && grep -q gateModifies "$LOCAL_MERGE_QUEUE_STATE/reports/c13-rewrites.md"'
$LOCAL_MERGE_QUEUE dequeue rewrites --repo c13 >/dev/null 2>&1
r3_config c13 "\"gate\": [\"bash $ROOT/c13-gate.sh\"], \"gateModifies\": [\"a/f.txt\"], \"finalCheck\": \"true\""
git -C "$(r3_wt c13 rewrites)" checkout -q -- a/f.txt
r3_queue c13 rewrites
out=$($LOCAL_MERGE_QUEUE land c13 2>&1); rc=$?
check "with the path named in gateModifies the entry lands, and the worktree is cleaned up"  '[[ $rc == 0 && -f "$ROOT/c13/rewrites.txt" && ! -d "$(r3_wt c13 rewrites)" ]]'
check "…the gate's rewrite is not in what landed (only the gated commit merges)"              '[[ "$(git -C "$ROOT/c13" show main:a/f.txt)" == a ]]'
# A prefix exempts what is under it, and nothing else.
cat > "$ROOT/c13-gate.sh" <<'SH'
#!/bin/bash
echo "rewritten by the gate" >> a/f.txt
echo "rewritten by the gate" >> b/f.txt
SH
r3_config c13 "\"gate\": [\"bash $ROOT/c13-gate.sh\"], \"gateModifies\": [\"a/\"], \"finalCheck\": \"true\""
r3_branch c13 partial partial.txt=1; r3_queue c13 partial
out=$($LOCAL_MERGE_QUEUE land c13 2>&1); rc=$?
check "a path outside the named prefixes still stalls the entry, and only it is listed"       '[[ $rc == 2 && "$out" == *"M b/f.txt"* && "$out" != *"M a/f.txt"* ]]'
$LOCAL_MERGE_QUEUE dequeue partial --repo c13 >/dev/null 2>&1
r3_config c13 '"gate": ["true"], "gateModifies": "a/f.txt"'
out=$($LOCAL_MERGE_QUEUE status c13 2>&1); rc=$?
check "a gateModifies that is not an array of relative paths is refused"                       '[[ $rc != 0 && "$out" == *gateModifies* ]]'

echo
echo "── round 3 · each guard of the commit binding is pinned by its own test (review item 4) ──"
# The re-check removed each of these in turn and nothing failed, because they are redundant in
# pairs: the merge names the recorded commit AND the check before it refuses a moved branch, and the
# publish likewise. A test seam (LOCAL_MERGE_QUEUE_TEST_HOLD) stops the run in each window between a
# check and the act it guards, so a commit made in the worktree there tells which guard held.
r3_init c14
r3_hook c14
r3_config c14 "\"gate\": [\"$(r3_gate_step c14)\"], \"finalCheck\": \"true\""
n14=0
c14_hold () {  # point: start a land that stops at <point>; every other point passes at once
  local p
  rm -f "$ROOT"/c14-hold.*
  for p in before-first-check before-publish before-second-check before-merge; do [[ $p == "$1" ]] || touch "$ROOT/c14-hold.$p.go"; done
  : > "$ROOT/c14-refs.log"
  LOCAL_MERGE_QUEUE_TEST_HOLD="$ROOT/c14-hold" $LOCAL_MERGE_QUEUE land c14 > "$ROOT/c14-land.out" 2>&1 &
  BG=$!
  r3_wait "$ROOT/c14-hold.$1"
}
c14_go () { touch "$ROOT/c14-hold.$1.go"; wait $BG; rc=$?; out=$(cat "$ROOT/c14-land.out"); }
c14_entry () {  # branch: an entry that needs a rebase (main moves after it is cut), approved
  r3_branch c14 "$1" "$1.txt=gated"
  n14=$((n14 + 1)); r3_outside c14 "other/moved-$n14.txt=1" "main moves under $1"
  r3_queue c14 "$1"
}
c14_ungated () { ( cd "$(r3_wt c14 "$1")" && echo ungated > sneaky.txt && git add -A && git commit -qm "made in the worktree, never gated" ); }

# 1. The check before the publish: nothing is published for a branch that moved.
c14_entry g1
c14_hold before-first-check
c14_ungated g1
c14_go before-first-check
check "the check before the publish stalls an entry whose branch moved after the gate, before anything is pushed for it" '[[ $rc == 2 && "$out" == *"changed during the gate"* ]] && ! grep -q "^refs/heads/g1 " "$ROOT/c14-refs.log"'
$LOCAL_MERGE_QUEUE dequeue g1 --repo c14 >/dev/null 2>&1

# 2. The publish names the recorded commit, not the branch: the remote branch never holds the ungated commit.
c14_entry g2
c14_hold before-publish
gated=$(git -C "$(r3_wt c14 g2)" rev-parse HEAD)
c14_ungated g2
c14_go before-publish
check "the publish pushes the gated commit, never the commit made in the worktree meanwhile (the entry then stalls)" '[[ $rc == 2 && "$out" == *"changed during the gate"* ]] && ! grep "^refs/heads/g2 " "$ROOT/c14-refs.log" | grep -qv "^refs/heads/g2 $gated"'
check "…and the remote branch holds the gated commit"                                     '[[ "$(git -C "$ROOT/c14-origin.git" rev-parse refs/heads/g2)" == "$gated" ]]'
$LOCAL_MERGE_QUEUE dequeue g2 --repo c14 >/dev/null 2>&1

# 3. The check before the merge: a branch that moved after the publish does not land.
c14_entry g3
c14_hold before-second-check
c14_ungated g3
c14_go before-second-check
check "the check before the merge stalls an entry whose branch moved after the publish: nothing lands" '[[ $rc == 2 && "$out" == *"changed during the gate"* && ! -e "$ROOT/c14/g3.txt" && ! -e "$ROOT/c14/sneaky.txt" ]]'
$LOCAL_MERGE_QUEUE dequeue g3 --repo c14 >/dev/null 2>&1

# 4. The merge names the recorded commit: a branch that moves between the last check and the merge still lands only the gated commit.
c14_entry g4
c14_hold before-merge
gated=$(git -C "$(r3_wt c14 g4)" rev-parse HEAD)
c14_ungated g4
c14_go before-merge
check "a commit made after the last check does not land: the merge's second parent is the gated commit" '[[ "$(git -C "$ROOT/c14" rev-parse main^2)" == "$gated" && -f "$ROOT/c14/g4.txt" && ! -e "$ROOT/c14/sneaky.txt" ]]'
check "…and the worktree, whose HEAD is not the landed commit, is kept (exit 3)"           '[[ $rc == 3 && -f "$(r3_wt c14 g4)/sneaky.txt" && "$out" == *"WORKTREE KEPT"* ]]'
git -C "$ROOT/c14" worktree remove --force "$(r3_wt c14 g4)"; git -C "$ROOT/c14" branch -q -D g4

# 5. The pair (reviewer): a hook that commits in the worktree while the publish push is in flight.
cat > "$ROOT/c14-hook.sh" <<'SH'
if [ "$ref" = "refs/heads/g5" ] && [ -e "$ROOT/c14-commit-on-push" ]; then
  rm -f "$ROOT/c14-commit-on-push"
  ( unset GIT_DIR GIT_QUARANTINE_PATH GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
    cd "$ROOT/c14-g5" && echo ungated > sneaky.txt && git add -A && git -c user.email=t@t.t -c user.name=T commit -qm "committed during the publish push" ) >/dev/null 2>&1
fi
SH
c14_entry g5
touch "$ROOT/c14-commit-on-push"
out=$($LOCAL_MERGE_QUEUE land c14 2>&1); rc=$?
check "a commit made in the worktree while the publish push is in flight does not land"   '[[ $rc == 2 && "$out" == *"changed during the gate"* && ! -e "$ROOT/c14/sneaky.txt" && ! -e "$ROOT/c14/g5.txt" ]] && r3_main_eq c14'

echo
echo "── round 3 · review item 7: the batch's reset --keep, and the redeploy push fetches first ──"
# 1. `git reset --keep` refuses where `--hard` would overwrite: a file made in an entry's worktree in
# the window between the guard and the branch move, named like a file the published tip brings.
r3_init c15
r3_hook c15
r3_config c15 "\"batch\": {\"max\": 5}, \"gate\": [\"$(r3_gate_step c15)\"], \"finalCheck\": \"true\""
r3_branch c15 k-1 k-1.txt=1; r3_branch c15 k-2 k-2.txt=2; r3_queue c15 k-1 k-2
rm -f "$ROOT"/c15-hold.*; touch "$ROOT/c15-hold.batch-move-k-1.go"
LOCAL_MERGE_QUEUE_TEST_HOLD="$ROOT/c15-hold" $LOCAL_MERGE_QUEUE land c15 > "$ROOT/c15-land.out" 2>&1 &
BG=$!
r3_wait "$ROOT/c15-hold.batch-move-k-2"
echo "mine, made after the guard" > "$(r3_wt c15 k-2)/k-1.txt"
touch "$ROOT/c15-hold.batch-move-k-2.go"; wait $BG; rc=$?; out=$(cat "$ROOT/c15-land.out")
check "(setup of the test) the batch landed both entries"                                  '[[ "$out" == *"landed in one push: k-1, k-2"* && -f "$ROOT/c15/k-2.txt" ]]'
check "a file made in the window between the guard and the branch move is not overwritten: the move is refused, not forced" '[[ "$(cat "$(r3_wt c15 k-2)/k-1.txt")" == "mine, made after the guard" && "$out" == *"COULD NOT MOVE k-2"* ]]'
check "…and the entry's worktree and branch are kept (exit 3)"                               '[[ $rc == 3 && "$out" == *"WORKTREE KEPT"* ]]'

# 2. The redeploy (settle) push fetches before it resets local main.
r3_init c15r
r3_hook c15r
r3_config c15r "\"deploy\": {\"skipMarker\": \"[skip-deploy]\"}, \"gate\": [\"$(r3_gate_step c15r)\"], \"finalCheck\": \"true\""
r3_branch c15r d1 d1.txt=1; r3_branch c15r d2 d2.txt=2; r3_queue c15r d1 d2
touch "$ROOT/c15r-fail-after-first"
$LOCAL_MERGE_QUEUE land c15r >/dev/null 2>&1; rc=$?
rm -f "$ROOT/c15r-fail-after-first"
check "(setup of the test) d1 landed marked and d2 stalled, so main sits on a build the host was told to skip" '[[ $rc == 2 && -f "$ROOT/c15r/d1.txt" && "$(git -C "$ROOT/c15r" log -1 --format=%B main)" == *"[skip-deploy]"* ]]'
$LOCAL_MERGE_QUEUE dequeue d2 --repo c15r >/dev/null 2>&1
cat > "$ROOT/c15r-hook.sh" <<'SH'
if [ "$ref" = refs/heads/main ] && [ -e "$ROOT/c15r-bot" ] && [ -z "${IN_BOT:-}" ]; then
  rm -f "$ROOT/c15r-bot"
  ( unset GIT_DIR GIT_QUARANTINE_PATH GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES; export IN_BOT=1
    cd "$ROOT/c15r-other" && git pull -q origin main && echo x > bot.txt && git add -A && git commit -qm "bot" && git push -q origin main ) >/dev/null 2>&1
  echo "REJECTED: main moved" >&2; exit 1
fi
SH
touch "$ROOT/c15r-bot"
out=$($LOCAL_MERGE_QUEUE land c15r 2>&1)
check "a redeploy push rejected because origin moved leaves local main on origin's new tip, not on a stale one" '[[ "$out" == *"THE REDEPLOY PUSH FAILED"* ]] && r3_main_eq c15r'
# ROUND3-END

echo
echo "════════════════════════════════════════════════════════════════"
echo "  passed $PASS   failed $FAIL"
# The sandbox is removed by its exact path when everything passed (it is a directory this script
# created with mktemp, and nothing else); after a failure it is left for inspection.
if [[ $FAIL == 0 && -n "$ROOT" && "$(basename "$ROOT")" == local-merge-queue-test.* && -d "$ROOT" ]]; then
  cd /; rm -rf -- "$ROOT"; echo "  sandbox removed"
else
  echo "  sandbox left at $ROOT"
fi
[[ $FAIL == 0 ]]
