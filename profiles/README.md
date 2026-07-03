# Profiles

The application creates default JSON profiles on first launch:

- `Default-Filesystem-Random-Read` — filesystem read workload (`format=no`)
- `Default-Filesystem-Format` — create/populate test files (`format=yes`, default file size `12g`)

Retired built-in profiles (`Default-4K-Random-Read`, `Default-70-30-Random-Mix`) are removed on startup if still present.

User-created profiles are also stored in this directory.
