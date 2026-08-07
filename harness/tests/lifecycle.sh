#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SOURCE_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

TEST_WORKSPACE="$TMP_ROOT/workspace"
RUNS_ROOT="$TEST_WORKSPACE/harness/runs"
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

# Positive lifecycle: supported commands create commit-bound evidence and review.
prepare_done_gate B1N-900
expect_pass 'positive done release' "$HARNESS_BIN/release-ticket" B1N-900 done
expect_pass 'positive task done' jq -e '.status == "done"' "$RUNS_ROOT/B1N-900/task.json"
expect_pass 'positive verification shape' jq -e --arg control "$CONTROL_SHA" --arg manifest "$MANIFEST_BLOB_SHA" '
  .overall == "passed" and .tier == "full" and (.commands | length == 1) and
  (.commit_sha == .commands[0].commit_sha) and .commands[0].exit_code == 0 and
  .control_plane.commit_sha == $control and .control_plane.manifest_blob_sha == $manifest
' "$RUNS_ROOT/B1N-900/verification.json"

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

# Legacy implementation evidence can be replaced by the supported recorder.
new_run B1N-914
cat > "$RUNS_ROOT/B1N-914/implementation.json" <<'JSON'
{"issue_id":"B1N-914","repository":"workspace","status":"implemented","summary":"legacy","files_changed":[],"known_issues":[]}
JSON
expect_pass 'legacy implementation migration' "$HARNESS_BIN/record-implementation" B1N-914 'Migrated legacy handoff' tracked.txt
expect_pass 'migrated implementation validates' "$HARNESS_BIN/validate-run" B1N-914

# Schema/runtime contract checks requiring no extra validator dependency.
expect_pass 'task schema exactly one repository' jq -e '.properties.repositories.maxItems == 1' "$TEST_WORKSPACE/harness/schemas/task.schema.json"
mutate "$RUNS_ROOT/B1N-914/task.json" '.repositories += ["frontend"]'
expect_fail 'runtime rejects multi-repository task' "$HARNESS_BIN/validate-run" B1N-914
mutate "$RUNS_ROOT/B1N-914/task.json" '.repositories = ["workspace"]'

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

printf 'lifecycle: passed %s deterministic assertions\n' "$pass_count"
