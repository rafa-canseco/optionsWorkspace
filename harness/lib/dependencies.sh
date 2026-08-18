#!/usr/bin/env bash

DEPENDENCY_GATES='contract_approved fixture_pinned pr_ready merged'

dependency_gate_valid() {
  [[ " $DEPENDENCY_GATES " == *" $1 "* ]]
}

dependency_repo_dir() {
  local repository="$1" path
  path="$(jq -r --arg repository "$repository" '.repositories[$repository].path // empty' "$MANIFEST")"
  [[ -n "$path" ]] || return 1
  printf '%s/%s\n' "$WORKSPACE_ROOT" "$path"
}

dependency_digest() {
  openssl dgst -sha256 | awk '{print $NF}'
}

dependency_repo_slug() {
  local repo_dir="$1" remote
  remote="$(git -C "$repo_dir" remote get-url origin 2>/dev/null)" || return 1
  remote="${remote%.git}"
  case "$remote" in
    https://github.com/*) printf '%s\n' "${remote#https://github.com/}" ;;
    git@github.com:*) printf '%s\n' "${remote#git@github.com:}" ;;
    *) return 1 ;;
  esac
}

dependency_github_json() {
  local uri="$1"
  command -v gh >/dev/null || return 1
  gh pr view "$uri" --json number,url,headRefOid,baseRefName,state,mergeCommit,reviewDecision
}

