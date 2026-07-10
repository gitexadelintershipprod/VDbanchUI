# Vdbench UI

<p align="center">
  <strong>Portable Windows manager for Oracle Vdbench</strong><br/>
  Single-host and Master/Slave distributed stress tests (Windows + Linux)
</p>

<p align="center">
  <a href="https://github.com/gitexadelintershipprod/VDbanchUI"><img src="https://img.shields.io/badge/GitHub-VDbanchUI-181717?logo=github" alt="GitHub"></a>
  <a href="Launch-VdbenchUI.bat"><img src="https://img.shields.io/badge/Platform-Windows%20Server%202022-0078D6?logo=windows" alt="Windows"></a>
  <a href="src/VdbenchUI.ps1"><img src="https://img.shields.io/badge/UI-PowerShell%20%2B%20WinForms-5391FE?logo=powershell" alt="PowerShell"></a>
  <a href="install/REQUIRED-FILES.txt"><img src="https://img.shields.io/badge/Install%20kit-scripts%20%2B%20packages-orange" alt="Install kit"></a>
  <a href="docs/en/README.md"><img src="https://img.shields.io/badge/Docs-EN%20%7C%20KA-brightgreen" alt="Docs"></a>
</p>

<p align="center">
  <a href="docs/en/README.md"><b>Documentation</b></a> ·
  <a href="docs/en/README.md">English</a> ·
  <a href="docs/ka/README.md">ქართული</a>
</p>

<p align="center">
  Prepare hosts → pick targets → build a profile → preview the <code>.parm</code> → run → review reports.
</p>

---

## Features

| | |
|---|---|
| **Local or distributed** | Run on one Windows Server, or drive Windows + Linux slaves over SSH from a master. |
| **Target-aware profiles** | Raw/block or filesystem parameters follow what you tick on Local / Slaves. |
| **Preview before damage** | Generated Vdbench config with explicit `RISK` warnings (format, raw disks). |
| **Live run monitor** | Console stream, IOPS / MB/s / latency chart, host summary, Start / Stop. |
| **Portable, no Docker** | Unzip, set paths, launch `Launch-VdbenchUI.bat`. Java/SSH/Vdbench come from the install kit. |

---

## Documentation

Guides are **separate pages** (switch language with the links — both languages are not on one page):

| Language | Guide |
|:---:|:---|
| English | [docs/en/README.md](docs/en/README.md) |
| ქართული | [docs/ka/README.md](docs/ka/README.md) |

Screenshots: [docs/assets/screenshots/](docs/assets/screenshots/)

---

## Install kit (`install/`)

Prepare scripts live in **[`install/`](install/)**. Copy that folder to lab hosts as `C:\install` (Windows) or `/root/install` (Linux).

| Script | Role |
|---|---|
| [`01-Prepare-Vdbench-Master.ps1`](install/01-Prepare-Vdbench-Master.ps1) | Windows **master** |
| [`02-Prepare-Vdbench-Windows-Slave.ps1`](install/02-Prepare-Vdbench-Windows-Slave.ps1) | Windows **slave** |
| [`03-Prepare-Vdbench-Linux-Slave-v4.3.sh`](install/03-Prepare-Vdbench-Linux-Slave-v4.3.sh) | Linux **slave** (RHEL 9) |
| [`04-Check-Vdbench-Hosts-Readiness.ps1`](install/04-Check-Vdbench-Hosts-Readiness.ps1) | Master readiness (UI **Readiness** button) |
| [`REQUIRED-FILES.txt`](install/REQUIRED-FILES.txt) | Full checklist of packages / RPMs you must add |

> **Critical order — SSH key before slave prepare**
>
> 1. Run **`01-Prepare-Vdbench-Master.ps1`** on the master first.  
> 2. It creates `C:\install\ssh\id_rsa`, `id_rsa.pub`, and **`C:\install\master_id_rsa.pub`**.  
> 3. **Copy `master_id_rsa.pub` (and the rest of each slave’s kit) onto every slave** into `C:\install` or `/root/install`.  
> 4. **Only then** run `02-*.ps1` / `03-*.sh` on the slaves.  
>
> Without the master’s public key on the slave, slave prepare fails and the master cannot SSH in.

Binary packages (JDK, OpenSSH MSI, `vdbench50407.zip`, Linux RPMs) are **not** in git — list them in [`install/REQUIRED-FILES.txt`](install/REQUIRED-FILES.txt).

---

## Quick start

1. Fill `C:\install` on the master (scripts from this repo + packages from `REQUIRED-FILES.txt`).
2. Prepare master → **copy SSH public key to slaves** → prepare slaves.
3. On the master UI host:

```bat
Launch-VdbenchUI.bat
```

4. **Settings** → validate paths → **Slaves** or **Local** → **Profile** → **Preview** → **Run** → **Reports**.

Full walkthrough with screenshots: [English](docs/en/README.md) · [ქართული](docs/ka/README.md)

---

## Runtime state

| Path | Content |
|---|---|
| `data/settings.json`, `data/slaves.json` | Mutable app state |
| `profiles/*.json` | Workload profiles |
| `runs/` or Reports root | Vdbench output per run |
| `logs/app.log` | Application log |

---

## Development validation

```bash
python3 tools/validate_offline.py
```

Windows:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Validate-Project.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Verify-Portable.ps1
```

Portable ZIP:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Package-Portable.ps1
```

---

## More

- [Master / Slave model](docs/MASTER_SLAVE_MODEL.md)
- [Project plan](docs/PROJECT_PLAN.md)
- [Tools](tools/README.md)
- [Profiles](profiles/README.md)

The UI does not install or download Oracle Vdbench. Supply `vdbench50407.zip` yourself under a lawful license.
