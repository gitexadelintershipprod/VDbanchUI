# AGENTS.md

## Cursor Cloud specific instructions

### What this project is
Portable Windows UI (PowerShell + Windows Forms) for managing an existing Oracle Vdbench
installation. The single GUI app is `src/VdbenchUI.ps1`, launched on Windows via
`Launch-VdbenchUI.bat`. See `README.md` for the full workflow.

### Platform reality in Cursor Cloud (Linux)
- The GUI app and all Windows tooling are **Windows-only**. `src/VdbenchUI.ps1` calls
  `Add-Type -AssemblyName System.Windows.Forms` at the top of the file (before the
  `-SelfTest` branch), so even headless self-test cannot run on Linux. Windows PowerShell
  (`powershell.exe`) is not present here, and the helper scripts under `tools/*.ps1`
  (`Validate-Project.ps1`, `Verify-Portable.ps1`, `Invoke-SmokeTest.ps1`,
  `Package-Portable.ps1`) depend on Windows PowerShell, WinForms, CIM, and `ssh.exe`.
  Do not expect these to run in this environment.
- The only runnable dev gate on Linux is the **stdlib-only** offline validator:
  `python3 tools/validate_offline.py`. It validates the JSON contracts
  (`config/parameter-catalog.json`, `config/default-settings.json`), syntax-greps the UI
  source, and renders representative raw, distributed (master/slave), and filesystem
  Vdbench `.parm` configs from the same catalog shape the UI uses.

### Run / test / lint / build (Linux dev scope)
- Run + test (core config generation + contracts): `python3 tools/validate_offline.py`
- Lint: there is no separate Linux linter. PowerShell syntax checking lives inside
  `tools/Validate-Project.ps1` and only runs on Windows.
- Build/package: `tools/Package-Portable.ps1` produces the portable ZIP and is Windows-only.

### Dependencies
- No installable dependencies. The validator uses only the Python 3 standard library;
  Python 3 is preinstalled. There is intentionally **no Docker** for this project (it is a
  portable Windows app) — do not containerize it.
