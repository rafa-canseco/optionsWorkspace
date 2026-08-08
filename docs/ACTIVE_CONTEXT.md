# Active Context Router

This is the minimal entry point for current product work.

## Current Direction

- Product: b1nary v2.
- Network: Base only.
- Primary UX: vault-first.
- Current milestone: ETH/USDC cash-secured put vault.
- Integration branch: `staging` in every active repository.
- Existing smart-wallet deposit flow remains the deposit entry point.
- RPC cost is a product constraint: batch, cache, index, and avoid duplicate reads.

Read `v2/V2_OPERATING_CONTEXT.md` for detailed milestones, contract concepts,
backend/frontend responsibilities, and open decisions.

## Context Routing

Use `../harness/bin/context <repository>` to list the additional context for one of:

- `workspace` (workspace harness changes only)
- `frontend`
- `backend`
- `blockchain`
- `marketMaker`

Do not load unrelated repositories or historical documents into the model context.

## Legacy Boundary

The following are historical or inactive by default:

- v1 trade-oriented documentation and interfaces
- Solana
- Arc
- XLayer and hackathon projects
- historical `dev` branches
- the broad legacy `playbook/CONTEXT.md`

They remain available for explicit legacy maintenance, research, and rollback
reference. They are not startup context for v2 tickets.
