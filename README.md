# Vdbench UI

Portable Windows UI for managing an existing Oracle Vdbench installation
(single host or Master/Slave distributed runs on Windows + Linux).

**Documentation language / დოკუმენტაციის ენა:**

| Language | Guide |
|---|---|
| English | **[User Guide (EN)](docs/en/README.md)** |
| ქართული | **[მომხმარებლის სახელმძღვანელო (KA)](docs/ka/README.md)** |

Each guide is a **separate page** (switch via the links above or the language line at the top of each guide). Screenshots, prerequisites, prepare scripts, and the full tab-by-tab workflow are documented there.

---

## Quick start

1. Prepare the lab with the install kit under `C:\install` (scripts `01`–`04`, JDK, OpenSSH, Vdbench ZIP, Linux RPMs). Details: [EN](docs/en/README.md#2-prerequisites--install-kit) · [KA](docs/ka/README.md#2-წინაპირობები-და-install-ნაკრები).
2. Run prepare scripts on master / Windows slave / Linux slave.
3. On the master UI host open:

```bat
Launch-VdbenchUI.bat
```

4. **Settings** → validate paths → **Slaves** or **Local** → **Profile** → **Preview** → **Run** → **Reports**.

### Prepare scripts (also in repo root)

| Script | Role |
|---|---|
| `01-Prepare-Vdbench-Master.ps1` | Windows master |
| `02-Prepare-Vdbench-Windows-Slave.ps1` | Windows slave |
| `03-Prepare-Vdbench-Linux-Slave-v4.3.sh` | Linux (RHEL 9) slave |
| `04-Check-Vdbench-Hosts-Readiness.ps1` | Master readiness checks (UI **Readiness** button) |

---

## Runtime state

- `data/settings.json`, `data/slaves.json` — mutable app state  
- `data/runs/*.json` — run metadata index  
- `runs/` or configured `ReportsRoot` — Vdbench output per run  
- `logs/app.log` — application log  
- `profiles/*.json` — workload profiles  

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

This project does not use Docker. The UI does not install or download Oracle Vdbench; supply `vdbench50407.zip` yourself.
