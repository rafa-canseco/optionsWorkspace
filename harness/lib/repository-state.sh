#!/usr/bin/env bash

# Shared deterministic repository/worktree checks. Callers must define
# WORKSPACE_ROOT and MANIFEST before sourcing this file.

canonical_directory() {
  (CDPATH= cd -- "$1" 2>/dev/null && pwd -P)
}

git_common_directory() {
  local repository="$1"
  local common
  local parent
  common="$(git -C "$repository" rev-parse --git-common-dir 2>/dev/null)" || return 1
  if [[ "$common" == /* ]]; then
    canonical_directory "$common"
    return
  fi
  parent="$(canonical_directory "$repository")" || return 1
  canonical_directory "$parent/$common"
}

resolve_worktree_path() {
  local worktree="$1"
  if [[ "$worktree" != /* ]]; then
    worktree="$WORKSPACE_ROOT/$worktree"
  fi
  canonical_directory "$worktree"
}

expected_repository_root() {
  local repository="$1"
  local repository_path
  repository_path="$(jq -r --arg repository "$repository" '.repositories[$repository].path // empty' "$MANIFEST")"
  [[ -n "$repository_path" ]] || return 1
  canonical_directory "$WORKSPACE_ROOT/$repository_path"
}

validate_claimed_repository() {
  local repository="$1"
  local worktree_input="$2"
  local issue_id="$3"
  local worktree worktree_root expected_root actual_common expected_common base_branch base_ref branch issue_lower branch_lower

  worktree="$(resolve_worktree_path "$worktree_input")" || {
    printf 'repository-state: claimed worktree does not exist: %s\n' "$worktree_input" >&2
    return 1
  }
  expected_root="$(expected_repository_root "$repository")" || {
    printf 'repository-state: configured repository path is unavailable: %s\n' "$repository" >&2
    return 1
  }
  git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    printf 'repository-state: claimed path is not a Git worktree: %s\n' "$worktree" >&2
    return 1
  }
  worktree_root="$(git -C "$worktree" rev-parse --show-toplevel)" || return 1
  worktree_root="$(canonical_directory "$worktree_root")" || return 1
  if [[ "$worktree" != "$worktree_root" ]]; then
    printf 'repository-state: claimed path must be the Git worktree root\n' >&2
    return 1
  fi
  git -C "$expected_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    printf 'repository-state: configured repository is not a Git repository: %s\n' "$expected_root" >&2
    return 1
  }

  actual_common="$(git_common_directory "$worktree")" || return 1
  expected_common="$(git_common_directory "$expected_root")" || return 1
  if [[ "$actual_common" != "$expected_common" ]]; then
    printf 'repository-state: claimed worktree belongs to another repository\n' >&2
    return 1
  fi

  base_branch="$(jq -r --arg repository "$repository" '.repositories[$repository].base_branch // empty' "$MANIFEST")"
  [[ -n "$base_branch" ]] || {
    printf 'repository-state: base branch is not configured for %s\n' "$repository" >&2
    return 1
  }
  base_ref=""
  if git -C "$worktree" show-ref --verify --quiet "refs/heads/$base_branch"; then
    base_ref="refs/heads/$base_branch"
  elif git -C "$worktree" show-ref --verify --quiet "refs/remotes/origin/$base_branch"; then
    base_ref="refs/remotes/origin/$base_branch"
  fi
  if [[ -z "$base_ref" ]] || ! git -C "$worktree" merge-base --is-ancestor "$base_ref" HEAD; then
    printf 'repository-state: claimed HEAD must descend from configured base branch %s\n' "$base_branch" >&2
    return 1
  fi

  branch="$(git -C "$worktree" branch --show-current)"
  if [[ -n "$branch" ]]; then
    issue_lower="$(printf '%s' "$issue_id" | tr '[:upper:]' '[:lower:]')"
    branch_lower="$(printf '%s' "$branch" | tr '[:upper:]' '[:lower:]')"
    if [[ "$branch" == "$base_branch" || "$branch_lower" != *"$issue_lower"* ]]; then
      printf 'repository-state: claimed branch must be a feature branch containing %s\n' "$issue_lower" >&2
      return 1
    fi
  fi

  printf '%s\n' "$worktree"
}

control_plane_identity() {
  local repository="$1"
  local claimed_worktree="$2"
  local caller_root caller_top control_commit manifest_blob current_manifest_blob
  local trusted_ref control_path current_object trusted_object
  local control_paths=(harness/bin harness/lib harness/repos.json harness/schemas)

  caller_root="$(canonical_directory "$WORKSPACE_ROOT")" || return 1
  caller_top="$(git -C "$caller_root" rev-parse --show-toplevel 2>/dev/null)" || {
    printf 'repository-state: harness control plane is not a Git worktree\n' >&2
    return 1
  }
  caller_top="$(canonical_directory "$caller_top")" || return 1
  if [[ "$caller_root" != "$caller_top" ]]; then
    printf 'repository-state: harness control plane must run from its Git worktree root\n' >&2
    return 1
  fi
  if [[ "$repository" == "workspace" && "$caller_root" != "$claimed_worktree" ]]; then
    printf 'repository-state: workspace checks must run from the claimed workspace root\n' >&2
    return 1
  fi

  if git -C "$caller_root" ls-files -v -- "${control_paths[@]}" | grep -Eq '^[a-zS]'; then
    printf 'repository-state: control-plane index flags are forbidden\n' >&2
    return 1
  fi
  if ! git -C "$caller_root" diff --quiet HEAD -- "${control_paths[@]}" ||
     ! git -C "$caller_root" diff --cached --quiet -- "${control_paths[@]}" ||
     [[ -n "$(git -C "$caller_root" status --porcelain=v1 --untracked-files=all -- "${control_paths[@]}")" ]]; then
    printf 'repository-state: harness control plane must be committed and clean at HEAD\n' >&2
    return 1
  fi

  control_commit="$(git -C "$caller_root" rev-parse HEAD)" || return 1
  manifest_blob="$(git -C "$caller_root" rev-parse HEAD:harness/repos.json 2>/dev/null)" || {
    printf 'repository-state: committed harness manifest is missing\n' >&2
    return 1
  }
  current_manifest_blob="$(git -C "$caller_root" hash-object "$MANIFEST")" || return 1
  if [[ "$manifest_blob" != "$current_manifest_blob" ]]; then
    printf 'repository-state: harness manifest differs from the committed control plane\n' >&2
    return 1
  fi

  # Workspace tickets verify their own exact claimed candidate root before merge.
  # Product tickets use a separate workspace checkout, so its committed authority
  # must match the trusted workspace base ref rather than merely being clean.
  if [[ "$repository" != "workspace" ]]; then
    # Product authority is anchored outside the caller-controlled manifest. The
    # workspace integration branch is a protocol invariant: product PRs target
    # staging, while the workspace harness itself is trusted from main.
    if git -C "$caller_root" show-ref --verify --quiet refs/remotes/origin/main; then
      trusted_ref="refs/remotes/origin/main"
    elif git -C "$caller_root" show-ref --verify --quiet refs/heads/main; then
      trusted_ref="refs/heads/main"
    else
      printf 'repository-state: trusted workspace main ref is unavailable\n' >&2
      return 1
    fi

    for control_path in "${control_paths[@]}"; do
      current_object="$(git -C "$caller_root" rev-parse "HEAD:$control_path" 2>/dev/null)" || {
        printf 'repository-state: committed control-plane path is missing: %s\n' "$control_path" >&2
        return 1
      }
      trusted_object="$(git -C "$caller_root" rev-parse "$trusted_ref:$control_path" 2>/dev/null)" || {
        printf 'repository-state: trusted control-plane path is missing: %s\n' "$control_path" >&2
        return 1
      }
      if [[ "$current_object" != "$trusted_object" ]]; then
        printf 'repository-state: product control plane differs from trusted %s at %s\n' \
          "$trusted_ref" "$control_path" >&2
        return 1
      fi
    done
  fi

  printf '%s\n%s\n' "$control_commit" "$manifest_blob"
}

reject_special_index_flags() {
  local worktree="$1"
  if git -C "$worktree" ls-files -v | grep -Eq '^[a-zS]'; then
    printf 'repository-state: assume-unchanged or skip-worktree index flags are forbidden\n' >&2
    return 1
  fi
}

require_clean_commit() {
  local worktree="$1"
  reject_special_index_flags "$worktree" || return
  if ! git -C "$worktree" update-index --really-refresh >/dev/null 2>&1; then
    printf 'repository-state: tracked files differ from the index\n' >&2
    return 1
  fi
  if ! git -C "$worktree" diff --quiet HEAD -- ||
     ! git -C "$worktree" diff --cached --quiet -- ||
     [[ -n "$(git -C "$worktree" status --porcelain=v1 --untracked-files=all)" ]]; then
    printf 'repository-state: claimed worktree must be clean at HEAD\n' >&2
    return 1
  fi
}
