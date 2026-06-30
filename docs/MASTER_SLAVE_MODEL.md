# Master / Slave Model

The UI separates profile parameters, host/target inventory, and run orchestration.

## Run Mode

- **Run mode** (`Single local run` vs `Master/Slave distributed run`) is selected in the header.
- Local mode uses targets from `data/localhost.json` on the **Local Host** tab.
- Distributed mode uses enabled, ready slaves from `data/slaves.json` on the **Master / Slave** tab.
- Raw vs filesystem test kind is derived from selected targets at run time (mixed targets are blocked).

## Profile

Profiles store workload parameters only. They no longer store `TestKind` or `LocalTargets`.

- The **Profile** tab is create-only: it starts with a blank draft and does not load saved profiles.
- Shared workload fields (`common.xfersize`, `common.threads`, `common.rate`) replace duplicate raw/filesystem entries in the editor.
- Saving a profile writes it to `profiles/` and resets the draft for the next new profile.
- Profile parameters are grouped into **General**, **Raw / SD**, and **Filesystem**.
- The editor is locked until a target is selected on **Local Host** or **Master / Slave**; derived test kind controls whether Raw / SD or Filesystem parameters are shown.
- `storage.threads` is hidden from the editor; use **Workload threads** in General (mapped to `wd=` / `fwd=`).
- Changing target type while the Profile tab is open shows a warning to review parameters.
- Detailed UI diagnostics are written to `logs/debug.log` when `LogLevel` is `DEBUG`.

## Run Tab

The **Run** tab is the profile library and execution orchestrator:

- Select, reload, delete, duplicate, import, export, and open the profiles folder.
- Choose which saved profile to execute and review mode, derived test kind, and selected targets before start.

## Settings

Global settings define the master-side paths and defaults:

- `InstallRoot`
- `VdbenchRoot`
- `ManagerRoot`
- `ReportsRoot`
- `ReadinessChecker`
- `MasterVdbenchBat`
- `WindowsVdbench`
- `LinuxVdbench`
- `SshConfig`
- `PrivateKey`

SSH private keys are managed outside the Master / Slave grid (Settings path reference only).

## Slave Inventory

Each slave entry contains:

- `Enabled` (Use) — only available after `ReadinessStatus = Ready`
- `Name`
- `Host`
- `OsType`
- `VdbenchPath`
- `Targets` (one or more selected raw/file/filesystem targets)
- `SshAlias`
- `ReadinessStatus` — `Pending`, `Checking`, `Ready`, `Failed`, `Error`, `Checker missing`
- `ReadinessCheckedAt` — ISO timestamp of the last readiness check
- `ReadinessOutput` — optional checker output text
- `PingStatus` / `PingCheckedAt` — per-row ICMP diagnostics
- `Notes`

### Per-row workflow

1. Add a host row — readiness starts automatically in the background.
2. When readiness is `Ready`, the **Use** checkbox can be enabled.
3. Click **Browse** on the row to discover disks/filesystems, create folders, and select targets (including test file create/overwrite).
4. **Ping** and **Re-check** are available on each row independently.
5. Save the inventory to persist `slaves.json`.

Remote targets are discovered through SSH using the row's `SshAlias` when present, otherwise `Host`.
Each enabled host must pass readiness and have at least one selected target before a run can start.

## Generated Vdbench Shape

For distributed runs, enabled slaves are rendered into `hd=` entries and their test
targets are rendered into `sd=` or `fsd=` entries depending on the profile type.

Example raw/block shape:

```text
hd=default,shell=ssh
hd=test001,system=10.10.10.11,vdbench=/opt/vdbench
sd=sd_test001_1,host=test001,lun=/dev/sdb,threads=8,openflags=o_direct
wd=wd1,sd=sd*,xfersize=4k,rdpct=70,seekpct=100
rd=rd1,wd=wd1,iorate=max,elapsed=300,interval=1
```

Example filesystem shape:

```text
hd=default,shell=ssh
hd=test001,system=10.10.10.11,vdbench=/opt/vdbench
fsd=fsd_test001_1,host=test001,anchor=/mnt/test,depth=1,width=1,files=100,size=1m
fwd=fwd1,fsd=fsd*,operation=read,xfersize=4k,fileio=random,fileselect=random
rd=rd1,fwd=fwd1,fwdrate=max,elapsed=300,interval=1,format=no
```

Exact command behavior can still be adjusted in the advanced/manual parameter area.
