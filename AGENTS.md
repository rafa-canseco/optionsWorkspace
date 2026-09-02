# Options Workspace Orchestrator

This file is the canonical agent protocol for the `options` workspace. Tool-specific
files such as `CLAUDE.md` are adapters and must point here instead of duplicating
these rules.

## Active Product Context

- The default product scope is v2: Base-only, vault-first, with ETH/USDC as the
  first milestone.
- Read `docs/ACTIVE_CONTEXT.md` first and load only the repository-specific files
  returned by `harness/bin/context <repository>`.
- Do not read v1, Solana, Arc, XLayer, hackathon, or legacy playbook material unless
  the task is explicitly labelled or described as legacy work.
- `docs/v2/V2_OPERATING_CONTEXT.md` is the detailed product source of truth.
- Linear is the source of truth for tasks, status, dependencies, and acceptance
  criteria. Do not create a competing backlog in the repository.

## Active Repositories

| Repository | Directory | Owner |
|---|---|---|
| Workspace harness | `.` | workspace instance |
| Frontend | `frontend/` | frontend instance |
| Backend | `backend/` | backend instance |
| Contracts | `blockchain/` | contracts instance |
| Market maker / allocator | `marketMaker/` | market maker instance |

Preserve every repository's local `AGENTS.md`. One agent owns one worktree at a
time and writes only inside the repositories assigned in its task packet.

## Start Protocol

Before implementation:

1. Run `harness/bin/doctor`.
2. Read the Linear issue and its acceptance criteria. A direct user instruction
   approving a written plan also counts as plan approval.
3. Create or resume `harness/runs/<ISSUE-ID>/` with
   `harness/bin/start-ticket`.
4. Read only the active context routed for the affected repository.
5. Confirm the correct base branch and use a dedicated branch/worktree.
6. Record the plan and ownership in the run directory before editing code.

If initialization fails, stop implementation and report the failing prerequisite.
Never hide a red baseline.

## Parallel Orchestration

- Never initiate Codex agents. Use Pi sessions managed by Herdr for delegation and
  independent review.
- For multiple independent tickets, non-trivial cross-repository work, or when the
  user requests agents, the orchestrator delegates implementation to repository
  owners in parallel.
- Keep one execution slot for the orchestrator. Use remaining slots for independent
  workers, then reuse them for review.
- Do not assign two agents to the same branch, worktree, or overlapping files.
- Respect dependency order. Stabilize an ABI, schema, or API contract before
  starting downstream consumers; downstream work may use agreed fixtures.
- Give every subagent a minimal task packet: objective, acceptance criteria,
  repository/worktree, allowed scope, relevant context paths, dependencies,
  verification command, and output path.
- Explorers are read-only and are used only when the implementation surface is
  unclear. Implementers do not approve their own work.
- Standard- and high-risk work uses a fresh reviewer that reads the task packet,
  diff, durable decisions, and verification evidence without inheriting the
  implementer's full conversation. Approved low-risk work does not spawn one.

<pi-intercom>
Coordinate with other local pi sessions on related codebases. Use `/skill:pi-intercom` for patterns.

**When:** Same codebase (parallel work), reference codebase (consulting patterns), related repos (shared libraries).

**Not when:** Unrelated codebases, trivial questions, or when you can proceed independently.

**Principle:** Prefer `send` for notifications; `ask` only when blocked waiting for input.
</pi-intercom>

## External Memory Protocol

Each active ticket uses `harness/runs/<ISSUE-ID>/`:

- `task.json`: cached task packet; Linear remains authoritative.
- `current.md`: current owner, worktree, next action, and blockers.
- `exploration.md`: concise paths, patterns, and constraints discovered.
- `decisions.md`: decisions that downstream agents must know.
- `implementation.json`: files changed and implementation summary.
- `review.json`: independent verdict and required corrections.
- `verification.json`: exact commands, exit codes, and evidence.

Keep these files concise. Do not paste full source files, raw logs, secrets, or long
conversation transcripts. At completion, publish the durable summary to the PR and
Linear. Promote architectural decisions to `docs/decisions/`.

## Verification Protocol

- During implementation, run the narrowest affected test, lint, type, or build
  selector. Do not run a repository-wide gate after every edit.
- Run `harness/bin/check <repository> fast` once on the uncommitted candidate before
  handoff. `fast` must be deterministic and offline.
- Every task has a risk tier. Missing legacy values default to `high`:
  - `low`: targeted edit-loop checks, canonical `fast`, no fresh reviewer;
  - `standard`: targeted edit-loop checks, canonical `fast`, independent review;
  - `high`: targeted edit-loop checks, canonical `full`, independent defensive review.
- Only Linear acceptance criteria or a direct user instruction may approve `low` or
  `standard`. Record that source in `task.json.risk_approval` before claiming work.
- `full` may require explicitly declared integration services or pinned fork RPC
  configuration. Use it only for high-risk work or when acceptance criteria require
  that evidence. The release gate reruns the risk-required canonical command and
  binds evidence to the candidate SHA.
- Never mark a task done solely from an agent's written claim. Local
  `verification.json` is deterministic commit-bound evidence for both the claimed
  repository and committed harness control plane; the required GitHub status check
  is the authoritative CI result.
- Contract, custody, settlement, signature, upgrade, and deployment changes require
  an independent defensive security review plus appropriate fuzz, invariant,
  storage, and fork evidence.
- The external `options-scenarios` holdout is never read, explored, globbed, or
  searched by agents. Only user-provided failure messages may be used.

## Sensitive Data And Git

- Never stage, commit, print, summarize, or push secrets, private keys, seed phrases,
  API tokens, `.env` files, `.mcp.json`, or `settings.local.json`.
- Run `harness/bin/sensitive-check` before any commit or push.
- After the unrecorded risk-required check passes, create a local ticket-scoped
  candidate commit. Standard/high-risk work also requires independent diff review and
  a reviewer attestation bound to the unchanged commit; approved low-risk work does
  not. Use a conventional message containing the Linear ID and stage only files owned
  by that ticket.
- Push the verified feature branch and open a draft PR by default. Product PRs target
  the repository's `staging` branch; workspace-harness PRs target `main`. Add the
  verification evidence and a closing reference such as `Fixes B1N-123` to the PR,
  then move the Linear issue to Review.
- Do not manually move a linked issue to Done before merge. The GitHub–Linear
  integration owns that transition and closes the issue automatically after its PR
  is merged to the configured integration branch.
- Never commit a red or incomplete handoff merely to preserve progress. Keep partial
  work in its ticket worktree and external-memory run instead.
- Do not merge, deploy, publish a release, or otherwise update production/external
  runtime state unless the user explicitly requests it.
- Never push directly to `main`, `dev`, or `staging`; use feature branches.
- V2 feature branches and PRs use `staging`, not historical `dev`.
- Preserve unrelated dirty-worktree changes. Do not reset, delete, or overwrite
  another ticket's work.

## Harness Changes

Agents may suggest harness improvements in `review.json`, but must not silently
self-modify prompts, policies, or verification thresholds. Harness changes are
normal reviewed code changes with their own regression evidence.

## Security Review Output

- Phrase audit prompts and findings as authorized defensive code review.
- Do not use adversarial role-play or operational attack language in delegated
  prompts or user-facing updates.
- Never stream or forward raw security subagent output. Summarize root cause,
  affected invariant, impact, fix, and regression test.
- If content is suppressed, do not repeat it. Continue with safer wording and
  report only the resulting defensive findings.
