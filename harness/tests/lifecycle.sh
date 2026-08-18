#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SOURCE_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

TEST_WORKSPACE="$TMP_ROOT/workspace"
RUNS_ROOT="$TEST_WORKSPACE/harness/runs"
export HARNESS_RUNS_ROOT="$RUNS_ROOT"
mkdir -p "$TEST_WORKSPACE"
cp -R "$SOURCE_ROOT/harness" "$TEST_WORKSPACE/harness"
cp "$SOURCE_ROOT/.gitignore" "$TEST_WORKSPACE/.gitignore"
cp "$SOURCE_ROOT/AGENTS.md" "$TEST_WORKSPACE/AGENTS.md"
rm -rf "$RUNS_ROOT"
mkdir -p "$RUNS_ROOT"
printf '*\n' > "$RUNS_ROOT/.gitignore"

cat > "$TEST_WORKSPACE/fixture-check" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in fast|full) ;; *) exit 2 ;; esac
if [[ "${FIXTURE_MUTATION:-}" == "dirty" ]]; then
  printf 'mutated\n' >> tracked.txt
elif [[ "${FIXTURE_MUTATION:-}" == "head" ]]; then
  printf 'mutated-head\n' >> tracked.txt
  git add tracked.txt
  git commit -qm 'test: command mutated HEAD'
elif [[ -n "${FIXTURE_STALE_MILESTONE:-}" ]]; then
  file="$HARNESS_RUNS_ROOT/$FIXTURE_STALE_MILESTONE/milestones.json"
  jq '.milestones[0].digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
fi
exit "${FIXTURE_CHECK_EXIT:-0}"
SCRIPT
chmod +x "$TEST_WORKSPACE/fixture-check"
printf 'fixture\n' > "$TEST_WORKSPACE/tracked.txt"

cat > "$TEST_WORKSPACE/harness/repos.json" <<'JSON'
{
  "version": 1,
  "active_context": "docs/ACTIVE_CONTEXT.md",
  "repositories": {
    "workspace": {
      "path": ".",
      "base_branch": "main",
      "owner": "workspace",
      "context": ["AGENTS.md"],
      "checks": {
        "fast": ["./fixture-check", "fast"],
        "full": ["./fixture-check", "full"]
      }
    },
    "backend": {
      "path": "backend",
      "base_branch": "staging",
      "owner": "backend",
      "context": ["AGENTS.md"],
      "checks": {
        "fast": ["./fixture-check", "fast"],
        "full": ["./fixture-check", "full"]
      }
    }
  }
}
JSON

git -C "$TEST_WORKSPACE" init -q -b main
git -C "$TEST_WORKSPACE" config user.email harness@example.invalid
git -C "$TEST_WORKSPACE" config user.name 'Harness Test'
git -C "$TEST_WORKSPACE" remote add origin https://github.com/example/project.git
git -C "$TEST_WORKSPACE" add .
git -C "$TEST_WORKSPACE" commit -qm 'test: initialize canonical fixture workspace'
CONTROL_SHA="$(git -C "$TEST_WORKSPACE" rev-parse HEAD)"
MANIFEST_BLOB_SHA="$(git -C "$TEST_WORKSPACE" rev-parse HEAD:harness/repos.json)"

PRODUCT_REPO="$TEST_WORKSPACE/backend"
mkdir -p "$PRODUCT_REPO"
cp "$TEST_WORKSPACE/fixture-check" "$PRODUCT_REPO/fixture-check"
printf 'product\n' > "$PRODUCT_REPO/tracked.txt"
git -C "$PRODUCT_REPO" init -q -b staging
git -C "$PRODUCT_REPO" config user.email harness@example.invalid
git -C "$PRODUCT_REPO" config user.name 'Harness Test'
git -C "$PRODUCT_REPO" add .
git -C "$PRODUCT_REPO" commit -qm 'test: initialize product fixture'

HARNESS_BIN="$TEST_WORKSPACE/harness/bin"
FAKE_BIN="$TMP_ROOT/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/gh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  pr) cat "$GH_FIXTURE" ;;
  api)
    case "${2:-}" in
      *required_status_checks) cat "$GH_REQUIRED_FIXTURE" ;;
      *check-runs*) cat "$GH_CHECKS_FIXTURE" ;;
      *) exit 2 ;;
    esac
    ;;
  *) exit 2 ;;
esac
SCRIPT
chmod +x "$FAKE_BIN/gh"
export PATH="$FAKE_BIN:$PATH"
pass_count=0
expect_pass() {
  local label="$1"
  shift
  if "$@" >"$TMP_ROOT/output" 2>&1; then
    pass_count=$((pass_count + 1))
  else
    printf 'lifecycle: expected pass: %s\n' "$label" >&2
    cat "$TMP_ROOT/output" >&2
    exit 1
  fi
}

expect_fail() {
  local label="$1"
  shift
  if "$@" >"$TMP_ROOT/output" 2>&1; then
    printf 'lifecycle: expected failure: %s\n' "$label" >&2
    cat "$TMP_ROOT/output" >&2
    exit 1
  fi
  pass_count=$((pass_count + 1))
}

