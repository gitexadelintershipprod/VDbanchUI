# Vdbench UI — User Guide (English)

<p align="center">
  <a href="./README.md"><b>Documentation</b></a> ·
  <a href="./README.md">English</a> ·
  <a href="../ka/README.md">ქართული</a>
</p>

<p align="center">
  Portable Windows UI for preparing, running, and reviewing Oracle <strong>Vdbench</strong>
  storage stress tests — single host or Master/Slave (Windows + Linux).
</p>

> The UI does **not** install Java, OpenSSH, or Vdbench by itself. First prepare the master and slaves with the [`install/`](../../install/) kit, then launch the UI.

---

## Table of contents

1. [What this product does](#1-what-this-product-does)
2. [Prerequisites & install kit](#2-prerequisites--install-kit)
3. [Prepare Master and Slaves](#3-prepare-master-and-slaves)
4. [Launch the UI](#4-launch-the-ui)
5. [Settings](#5-settings)
6. [Local (single-host run)](#6-local-single-host-run)
7. [Slaves (distributed run)](#7-slaves-distributed-run)
8. [Profile](#8-profile)
9. [Preview](#9-preview)
10. [Run](#10-run)
11. [Reports](#11-reports)
12. [Safe smoke test](#12-safe-smoke-test)
13. [Important safety notes](#13-important-safety-notes)

---

## 1. What this product does

| Capability | Description |
|---|---|
| Local run | Drive Vdbench on the current Windows Server only |
| Distributed run | Master + one or more Windows/Linux slaves over SSH |
| Target pick | Raw disks, filesystems, and test files (Browse / Use) |
| Profiles | Workload parameters (xfersize, rdpct, elapsed, format, …) |
| Preview | Generated `.parm` text with `RISK` warnings before start |
| Run monitor | Live log, chart, host summary, Start / Stop |
| Reports | History of completed and abandoned runs |

Typical hosts in a lab:

- **Master / UI host:** Windows Server 2022 Desktop Experience  
- **Windows slave:** Windows Server with OpenSSH + Java + Vdbench  
- **Linux slave:** RHEL 9 (or compatible) with SSH + Java + Vdbench  

---

## 2. Prerequisites & install kit

Prepare scripts ship in the repo under **[`install/`](../../install/)**. On each lab host, copy that folder to:

| Host | Staging path |
|---|---|
| Windows master / Windows slave | `C:\install` |
| Linux slave | `/root/install` |

The UI’s **Install root (reference)** field points at `C:\install` on the master. Full package checklist: [`install/REQUIRED-FILES.txt`](../../install/REQUIRED-FILES.txt).

### 2.1 Root of `C:\install` (required files)

| File / folder | Required for | Purpose |
|---|---|---|
| `01-Prepare-Vdbench-Master.ps1` | Master | Installs Java, OpenSSH, Vdbench, SSH key on the master |
| `02-Prepare-Vdbench-Windows-Slave.ps1` | Windows slave | Same on a Windows slave + trusts master’s public key |
| `03-Prepare-Vdbench-Linux-Slave-v4.3.sh` | Linux slave | Offline-friendly RHEL 9 slave prepare |
| `04-Check-Vdbench-Hosts-Readiness.ps1` | Master (UI) | Used by the **Readiness** button (separate PowerShell window) |
| `REQUIRED-FILES.txt` | All | Checklist of binaries you must add (not in git) |
| `vdbench-50407.pdf` | Optional | Oracle Vdbench 5.04.07 user guide (reference only) |
| `microsoft-jdk-11.0.31-windows-x64.exe` | Master + Win slave | Microsoft JDK 11 (preferred) |
| `OpenSSH-Win64-v10.0.0.0.msi` | Master + Win slave | OpenSSH Client + Server |
| `vdbench50407.zip` | Master + all slaves | Oracle Vdbench archive (extract under `C:\vdbench` / `/opt/vdbench`) |
| `java-11-openjdk-headless-11.0.25.0.9-7.el9.x86_64.rpm` | Linux slave | Headless OpenJDK 11 for RHEL 9 |
| `unzip-6.0-60.el9.x86_64.rpm` | Linux slave | Unzip for the Vdbench ZIP on Linux |
| `rpms\` | Linux slave | Extra EL9 RPMs Java/NSS/Lua depend on (offline) |
| `ssh\` | Master (created by `01`) | Private/public key (`id_rsa`) used by the UI and Vdbench |
| `master_id_rsa.pub` | **Every slave** (copied from master) | Master public key — **required before** running `02` / `03` |
| `files\` | Optional | Extra staging files for prepare scripts |

Scripts come from this repository’s [`install/`](../../install/) folder. Binary packages are **not** in git — add them yourself per `REQUIRED-FILES.txt`.

### 2.2 `C:\install\rpms` (Linux offline dependencies)

Copy the whole `rpms` folder to the Linux slave staging area (`/root/install/rpms`). Typical contents:

| RPM | Why it is needed |
|---|---|
| `alsa-lib-*.rpm` | Java runtime dependency |
| `cups-libs-*.rpm` | Java runtime dependency |
| `copy-jdk-configs-*.rpm`, `javapackages-filesystem-*.rpm` | JDK packaging glue |
| `lksctp-tools-*.rpm` | Java networking (SCTP) support |
| `nspr-*.rpm`, `nss-*.rpm`, `nss-softokn-*.rpm`, `nss-softokn-freebl-*.rpm`, `nss-sysinit-*.rpm`, `nss-util-*.rpm` | NSS crypto stack for OpenJDK |
| `lua-*.rpm`, `lua-libs-*.rpm`, `lua-posix-*.rpm`, `compat-lua-*.rpm`, `compat-lua-libs-*.rpm` | Packaging / script tooling used during install |

Without these offline RPMs, Linux prepare will fail on air-gapped hosts (`OFFLINE_ONLY=1` is the default).

### 2.3 Who needs what (checklist)

| Role | OS | Must have before UI run |
|---|---|---|
| Master | Windows Server 2022 | JDK 11, OpenSSH Client+Server, Vdbench under `C:\vdbench`, private key in `C:\install\ssh`, readiness script |
| Windows slave | Windows Server | JDK 11, OpenSSH Server, Vdbench under `C:\vdbench`, master’s **public** key in `administrators_authorized_keys` |
| Linux slave | RHEL 9 | OpenJDK 11 (+ deps), `sshd`, Vdbench under `/opt/vdbench`, master’s public key in `/root/.ssh/authorized_keys` |

---

## 3. Prepare Master and Slaves

Run prepare scripts **as Administrator** (Windows) or **root** (Linux). Lab defaults often disable firewall/UAC/SELinux unless you pass keep-enabled flags — use only in isolated stress labs.

### Required order (do not skip)

```text
1) Prepare MASTER with 01-*.ps1
2) Copy SSH public key (+ slave packages) to every slave
3) Prepare each SLAVE with 02-*.ps1 / 03-*.sh
4) Use 04-*.ps1 / UI Readiness to verify
```

> ### Critical: copy SSH files from master → slaves **before** slave prepare
>
> After `01-Prepare-Vdbench-Master.ps1` finishes, the master has:
>
> | Path on master | What it is |
> |---|---|
> | `C:\install\ssh\id_rsa` | Private key (stays on master; UI / Vdbench use it) |
> | `C:\install\ssh\id_rsa.pub` | Public key |
> | `C:\install\master_id_rsa.pub` | **Export for slaves** (same public key — copy this file) |
>
> **Copy `master_id_rsa.pub` onto every slave** into their install folder:
>
> - Windows slave → `C:\install\master_id_rsa.pub`
> - Linux slave → `/root/install/master_id_rsa.pub`
>
> Only **after** that file is present, run `02-Prepare-Vdbench-Windows-Slave.ps1` or `03-Prepare-Vdbench-Linux-Slave-v4.3.sh`.  
> If you run slave prepare first, it fails looking for the master’s public key, and the master will not be able to SSH to that host.

### 3.1 Master (`01-Prepare-Vdbench-Master.ps1`)

On the Windows master, with the install kit under `C:\install`:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
C:\install\01-Prepare-Vdbench-Master.ps1
```

What it does (summary):

- Installs Microsoft JDK 11 and sets `JAVA_HOME` / PATH  
- Installs OpenSSH Client + Server  
- Creates a passphrase-less SSH key (under `C:\install\ssh`) and hardens ACL on the private key  
- Writes `C:\install\master_id_rsa.pub` for distribution to slaves  
- Extracts Vdbench to `C:\vdbench` and fixes the Windows `vdbench.bat` classpath quirk  
- Prepares distributed templates  

Useful switches: `-RecreateSshKey`, `-ForceJavaInstall`, `-KeepFirewallEnabled`, `-KeepUACEnabled`.

### 3.2 Copy SSH key to slaves (mandatory step)

From the master, after step 3.1 succeeds, copy the public key (USB, share, or `scp` once you have another temporary login):

```text
Master:  C:\install\master_id_rsa.pub
   │
   ├──► Windows slave:  C:\install\master_id_rsa.pub
   └──► Linux slave:    /root/install/master_id_rsa.pub
```

Also copy the rest of that slave’s kit (JDK/OpenSSH/ZIP or Linux RPMs) listed in `REQUIRED-FILES.txt`. **Do not** copy the master’s **private** key (`id_rsa`) to slaves.

### 3.3 Windows slave (`02-Prepare-Vdbench-Windows-Slave.ps1`)

Only after `master_id_rsa.pub` is in the slave’s `C:\install`:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
C:\install\02-Prepare-Vdbench-Windows-Slave.ps1
```

Expects (among others):

- `microsoft-jdk-*-windows-x64.exe` (or `.msi`)  
- `OpenSSH-Win64-*.msi`  
- `vdbench*.zip`  
- **`master_id_rsa.pub`** (copied from master — see §3.2)  

After reboot, from the master:

```text
ssh Administrator@<SLAVE_IP> hostname
ssh Administrator@<SLAVE_IP> java --version
ssh Administrator@<SLAVE_IP> C:\vdbench\vdbench.bat -t
```

### 3.4 Linux slave (`03-Prepare-Vdbench-Linux-Slave-v4.3.sh`)

Stage files under `/root/install` (script + `vdbench*.zip` + **`master_id_rsa.pub`** + RPMs / `rpms/`), then:

```bash
cd /root/install
chmod +x ./03-Prepare-Vdbench-Linux-Slave-v4.3.sh
./03-Prepare-Vdbench-Linux-Slave-v4.3.sh
```

Default is **offline**. Online fallback:

```bash
OFFLINE_ONLY=0 ./03-Prepare-Vdbench-Linux-Slave-v4.3.sh
```

Resulting layout: assets under `/opt/install`, Vdbench under `/opt/vdbench`.

### 3.5 Readiness checker (`04-Check-Vdbench-Hosts-Readiness.ps1`)

Runs on the **master**. CLI example:

```powershell
C:\install\04-Check-Vdbench-Hosts-Readiness.ps1 -WindowsHosts 10.50.11.153 -LinuxHosts 10.50.11.174
```

In the UI, set **Readiness checker** to this script and **Readiness args template** to `{HostFlag}` so each row’s **Readiness** button checks that row’s Host/IP.

---

## 4. Launch the UI

On the master, from the portable app (or repo) folder:

```bat
Launch-VdbenchUI.bat
```

This starts PowerShell in **STA** mode (required for Windows Forms).

Mutable runtime state:

| Path | Content |
|---|---|
| `data/settings.json` | Paths and UI preferences |
| `data/slaves.json` | Slave inventory |
| `profiles/*.json` | Saved workload profiles |
| `runs/` or Reports root | Vdbench output folders |
| `logs/app.log` | Application log |

---

## 5. Settings

![Settings tab](../assets/screenshots/01-settings.png)

Configure paths **before** first distributed run. Typical values:

| Field | Example | Notes |
|---|---|---|
| Vdbench root | `C:\vdbench` | Master install |
| Reports root | `C:\vdbench\manager\reports` | Run output |
| Readiness checker | `C:\install\04-Check-Vdbench-Hosts-Readiness.ps1` | Opens its own window |
| Master vdbench.bat | `C:\vdbench\vdbench.bat` | Must exist (`Exists=True`) |
| Windows / Linux Vdbench path | `C:\vdbench` / `/opt/vdbench` | Defaults for new slaves |
| SSH config / Private key | user `.ssh\config` + `C:\install\ssh\id_rsa` | Auth for browse/clean/readiness |
| Readiness args template | `{HostFlag}` | Required for the shipped checker |

Click **Validate paths** and confirm every critical path reports **Exists=True** (as in the screenshot).

**Save settings** after edits.

---

## 6. Local (single-host run)

![Local tab](../assets/screenshots/02-local.png)

1. Set **Run mode** to **Single local run**.  
2. Open **Local**.  
3. **Refresh disks** / **Browse** to discover raw disks, filesystems, and test files.  
4. Tick **Use** on the targets you intend to stress.  
5. For a test file, optionally enable **Create/overwrite file**.  

Raw physical disks and filesystem format are destructive — always review **Preview** before **Start**.

---

## 7. Slaves (distributed run)

![Slaves tab](../assets/screenshots/03-slaves.png)

1. Set **Run mode** to **Master/Slave distributed run**.  
2. **Add slave** — enter a real **Host / IP** (not only a display name).  
3. Set **OS**, **User** (`administrator` / `root`), and **VdbenchPath**.  
4. Click **Ping**, then **Readiness** (separate PowerShell window; wait for Enter).  
5. When status is **Ready**, enable **Use**.  
6. **Browse** — discover disks/filesystems, create folders if needed, tick **Use** on anchors (e.g. `D:\fs_test`, `/stresstest`).  
7. **Clean** — deletes **contents** of selected filesystem anchors (not raw disks). Needs selected filesystem targets.  
8. **Save** the inventory.

Mixed raw + filesystem selections across the run are blocked; all selected targets must share one test kind.

---

## 8. Profile

![Profile tab](../assets/screenshots/04-profile.png)

Profiles store **workload parameters only** (not host inventory).

1. Select targets on **Local** or **Slaves** first (this derives **Filesystem** vs **Raw/block**).  
2. Open **Profile** → **New**, set a name (e.g. `Test-001`).  
3. Edit General / FSD / FWD / FS Run (filesystem) or SD / WD (raw).  
4. Use **?** for bilingual parameter help.  
5. Uncheck **On** to leave a parameter out of the active config (value kept; can render as a comment).  
6. **Save profile**.

Examples: elapsed, warmup, interval, format, create_anchors, rdpct, xfersize, threads. Filesystem `fwdrate` is fixed at `max` in this UI.

---

## 9. Preview

![Preview tab](../assets/screenshots/05-preview.png)

Shows the generated Vdbench `.parm`:

- `hd=` master/slave definitions (`system=`, `user=`, `vdbench=`)  
- `fsd=` / `sd=` storage or filesystem definitions  
- `fwd=` / `wd=` workloads  
- `rd=` run definition  

Red **RISK** lines (e.g. `format=yes`) mean data on the anchor can be rewritten. Use **Refresh** / **Copy config** as needed.

---

## 10. Run

![Run tab](../assets/screenshots/06-run.png)

1. Choose the saved **Run profile**.  
2. Confirm **Run Setup** (mode, test kind, selected targets).  
3. Optionally use **Config only** (if available in your build) to write a run folder without starting Vdbench.  
4. Click **Start**. Monitor console, chart (IOPS / MB/s / latency), and host summary.  
5. Use **Stop/Kill** if you must abort.  

When finished, reports land under the configured Reports root (e.g. `C:\vdbench\manager\reports\20260709-170937`).

---

## 11. Reports

![Reports tab](../assets/screenshots/07-reports.png)

History of runs: Id, StartedAt, Status (`Completed` / `Abandoned`), ExitCode, Profile, Mode, TestKind, RunDir.

- **Refresh** — reload the list  
- **Open folder** — open the selected run directory in Explorer  

---

## 12. Safe smoke test

Before stressing real disks:

1. On **Run**, use **Config only** to write a `.parm` and run folder without starting Vdbench.  
2. Confirm the run folder appears under Reports root.  
3. For a short real run, use a dedicated empty filesystem anchor (never production volumes).  
4. Review **Preview** for `RISK` warnings before **Start**.  

---

## 13. Important safety notes

- Vdbench can destroy data on raw devices and formatted filesystem anchors.  
- Prefer dedicated stress disks / empty anchors (`D:\fs_test`, `/stresstest`), never production volumes.  
- **Clean** removes filesystem **contents** only; still irreversible for that data.  
- SSH destinations use each slave’s **Host / IP** (and User). Display **Name** is cosmetic.  
- The UI never downloads Oracle Vdbench; you must supply `vdbench50407.zip` lawfully.

---

## More technical detail

- [Master / Slave model](../MASTER_SLAVE_MODEL.md)  
- [Project plan / architecture](../PROJECT_PLAN.md)  
- Back to [repository README](../../README.md)
