#!/usr/bin/env bash

workflow_next_action() {
  case "$1" in
    planned) printf 'claim implementation\n' ;;
    implementing) printf 'record implementation\n' ;;
    candidate) printf 'release for review\n' ;;
    awaiting_review) printf 'claim independent review\n' ;;
    reviewing) printf 'record verdict and release\n' ;;
    repair) printf 'claim repair implementation\n' ;;
    human_blocked) printf 'await follow-up Linear decision\n' ;;
    approved) printf 'await merge\n' ;;
    *) return 1 ;;
  esac
}

workflow_task_status() {
  case "$1" in
    planned|repair) printf 'planned\n' ;;
    implementing|candidate|reviewing) printf 'in_progress\n' ;;
    awaiting_review) printf 'review\n' ;;
    human_blocked) printf 'blocked\n' ;;
    approved) printf 'done\n' ;;
    *) return 1 ;;
  esac
}

workflow_edge_allowed() {
  case "$1:$2:$3" in
    planned:implementing:claim_implementation|repair:implementing:claim_repair|\
    implementing:candidate:record_implementation|candidate:awaiting_review:release_review|\
    awaiting_review:reviewing:claim_review|reviewing:repair:changes_requested|\
    reviewing:repair:review_blocked|reviewing:human_blocked:repair_budget_exhausted|\
    reviewing:approved:approve) return 0 ;;
    *) return 1 ;;
  esac
}

workflow_create() {
  local run_dir="$1" issue_id="$2" now next
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  next="$(workflow_next_action planned)"
  jq -n --arg issue_id "$issue_id" --arg now "$now" --arg next "$next" '{
    issue_id:$issue_id, phase:"planned", repair_count:0, max_repairs:2,
    blocker:null, last_evidence_commit:null, next_action:$next,
    history:[{from:null,to:"planned",action:"start",actor:"start-ticket",at:$now}]
  }' > "$run_dir/workflow.json"
}

workflow_transition() (
  local run_dir="$1" expected="$2" next_phase="$3" actor="$4" action="$5"
  local blocker="${6:-}" evidence_commit="${7:-}" increment="${8:-0}"
  local lock="$run_dir/.workflow.lock" tmp status next now
  workflow_edge_allowed "$expected" "$next_phase" "$action" || {
    printf 'workflow: rejected transition %s -> %s (%s)\n' "$expected" "$next_phase" "$action" >&2
    return 1
  }
  mkdir "$lock" 2>/dev/null || { printf 'workflow: transition already in progress\n' >&2; return 1; }
  tmp="$run_dir/workflow.json.tmp.$$"
  trap 'rm -f "$tmp"; rmdir "$lock" 2>/dev/null || true' EXIT
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  next="$(workflow_next_action "$next_phase")"
  jq --arg expected "$expected" --arg next "$next_phase" --arg actor "$actor" \
    --arg action "$action" --arg at "$now" --arg next_action "$next" \
    --arg blocker "$blocker" --arg evidence "$evidence_commit" --argjson increment "$increment" '
      select(.phase == $expected) |
      .phase = $next |
      .repair_count += $increment |
      .blocker = (if $blocker == "" then null else $blocker end) |
      .last_evidence_commit = (if $evidence == "" then .last_evidence_commit else $evidence end) |
      .next_action = $next_action |
      .history += [({from:$expected,to:$next,action:$action,actor:$actor,at:$at}
        + (if $evidence == "" then {} else {evidence_commit:$evidence} end))]
    ' "$run_dir/workflow.json" > "$tmp"
  [[ -s "$tmp" ]] || return 1
  mv "$tmp" "$run_dir/workflow.json"
  status="$(workflow_task_status "$next_phase")"
  if [[ "${HARNESS_TEST_FAIL_TASK_PROJECTION:-}" != 1 ]] &&
     jq --arg status "$status" '.status = $status' "$run_dir/task.json" > "$run_dir/task.json.tmp.$$"; then
    mv "$run_dir/task.json.tmp.$$" "$run_dir/task.json" || true
  else
    rm -f "$run_dir/task.json.tmp.$$"
    printf 'workflow: warning: task.status projection is stale\n' >&2
  fi
)

workflow_review_result() {
  local run_dir="$1" actor="$2" verdict="$3" evidence="$4" count max
  case "$verdict" in
    blocked)
      workflow_transition "$run_dir" reviewing repair "$actor" review_blocked \
        'independent review blocked' "$evidence"
      ;;
    changes_requested)
      count="$(jq -r '.repair_count' "$run_dir/workflow.json")"
      max="$(jq -r '.max_repairs' "$run_dir/workflow.json")"
      if (( count < max )); then
        workflow_transition "$run_dir" reviewing repair "$actor" changes_requested '' "$evidence" 1
      else
        workflow_transition "$run_dir" reviewing human_blocked "$actor" repair_budget_exhausted \
          "repair budget exhausted after $max repairs" "$evidence"
      fi
      ;;
    *) return 1 ;;
  esac
}
