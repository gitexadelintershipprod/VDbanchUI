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
- **Readiness args template** — free-form text appended verbatim to the checker
  invocation, after substituting any of these tokens it contains:
  - `{HostFlag}` — the checker's real parameter for "which remote host to check":
    `-WindowsHosts "<Host>"` if this row's **OS** is Windows, `-LinuxHosts "<Host>"`
    if it is Linux. **This is the shipped default** (`{HostFlag}` alone) and matches
    the actual contract of the checker this app ships pointing at
    (`04-Check-Vdbench-Hosts-Readiness.ps1`), confirmed by running it manually:
    ```
    powershell -ExecutionPolicy Bypass -File C:\install\04-Check-Vdbench-Hosts-Readiness.ps1 -WindowsHosts 10.50.11.xxx
    powershell -ExecutionPolicy Bypass -File C:\install\04-Check-Vdbench-Hosts-Readiness.ps1 -LinuxHosts 10.50.11.xxx
    ```
  - `{Host}` / `{VdbenchPath}` / `{Target}` — raw substitutions of this row's Host,
    VdbenchPath, and selected/default Target, for a *different* checker script that
    declares its own differently-named parameters (e.g. a custom
    `param([string]$HostName, ...)` block). Not needed for the shipped checker.

**Earlier revisions of this doc said the shipped default should be empty** ("most
checker scripts take no arguments"). That was wrong for this specific checker: with
no host argument at all, it silently only checks the Master's own local
prerequisites (ssh.exe, keys, `vdbench.bat`, java — the `[OK]`/`[FAIL]` lines under
"Checking Master readiness") and never actually validates the specific slave a user
clicked **Readiness** for — clicking Readiness on any slave row looked like it "did
something" (a window opened, checks ran) while never checking that slave at all.
`{HostFlag}` fixes this by passing the clicked row's own Host/OS dynamically, so
each row's Readiness click genuinely checks that row's host over SSH, in addition to
the Master's own local checks that always run regardless of arguments.

If your checker script uses `[CmdletBinding()]` (very common) and does not declare
whatever parameter your template references, PowerShell throws a hard error at the
top instead of running any checks at all:

```
A parameter cannot be found that matches parameter name 'HostName'.
```

This is what "Readiness ჩეკი" doing nothing / throwing a confusing error from the UI
usually means: the app was passing arguments the checker script doesn't declare. If
you are using a different checker script than the shipped default, clear the
template back to blank (or use `{Host}`/`{VdbenchPath}`/`{Target}` only if it
declares matching parameters) rather than leaving `{HostFlag}` in place.

The checker process's working directory is always set to the folder containing the
checker script itself — the same as double-clicking / "Run with PowerShell" on it
from Explorer. This matters because a checker script that references any relative
path (e.g. writing its own log or a scratch folder) will otherwise inherit whatever
directory the UI app happened to be launched from, which can silently create files
outside the real Vdbench install (for example, a stray `vdbench` folder next to the
checker script instead of inside the actual `C:\vdbench`).

On upgrade, a machine with an already-initialized `data/settings.json` that still
has an old default template (the original named-params version, or the empty
version that briefly replaced it) gets it automatically advanced to the current
`{HostFlag}` default (see `Migrate-LegacySettings` in `State.ps1`) — but only while
**Readiness checker** still points at the stock shipped script; a deliberately
customized template, or one for a different checker script, is always left
untouched.

#### Why the checker window is now a genuinely separate window that never auto-closes

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

The window also used to close **itself** automatically as soon as the checker process
exited, as long as its exit code was `0` - on the (wrong) assumption that exit code `0`
meant "nothing worth reviewing happened". That is not true for the shipped checker: it
exits `0` unconditionally regardless of whether its own internal `[OK]`/`[FAIL]` checks
passed - exit code `0` there means "the script itself ran to completion", not "every
check inside it passed". A run with one or more failing internal checks (e.g. a `[FAIL]`
on `Master vdbench.bat exists`) still auto-closed the window before there was any chance
to read which check had failed. The window launched by **Readiness** now always pauses
with a `Review the output above, then press Enter to close this window...` prompt before
exiting, regardless of the checker's exit code - it never closes on its own; the human
always has to dismiss it.