dependency_required_checks() {
  local slug="$1" base="$2"
  command -v gh >/dev/null || return 1
  gh api "repos/$slug/branches/$base/protection/required_status_checks" |
    jq -ce '([(.contexts // [])[] | {context:.,app_id:null}] +
      [(.checks // [])[] | {context:.context,app_id:.app_id}]) | unique_by([.context,.app_id]) | select(length > 0)'
}

dependency_check_runs() {
  local slug="$1" commit="$2"
  command -v gh >/dev/null || return 1
  gh api "repos/$slug/commits/$commit/check-runs?filter=latest" | jq -ce '.check_runs'
}

dependency_evidence() {
  local repository="$1" commit="$2" gate="$3" artifact="$4" repo_dir live base slug prefix required check_runs
  dependency_gate_valid "$gate" || return 1
  repo_dir="$(dependency_repo_dir "$repository")" || return 1
  case "$gate" in
    contract_approved|fixture_pinned)
      [[ "$artifact" != /* && "$artifact" != *'..'* ]] || return 1
      git -C "$repo_dir" cat-file -e "$commit:$artifact" 2>/dev/null || return 1
      jq -cn --arg digest "$(git -C "$repo_dir" show "$commit:$artifact" | dependency_digest)" \
        '{digest:$digest}'
      ;;
    pr_ready|merged)
      slug="$(dependency_repo_slug "$repo_dir")" || return 1
      prefix="https://github.com/$slug/pull/"
      [[ "$artifact" == "$prefix"* ]] || return 1
      [[ "${artifact:${#prefix}}" =~ ^[0-9]+$ ]] || return 1
      live="$(dependency_github_json "$artifact" 2>/dev/null)" || return 1
      base="$(jq -r --arg repository "$repository" '.repositories[$repository].base_branch' "$MANIFEST")"
      required="$(dependency_required_checks "$slug" "$base" 2>/dev/null)" || return 1
      check_runs="$(dependency_check_runs "$slug" "$commit" 2>/dev/null)" || return 1
      jq -e --arg artifact "$artifact" --arg commit "$commit" --arg base "$base" --arg gate "$gate" '
        .url == $artifact and .headRefOid == $commit and .baseRefName == $base and
        .reviewDecision == "APPROVED" and
        (if $gate == "merged" then .state == "MERGED" and (.mergeCommit.oid | type == "string" and length > 0)
         else (.state == "OPEN" or .state == "MERGED") end)
      ' <<<"$live" >/dev/null || return 1
      jq -en --argjson required "$required" --argjson runs "$check_runs" '
        ($required | length > 0) and all($required[]; . as $requirement |
          any($runs[]; .name == $requirement.context and
            ($requirement.app_id == null or .app.id == $requirement.app_id) and
            .status == "completed" and .conclusion == "success"))
      ' >/dev/null || return 1
      jq -cn --arg digest "$(printf '%s' "$artifact" | dependency_digest)" \
        --argjson pr_number "$(jq '.number' <<<"$live")" \
        --arg base_branch "$base" \
        --arg merge_commit "$(jq -r '.mergeCommit.oid // empty' <<<"$live")" \
        '{digest:$digest,pr_number:$pr_number,base_branch:$base_branch,merge_commit:(if $merge_commit == "" then null else $merge_commit end)}'
      ;;
  esac
}

dependency_milestone_valid() {
  local source_dir="$1" requested_gate="$2" milestone="$3" repository commit implementer reviewer evidence
  repository="$(jq -r '.repositories[0]' "$source_dir/task.json" 2>/dev/null)" || return 1
  commit="$(jq -r 'select(.status == "implemented") | .commit_sha' "$source_dir/implementation.json" 2>/dev/null)" || return 1
  implementer="$(jq -r '.implementer' "$source_dir/implementation.json" 2>/dev/null)" || return 1
  reviewer="$(jq -r --arg commit "$commit" 'select(.verdict == "approved" and .reviewed_commit == $commit) | .reviewer' "$source_dir/review.json" 2>/dev/null)" || return 1
  [[ -n "$reviewer" ]] || return 1
  jq -e --arg commit "$commit" --arg reviewer "$reviewer" '
    .phase == "approved" and .last_evidence_commit == $commit and
    .history[-1].action == "approve" and .history[-1].actor == $reviewer
  ' "$source_dir/workflow.json" >/dev/null || return 1
  jq -e --arg repository "$repository" --arg commit "$commit" --arg requested "$requested_gate" \
    --arg implementer "$implementer" --arg reviewer "$reviewer" '
    .status == "approved" and .repository == $repository and .source_commit == $commit and
    (.gate == $requested or ($requested == "pr_ready" and .gate == "merged")) and
    .algorithm == "sha256" and (.digest | test("^[0-9a-f]{64}$")) and
    .proposer == $implementer and .approver == $reviewer and
    .approver != .proposer and .approver != $implementer and
    (.proposed_at | type == "string") and (.approved_at | type == "string")
  ' <<<"$milestone" >/dev/null || return 1
  evidence="$(dependency_evidence "$repository" "$commit" "$(jq -r '.gate' <<<"$milestone")" "$(jq -r '.artifact' <<<"$milestone")")" || return 1
  jq -e --argjson evidence "$evidence" '
    .digest == $evidence.digest and
    ((.pr_number // null) == ($evidence.pr_number // null)) and
    ((.base_branch // null) == ($evidence.base_branch // null)) and
    ((.merge_commit // null) == ($evidence.merge_commit // null))
  ' <<<"$milestone" >/dev/null
}

dependencies_check() {
  local run_dir="$1" edge source gate source_dir matches milestone failed=0
  while IFS= read -r edge; do
    source="$(jq -r '.issue_id' <<<"$edge")"
    gate="$(jq -r '.gate' <<<"$edge")"
    source_dir="$RUNS_ROOT/$source"
    if [[ ! -f "$source_dir/milestones.json" ]]; then
      printf '%s:%s missing predecessor evidence\n' "$source" "$gate"
      failed=1
      continue
    fi
    matches="$(jq -c --arg gate "$gate" '.milestones[] | select(.gate == $gate or ($gate == "pr_ready" and .gate == "merged"))' "$source_dir/milestones.json" 2>/dev/null)"
    if [[ -z "$matches" ]]; then
      printf '%s:%s pending milestone\n' "$source" "$gate"
      failed=1
      continue
    fi
    milestone=''
    while IFS= read -r candidate; do
      if dependency_milestone_valid "$source_dir" "$gate" "$candidate"; then milestone="$candidate"; break; fi
    done <<<"$matches"
    if [[ -z "$milestone" ]]; then
      printf '%s:%s stale or unapproved milestone\n' "$source" "$gate"
      failed=1
    fi
  done < <(jq -c '.dependencies[]' "$run_dir/task.json")
  return "$failed"
}
