# Vdbench UI

Portable Windows UI for managing an existing Oracle Vdbench installation.

This project is intentionally isolated from other repositories and does not use Docker.
It is designed for Windows Server 2022 Desktop Experience where Java and Vdbench are
already installed and working.

## Run

On the Windows server, open:

```bat
Launch-VdbenchUI.bat
```

The launcher starts PowerShell in STA mode because Windows Forms and Clipboard actions
need an STA thread.

The application stores mutable state under:

- `data/settings.json`
- `profiles/*.json`
- `runs/*`
- `logs/*`

Settings, profiles, slave inventory, and selected run folders can be exported from the UI.

## Development Validation

On Linux or any machine with Python 3:

```bash
python3 tools/validate_offline.py
```

On the Windows target:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Validate-Project.ps1
```

`Validate-Project.ps1` also runs the main app script in headless `-SelfTest` mode to
verify raw, distributed, and filesystem config generation without opening the UI.

Non-UI smoke test on the Windows target:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Invoke-SmokeTest.ps1
```

All non-UI Windows gates in one command:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Verify-Portable.ps1
```

Direct app self-test:

```powershell
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File .\src\VdbenchUI.ps1 -SelfTest
```

## Portable Package

On Windows:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Package-Portable.ps1
```

The ZIP is written under `dist\` and excludes runtime state such as `data`, `runs`,
`reports`, and `logs`.

## First Workflow

1. Open `Settings / Paths`.
2. Confirm `VdbenchRoot`, `MasterVdbenchBat`, `ReportsRoot`, SSH paths, and readiness checker.
3. Open `Master / Slave`.
4. Add slaves, OS type, Vdbench path, SSH alias, and test target. Use `Pick target`
   to discover local targets or remote slave targets over SSH.
5. Open `Profile Builder`.
6. Create or edit a profile. Use `Pick target` to fill `storage.lun` or
   `fsd.anchor`, and use the `?` buttons for parameter help.
7. Disable optional parameters by clearing the `Enabled` checkbox. Disabled values are preserved and rendered as comments in the generated config.
8. Review `Config Preview`.
9. Use `Run Monitor` -> `Config only` to create a `.parm` and run folder without starting Vdbench.
10. Start the real run from `Run Monitor` -> `Start`.

## Safe Smoke Test

Before running against real disks, you can test the UI flow with the bundled fake runner:

1. Open `Settings / Paths`.
2. Click `Use fake runner`.
3. Save settings.
4. Start a run from `Run Monitor`.

This exercises config generation, process launch, live log streaming, chart parsing, and
report history without touching storage targets. Restore `Master vdbench.bat` to the real
`C:\vdbench\vdbench.bat` before production tests.

## Notes

- The UI does not install Java, SSH, or Vdbench.
- The UI does not download or bundle Oracle Vdbench.
- Raw disk and destructive tests are exposed, but the generated config preview and run log are always visible before execution.
- Raw physical-device targets and filesystem format/root-target cases are flagged as `RISK` warnings and require an extra confirmation before `Start`.
- Profiles and slave inventory can be imported/exported from the UI.
- Target discovery uses Windows CIM locally and SSH for remote slaves. Manual target
  entry remains available when discovery is not appropriate.
- Settings can be imported/exported from `Settings / Paths`.
- Selected reports can be exported as ZIP bundles from `Status / Reports`.
