# Profiles

The application creates default JSON profiles on first launch:

- `Default-Filesystem-Random-Read` — filesystem read workload (`format=no`)
- `Default-Filesystem-Format` — create/populate test files (`format=yes`, default file size `12g`)
- `Default-Distributed-WP` — acceptance Workload Profile: 100% random, 32k, 70% read / 30% write
  (`rdpct=70`), 16 threads on one shared test file per target (`fileio=(random,shared)`,
  `files=1`, `size=5g` — raise to `1.25t` for the full test), 5 min warmup + 30 min measured
  (`elapsed=2100`, `warmup=300`), `format=restart` (creates missing test files on first run,
  reuses them afterwards)

Retired built-in profiles (`Default-4K-Random-Read`, `Default-70-30-Random-Mix`) are removed on startup if still present.

Filesystem profiles always use fixed defaults (hidden in the Profile editor): one test file per target (`files=1`), non-shared FSD (`shared=no`), and multi-thread-safe random I/O (`fileio=(random,shared)`). Opening or saving a profile normalizes these values automatically.

User-created profiles are also stored in this directory.
