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
- `ReadinessStatus` — `Not checked`, `Checking...`, `Ready`, `Failed`, `Error`, `Checker missing` (legacy `Pending` may still appear from older inventories)
- `ReadinessCheckedAt` — ISO timestamp of the last readiness check
- `ReadinessOutput` — optional checker output text
- `PingStatus` / `PingCheckedAt` — per-row ICMP diagnostics
- `Notes`

### Per-row workflow

1. Click **Add slave** and enter **Host / IP**, optional name, and OS.
2. Click **Readiness** on the row to verify the host (opens a PowerShell window for the checker script).
3. When readiness is `Ready`, the **Use** checkbox can be enabled.
4. Click **Browse** on the row to discover disks/filesystems, create folders, and select targets (including test file create/overwrite).
5. **Ping** is available on each row independently.
6. Save the inventory to persist `slaves.json`.

Remote targets are discovered through SSH using the row's `SshAlias` when present, otherwise `Host`.
Each enabled host must pass readiness and have at least one selected target before a run can start.

### Readiness checker script contract

`Settings → Readiness checker` points at an external `.ps1` script (not part of this
repo) that the UI launches in its own PowerShell window whenever **Readiness** is
clicked. Two settings govern this launch:

- **Readiness checker** — absolute path to the script.
- **Readiness args template** — optional `{Host}` / `{VdbenchPath}` / `{Target}`
  substitutions appended as `-HostName ... -VdbenchPath ... -Target ...`.

**The shipped default for "Readiness args template" is empty.** Most real checker
scripts (including the common `NN-Check-*-Readiness.ps1` provisioning style) test
every configured host — master and all slaves — in a single run and take no
parameters at all. If such a script also uses `[CmdletBinding()]` (very common),
passing it an unrecognized named parameter like `-HostName` makes PowerShell throw:

```
A parameter cannot be found that matches parameter name 'HostName'.
```

This is what "Readiness ჩეკი" doing nothing / throwing a confusing error from the UI
usually means: the app was passing arguments the checker script doesn't declare.
Only fill in "Readiness args template" if your specific checker script explicitly
declares matching parameters (e.g. its own `param([string]$HostName, ...)` block).

The checker process's working directory is always set to the folder containing the
checker script itself — the same as double-clicking / "Run with PowerShell" on it
from Explorer. This matters because a checker script that references any relative
path (e.g. writing its own log or a scratch folder) will otherwise inherit whatever
directory the UI app happened to be launched from, which can silently create files
outside the real Vdbench install (for example, a stray `vdbench` folder next to the
checker script instead of inside the actual `C:\vdbench`).

On upgrade, a machine with an already-initialized `data/settings.json` that still
has the old default template gets it automatically cleared to empty (see
`Migrate-LegacySettings` in `State.ps1`); a deliberately customized template is left
untouched.

#### Why the checker window is now a genuinely separate window

The checker process used to be started with `UseShellExecute=$false` and
`CreateNoWindow=$false`. That exact combination does **not** create a new console -
per Win32 `CreateProcess` semantics (see Microsoft's own `ProcessStartInfo.CreateNoWindow`
docs/blog post on this precise gotcha), it only avoids *suppressing* a console; the
child silently shares/inherits whatever console (if any) the UI's own host process is
already attached to. When the UI is launched from a `.bat`/console shortcut, that meant
the checker's output never opened a visibly separate window - it echoed into the
pre-existing, possibly hidden console the whole app was started from - and, worse,
closing that shared console sends a close signal to every process attached to it,
including the UI itself, which is what could make the app appear to need a forced
shutdown after an error. `Get-SlaveReadinessResult` now sets `UseShellExecute=$true`
for this launch, which Windows always honors as "open a brand-new window" regardless of
`CreateNoWindow`, fully decoupling the checker's console from the app's own. It is now
safe to close the checker window at any time without affecting the main UI.

Clicking **Readiness** (or **Ping**) again on a row while a check is already running for
it (cell reads `Checking...` / `Pinging...`) is now ignored instead of queuing another
background job. This also stops a duplicate "ran in a separate window" popup from
appearing per click - the checker window already showed the real output live, so once
it ran in its own window the app no longer pops a second confirmation dialog on top of
it. Previously, clicking Readiness repeatedly (a natural reaction when nothing seemed to
happen right away) queued one background job - and one popup - per click; when they all
completed together, the resulting wall of stacked dialogs looked and felt like the whole
UI had frozen.

#### A `[FAIL]` line in the checker's own output is not a UI bug

Every `[OK]` / `[FAIL]` line the checker prints - including things like
`Master vdbench.bat exists` - comes entirely from the external checker script itself; the
UI only launches it and reports its exit code. A `[FAIL]` there means the checker's own
file-existence check genuinely did not find that file on the target machine at the
moment it ran - the UI has no way to influence or fabricate that result, and silently
hiding it would defeat the whole point of a readiness check.

The most common real-world reason `vdbench.bat` is reported missing at the expected path
(e.g. `C:\vdbench\vdbench.bat`) is that the official Vdbench distribution zip extracts
into its own version-named subfolder (e.g. `C:\vdbench\vdbench50407\vdbench.bat`) rather
than flattening `vdbench.bat` straight into the folder you expect. Either move the
extracted contents up one level, or point **Settings → Master vdbench.bat** at wherever
the file actually lives.

To check the same path independently of the external checker, use **Settings →
Validate**: it runs a local, instant `Test-Path` against `Master vdbench.bat` (and the
other configured paths) and reports `Exists=True/False` directly - no external script, no
extra window, no SSH involved. If Validate also reports `False`, the file really is
missing/misplaced on this machine. If Validate reports `True` while the external checker
still fails, the checker script has its own separate, hardcoded expectation for that
path (it takes no parameters by design - see above) that does not read this app's
Settings at all; treat the checker's message as authoritative for the actual host layout
and update Settings to match it, not the other way around.

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
