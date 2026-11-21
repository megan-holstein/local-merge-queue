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
  touch "$ROOT/gate-started"
  for i in \$(seq 1 300); do [[ -e "$ROOT/gate-release" ]] && break; sleep 0.2; done
  [[ -e "$ROOT/gate-fail" ]] && exit 1
fi
test -f base.txt && test ! -e bad.txt
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
out=$($LOCAL_MERGE_QUEUE approve lock-a --repo b 2>&1); rc=$?
check "a lock a live process has held for over a minute is broken" '[[ $rc == 0 && "$(qinfo)" == lock-a:approved ]]'
$LOCAL_MERGE_QUEUE unapprove lock-a --repo b >/dev/null 2>&1
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
check "--batch turns it on where the config has no batch key"    '[[ "$(gates)" == 1 && "$out" == *"batch gated once: fl-1, fl-2"* ]]'
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
check "…the output says which entries were gated together"       '[[ "$out" == *"gated together in one batch: g-1, g-2, g-3"* && "$out" == *"gated in a batch with"* ]]'
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
check "max caps a batch: three entries with max 2 run two gates" '[[ "$(gates)" == 2 && "$out" == *"gated together in one batch: m-1, m-2"* && -f "$ROOT/brepo/m-3.txt" ]]'
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
check "the unapproved entry of a batch is not landed"            '[[ ! -f "$ROOT/brepo/u-2.txt" && "$(qinfo)" == u-2:enqueued && -f "$ROOT/brepo/u-1.txt" ]]'
check "the entry behind it is gated on its own, and lands"       '[[ "$out" == *"not the tree the batch gated"* && -f "$ROOT/brepo/u-3.txt" && "$(gates)" == 2 ]]'
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
check "…and la-1 and la-2 were gated together"                   '[[ "$out" == *"gated together in one batch: la-1, la-2"* ]]'

export LOCAL_MERGE_QUEUE_CONFIG="$SAVED_CONFIG" LOCAL_MERGE_QUEUE_STATE="$SAVED_STATE"
cd "$ROOT/repo"

echo
echo "════════════════════════════════════════════════════════════════"
echo "  passed $PASS   failed $FAIL"
echo "  sandbox left at $ROOT"
[[ $FAIL == 0 ]]
