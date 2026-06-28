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

The offline validator checks JSON contracts and renders representative raw,
distributed, and filesystem Vdbench configs from the catalog.

## Fake Runner

`FakeVdbench.ps1` is a safe runner for UI smoke testing. Point `Master vdbench.bat` to
this file to test process launch, charts, logs, and reports without touching disks.

Run the non-UI smoke test on Windows:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Invoke-SmokeTest.ps1
```

It validates the project, runs the fake runner, checks stdout, and writes artifacts under
`data\smoke\`.

## Packaging

Run `Package-Portable.ps1` on Windows to create a portable ZIP under `dist\`.

The UI itself can also export selected run folders as ZIP bundles from `Status / Reports`.

## One-Command Verification

Run all non-UI Windows gates:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Verify-Portable.ps1
```

This runs project validation, the fake-runner smoke test, package creation, and ZIP
content inspection.