mutate() {
  local file="$1"
  local filter="$2"
  jq "$filter" "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

select_issue_branch() {
  local issue_id="$1"
  local branch="feat/$(printf '%s' "$issue_id" | tr '[:upper:]' '[:lower:]')-fixture"
  git -C "$TEST_WORKSPACE" switch -q main
  git -C "$TEST_WORKSPACE" branch -D "$branch" >/dev/null 2>&1 || true
  git -C "$TEST_WORKSPACE" switch -qc "$branch" main
}

new_run() {
  local issue_id="$1"
  select_issue_branch "$issue_id"
  expect_pass "$issue_id start" "$HARNESS_BIN/start-ticket" "$issue_id" workspace "Lifecycle fixture"
  mutate "$RUNS_ROOT/$issue_id/task.json" '.acceptance_criteria = ["Lifecycle gates deterministic evidence"]'
  expect_pass "$issue_id claim implementer" "$HARNESS_BIN/claim-ticket" "$issue_id" implementer "$TEST_WORKSPACE"
  expect_pass "$issue_id implementation" "$HARNESS_BIN/record-implementation" "$issue_id" "Fixture implemented" tracked.txt
}

record_full() {
  local issue_id="$1"
  expect_pass "$issue_id record full" "$HARNESS_BIN/check" workspace full --record "$issue_id"
}

prepare_done_gate() {
  local issue_id="$1"
  new_run "$issue_id"
  record_full "$issue_id"
  expect_pass "$issue_id release review" "$HARNESS_BIN/release-ticket" "$issue_id" review
  expect_pass "$issue_id claim reviewer" "$HARNESS_BIN/claim-ticket" "$issue_id" reviewer "$TEST_WORKSPACE"
  expect_pass "$issue_id record review" "$HARNESS_BIN/record-review" "$issue_id" approved
}

approve_source_review() {
  local issue_id="$1" reviewer="$2"
  record_full "$issue_id"
  expect_pass "$issue_id release milestone review" "$HARNESS_BIN/release-ticket" "$issue_id" review
  expect_pass "$issue_id claim milestone reviewer" "$HARNESS_BIN/claim-ticket" "$issue_id" "$reviewer" "$TEST_WORKSPACE"
  expect_pass "$issue_id approve source review" "$HARNESS_BIN/record-review" "$issue_id" approved
  expect_pass "$issue_id release approved source" "$HARNESS_BIN/release-ticket" "$issue_id" done
}

# Positive lifecycle: supported commands create commit-bound evidence and review.
prepare_done_gate B1N-900
expect_pass 'positive done release' "$HARNESS_BIN/release-ticket" B1N-900 done
expect_pass 'positive task done' jq -e '.status == "done"' "$RUNS_ROOT/B1N-900/task.json"
expect_pass 'positive verification shape' jq -e --arg control "$CONTROL_SHA" --arg manifest "$MANIFEST_BLOB_SHA" '
  .overall == "passed" and .tier == "full" and (.commands | length == 1) and
  (.commit_sha == .commands[0].commit_sha) and .commands[0].exit_code == 0 and
  .control_plane.commit_sha == $control and .control_plane.manifest_blob_sha == $manifest
' "$RUNS_ROOT/B1N-900/verification.json"

# workflow.json remains authoritative if the task.status projection fails.
select_issue_branch B1N-923
expect_pass 'projection fixture start' "$HARNESS_BIN/start-ticket" B1N-923 workspace 'Projection fixture'
mutate "$RUNS_ROOT/B1N-923/task.json" '.acceptance_criteria = ["Workflow remains authoritative"]'
expect_pass 'claim survives task projection failure' env HARNESS_TEST_FAIL_TASK_PROJECTION=1 \
  "$HARNESS_BIN/claim-ticket" B1N-923 implementer "$TEST_WORKSPACE"
expect_pass 'projection failure keeps valid workflow' "$HARNESS_BIN/validate-run" B1N-923
expect_pass 'projection failure advances workflow only' jq -e '.phase == "implementing"' "$RUNS_ROOT/B1N-923/workflow.json"
expect_pass 'status derives from validated workflow' bash -c '
  HARNESS_RUNS_ROOT="$1" "$2/status" | grep -E "B1N-923[[:space:]]+implementing[[:space:]]+0/2[[:space:]]+in_progress"
' _ "$RUNS_ROOT" "$HARNESS_BIN"

# Failed execution is recorded from the process and cannot release.
new_run B1N-901
expect_fail 'failed check returns nonzero' env FIXTURE_CHECK_EXIT=7 "$HARNESS_BIN/check" workspace full --record B1N-901
expect_pass 'failed evidence derived' jq -e \
  '.overall == "failed" and .commands[0].status == "failed" and .commands[0].exit_code == 7' \
  "$RUNS_ROOT/B1N-901/verification.json"
expect_fail 'failed real command cannot release' env FIXTURE_CHECK_EXIT=7 "$HARNESS_BIN/release-ticket" B1N-901 review

# A complete, structurally valid forged pass is overwritten by release's real run.
new_run B1N-902
HEAD_SHA="$(git -C "$TEST_WORKSPACE" rev-parse HEAD)"
NOW='2026-08-07T00:00:00Z'
jq -n --arg sha "$HEAD_SHA" --arg control "$CONTROL_SHA" --arg manifest "$MANIFEST_BLOB_SHA" --arg now "$NOW" '{
  issue_id:"B1N-902", repository:"workspace", tier:"full", commit_sha:$sha,
  started_at:$now, ended_at:$now, duration_seconds:0,
  control_plane:{commit_sha:$control,manifest_blob_sha:$manifest},
  check_command:{command:"harness/bin/check",arguments:["workspace","full","--record","B1N-902"]},
  overall:"passed", commands:[{command:"./fixture-check",arguments:["full"],started_at:$now,ended_at:$now,duration_seconds:0,commit_sha:$sha,exit_code:0,status:"passed"}]
}' > "$RUNS_ROOT/B1N-902/verification.json"
expect_pass 'forged pass is structurally valid' "$HARNESS_BIN/validate-run" B1N-902
expect_fail 'forged pass cannot bypass failing canonical command' env FIXTURE_CHECK_EXIT=9 "$HARNESS_BIN/release-ticket" B1N-902 review
expect_pass 'forged pass overwritten with failure' jq -e '.overall == "failed" and .commands[0].exit_code == 9' "$RUNS_ROOT/B1N-902/verification.json"

# Structural negative cases remain rejected.
new_run B1N-903
mutate "$RUNS_ROOT/B1N-903/verification.json" '.overall = "passed"'
expect_fail 'manual empty pass rejected' "$HARNESS_BIN/validate-run" B1N-903

