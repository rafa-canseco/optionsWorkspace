# V2 Operating Context

## Direction

V2 is Base-only and vault-oriented. The trading interface from v1 can remain available for advanced users, but it is no longer the primary product surface. The primary experience is a vault flow: users deposit capital, the system operates strategies, and users see only the state they need to decide whether to enter, wait, withdraw, or claim.

Solana remains offline. Arc, XLayer, and hackathon experiments are out of scope. The historical `dev` branch is contaminated and must not be used as the integration base for v2 work.

## Product Name

Use `v2` as the product/project name. Do not introduce a separate public name until the user decides one.

## Milestones

### Milestone 1: CSP Vault

Goal: prove the ETH/USDC cash-secured put vault end to end.

Done means:

- A user can deposit USDC through the existing smart wallet flow.
- The CSP vault opens ETH/USDC cash-secured puts repeatedly.
- The allocator starts as our bot, while the architecture remains compatible with curated vaults.
- The vault keeps operating until assignment happens or the user exits.
- If not assigned, the user can exit in USDC according to epoch and withdrawal rules.
- If assigned, the user can claim ETH/WETH.
- Contracts are deployed on Base testnet for integration.
- Critical validation runs on a Base mainnet fork.
- Backend and frontend show only the information users need.

Milestone 1 does not include:

- Covered calls.
- Meta vault / full Patient Wheel automation.
- Mainnet production launch.
- Solana, Arc, or XLayer.
- Rebuilding all of v1.

### Milestone 2: Covered Call Vault

Build and validate the covered call vault separately. This vault accepts ETH/WETH and repeatedly sells covered calls. It should be designed with the same modularity and curator model as the CSP vault.

### Milestone 3: Meta Vault / Patient Wheel

Unify CSP and covered call vaults into the full Patient Wheel:

- USDC sells cash-secured puts.
- If no assignment, it remains in the CSP loop.
- If assigned, the vault receives ETH/WETH.
- ETH/WETH sells covered calls.
- If called away, the vault returns to USDC.
- The cycle repeats.

### Milestone 4: Mainnet

Deploy v2 to mainnet only after the Wheel is complete and validated. The mainnet deliverable should include the full CSP + covered call Wheel, not only the CSP vault.

## Asset Scope

Milestone 1 is ETH/USDC only.

The implementation should stay modular enough to add other assets later. Do not hardcode ETH/USDC into backend or frontend product architecture when a simple asset config, vault registry, or typed metadata layer would keep the path open. Still, do not build multi-asset UI or generalized strategy routing before ETH/USDC works.

## Contract Model

Milestone 1 source of truth: `blockchain/src/vaults/EthCspVault.sol`.

Core concepts:

- `sharesOf(user)`: active vault ownership.
- `pendingDepositAssets(user)`: deposit waiting for activation.
- `currentEpoch`: current vault cycle.
- `batches(batchId)`: CSP batches opened by the vault.
- `activeBatches`: whether capital is currently deployed.
- `activeCollateral`: capital committed to open options.
- `pendingWithdrawalShares(user)`: withdrawal requested by user.
- `claimableAssignedUnderlying(user)`: ETH/WETH claimable after assignment.
- `totalManagedAssets`: vault-managed capital.
- `openCspBatch`: allocator action to sell puts.
- `settleCspBatch`: normal settlement path.
- `closeEpoch`: closes cycle and finalizes deposits/withdrawals.

## Allocator And Curator Model

At first, the allocator is our bot.

The model should evolve toward curated vaults similar in spirit to Morpho:

- Curators define risk/strategy parameters.
- Allocators execute within those constraints.
- Users select a vault/curator instead of selecting every trade.
- Multiple vaults with different risk profiles should be possible later.

Do not design the system as if one hardcoded admin wallet will operate every vault forever.

## Backend Responsibilities

Backend is hybrid:

- Use RPC/read-through for critical current state.
- Use event indexing and storage for history, activity, and derived state when it reduces RPC calls.
- Expose product-level APIs to the frontend instead of leaking raw ABI details.
- Cache, batch, multicall, and snapshot aggressively where appropriate.

RPC cost optimization is a must-have requirement. Avoid expensive polling, duplicate reads per render, and broad per-user scans. Prefer event indexing plus compact current-state reads.

Backend should expose:

- Vault summary.
- User vault state.
- Active or recent batch state.
- Deposit, withdrawal, claim, and assignment availability.
- Minimal activity/history.
- Allocator/bot operational state where useful.

## Frontend Responsibilities

Frontend v2 is a new vault-first UX.

The user should understand:

- How much USDC they deposited.
- How much is active vs pending.
- Whether the vault is idle, deploying, active, settling, assigned, or claimable.
- Simple earnings/premium information.
- Whether they can deposit, request withdrawal, claim USDC, or claim ETH/WETH.

Less is more. Do not show every contract field just because it exists.

The v1 trading interface can remain available for users who want manual trading, but it should not dominate v2.

## Branching And Deployments

- `main`: stable clean baseline.
- `dev`: deprecated/contaminated; do not target for v2.
- `staging`: v2 integration branch in every active repo (`frontend`, `backend`, `blockchain`, `marketMaker`).
- Feature branches should start from `staging` unless the user explicitly asks for a branch from `main`.
- Backend vault work must not start from Agora/Arc branches.

PRs for v2 target `staging`, not `dev`.

## Agent Rules

- Read this file before planning v2 work.
- Do not use `dev` for v2.
- Do not add Solana, Arc, or XLayer to v2 work.
- Keep Milestone 1 focused on ETH/USDC CSP Vault.
- Keep architecture modular for future assets.
- Use the existing smart wallet deposit flow.
- Treat RPC cost reduction as a product requirement.
- Prefer small, composable backend APIs over exposing contract internals.
- Keep the UX minimal and user-state driven.
- Document cross-repo decisions before implementation.

## Open Decisions

- Event index schema for vault history.
- Allocator bot runtime and deployment owner.
- Covered call vault contract path for Milestone 2.
- Meta vault architecture for Milestone 3.
