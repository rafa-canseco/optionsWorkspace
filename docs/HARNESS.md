# Options Development Harness

The harness turns a Linear ticket into isolated implementation, independent review,
and reproducible verification without carrying an entire development session in a
model's context window.

## Typical Flow

```bash
./harness/bin/doctor
./harness/bin/install-hooks
./harness/bin/start-ticket B1N-123 backend "Expose compact vault state"
./harness/bin/claim-ticket B1N-123 backend-agent backend/.worktrees/B1N-123
./harness/bin/status
./harness/bin/context backend
./harness/bin/check backend fast
# Before committing: run full on the candidate and obtain independent diff review.
./harness/bin/check backend full
# Commit only that green, reviewed candidate, then bind the handoff to its SHA:
./harness/bin/record-implementation B1N-123 "Implemented compact vault state" src/vault.py
# release-ticket reruns canonical full verification and overwrites mutable evidence:
./harness/bin/release-ticket B1N-123 review
# The reviewer claims the unchanged commit and records the review attestation:
./harness/bin/claim-ticket B1N-123 backend-reviewer backend/.worktrees/B1N-123
./harness/bin/record-review B1N-123 approved
./harness/bin/release-ticket B1N-123 done
./harness/bin/sensitive-check
```

Linear remains authoritative. Files under `harness/runs/` are local coordination
memory and are intentionally ignored by Git.

One task packet owns exactly one repository. Split a cross-repository initiative
into linked Linear tickets, one per repository, then run those tickets in parallel
after their shared ABI/schema/API decision is recorded.

## Parallel Tickets

Use one branch/worktree and one run directory per ticket. The orchestrator assigns
independent tickets to separate repository owners, keeps one execution slot for
coordination, and reuses worker slots for independent review after implementation.

`claim-ticket` uses an atomic directory claim so two agents cannot own the same
ticket concurrently. `release-ticket` preserves claim history and makes the ticket
available for an independent reviewer. `status` shows every local run without loading
its documents into model context. A claim is rejected until the task packet has at
least one acceptance criterion.

`release-ticket ... review` and `release-ticket ... done` rerun the canonical full
command through `check ... --record` before evaluating the transition, so a complete
but forged JSON pass is overwritten rather than trusted. `done` additionally requires
non-empty acceptance criteria and an approved reviewer attestation. Proof and review
must name the repository HEAD in the current claimed worktree; stale, mismatched,
dirty, same-owner-label, or non-canonical evidence is rejected. Claimed worktrees
must belong to the configured Git repository, descend from its base branch, and use
a feature branch containing the issue ID when they are not detached.

Do not parallelize downstream consumers until their ABI, event, schema, or API
contract is stable. Never allow agents to share a branch or edit overlapping files.

## Delivery Policy

A ticket-scoped candidate commit is created only after the unrecorded full check,
sensitive-data check, and independent diff review pass. The commit must live on the
ticket's feature branch, contain only that ticket's files, use a conventional message
with the Linear ID, and leave unrelated working-tree changes untouched. After commit,
the supported record/release commands bind implementation, a fresh canonical full
run, and the reviewer attestation to the unchanged SHA.

The verified feature branch is then pushed and a draft PR is opened automatically.
Product PRs target `staging`; the workspace-harness repository targets `main`. The
PR receives the verification summary plus a closing reference such as
`Fixes B1N-123`, and Linear moves to Review. A failed or incomplete ticket remains
uncommitted in its isolated worktree with its state under
`harness/runs/<ISSUE-ID>/`.

Merge, deployment, release publication, and production changes still require an
explicit user request. Once an authorized merge lands on the configured integration
branch, the native GitHub–Linear automation moves the linked issue to Done. Agents
must not close it early or require a second user instruction after merge.

## Verification

- `fast`: deterministic, offline feedback used while coding.
- `full`: review gate with builds, integration checks, and risk-appropriate contract
  fuzz/invariant/fork verification.
- `check <repository> <fast|full> --record <ISSUE-ID>`: executes the command array
  configured in `harness/repos.json` without `eval`, derives command and overall
  status from its process exit code, and atomically writes `verification.json`.