new_run B1N-904
record_full B1N-904
mutate "$RUNS_ROOT/B1N-904/verification.json" 'del(.commands[0].exit_code)'
expect_fail 'missing exit code rejected' "$HARNESS_BIN/validate-run" B1N-904

new_run B1N-905
record_full B1N-905
mutate "$RUNS_ROOT/B1N-905/verification.json" '.commands[0].exit_code = 9'
expect_fail 'nonzero passed exit rejected' "$HARNESS_BIN/validate-run" B1N-905

new_run B1N-906
record_full B1N-906
mutate "$RUNS_ROOT/B1N-906/verification.json" '.unexpected = true'
expect_fail 'additional verification property rejected' "$HARNESS_BIN/validate-run" B1N-906

# Worktree identity is checked before a claim is created.
select_issue_branch B1N-907
expect_pass 'unrelated start' "$HARNESS_BIN/start-ticket" B1N-907 workspace 'Unrelated repository fixture'
mutate "$RUNS_ROOT/B1N-907/task.json" '.acceptance_criteria = ["Reject unrelated repository"]'
expect_fail 'same-repository subdirectory claim rejected' "$HARNESS_BIN/claim-ticket" B1N-907 subdirectory "$TEST_WORKSPACE/harness"
UNRELATED="$TMP_ROOT/unrelated"
mkdir -p "$UNRELATED"
git -C "$UNRELATED" init -q -b main
git -C "$UNRELATED" config user.email harness@example.invalid
git -C "$UNRELATED" config user.name 'Harness Test'
printf 'other\n' > "$UNRELATED/file"
git -C "$UNRELATED" add file
git -C "$UNRELATED" commit -qm initial
git -C "$UNRELATED" switch -qc feat/b1n-907-other
expect_fail 'unrelated repository claim rejected' "$HARNESS_BIN/claim-ticket" B1N-907 outsider "$UNRELATED"

# Dirty and special-index states cannot be recorded or released.
new_run B1N-908
printf 'dirty\n' >> "$TEST_WORKSPACE/tracked.txt"
expect_fail 'dirty implementation recorder rejected' "$HARNESS_BIN/record-implementation" B1N-908 'Dirty' tracked.txt
git -C "$TEST_WORKSPACE" restore tracked.txt

git -C "$TEST_WORKSPACE" update-index --assume-unchanged tracked.txt
expect_fail 'assume-unchanged verification rejected' "$HARNESS_BIN/check" workspace full --record B1N-908
git -C "$TEST_WORKSPACE" update-index --no-assume-unchanged tracked.txt

git -C "$TEST_WORKSPACE" update-index --skip-worktree tracked.txt
expect_fail 'skip-worktree verification rejected' "$HARNESS_BIN/check" workspace full --record B1N-908
git -C "$TEST_WORKSPACE" update-index --no-skip-worktree tracked.txt

printf 'dirty-release\n' >> "$TEST_WORKSPACE/tracked.txt"
expect_fail 'dirty release rejected by canonical rerun' "$HARNESS_BIN/release-ticket" B1N-908 review
git -C "$TEST_WORKSPACE" restore tracked.txt

# A check that mutates the tree or HEAD writes non-releasable failure evidence.
new_run B1N-909
expect_fail 'command dirty mutation rejected' env FIXTURE_MUTATION=dirty "$HARNESS_BIN/check" workspace full --record B1N-909
expect_pass 'dirty mutation recorded failed' jq -e '.overall == "failed" and .commands[0].exit_code == 70' "$RUNS_ROOT/B1N-909/verification.json"
git -C "$TEST_WORKSPACE" restore tracked.txt

new_run B1N-910
PRE_MUTATION_SHA="$(git -C "$TEST_WORKSPACE" rev-parse HEAD)"
expect_fail 'command HEAD mutation rejected' env FIXTURE_MUTATION=head "$HARNESS_BIN/check" workspace full --record B1N-910
expect_pass 'HEAD mutation recorded failed' jq -e '.overall == "failed" and .commands[0].exit_code == 70' "$RUNS_ROOT/B1N-910/verification.json"
git -C "$TEST_WORKSPACE" reset -q --hard "$PRE_MUTATION_SHA"

# Same literal owner is rejected. Different labels remain unauthenticated local
# attestations; authoritative human identity belongs to protected GitHub review.
new_run B1N-911
record_full B1N-911
expect_pass 'self review release review' "$HARNESS_BIN/release-ticket" B1N-911 review
expect_pass 'self review claim' "$HARNESS_BIN/claim-ticket" B1N-911 implementer "$TEST_WORKSPACE"
expect_fail 'same-owner record-review rejected' "$HARNESS_BIN/record-review" B1N-911 approved

prepare_done_gate B1N-912
mutate "$RUNS_ROOT/B1N-912/review.json" '.reviewed_commit = "0000000000000000000000000000000000000000"'
expect_fail 'wrong reviewed commit rejected after rerun' "$HARNESS_BIN/release-ticket" B1N-912 done

prepare_done_gate B1N-913
# "reviewer-alias" is intentionally accepted as a distinct local label. This
# test documents the trust boundary rather than pretending to authenticate actors.
mutate "$RUNS_ROOT/B1N-913/review.json" '.reviewer = "reviewer-alias"'
mutate "$RUNS_ROOT/B1N-913/.claim/owner.json" '.owner = "reviewer-alias"'
expect_pass 'distinct reviewer label is only a local attestation' "$HARNESS_BIN/release-ticket" B1N-913 done

# Another worktree from the same repository cannot supply workspace authority.
new_run B1N-916
ALT_CALLER="$TMP_ROOT/alternate-workspace"
git -C "$TEST_WORKSPACE" worktree add -q -b feat/b1n-916-alternate "$ALT_CALLER" main
mutate "$ALT_CALLER/harness/repos.json" '.repositories.workspace.checks.full = ["true"]'
git -C "$ALT_CALLER" add harness/repos.json
git -C "$ALT_CALLER" commit -qm 'test: attempt alternate control plane'
expect_fail 'alternate workspace cannot override claimed control plane' env HARNESS_RUNS_ROOT="$RUNS_ROOT" "$ALT_CALLER/harness/bin/release-ticket" B1N-916 review
git -C "$TEST_WORKSPACE" worktree remove --force "$ALT_CALLER"