Clicking **Readiness** (or **Ping**) again on a row while a check is already running for
it (cell reads `Checking...` / `Pinging...`) is ignored instead of queuing another
background job. The app also no longer shows its own "it ran" confirmation popup at all
for a completed separate-window check (success or failure) - the checker's own window is
already the single source of truth for that result, and now that it always stays open
until dismissed (see above), a second, app-level popup on top of it added nothing.
Previously, clicking Readiness repeatedly (a natural reaction when nothing seemed to
happen right away) queued one background job - and one popup - per click; when they all
completed together, the resulting wall of stacked dialogs looked and felt like the whole
UI had frozen.

#### A `[FAIL]` line in the checker's own output is not a UI bug - troubleshooting steps

Every `[OK]` / `[FAIL]` line the checker prints - including things like
`Master vdbench.bat exists` - comes entirely from the external checker script itself; the
UI only launches it (now with `{HostFlag}` - see above) and reports its exit code. A
`[FAIL]` there means the checker's own check genuinely did not pass at the moment it ran
- the UI has no way to influence or fabricate that result, and silently hiding it would
defeat the whole point of a readiness check. The `Master ...` checks specifically
(ssh.exe, keys, `vdbench.bat`, java) run against the Master itself - the machine running
the checker - and are independent of `-WindowsHosts`/`-LinuxHosts`, which control which
*additional*, remote host gets checked over SSH; passing the right host flag makes the
checker also validate the specific slave a row's Readiness button was clicked for, but
does not change whether the Master's own local checks pass or fail.

If `Master vdbench.bat exists` fails and the file visibly exists at the exact path the
checker printed (it prints the full path it checked right under the `[FAIL]` line), work
through these steps in order rather than guessing blindly - each one narrows down where
the discrepancy actually is:

1. **Cross-check with this app's own, independent Test-Path.** Use **Settings →
   Validate**: it runs a local, instant `Test-Path` against `Master vdbench.bat` (and the
   other configured paths) and reports `Exists=True/False` directly - no external
   script, no extra window, no SSH, no remoting involved. This isolates "is the path in
   Settings even correct" from "why does the external checker disagree with it".
   - If Validate also reports `False`: the path configured in **Settings → Master
     vdbench.bat** does not match the real file. The most common real-world cause is the
     official Vdbench distribution zip extracting into its own version-named subfolder
     (e.g. `C:\vdbench\vdbench50407\vdbench.bat`) rather than flattening `vdbench.bat`
     straight into the folder you expect - move the extracted contents up one level, or
     point Settings at wherever the file actually lives.
   - If Validate reports `True`: the path/file are genuinely fine from this app's point
     of view, and the checker's own logic for this specific check needs to be inspected
     directly - continue to step 2.
2. **Run the exact same path check yourself, independently of both this app and the
   checker**, in any PowerShell window on the Master:
   ```powershell
   Test-Path "C:\vdbench\vdbench.bat"
   Get-Item "C:\vdbench\vdbench.bat" | Format-List FullName, Length, LastWriteTime, Attributes, PSIsContainer
   ```
   If `Test-Path` itself says `False` here, the file is not where it visibly appears to
   be (e.g. a different drive, a cloud-sync placeholder that has not fully downloaded, a
   permissions issue) independent of this app entirely. If it says `True` and the
   `Attributes`/`Length` look normal, the file is fully real and readable, and the
   discrepancy is specific to whatever the checker script itself does for this check.
3. **Inspect what the checker script's own code actually does for this specific check**
   - since it is an external script not part of this repo, its exact logic is opaque to
   this app and to anyone without reading it:
   ```powershell
   Select-String -Path "C:\install\04-Check-Vdbench-Hosts-Readiness.ps1" -Pattern "vdbench.bat" -Context 3,3
   ```
   This reveals whether the check is a plain `Test-Path` (should behave identically to
   step 2), something remote (e.g. `Invoke-Command`/WinRM/UNC path against the Master's
   own hostname, which can fail for reasons - WinRM not enabled, `TrustedHosts`,
   firewall, DNS - entirely unrelated to whether the local file exists), or something
   stricter than existence (e.g. a version/content/hash check). Whatever step 3 reveals
   determines the real fix: if it is a hardcoded path that does not match this Settings'
   value, either move the file to match the checker's expectation or edit the checker
   script (outside this repo); if it is a remoting-based check, the fix is on the
   WinRM/network side, not in Settings.

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