Recording requires an active claim whose path is exactly the configured repository's
Git worktree root; a subdirectory or unrelated repository is rejected. The claimed
worktree must be clean, and assume-unchanged and skip-worktree index flags are
forbidden. Run `record-implementation` only after committing; its owner and commit
must match the implementation claim at the review gate. Verification evidence contains
the issue, repository, tier, structured canonical command and arguments, timestamps,
duration, product/workspace commit SHA, harness control-plane commit and manifest blob
SHA, exit code, command status, and derived overall status. The recorder checks
repository identity, HEAD, flags, cleanliness, and control-plane identity before and
after execution. A command that changes the worktree, HEAD, or control plane produces
failed, non-releasable evidence.

Failed commands still write failed evidence and return nonzero. Passing JSON is not a
trusted receipt by itself: release transitions rerun canonical full verification and
overwrite it. For a legacy active run whose implementation artifact predates commit
metadata, rerun `record-implementation` from the original clean implementation claim;
it deliberately replaces the legacy artifact, then applies strict validation.

`record-review <ISSUE-ID> <approved|changes_requested|blocked>` derives a reviewer
label from the active claim and the reviewed commit from its clean worktree. It rejects
the exact implementation-owner label, and `release-ticket ... done` checks the label
and commit again. Local owner strings are unauthenticated attestations: the same actor
can choose another label. Required GitHub review and branch protection are the
authoritative human identity boundary.

### Mechanical proof and judgment

Local harness evidence shows that the release command executed the configured process
at a specific clean commit and derived status from its exit code. For `workspace`, the
harness caller root must be the claimed root, so another worktree cannot redefine its
canonical manifest or scripts. For product tickets, the separate workspace control
plane's authoritative paths (`harness/bin`, `harness/lib`, manifest, and schemas) must
be committed and clean. Their committed tree/blob identities must also match the
trusted workspace `main` ref, using `origin/main` when available and local `main`
otherwise. The trust anchor is intentionally not read from the caller-controlled
manifest. This allows harmless
commits with identical control-plane content while rejecting alternate worktrees that
change canonical checks or scripts. The caller commit and committed manifest blob are
recorded and rechecked at release; unrelated workspace files do not block product
verification. This is not a signed or cryptographic CI receipt and does not prove
product correctness. The required GitHub Actions status check on the PR is the
authoritative CI result; branch protection must enforce it. Implementation summaries,
acceptance assessment, architecture, test semantics, and review findings remain
human/AI judgment artifacts. A reviewer must inspect the diff before the candidate
commit and bind that judgment to the unchanged commit afterward; the reviewer must not
author verification pass status.

The current baseline may be red. The harness reports failures honestly; it does not
silently waive them. Product cleanup should be tracked in separate Linear tickets.

### Workspace harness target

`workspace` is a first-class repository target with base branch `main`:

```bash
./harness/bin/context workspace
./harness/bin/check workspace fast
./harness/bin/check workspace full
./harness/bin/doctor workspace
```

The workspace checks validate shell syntax, JSON parsing, lifecycle positive and
negative cases, and sensitive-data behavior without running product suites. The
explicit `doctor workspace` mode is for an isolated top-level workspace worktree and
does not require nested product repositories or the `bun`, `uv`, and `forge`
runtimes. Plain `doctor` preserves the primary-checkout gate and validates all five
manifest targets, all four nested product repositories, and their runtimes.

## Legacy

V1 and multichain material is preserved as historical reference but excluded from
default context. Opt in only when a Linear ticket explicitly targets legacy work.

## Sensitive Data

`.mcp.json`, `.env*`, `settings.local.json`, keypairs, and secret files are local.
Run `sensitive-check` before commits and pushes. It is a conservative heuristic,
not a substitute for provider-side secret scanning. The script reports filenames or
a generic content warning and never prints matched secret values.

`install-hooks` configures the meta-repository and the four active repositories to
run the same check before commits and pushes. Re-run it after cloning the workspace.
The pre-push hook also scans outgoing commit diffs, so a secret cannot bypass the
gate merely because it is no longer staged or was removed in a later local commit.
