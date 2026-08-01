# Active Repository Map

## Frontend

- Directory: `frontend/`
- Stack: Next.js, React, TypeScript, Bun
- Owns: vault-first UX, smart-wallet interactions, typed API consumption
- Fast verification: `bun run check:fast`

## Backend

- Directory: `backend/`
- Stack: Python, FastAPI, uv
- Owns: product APIs, event indexing, cached/read-through state, bot lifecycle
- Fast verification: `./scripts/harness-check.sh fast`

## Contracts

- Directory: `blockchain/`
- Stack: Solidity, Foundry
- Owns: vault accounting, option lifecycle, settlement, custody, upgrades
- Fast verification: `./scripts/harness-check.sh fast`

## Market Maker / Allocator

- Directory: `marketMaker/`
- Stack: Python, uv
- Owns: pricing, quote publication, hedging, and initial allocator operations
- Fast verification: `./scripts/harness-check.sh fast`

## Cross-Repository Contract

Contract ABIs and event semantics flow from contracts to backend and frontend.
Product-level API schemas flow from backend to frontend. Stabilize and record these
interfaces before parallel downstream implementation.

## Historical Repositories

`solana/`, `arc/`, `b1nary-xlayer-hackathon/`, copied backend worktrees, and v1 docs
are excluded from active v2 context unless a task explicitly opts into legacy work.
