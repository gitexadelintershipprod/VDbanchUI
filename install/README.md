# install/

Lab prepare kit for Vdbench UI.

| File | Purpose |
|---|---|
| `01-Prepare-Vdbench-Master.ps1` | Windows master |
| `02-Prepare-Vdbench-Windows-Slave.ps1` | Windows slave |
| `03-Prepare-Vdbench-Linux-Slave-v4.3.sh` | Linux slave (RHEL 9) |
| `04-Check-Vdbench-Hosts-Readiness.ps1` | Master readiness checks |
| `REQUIRED-FILES.txt` | Packages / RPMs you must add (not in git) |

Copy this folder to `C:\install` (Windows) or `/root/install` (Linux).

**Order:** run `01` on the master → copy `master_id_ed25519.pub` to every slave → run `02` / `03` on slaves.

See [REQUIRED-FILES.txt](REQUIRED-FILES.txt) and the bilingual guides under [`docs/en`](../docs/en/README.md) / [`docs/ka`](../docs/ka/README.md).
