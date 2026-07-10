# Tools

Run this on the Windows Server 2022 target before the first real benchmark run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Validate-Project.ps1
```

The validator checks:

- PowerShell syntax for `src\VdbenchUI.ps1`
- headless app self-test for config generation
- JSON parsing for config files
- duplicate parameter catalog keys
- required default settings

For development environments without Windows PowerShell, run:

```bash
python3 tools/validate_offline.py
```

The offline validator checks JSON contracts, module layout, golden fixtures, and renders
representative raw, distributed, and filesystem Vdbench configs from the catalog.

## Module layout

Application logic lives under `src/modules/`. The entry script `src/VdbenchUI.ps1` loads
modules in dependency order via `Import-AppModules`.

## Fake Runner (dev / CI only)

`FakeVdbench.ps1` is used by headless self-test and `Invoke-SmokeTest.ps1`. It is **not**
exposed in the Settings UI. Point `Master vdbench.bat` at this file manually only when
you intentionally want a non-destructive process smoke test.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Invoke-SmokeTest.ps1
```

## Packaging

Run `Package-Portable.ps1` on Windows to create a portable ZIP under `dist\`.
The package includes `install/` (prepare scripts + `REQUIRED-FILES.txt`), `docs/`, `src/`, and `tools/`.

Reports tab actions: **Refresh** and **Open folder** (open the selected run directory).

## One-Command Verification

Run all non-UI Windows gates:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Verify-Portable.ps1
```

This runs project validation, the fake-runner smoke test, package creation, and ZIP
content inspection.