# Product verification uses its product worktree but binds the clean workspace
# harness control-plane commit and committed manifest blob.
git -C "$PRODUCT_REPO" switch -qc feat/b1n-917-product staging
expect_pass 'product start' "$HARNESS_BIN/start-ticket" B1N-917 backend 'Product control-plane fixture'
mutate "$RUNS_ROOT/B1N-917/task.json" '.acceptance_criteria = ["Bind product proof to workspace control plane"]'
expect_pass 'product claim' "$HARNESS_BIN/claim-ticket" B1N-917 product-implementer "$PRODUCT_REPO"
expect_pass 'product implementation' "$HARNESS_BIN/record-implementation" B1N-917 'Product fixture implemented' tracked.txt
expect_pass 'product recorded full' "$HARNESS_BIN/check" backend full --record B1N-917
expect_pass 'product control plane bound' jq -e --arg control "$CONTROL_SHA" --arg manifest "$MANIFEST_BLOB_SHA" '
  .repository == "backend" and .overall == "passed" and
  .control_plane.commit_sha == $control and .control_plane.manifest_blob_sha == $manifest
' "$RUNS_ROOT/B1N-917/verification.json"

# A clean alternate workspace worktree cannot redefine a product command: its
# committed control-plane content must match the trusted workspace base ref.
ALT_PRODUCT_CALLER="$TMP_ROOT/alternate-product-control"
git -C "$TEST_WORKSPACE" worktree add -q -b feat/b1n-917-product-control "$ALT_PRODUCT_CALLER" main
ln -s "$PRODUCT_REPO" "$ALT_PRODUCT_CALLER/backend"
mutate "$ALT_PRODUCT_CALLER/harness/repos.json" \
  '.repositories.backend.checks.full = ["true"] | .repositories.workspace.base_branch = "feat/b1n-917-product-control"'
git -C "$ALT_PRODUCT_CALLER" add harness/repos.json
git -C "$ALT_PRODUCT_CALLER" commit -qm 'test: attempt alternate product control plane'
expect_fail 'alternate product control plane cannot override trusted base' env HARNESS_RUNS_ROOT="$RUNS_ROOT" "$ALT_PRODUCT_CALLER/harness/bin/release-ticket" B1N-917 review
git -C "$TEST_WORKSPACE" worktree remove --force "$ALT_PRODUCT_CALLER"

expect_pass 'product release reruns bound full' "$HARNESS_BIN/release-ticket" B1N-917 review

# A failed lifecycle transition restores the active claim for retry.
new_run B1N-922
mkdir "$RUNS_ROOT/B1N-922/.workflow.lock"
expect_fail 'release lock contention fails safely' "$HARNESS_BIN/release-ticket" B1N-922 review
expect_pass 'failed release restores claim and phase' bash -c '
  [[ -f "$1/.claim/owner.json" ]] && [[ "$(jq -r .phase "$1/workflow.json")" == candidate ]]
' _ "$RUNS_ROOT/B1N-922"
rmdir "$RUNS_ROOT/B1N-922/.workflow.lock"
expect_pass 'restored release retries' "$HARNESS_BIN/release-ticket" B1N-922 review

# Fixed lifecycle: two repair cycles, terminal third rejection, and resumable ordinary block.
new_run B1N-918
expect_pass 'multi-event workflow validates' "$HARNESS_BIN/validate-run" B1N-918
expect_pass 'cycle one release review' "$HARNESS_BIN/release-ticket" B1N-918 review
expect_pass 'cycle one claim reviewer' "$HARNESS_BIN/claim-ticket" B1N-918 reviewer-1 "$TEST_WORKSPACE"
expect_pass 'cycle one verdict' "$HARNESS_BIN/record-review" B1N-918 changes_requested
expect_pass 'cycle one repair' "$HARNESS_BIN/release-ticket" B1N-918 planned
expect_pass 'cycle one budget' jq -e '.phase == "repair" and .repair_count == 1' "$RUNS_ROOT/B1N-918/workflow.json"
expect_pass 'cycle one claim repair' "$HARNESS_BIN/claim-ticket" B1N-918 implementer "$TEST_WORKSPACE"
expect_pass 'cycle one implementation' "$HARNESS_BIN/record-implementation" B1N-918 'Repair one' tracked.txt
expect_pass 'cycle two release review' "$HARNESS_BIN/release-ticket" B1N-918 review
expect_pass 'cycle two claim reviewer' "$HARNESS_BIN/claim-ticket" B1N-918 reviewer-2 "$TEST_WORKSPACE"
expect_pass 'cycle two verdict' "$HARNESS_BIN/record-review" B1N-918 changes_requested
expect_pass 'cycle two repair' "$HARNESS_BIN/release-ticket" B1N-918 planned
expect_pass 'cycle two budget' jq -e '.phase == "repair" and .repair_count == 2' "$RUNS_ROOT/B1N-918/workflow.json"
expect_pass 'cycle two claim repair' "$HARNESS_BIN/claim-ticket" B1N-918 implementer "$TEST_WORKSPACE"
expect_pass 'cycle two implementation' "$HARNESS_BIN/record-implementation" B1N-918 'Repair two' tracked.txt
expect_pass 'cycle three release review' "$HARNESS_BIN/release-ticket" B1N-918 review
expect_pass 'cycle three claim reviewer' "$HARNESS_BIN/claim-ticket" B1N-918 reviewer-3 "$TEST_WORKSPACE"
expect_pass 'cycle three verdict' "$HARNESS_BIN/record-review" B1N-918 changes_requested
expect_pass 'cycle three human block' "$HARNESS_BIN/release-ticket" B1N-918 planned
expect_pass 'repair cap is terminal' jq -e '.phase == "human_blocked" and .repair_count == 2 and .blocker != null' "$RUNS_ROOT/B1N-918/workflow.json"
expect_fail 'human blocked cannot be claimed' "$HARNESS_BIN/claim-ticket" B1N-918 implementer "$TEST_WORKSPACE"

