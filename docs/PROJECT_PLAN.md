# Project Plan

## Goal

Create a portable local Windows application that visualizes and manages Oracle Vdbench
runs on Windows Server 2022 Desktop Experience.

## Scope

- Work only inside `/home/koiot/cursor/new-project`.
- Do not use Docker.
- Assume Java, SSH, and Vdbench are already installed on the target server.
- Provide a practical control-panel UI similar in spirit to Iometer: target selection,
  workload profile, run control, status, and reports.

## Main Modules

1. Settings / Paths
   - Vdbench root
   - Master `vdbench.bat`
   - report root
   - readiness checker script
   - SSH config and private key
   - Windows and Linux Vdbench path defaults

2. Master / Slave
   - single local mode or distributed master/slave mode
   - slave inventory
   - per-slave test target mapping
   - readiness and connection checks

3. Profile Builder
   - parameter catalog with help text
   - dropdowns for constrained values
   - numeric/text inputs for free values
   - per-parameter enable/disable control
   - advanced manual lines

4. Config Preview
   - generated Vdbench parameter file
   - disabled parameters rendered as comments
   - warnings for missing paths or targets

5. Run Monitor
   - write `.parm` file
   - run existing Vdbench CLI
   - stream stdout/stderr
   - stop/kill process
   - persist run metadata

6. Reports
   - run history
   - profile/config/log artifacts
   - basic summary extracted from output when available

## Initial Implementation Choice

The first implementation uses PowerShell + Windows Forms. This keeps the app portable on
a clean Windows Server 2022 Desktop Experience installation without requiring a .NET SDK,
Node.js, Python, or Docker on the target server.
