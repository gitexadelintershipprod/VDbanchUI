# Project Plan

## Goal

Create a portable local Windows application that visualizes and manages Oracle Vdbench
runs on Windows Server 2022 Desktop Experience.

## Scope

- Portable Windows UI; no Docker on the target server.
- Assume Java, SSH, and Vdbench are already installed on the target server.
- Provide a practical control-panel UI similar in spirit to Iometer: target selection,
  workload profile, run control, status, and reports.

## Architecture (refactored)

The application is split into PowerShell modules under `src/modules/`:

| Module | Responsibility |
|--------|----------------|
| `Core.ps1` | JSON I/O, path helpers, logging, module loader |
| `Metrics.ps1` | Vdbench stdout metric parsing (timestamp + legacy formats) |
| `ProcessRunner.ps1` | Process start info, process-tree kill |
| `State.ps1` | Settings, profiles, slaves persistence |
| `UiHelpers.ps1` | Dialog helpers, common controls |
| `TargetDiscovery.ps1` | Local/remote target inventory |
| `UiTabs.ps1` | Windows Forms tab builders |
| `ConfigGeneration.ps1` | Pure Vdbench `.parm` generation and validation |
| `Runner.ps1` | Run lifecycle, charts, metadata |
| `SelfTest.ps1` | Hermetic headless self-test |

Entry point: `src/VdbenchUI.ps1` (dot-sources modules).

## Runtime directories

| Path | Purpose |
|------|---------|
| `data/settings.json` | User settings |
| `data/slaves.json` | Slave inventory |
| `data/runs/*.json` | Run metadata index (not Vdbench output) |
| `runs/` or `ReportsRoot` | Vdbench run output folders (`.parm`, logs, reports) |
| `logs/app.log` | Application log |
| `profiles/*.json` | Saved workload profiles |

## Main Modules (UI tabs)

1. Settings / Paths
2. Local
3. Slaves
4. Profile
5. Preview
6. Run
7. Reports

## Validation

- Linux/CI: `python3 tools/validate_offline.py`
- Windows: `tools/Validate-Project.ps1`, `tools/Verify-Portable.ps1`
- Golden fixtures: `tests/fixtures/*.txt`
- Pester (Windows): `tests/ConfigGeneration.Tests.ps1`

## Initial Implementation Choice

PowerShell + Windows Forms keeps the app portable on Windows Server 2022 Desktop
Experience without requiring a .NET SDK, Node.js, Python, or Docker on the target server.
