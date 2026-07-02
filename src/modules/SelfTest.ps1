function Assert-SelfTestContainsAll {
    param(
        [string]$Text,
        [string[]]$ExpectedParts,
        [string]$Name
    )
    foreach ($part in $ExpectedParts) {
        if ($Text -notlike ("*" + $part + "*")) {
            throw ("Self-test failed: {0}. Missing: {1}" -f $Name, $part)
        }
    }
}

function Assert-SelfTestContains {
    param(
        [string]$Text,
        [string]$Expected,
        [string]$Name
    )
    if ($Text -notlike ("*" + $Expected + "*")) {
        throw ("Self-test failed: {0}. Missing: {1}" -f $Name, $Expected)
    }
}

function Assert-SelfTestEquals {
    param(
        [object]$Actual,
        [object]$Expected,
        [string]$Name
    )
    if ([string]$Actual -ne [string]$Expected) {
        throw ("Self-test failed: {0}. Expected '{1}', got '{2}'." -f $Name, $Expected, $Actual)
    }
}

function Save-SelfTestPaths {
    return @{
        DataRoot = $script:DataRoot
        ProfileRoot = $script:ProfileRoot
        RunStateRoot = $script:RunStateRoot
        LogRoot = $script:LogRoot
        SettingsPath = $script:SettingsPath
        SlavesPath = $script:SlavesPath
        LocalHostTargetsPath = $script:LocalHostTargetsPath
        AppRoot = $script:AppRoot
    }
}

function Use-SelfTestPaths {
    param([string]$TempRoot)
    $script:DataRoot = Join-Path $TempRoot "data"
    $script:ProfileRoot = Join-Path $TempRoot "profiles"
    $script:RunStateRoot = Join-Path $script:DataRoot "runs"
    $script:LogRoot = Join-Path $TempRoot "logs"
    $script:SettingsPath = Join-Path $script:DataRoot "settings.json"
    $script:SlavesPath = Join-Path $script:DataRoot "slaves.json"
    $script:LocalHostTargetsPath = Join-Path $script:DataRoot "localhost.json"
}

function Restore-SelfTestPaths {
    param([hashtable]$Saved)
    foreach ($key in $Saved.Keys) {
        Set-Variable -Name ("script:{0}" -f $key) -Value $Saved[$key] -Scope Script
    }
}