new_run B1N-919
expect_pass 'blocked release review' "$HARNESS_BIN/release-ticket" B1N-919 review
expect_pass 'blocked claim reviewer' "$HARNESS_BIN/claim-ticket" B1N-919 blocker-reviewer "$TEST_WORKSPACE"
expect_pass 'blocked verdict' "$HARNESS_BIN/record-review" B1N-919 blocked
expect_pass 'blocked release is resumable' "$HARNESS_BIN/release-ticket" B1N-919 blocked
expect_pass 'blocked budget unchanged' jq -e '.phase == "repair" and .repair_count == 0 and .blocker != null' "$RUNS_ROOT/B1N-919/workflow.json"
expect_pass 'resume reports blocker and next action' bash -c '
  "$1/start-ticket" B1N-919 workspace "Lifecycle fixture" | grep -E "phase=repair.*blocker=independent review blocked.*next=claim repair implementation"
' _ "$HARNESS_BIN"
expect_pass 'blocked repair claim' "$HARNESS_BIN/claim-ticket" B1N-919 implementer "$TEST_WORKSPACE"
expect_pass 'blocked claim clears blocker' jq -e '.phase == "implementing" and .repair_count == 0 and .blocker == null' "$RUNS_ROOT/B1N-919/workflow.json"

# Active legacy runs migrate explicitly; completed historical runs stay untouched.
select_issue_branch B1N-920
expect_pass 'legacy start' "$HARNESS_BIN/start-ticket" B1N-920 workspace 'Legacy fixture'
mutate "$RUNS_ROOT/B1N-920/task.json" '.acceptance_criteria = ["Migrate explicitly"]'
rm "$RUNS_ROOT/B1N-920/workflow.json"
expect_fail 'legacy run does not resume implicitly' "$HARNESS_BIN/start-ticket" B1N-920 workspace 'Legacy fixture'
expect_pass 'legacy planned migration' "$HARNESS_BIN/migrate-run" B1N-920 migration-owner planned 0
expect_pass 'migrated workflow validates' "$HARNESS_BIN/validate-run" B1N-920
expect_fail 'migration is one-time' "$HARNESS_BIN/migrate-run" B1N-920 migration-owner planned 0
expect_fail 'phase skipping rejected' bash -c '
  source "$1/harness/lib/workflow.sh"
  workflow_transition "$2/B1N-920" planned approved actor approve
' _ "$TEST_WORKSPACE" "$RUNS_ROOT"

select_issue_branch B1N-921
expect_pass 'completed legacy start' "$HARNESS_BIN/start-ticket" B1N-921 workspace 'Completed fixture'
mutate "$RUNS_ROOT/B1N-921/task.json" '.status = "done"'
rm "$RUNS_ROOT/B1N-921/workflow.json"
expect_fail 'completed legacy migration rejected' "$HARNESS_BIN/migrate-run" B1N-921 migration-owner planned 0
expect_pass 'completed legacy start is historical' bash -c '
  "$1/start-ticket" B1N-921 workspace "Completed fixture" | grep -q "historical completed"
' _ "$HARNESS_BIN"
expect_pass 'completed legacy status is complete' bash -c '
  HARNESS_RUNS_ROOT="$1" "$2/status" | grep -E "B1N-921[[:space:]]+historical.*complete"
' _ "$RUNS_ROOT" "$HARNESS_BIN"

# Legacy implementation evidence can be replaced by the supported recorder.
new_run B1N-914
cat > "$RUNS_ROOT/B1N-914/implementation.json" <<'JSON'
{"issue_id":"B1N-914","repository":"workspace","status":"implemented","summary":"legacy","files_changed":[],"known_issues":[]}
JSON
expect_pass 'legacy implementation migration' "$HARNESS_BIN/record-implementation" B1N-914 'Migrated legacy handoff' tracked.txt
expect_pass 'migrated implementation validates' "$HARNESS_BIN/validate-run" B1N-914

# Schema/runtime contract checks requiring no extra validator dependency.
expect_pass 'task schema exactly one repository' jq -e '.properties.repositories.maxItems == 1' "$TEST_WORKSPACE/harness/schemas/task.schema.json"
expect_pass 'workflow schema fixes repair budget' jq -e '.properties.max_repairs.const == 2 and .properties.repair_count.maximum == 2' "$TEST_WORKSPACE/harness/schemas/workflow.schema.json"
mutate "$RUNS_ROOT/B1N-914/task.json" '.repositories += ["frontend"]'
expect_fail 'runtime rejects multi-repository task' "$HARNESS_BIN/validate-run" B1N-914
mutate "$RUNS_ROOT/B1N-914/task.json" '.repositories = ["workspace"]'

