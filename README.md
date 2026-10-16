# helix-kernel

Native AI SQL, versioned sidecars, jobs/outbox, authority schema and admission.

| | |
|---|---|
| Ownership group | Database Kernel |
| Primary form | C / SQL |
| Visibility | PUBLIC |
| Status | **Design phase.** Nothing here is implemented or supported yet. |

Design source of truth: the private `helix-atlas` repository (`architecture/repos/helix-kernel.md`).
Organization master prompt: PgHelix Organization Master Prompt, 16 Oct 2026.

## Build and test

`make installcheck (PostgreSQL 16-18, PGXS)` — to be wired up when the first implementation milestone lands.

## License

Not yet decided. The license is an ADR in `helix-atlas`; until it is accepted, no license is granted and all rights are reserved.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).
