# optionsWorkspace

Development harness and orchestration configuration for the b1nary Options
workspace.

This repository contains only the shared agent protocol, active v2 context,
external-memory schemas, verification entrypoints, hooks, and CI configuration.
The product repositories (`frontend`, `backend`, `blockchain`, and
`marketMaker`) remain independent Git repositories and are intentionally ignored
here.

## Start

```bash
./harness/bin/doctor
./harness/bin/start-ticket B1N-123 backend "Ticket objective"
./harness/bin/context backend
```

See [`docs/HARNESS.md`](docs/HARNESS.md) for task lifecycle, parallel worktrees,
review gates, and sensitive-data protections.