# Typed dependency gates are commit-pinned, independently approved, and joined.
new_run B1N-930
expect_pass 'local milestone proposed' "$HARNESS_BIN/record-milestone" propose B1N-930 contract_approved tracked.txt
expect_fail 'unreviewed milestone approval rejected' "$HARNESS_BIN/record-milestone" approve B1N-930 contract_approved
SOURCE_COMMIT="$(jq -r '.commit_sha' "$RUNS_ROOT/B1N-930/implementation.json")"
mutate "$RUNS_ROOT/B1N-930/review.json" ".verdict=\"approved\" | .reviewer=\"forged-reviewer\" | .reviewed_commit=\"$SOURCE_COMMIT\" | .reviewed_at=\"2026-08-18T00:00:00Z\""
expect_fail 'forged mutable review cannot approve milestone' "$HARNESS_BIN/record-milestone" approve B1N-930 contract_approved
jq -n '{issue_id:"B1N-930",repository:"workspace",verdict:"pending",findings:[]}' > "$RUNS_ROOT/B1N-930/review.json"
approve_source_review B1N-930 contract-reviewer
expect_pass 'local milestone independently approved' "$HARNESS_BIN/record-milestone" approve B1N-930 contract_approved
cp "$RUNS_ROOT/B1N-930/milestones.json" "$TMP_ROOT/approved-milestone.backup"
mutate "$RUNS_ROOT/B1N-930/milestones.json" '.milestones[0].approver = "spoofed-reviewer"'
expect_fail 'spoofed milestone approver rejected' "$HARNESS_BIN/validate-run" B1N-930
mv "$TMP_ROOT/approved-milestone.backup" "$RUNS_ROOT/B1N-930/milestones.json"
select_issue_branch B1N-931
expect_pass 'local consumer start' "$HARNESS_BIN/start-ticket" B1N-931 workspace 'Local dependency consumer'
mutate "$RUNS_ROOT/B1N-931/task.json" '.acceptance_criteria=["Gate satisfied"] | .dependencies=[{"issue_id":"B1N-930","gate":"contract_approved"}]'
expect_pass 'approved local gate permits claim' "$HARNESS_BIN/claim-ticket" B1N-931 consumer "$TEST_WORKSPACE"
expect_pass 'dependent implementation records' "$HARNESS_BIN/record-implementation" B1N-931 'Dependent implementation' tracked.txt
cp "$RUNS_ROOT/B1N-930/milestones.json" "$TMP_ROOT/release-gate.backup"
mutate "$RUNS_ROOT/B1N-930/milestones.json" '.milestones[0].digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
expect_fail 'stale gate blocks review delivery' "$HARNESS_BIN/release-ticket" B1N-931 review
mv "$TMP_ROOT/release-gate.backup" "$RUNS_ROOT/B1N-930/milestones.json"
cp "$RUNS_ROOT/B1N-930/milestones.json" "$TMP_ROOT/during-check.backup"
expect_fail 'gate stale during full check blocks transition' env FIXTURE_STALE_MILESTONE=B1N-930 "$HARNESS_BIN/release-ticket" B1N-931 review
mv "$TMP_ROOT/during-check.backup" "$RUNS_ROOT/B1N-930/milestones.json"
expect_pass 'fresh gate permits review delivery' "$HARNESS_BIN/release-ticket" B1N-931 review
cp "$RUNS_ROOT/B1N-930/milestones.json" "$TMP_ROOT/review-ready.backup"
mutate "$RUNS_ROOT/B1N-930/milestones.json" '.milestones[0].digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
expect_pass 'ready revalidates awaiting review gate' bash -c '
  "$1/ready" | grep -E "B1N-931 blocked B1N-930:contract_approved stale"
' _ "$HARNESS_BIN"
mv "$TMP_ROOT/review-ready.backup" "$RUNS_ROOT/B1N-930/milestones.json"

new_run B1N-932
expect_pass 'fixture candidate proposed' "$HARNESS_BIN/record-milestone" propose B1N-932 fixture_pinned tracked.txt
select_issue_branch B1N-933
expect_pass 'partial join start' "$HARNESS_BIN/start-ticket" B1N-933 workspace 'Partial join consumer'
mutate "$RUNS_ROOT/B1N-933/task.json" '.acceptance_criteria=["All gates"] | .dependencies=[{"issue_id":"B1N-930","gate":"contract_approved"},{"issue_id":"B1N-932","gate":"fixture_pinned"},{"issue_id":"B1N-999","gate":"merged"}]'
expect_fail 'partial join rejected' "$HARNESS_BIN/claim-ticket" B1N-933 consumer "$TEST_WORKSPACE"
select_issue_branch B1N-934
expect_pass 'independent run start' "$HARNESS_BIN/start-ticket" B1N-934 workspace 'Independent branch'
mutate "$RUNS_ROOT/B1N-934/task.json" '.acceptance_criteria=["Independent"]'
expect_pass 'ready isolates blocked descendants' bash -c '
  output="$("$1/ready")"
  grep -E "B1N-933 blocked B1N-932:fixture_pinned.*B1N-999:merged" <<<"$output" >/dev/null &&
    grep -E "B1N-934 ready implementation" <<<"$output" >/dev/null
' _ "$HARNESS_BIN"

cp "$RUNS_ROOT/B1N-930/milestones.json" "$TMP_ROOT/milestones.backup"
mutate "$RUNS_ROOT/B1N-930/milestones.json" '.milestones[0].digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
select_issue_branch B1N-935
expect_pass 'stale digest consumer start' "$HARNESS_BIN/start-ticket" B1N-935 workspace 'Stale digest consumer'
mutate "$RUNS_ROOT/B1N-935/task.json" '.acceptance_criteria=["Fresh digest"] | .dependencies=[{"issue_id":"B1N-930","gate":"contract_approved"}]'
expect_fail 'altered digest rejected' "$HARNESS_BIN/claim-ticket" B1N-935 consumer "$TEST_WORKSPACE"
mv "$TMP_ROOT/milestones.backup" "$RUNS_ROOT/B1N-930/milestones.json"
cp "$RUNS_ROOT/B1N-930/implementation.json" "$TMP_ROOT/implementation.backup"
mutate "$RUNS_ROOT/B1N-930/implementation.json" '.commit_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
expect_fail 'changed source commit rejected' "$HARNESS_BIN/claim-ticket" B1N-935 consumer "$TEST_WORKSPACE"
mv "$TMP_ROOT/implementation.backup" "$RUNS_ROOT/B1N-930/implementation.json"
mutate "$RUNS_ROOT/B1N-930/milestones.json" '.milestones[0].algorithm = "sha1"'
expect_fail 'wrong digest algorithm rejected' "$HARNESS_BIN/validate-run" B1N-930
mutate "$RUNS_ROOT/B1N-930/milestones.json" '.milestones[0].algorithm = "sha256"'