function Invoke-AppSelfTest {
    $savedPaths = Save-SelfTestPaths
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("VdbenchUI-SelfTest-" + [guid]::NewGuid().ToString("N"))
    try {
        Use-SelfTestPaths $tempRoot
        Initialize-AppState

        Set-PropertyValue $script:Settings "MasterVdbenchBat" (Join-Path $script:AppRoot "tools\FakeVdbench.ps1")
        Set-PropertyValue $script:Settings "RunMode" "Single local run"

        $script:CurrentProfile = New-DefaultProfile "SelfTest-Raw"
        $script:RunProfile = $script:CurrentProfile
        $script:LocalHostTargets = @((New-TargetSelection -Kind "Test file" -Target "C:\vdbench\testfile.dat" -Selected $true))
        Set-ProfileParamValue $script:CurrentProfile "storage.dedupratio" "2"
        Set-ProfileParamEnabled $script:CurrentProfile "storage.dedupratio" $false
        $raw = Build-VdbenchConfig
        Assert-SelfTestContains $raw.Text "sd=sd1,lun=C:\vdbench\testfile.dat" "raw storage line"
        Assert-SelfTestContainsAll $raw.Text @(
            "wd=wd1,sd=sd1",
            "xfersize=4k",
            "rdpct=70",
            "seekpct=100"
        ) "raw workload line"
        Assert-SelfTestContainsAll $raw.Text @(
            "rd=rd1,wd=wd1",
            "elapsed=300",
            "warmup=30",
            "interval=1",
            "iorate=max"
        ) "raw run line"
        Assert-SelfTestContains $raw.Text "* disabled: dedupratio=2" "disabled parameter rendering"

        $script:LocalHostTargets = @((New-TargetSelection -Kind "Raw disk" -Target "\\.\PhysicalDrive1" -Selected $true))
        $rawRisk = Build-VdbenchConfig
        Assert-SelfTestContains (($rawRisk.Warnings -join "`n")) "RISK: local target '\\.\PhysicalDrive1' looks like a raw physical device." "raw risk warning"
        $script:LocalHostTargets = @((New-TargetSelection -Kind "Raw disk" -Target "\\.\E:" -Selected $true))
        $rawVolumeRisk = Build-VdbenchConfig
        Assert-SelfTestContains (($rawVolumeRisk.Warnings -join "`n")) "RISK: local target '\\.\E:' looks like a raw physical device." "raw volume risk warning"
        $script:LocalHostTargets = @((New-TargetSelection -Kind "Test file" -Target "C:\vdbench\testfile.dat" -Selected $true))

        Set-PropertyValue $script:Settings "RunMode" "Master/Slave distributed run"
        $script:Slaves = @(
            [pscustomobject]@{
                Enabled = $true
                Name = "test-001"
                Host = "10.0.0.11"
                OsType = "Linux"
                VdbenchPath = "/opt/vdbench"
                TestTarget = "/dev/sdb"
                Targets = @((New-TargetSelection -Kind "Raw disk" -Target "/dev/sdb" -Selected $true))
                SshAlias = "test-001"
                ReadinessStatus = "Ready"
                Notes = ""
            }
        )
        $distributed = Build-VdbenchConfig
        Assert-SelfTestContains $distributed.Text "hd=default,shell=ssh" "distributed host defaults"
        Assert-SelfTestContains $distributed.Text "hd=test-001,system=test-001,vdbench=/opt/vdbench" "distributed host line"
        Assert-SelfTestContains $distributed.Text "sd=sd_test_001_1,host=test-001,lun=/dev/sdb" "distributed storage line"
        Assert-SelfTestContains $distributed.Text "wd=wd1,sd=sd*" "distributed workload fanout"
        Assert-SelfTestContains (($distributed.Warnings -join "`n")) "RISK: slave 'test-001' target '/dev/sdb' looks like a raw physical device." "distributed raw risk warning"

        Set-PropertyValue $script:Settings "RunMode" "Single local run"
        $script:CurrentProfile = New-DefaultProfile "SelfTest-Filesystem"
        $script:RunProfile = $script:CurrentProfile
        $script:LocalHostTargets = @((New-TargetSelection -Kind "Filesystem" -Target "C:\vdbench\fs_test" -Selected $true))
        $fs = Build-VdbenchConfig
        Assert-SelfTestContains $fs.Text "create_anchors=yes" "filesystem create_anchors"
        Assert-SelfTestContains $fs.Text "fsd=fsd1,anchor=C:\vdbench\fs_test" "filesystem definition"
        Assert-SelfTestContains $fs.Text "fwd=fwd1,fsd=fsd1" "filesystem workload"
        Assert-SelfTestContains $fs.Text "operation=read" "filesystem workload operation"
        Assert-SelfTestContainsAll $fs.Text @(
            "rd=rd1,fwd=fwd1",
            "elapsed=300",
            "warmup=30",
            "interval=1",
            "fwdrate=max",
            "format=no"
        ) "filesystem run"

        Set-PropertyValue $script:Settings "RunMode" "Master/Slave distributed run"
        $script:Slaves = @(
            [pscustomobject]@{
                Enabled = $true
                Name = "test-002"
                Host = "10.0.0.12"
                OsType = "Linux"
                VdbenchPath = "/opt/vdbench"
                TestTarget = "/mnt/test"
                Targets = @((New-TargetSelection -Kind "Filesystem" -Target "/mnt/test" -Selected $true))
                SshAlias = "test-002"
                ReadinessStatus = "Ready"
                Notes = ""
            }
        )
        $script:CurrentProfile = New-DefaultProfile "SelfTest-Filesystem-Distributed"
        $script:RunProfile = $script:CurrentProfile
        $fsDistributed = Build-VdbenchConfig
        Assert-SelfTestContains $fsDistributed.Text "create_anchors=yes" "distributed filesystem create_anchors"
        Assert-SelfTestContains $fsDistributed.Text "fsd=fsd_test_002_1,anchor=/mnt/test" "distributed filesystem definition"
        Assert-SelfTestContains $fsDistributed.Text "fwd=fwd_test_002_1,fsd=fsd_test_002_1,host=test-002" "distributed filesystem workload host binding"
        Assert-SelfTestContains $fsDistributed.Text "rd=rd1,fwd=fwd*" "distributed filesystem run fanout"

        Set-PropertyValue $script:Settings "RunMode" "Single local run"
        $script:LocalHostTargets = @(
            (New-TargetSelection -Kind "Test file" -Target "C:\vdbench\testfile.dat" -Selected $true),
            (New-TargetSelection -Kind "Filesystem" -Target "C:\vdbench\fs_test" -Selected $true)
        )
        $mixed = Build-VdbenchConfig
        Assert-SelfTestContains (($mixed.Warnings -join "`n")) "BLOCKER: mixed raw and filesystem targets in the same run." "mixed target blocker"

        Set-PropertyValue $script:Settings "RunMode" "Single local run"
        $script:LocalHostTargets = @((New-TargetSelection -Kind "Filesystem" -Target "C:\" -Selected $true))
        Set-ProfileParamValue $script:CurrentProfile "run.format" "yes"
        $fsRisk = Build-VdbenchConfig
        $fsRiskWarnings = $fsRisk.Warnings -join "`n"
        Assert-SelfTestContains $fsRiskWarnings "RISK: filesystem format is enabled with value 'yes'." "filesystem format risk"
        Assert-SelfTestContains $fsRiskWarnings "RISK: filesystem anchor 'C:\' looks like a root drive/path." "filesystem anchor risk"

        Set-ProfileParamValue $script:CurrentProfile "run.elapsed" "not-a-number"
        $invalid = Build-VdbenchConfig
        Assert-SelfTestContains (($invalid.Warnings -join "`n")) "Invalid value for Elapsed time" "invalid elapsed warning"

        $parsedTargets = @(Convert-TargetInventoryOutput "Raw disk|\\.\PhysicalDrive2|Test model`nFilesystem|C:\|NTFS")
        Assert-SelfTestEquals $parsedTargets.Count 2 "target inventory parser count"
        Assert-SelfTestEquals $parsedTargets[0].Target "\\.\PhysicalDrive2" "target inventory raw target"
        Assert-SelfTestEquals $parsedTargets[1].Target "C:\" "target inventory filesystem target"

        $fakeMetric = Get-MetricValuesFromLine "07:02:41.012          1     6389    99.80  40960240    70    0.015"
        Assert-SelfTestEquals $fakeMetric.Iops 6389 "vdbench timestamp metric iops"
        if ([math]::Abs($fakeMetric.Mbps - 99.80) -gt 0.01) {
            throw ("Self-test failed: vdbench timestamp metric mbps. Expected ~99.80, got '{0}'." -f $fakeMetric.Mbps)
        }

        $legacyMetric = Get-MetricValuesFromLine "          12       2500    9.77    4096    70    0.850"
        Assert-SelfTestEquals $legacyMetric.Iops 2500 "legacy metric iops"

        $psiPs1 = Get-VdbenchProcessStartInfo (Join-Path $script:AppRoot "tools\FakeVdbench.ps1") "C:\tmp\profile.parm" "C:\tmp\out folder" $script:AppRoot
        Assert-SelfTestEquals $psiPs1.FileName "powershell.exe" "ps1 runner executable"
        Assert-SelfTestContains $psiPs1.Arguments "-ExecutionPolicy Bypass -File" "ps1 runner arguments"
        Assert-SelfTestContains $psiPs1.Arguments "-f `"C:\tmp\profile.parm`" -o `"C:\tmp\out folder`"" "ps1 runner quoted paths"

        $psiBat = Get-VdbenchProcessStartInfo "C:\Program Files\vdbench\vdbench.bat" "C:\tmp\profile.parm" "C:\tmp\out folder" "C:\Program Files\vdbench"
        Assert-SelfTestEquals $psiBat.FileName "cmd.exe" "bat runner executable"
        Assert-SelfTestContains $psiBat.Arguments "/d /c" "bat runner cmd switch"
        Assert-SelfTestContains $psiBat.Arguments "`"C:\Program Files\vdbench\vdbench.bat`"" "bat runner quoted executable"

        Write-Host "VdbenchUI self-test OK."
    } finally {
        Restore-SelfTestPaths $savedPaths
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
