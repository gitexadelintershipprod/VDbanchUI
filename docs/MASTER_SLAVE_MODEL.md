# Master / Slave Model

The UI treats distributed Vdbench execution as first-class state.

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

## Slave Inventory

Each slave entry contains:

- `Enabled`
- `Name`
- `Host`
- `OsType`
- `VdbenchPath`
- `TestTarget`
- `SshAlias`
- `PrivateKey`
- `Status`
- `Notes`

The `Pick target` action can populate `TestTarget` from discovered targets. Local
targets are discovered through Windows CIM. Remote slave targets are discovered through
SSH using the row's `SshAlias` when present, otherwise `Host`.

## Generated Vdbench Shape

For distributed runs, enabled slaves are rendered into `hd=` entries and their test
targets are rendered into `sd=` or `fsd=` entries depending on the profile type.

Example raw/block shape:

```text
hd=default,shell=ssh
hd=test001,system=10.10.10.11,vdbench=/opt/vdbench
sd=sd_test001,host=test001,lun=/dev/sdb,threads=8,openflags=o_direct
wd=wd1,sd=sd*,xfersize=4k,rdpct=70,seekpct=100
rd=rd1,wd=wd1,iorate=max,elapsed=300,interval=1
```

Example filesystem shape:

```text
hd=default,shell=ssh
hd=test001,system=10.10.10.11,vdbench=/opt/vdbench
fsd=fsd_test001,host=test001,anchor=/mnt/test,depth=1,width=1,files=100,size=1m
fwd=fwd1,fsd=fsd*,operation=read,xfersize=4k,fileio=random,fileselect=random
rd=rd1,fwd=fwd1,fwdrate=max,elapsed=300,interval=1,format=no
```

Exact command behavior can still be adjusted in the advanced/manual parameter area.