GH_URL='https://github.com/example/project/pull/7'
new_run B1N-936
GH_HEAD="$(jq -r '.commit_sha' "$RUNS_ROOT/B1N-936/implementation.json")"
GH_FIXTURE="$TMP_ROOT/gh.json"
GH_REQUIRED_FIXTURE="$TMP_ROOT/required-checks.json"
GH_CHECKS_FIXTURE="$TMP_ROOT/check-runs.json"
printf '{"checks":[{"context":"validate","app_id":123}]}\n' > "$GH_REQUIRED_FIXTURE"
printf '{"check_runs":[{"name":"validate","status":"completed","conclusion":"success","app":{"id":123}}]}\n' > "$GH_CHECKS_FIXTURE"
export GH_FIXTURE GH_REQUIRED_FIXTURE GH_CHECKS_FIXTURE
cat > "$GH_FIXTURE" <<JSON
{"number":7,"url":"$GH_URL","headRefOid":"$GH_HEAD","baseRefName":"main","state":"OPEN","mergeCommit":null,"reviewDecision":"APPROVED","statusCheckRollup":[{"name":"validate","status":"COMPLETED","conclusion":"SUCCESS"}]}
JSON
expect_fail 'foreign repository pr rejected' env HARNESS_GH_FIXTURE="$GH_FIXTURE" "$HARNESS_BIN/record-milestone" propose B1N-936 pr_ready 'https://github.com/foreign/project/pull/7'
expect_pass 'pr ready proposed' env HARNESS_GH_FIXTURE="$GH_FIXTURE" "$HARNESS_BIN/record-milestone" propose B1N-936 pr_ready "$GH_URL"
approve_source_review B1N-936 pr-reviewer
expect_pass 'pr ready approved' env HARNESS_GH_FIXTURE="$GH_FIXTURE" "$HARNESS_BIN/record-milestone" approve B1N-936 pr_ready
select_issue_branch B1N-937
expect_pass 'pr consumer start' "$HARNESS_BIN/start-ticket" B1N-937 workspace 'PR consumer'
mutate "$RUNS_ROOT/B1N-937/task.json" '.acceptance_criteria=["PR ready"] | .dependencies=[{"issue_id":"B1N-936","gate":"pr_ready"}]'
expect_pass 'live green pr permits claim' env HARNESS_GH_FIXTURE="$GH_FIXTURE" "$HARNESS_BIN/claim-ticket" B1N-937 consumer "$TEST_WORKSPACE"
mutate "$GH_FIXTURE" '.headRefOid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
select_issue_branch B1N-938
expect_pass 'changed head consumer start' "$HARNESS_BIN/start-ticket" B1N-938 workspace 'Changed head consumer'
mutate "$RUNS_ROOT/B1N-938/task.json" '.acceptance_criteria=["Same head"] | .dependencies=[{"issue_id":"B1N-936","gate":"pr_ready"}]'
expect_fail 'changed pr head rejected' env HARNESS_GH_FIXTURE="$GH_FIXTURE" "$HARNESS_BIN/claim-ticket" B1N-938 consumer "$TEST_WORKSPACE"

new_run B1N-940
RED_HEAD="$(jq -r '.commit_sha' "$RUNS_ROOT/B1N-940/implementation.json")"
cat > "$GH_FIXTURE" <<JSON
{"number":8,"url":"$GH_URL","headRefOid":"$RED_HEAD","baseRefName":"main","state":"OPEN","mergeCommit":null,"reviewDecision":"APPROVED","statusCheckRollup":[{"name":"validate","status":"COMPLETED","conclusion":"FAILURE"}]}
JSON
mutate "$GH_CHECKS_FIXTURE" '.check_runs[0].conclusion="failure"'
expect_fail 'red pr checks rejected' env HARNESS_GH_FIXTURE="$GH_FIXTURE" "$HARNESS_BIN/record-milestone" propose B1N-940 pr_ready "$GH_URL"
mutate "$GH_CHECKS_FIXTURE" '.check_runs[0].conclusion="success"'
mutate "$GH_FIXTURE" '.reviewDecision=""'
expect_fail 'missing pr review rejected' env HARNESS_GH_FIXTURE="$GH_FIXTURE" "$HARNESS_BIN/record-milestone" propose B1N-940 pr_ready "$GH_URL"
mutate "$GH_FIXTURE" '.reviewDecision="APPROVED"'
printf '{"checks":[{"context":"required-but-missing","app_id":123}]}\n' > "$GH_REQUIRED_FIXTURE"
expect_fail 'missing required check rejected' env HARNESS_GH_FIXTURE="$GH_FIXTURE" "$HARNESS_BIN/record-milestone" propose B1N-940 pr_ready "$GH_URL"
printf '{"checks":[{"context":"validate","app_id":123}]}\n' > "$GH_REQUIRED_FIXTURE"
mutate "$GH_CHECKS_FIXTURE" '.check_runs[0].app.id = 999'
expect_fail 'wrong check app rejected' env HARNESS_GH_FIXTURE="$GH_FIXTURE" "$HARNESS_BIN/record-milestone" propose B1N-940 pr_ready "$GH_URL"
mutate "$GH_CHECKS_FIXTURE" '.check_runs[0].app.id = 123'
mutate "$GH_FIXTURE" '.baseRefName="staging"'
expect_fail 'wrong pr target rejected' env HARNESS_GH_FIXTURE="$GH_FIXTURE" "$HARNESS_BIN/record-milestone" propose B1N-940 pr_ready "$GH_URL"

