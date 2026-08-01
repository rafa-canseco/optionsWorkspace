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
./harness/bin/check backend full
./harness/bin/release-ticket B1N-123 review
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

`release-ticket ... review` requires an implemented handoff and passing verification.
`release-ticket ... done` additionally requires non-empty acceptance criteria, an
approved independent review, and passing full verification.

Do not parallelize downstream consumers until their ABI, event, schema, or API
contract is stable. Never allow agents to share a branch or edit overlapping files.

## Delivery Policy

An approved ticket is committed locally by default after full verification and the
sensitive-data check pass. The commit must live on the ticket's feature branch,
contain only that ticket's files, use a conventional message with the Linear ID,
and leave unrelated working-tree changes untouched.

The verified feature branch is then pushed and a draft PR is opened automatically.
Product PRs target `staging`; the workspace-harness repository targets `main`. The
PR receives the verification summary and Linear moves to Review. A failed or
incomplete ticket remains uncommitted in its isolated worktree with its state under
`harness/runs/<ISSUE-ID>/`.

Merge, deployment, release publication, production changes, and moving Linear to
Done still require an explicit user request.

## Verification

- `fast`: deterministic, offline feedback used while coding.
- `full`: review gate with builds, integration checks, and risk-appropriate contract
  fuzz/invariant/fork verification.

The current baseline may be red. The harness reports failures honestly; it does not
silently waive them. Product cleanup should be tracked in separate Linear tickets.

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