new_run B1N-942
MERGED_HEAD="$(jq -r '.commit_sha' "$RUNS_ROOT/B1N-942/implementation.json")"
cat > "$GH_FIXTURE" <<JSON
{"number":9,"url":"$GH_URL","headRefOid":"$MERGED_HEAD","baseRefName":"main","state":"MERGED","mergeCommit":{"oid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"reviewDecision":"APPROVED","statusCheckRollup":[{"name":"validate","status":"COMPLETED","conclusion":"SUCCESS"}]}
JSON
expect_pass 'merged milestone proposed' env HARNESS_GH_FIXTURE="$GH_FIXTURE" "$HARNESS_BIN/record-milestone" propose B1N-942 merged "$GH_URL"
approve_source_review B1N-942 merge-reviewer
expect_pass 'merged milestone approved' env HARNESS_GH_FIXTURE="$GH_FIXTURE" "$HARNESS_BIN/record-milestone" approve B1N-942 merged
select_issue_branch B1N-943
expect_pass 'merged-as-ready consumer start' "$HARNESS_BIN/start-ticket" B1N-943 workspace 'Merged satisfies ready'
mutate "$RUNS_ROOT/B1N-943/task.json" '.acceptance_criteria=["Merged satisfies ready"] | .dependencies=[{"issue_id":"B1N-942","gate":"pr_ready"}]'
expect_pass 'merged satisfies same-source pr ready' env HARNESS_GH_FIXTURE="$GH_FIXTURE" "$HARNESS_BIN/claim-ticket" B1N-943 consumer "$TEST_WORKSPACE"
mutate "$GH_FIXTURE" '.mergeCommit.oid = "cccccccccccccccccccccccccccccccccccccccc"'
select_issue_branch B1N-944
expect_pass 'changed merge consumer start' "$HARNESS_BIN/start-ticket" B1N-944 workspace 'Changed merge consumer'
mutate "$RUNS_ROOT/B1N-944/task.json" '.acceptance_criteria=["Same merge"] | .dependencies=[{"issue_id":"B1N-942","gate":"merged"}]'
expect_fail 'changed merge commit rejected' env HARNESS_GH_FIXTURE="$GH_FIXTURE" "$HARNESS_BIN/claim-ticket" B1N-944 consumer "$TEST_WORKSPACE"

select_issue_branch B1N-945
expect_pass 'missing predecessor start' "$HARNESS_BIN/start-ticket" B1N-945 workspace 'Missing predecessor'
mutate "$RUNS_ROOT/B1N-945/task.json" '.acceptance_criteria=["Exists"] | .dependencies=[{"issue_id":"B1N-999","gate":"merged"}]'
expect_fail 'missing predecessor rejected' "$HARNESS_BIN/claim-ticket" B1N-945 consumer "$TEST_WORKSPACE"
select_issue_branch B1N-946
expect_pass 'unknown gate start' "$HARNESS_BIN/start-ticket" B1N-946 workspace 'Unknown gate'
mutate "$RUNS_ROOT/B1N-946/task.json" '.acceptance_criteria=["Closed enum"] | .dependencies=[{"issue_id":"B1N-930","gate":"unknown"}]'
expect_fail 'unknown gate rejected' "$HARNESS_BIN/validate-run" B1N-946
select_issue_branch B1N-947
expect_pass 'legacy dependency start' "$HARNESS_BIN/start-ticket" B1N-947 workspace 'Legacy dependencies'
mutate "$RUNS_ROOT/B1N-947/task.json" '.acceptance_criteria=["Migrate"] | .dependencies=["B1N-999"]'
expect_fail 'legacy dependency requires migration' "$HARNESS_BIN/validate-run" B1N-947
expect_pass 'legacy dependency migrates explicitly' "$HARNESS_BIN/migrate-dependencies" B1N-947 B1N-999:merged
expect_pass 'migrated dependency validates' "$HARNESS_BIN/validate-run" B1N-947
select_issue_branch B1N-948
expect_pass 'rollback migration start' "$HARNESS_BIN/start-ticket" B1N-948 workspace 'Rollback dependency migration'
mutate "$RUNS_ROOT/B1N-948/task.json" '.acceptance_criteria=["Rollback"] | .dependencies=["B1N-948"]'
expect_fail 'invalid dependency migration rolls back' "$HARNESS_BIN/migrate-dependencies" B1N-948 B1N-948:merged
expect_pass 'failed migration preserves legacy input' jq -e '.dependencies == ["B1N-948"]' "$RUNS_ROOT/B1N-948/task.json"

# Sensitive preflight failure is recorded but cannot satisfy release.
new_run B1N-915
printf '%s%s\n' 'API_' 'KEY=abcdefghijklmnopqrstuvwxyz123456' > "$TEST_WORKSPACE/leaked.txt"
git -C "$TEST_WORKSPACE" add leaked.txt
git -C "$TEST_WORKSPACE" commit -qm 'test: add generated sensitive fixture'
expect_fail 'sensitive preflight returns nonzero' "$HARNESS_BIN/check" workspace full --record B1N-915
expect_pass 'sensitive failure recorded' jq -e \
  '.overall == "failed" and .commands[0].command == "harness/bin/sensitive-check" and .commands[0].status == "failed" and .commands[0].exit_code != 0' \
  "$RUNS_ROOT/B1N-915/verification.json"
expect_fail 'sensitive failure cannot release' "$HARNESS_BIN/release-ticket" B1N-915 review
mkdir "$RUNS_ROOT/B1N-924"
printf '{malformed\n' > "$RUNS_ROOT/B1N-924/task.json"
expect_pass 'status reports malformed and invalid runs then continues' bash -c '
  output="$(HARNESS_RUNS_ROOT="$1" "$2/status")"
  grep -E "B1N-924[[:space:]]+invalid" <<<"$output" >/dev/null &&
    grep -E "B1N-903[[:space:]]+invalid" <<<"$output" >/dev/null &&
    grep -E "B1N-914[[:space:]]+candidate" <<<"$output" >/dev/null
' _ "$RUNS_ROOT" "$HARNESS_BIN"

printf 'lifecycle: passed %s deterministic assertions\n' "$pass_count"
