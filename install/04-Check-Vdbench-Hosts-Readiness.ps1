#requires -RunAsAdministrator
<#
FINAL v4 - Check Vdbench Master -> Windows/Linux Slave readiness.

Run on Vdbench MASTER.

Fixes:
- Works on Windows PowerShell 5.1: does NOT use ProcessStartInfo.ArgumentList.
- Fixes report formatting bug.
- Runs local Vdbench from the discovered vdbench.bat directory under C:\vdbench.
- Runs remote Windows Vdbench from the discovered vdbench.bat directory under C:\vdbench.
- Runs remote Linux Vdbench from /opt/vdbench working directory.
- Creates TXT and CSV report.

Examples:
  C:\install\04-Check-Vdbench-Hosts-Readiness.ps1 -WindowsHosts 10.50.11.178
  C:\install\04-Check-Vdbench-Hosts-Readiness.ps1 -WindowsHosts 10.50.11.178 -LinuxHosts 10.50.11.179
  C:\install\04-Check-Vdbench-Hosts-Readiness.ps1 -WindowsHosts 10.50.11.178 -SkipPing
  C:\install\04-Check-Vdbench-Hosts-Readiness.ps1 -WindowsHosts 10.50.11.178 -PrivateKeyPath C:\install\ssh\id_rsa
#>

param(
    [string[]]$WindowsHosts = @(),
    [string[]]$LinuxHosts = @(),

    [string]$WindowsUser = "Administrator",
    [string]$LinuxUser = "root",

    [string]$MasterVdbenchRoot = "C:\vdbench",
    [string]$WindowsVdbenchRoot = "C:\vdbench",
    [string]$LinuxVdbenchRoot = "/opt/vdbench",
    [string]$PrivateKeyPath = "C:\install\ssh\id_rsa",

    [string]$OutputDir = "C:\vdbench\output\host_readiness",
    [int]$ConnectTimeoutSeconds = 10,
    [switch]$SkipPing
)

$ErrorActionPreference = "Continue"

$script:Results = New-Object System.Collections.ArrayList
$script:ReportLines = New-Object System.Collections.ArrayList

function Write-Step {
    param([string]$Message)

    $line = "============================================================"
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan

    [void]$script:ReportLines.Add("")
    [void]$script:ReportLines.Add($line)
    [void]$script:ReportLines.Add($Message)
    [void]$script:ReportLines.Add($line)
}

function Add-ReportLine {
    param([string]$Line)
    [void]$script:ReportLines.Add($Line)
}

function Add-Result {
    param(
        [string]$Scope,
        [string]$HostName,
        [string]$Check,
        [bool]$Ok,
        [string]$Details = ""
    )

    $status = if ($Ok) { "OK" } else { "FAIL" }
    $cleanDetails = (($Details | Out-String).Trim())

    $obj = [PSCustomObject]@{
        Scope   = $Scope
        Host    = $HostName
        Check   = $Check
        Status  = $status
        Details = $cleanDetails
    }

    [void]$script:Results.Add($obj)

    if ($Ok) {
        Write-Host ("[OK]   {0,-12} {1,-20} {2}" -f $Scope, $HostName, $Check) -ForegroundColor Green
    }
    else {
        Write-Host ("[FAIL] {0,-12} {1,-20} {2}" -f $Scope, $HostName, $Check) -ForegroundColor Red
    }

    if ($cleanDetails) {
        $short = ($cleanDetails -split "`r?`n" | Select-Object -First 12) -join "`n"
        Write-Host $short -ForegroundColor DarkGray
    }

    $line = "[{0}] {1} | {2} | {3}" -f $status, $Scope, $HostName, $Check
    Add-ReportLine $line
    if ($cleanDetails) { Add-ReportLine $cleanDetails }
}

function Quote-CommandArg {
    param([string]$Arg)

    if ($null -eq $Arg) { return '""' }
    if ($Arg -eq "") { return '""' }
    if ($Arg -notmatch '[\s"]') { return $Arg }
    return '"' + ($Arg -replace '"', '\"') + '"'
}

function Invoke-Native {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 60,
        [string]$WorkingDirectory = ""
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    if ($WorkingDirectory -and (Test-Path $WorkingDirectory)) {
        $psi.WorkingDirectory = $WorkingDirectory
    }

    $psi.Arguments = (($Arguments | ForEach-Object { Quote-CommandArg $_ }) -join " ")

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi

    try {
        [void]$p.Start()
    }
    catch {
        return [PSCustomObject]@{
            ExitCode = 999
            Output   = "PROCESS START FAILED: $($_.Exception.Message)`nFilePath=$FilePath`nArguments=$($psi.Arguments)"
        }
    }

    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        try { $p.Kill() } catch {}
        return [PSCustomObject]@{
            ExitCode = 124
            Output   = "TIMEOUT after $TimeoutSeconds seconds`nFilePath=$FilePath`nArguments=$($psi.Arguments)"
        }
    }

    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()

    $combined = @()
    if ($stdout) { $combined += $stdout.TrimEnd() }
    if ($stderr) { $combined += $stderr.TrimEnd() }

    return [PSCustomObject]@{
        ExitCode = $p.ExitCode
        Output   = (($combined -join "`n").Trim())
    }
}

function Invoke-Cmd {
    param(
        [string]$CommandLine,
        [int]$TimeoutSeconds = 60,
        [string]$WorkingDirectory = ""
    )

    return Invoke-Native -FilePath "cmd.exe" -Arguments @("/d", "/c", $CommandLine) -TimeoutSeconds $TimeoutSeconds -WorkingDirectory $WorkingDirectory
}

function Invoke-SshCommand {
    param(
        [string]$User,
        [string]$HostName,
        [string]$Command,
        [int]$TimeoutSeconds = 60
    )

    $target = "$User@$HostName"

    $args = New-Object System.Collections.Generic.List[string]
    [void]$args.Add("-o"); [void]$args.Add("BatchMode=yes")
    [void]$args.Add("-o"); [void]$args.Add("ConnectTimeout=$ConnectTimeoutSeconds")
    [void]$args.Add("-o"); [void]$args.Add("StrictHostKeyChecking=no")
    [void]$args.Add("-o"); [void]$args.Add("UserKnownHostsFile=NUL")
    if (-not [string]::IsNullOrWhiteSpace($PrivateKeyPath) -and (Test-Path -LiteralPath $PrivateKeyPath)) {
        [void]$args.Add("-i"); [void]$args.Add($PrivateKeyPath)
    }
    [void]$args.Add($target)
    [void]$args.Add($Command)

    return Invoke-Native -FilePath "ssh.exe" -Arguments $args.ToArray() -TimeoutSeconds $TimeoutSeconds
}

function Test-HostNetwork {
    param([string]$Scope, [string]$HostName)

    if (-not $SkipPing) {
        try {
            $pingOk = Test-Connection -ComputerName $HostName -Count 2 -Quiet -ErrorAction SilentlyContinue
            Add-Result -Scope $Scope -HostName $HostName -Check "Ping" -Ok ([bool]$pingOk)
        }
        catch {
            Add-Result -Scope $Scope -HostName $HostName -Check "Ping" -Ok $false -Details $_.Exception.Message
        }
    }

    try {
        $portOk = Test-NetConnection -ComputerName $HostName -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue
        Add-Result -Scope $Scope -HostName $HostName -Check "TCP 22 reachable" -Ok ([bool]$portOk)
    }
    catch {
        Add-Result -Scope $Scope -HostName $HostName -Check "TCP 22 reachable" -Ok $false -Details $_.Exception.Message
    }
}

function Resolve-LocalVdbenchBat {
    param([string]$Root)

    $direct = Join-Path $Root "vdbench.bat"
    if (Test-Path -LiteralPath $direct -PathType Leaf) {
        return (Get-Item -LiteralPath $direct).FullName
    }

    if (Test-Path -LiteralPath $Root -PathType Container) {
        try {
            $hit = Get-ChildItem -LiteralPath $Root -Filter "vdbench.bat" -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) {
                return $hit.FullName
            }
        }
        catch {
            # Keep direct path as the reported expected path below.
        }
    }

    return $direct
}

function New-RemoteWindowsFindVdbenchCommand {
    param([string]$Root)

    $ps = "`$root = '$Root'; " +
          "`$direct = Join-Path `$root 'vdbench.bat'; " +
          "if (Test-Path -LiteralPath `$direct -PathType Leaf) { Write-Output `$direct; exit 0 }; " +
          "if (-not (Test-Path -LiteralPath `$root -PathType Container)) { Write-Output ('MISSING root: ' + `$root); exit 2 }; " +
          "`$hit = Get-ChildItem -LiteralPath `$root -Filter 'vdbench.bat' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1; " +
          "if (`$hit) { Write-Output `$hit.FullName; exit 0 }; " +
          "Write-Output ('MISSING vdbench.bat under ' + `$root); exit 2"

    return "powershell -NoProfile -ExecutionPolicy Bypass -Command `"$ps`""
}

function New-RemoteWindowsRunVdbenchCommand {
    param([string]$Root)

    $ps = "`$root = '$Root'; " +
          "`$direct = Join-Path `$root 'vdbench.bat'; " +
          "if (Test-Path -LiteralPath `$direct -PathType Leaf) { `$bat = `$direct } else { " +
          "  `$hit = Get-ChildItem -LiteralPath `$root -Filter 'vdbench.bat' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1; " +
          "  if (-not `$hit) { Write-Error ('vdbench.bat not found under ' + `$root); exit 2 }; " +
          "  `$bat = `$hit.FullName " +
          "}; " +
          "Set-Location -LiteralPath (Split-Path -Parent `$bat); " +
          "& `$bat -t"

    return "powershell -NoProfile -ExecutionPolicy Bypass -Command `"$ps`""
}

function Check-Master {
    Write-Step "Checking Master readiness"

    $ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
    Add-Result -Scope "MASTER" -HostName $env:COMPUTERNAME -Check "ssh.exe exists" -Ok ([bool]$ssh) -Details ($(if ($ssh) { $ssh.Source } else { "ssh.exe not found" }))

    if ($ssh) {
        $sshVer = Invoke-Cmd -CommandLine "ssh -V 2>&1" -TimeoutSeconds 15
        Add-Result -Scope "MASTER" -HostName $env:COMPUTERNAME -Check "ssh -V" -Ok ($sshVer.ExitCode -eq 0) -Details $sshVer.Output
    }

    $privateKey = "C:\install\ssh\id_rsa"
    $sshConfig = Join-Path "$env:USERPROFILE\.ssh" "config"
    $publicKeyCandidates = @(
        "C:\install\master_id_ed25519.pub",
        "C:\install\ssh\id_rsa.pub"
    )
    $publicKey = $publicKeyCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    $masterVdbenchBat = Resolve-LocalVdbenchBat -Root $MasterVdbenchRoot

    Add-Result -Scope "MASTER" -HostName $env:COMPUTERNAME -Check "Private key exists" -Ok (Test-Path -LiteralPath $privateKey -PathType Leaf) -Details $privateKey
    Add-Result -Scope "MASTER" -HostName $env:COMPUTERNAME -Check "Public key exists" -Ok ([bool]$publicKey) -Details ($(if ($publicKey) { $publicKey } else { $publicKeyCandidates -join "; " }))
    Add-Result -Scope "MASTER" -HostName $env:COMPUTERNAME -Check "SSH config exists" -Ok (Test-Path -LiteralPath $sshConfig -PathType Leaf) -Details $sshConfig
    Add-Result -Scope "MASTER" -HostName $env:COMPUTERNAME -Check "Master vdbench.bat exists" -Ok (Test-Path -LiteralPath $masterVdbenchBat -PathType Leaf) -Details $masterVdbenchBat

    $java = Get-Command java.exe -ErrorAction SilentlyContinue
    Add-Result -Scope "MASTER" -HostName $env:COMPUTERNAME -Check "java.exe exists" -Ok ([bool]$java) -Details ($(if ($java) { $java.Source } else { "java.exe not found" }))

    if ($java) {
        $javaVer = Invoke-Native -FilePath "java.exe" -Arguments @("--version") -TimeoutSeconds 30
        Add-Result -Scope "MASTER" -HostName $env:COMPUTERNAME -Check "java --version" -Ok ($javaVer.ExitCode -eq 0) -Details $javaVer.Output
    }

    if (Test-Path -LiteralPath $masterVdbenchBat -PathType Leaf) {
        $vdbenchDir = Split-Path -Parent $masterVdbenchBat
        $vdbenchTest = Invoke-Cmd -CommandLine "call vdbench.bat -t" -WorkingDirectory $vdbenchDir -TimeoutSeconds 120
        Add-Result -Scope "MASTER" -HostName $env:COMPUTERNAME -Check "vdbench -t local" -Ok ($vdbenchTest.ExitCode -eq 0) -Details $vdbenchTest.Output
    }
}

function Check-WindowsSlave {
    param([string]$HostName)

    Write-Step "Checking Windows slave: $HostName"
    Test-HostNetwork -Scope "WINDOWS" -HostName $HostName

    $r = Invoke-SshCommand -User $WindowsUser -HostName $HostName -Command "hostname" -TimeoutSeconds 30
    Add-Result -Scope "WINDOWS" -HostName $HostName -Check "SSH BatchMode hostname" -Ok ($r.ExitCode -eq 0) -Details $r.Output

    if ($r.ExitCode -ne 0) {
        Add-Result -Scope "WINDOWS" -HostName $HostName -Check "Stop checks for host" -Ok $false -Details "SSH failed. Fix key auth/sshd first. Try manually: ssh $WindowsUser@$HostName hostname"
        return
    }

    $r = Invoke-SshCommand -User $WindowsUser -HostName $HostName -Command "whoami" -TimeoutSeconds 20
    Add-Result -Scope "WINDOWS" -HostName $HostName -Check "Remote whoami" -Ok ($r.ExitCode -eq 0) -Details $r.Output

    $r = Invoke-SshCommand -User $WindowsUser -HostName $HostName -Command "java --version" -TimeoutSeconds 40
    Add-Result -Scope "WINDOWS" -HostName $HostName -Check "Remote java --version" -Ok ($r.ExitCode -eq 0) -Details $r.Output

    $checkCmd = New-RemoteWindowsFindVdbenchCommand -Root $WindowsVdbenchRoot
    $r = Invoke-SshCommand -User $WindowsUser -HostName $HostName -Command $checkCmd -TimeoutSeconds 60
    Add-Result -Scope "WINDOWS" -HostName $HostName -Check "Remote vdbench.bat exists" -Ok ($r.ExitCode -eq 0) -Details $r.Output

    $runCmd = New-RemoteWindowsRunVdbenchCommand -Root $WindowsVdbenchRoot
    $r = Invoke-SshCommand -User $WindowsUser -HostName $HostName -Command $runCmd -TimeoutSeconds 120
    Add-Result -Scope "WINDOWS" -HostName $HostName -Check "Remote vdbench -t" -Ok ($r.ExitCode -eq 0) -Details $r.Output

    $diskCmd = 'powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Disk | Sort-Object Number | Format-Table Number,FriendlyName,Size,BusType,IsBoot,IsSystem,IsOffline,IsReadOnly -AutoSize"'
    $r = Invoke-SshCommand -User $WindowsUser -HostName $HostName -Command $diskCmd -TimeoutSeconds 60
    Add-Result -Scope "WINDOWS" -HostName $HostName -Check "Remote disk list" -Ok ($r.ExitCode -eq 0) -Details $r.Output
}

function Check-LinuxSlave {
    param([string]$HostName)

    Write-Step "Checking Linux slave: $HostName"
    Test-HostNetwork -Scope "LINUX" -HostName $HostName

    $r = Invoke-SshCommand -User $LinuxUser -HostName $HostName -Command "hostname" -TimeoutSeconds 30
    Add-Result -Scope "LINUX" -HostName $HostName -Check "SSH BatchMode hostname" -Ok ($r.ExitCode -eq 0) -Details $r.Output

    if ($r.ExitCode -ne 0) {
        Add-Result -Scope "LINUX" -HostName $HostName -Check "Stop checks for host" -Ok $false -Details "SSH failed. Fix key auth/sshd first. Try manually: ssh $LinuxUser@$HostName hostname"
        return
    }

    $r = Invoke-SshCommand -User $LinuxUser -HostName $HostName -Command "whoami" -TimeoutSeconds 20
    Add-Result -Scope "LINUX" -HostName $HostName -Check "Remote whoami" -Ok ($r.ExitCode -eq 0) -Details $r.Output

    $r = Invoke-SshCommand -User $LinuxUser -HostName $HostName -Command "java --version" -TimeoutSeconds 40
    Add-Result -Scope "LINUX" -HostName $HostName -Check "Remote java --version" -Ok ($r.ExitCode -eq 0) -Details $r.Output

    $vdbenchBin = "$LinuxVdbenchRoot/vdbench"
    $checkCmd = "test -x '$vdbenchBin' && echo OK: $vdbenchBin || { echo MISSING: $vdbenchBin; exit 2; }"
    $r = Invoke-SshCommand -User $LinuxUser -HostName $HostName -Command $checkCmd -TimeoutSeconds 30
    Add-Result -Scope "LINUX" -HostName $HostName -Check "Remote vdbench exists" -Ok ($r.ExitCode -eq 0) -Details $r.Output

    $r = Invoke-SshCommand -User $LinuxUser -HostName $HostName -Command "cd '$LinuxVdbenchRoot' && ./vdbench -t" -TimeoutSeconds 120
    Add-Result -Scope "LINUX" -HostName $HostName -Check "Remote vdbench -t" -Ok ($r.ExitCode -eq 0) -Details $r.Output

    $diskCmd = "lsblk -o NAME,TYPE,SIZE,MODEL,SERIAL,ROTA,MOUNTPOINTS"
    $r = Invoke-SshCommand -User $LinuxUser -HostName $HostName -Command $diskCmd -TimeoutSeconds 60
    Add-Result -Scope "LINUX" -HostName $HostName -Check "Remote disk list" -Ok ($r.ExitCode -eq 0) -Details $r.Output
}

function Write-Reports {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $txt = Join-Path $OutputDir "vdbench_host_readiness_$timestamp.txt"
    $csv = Join-Path $OutputDir "vdbench_host_readiness_$timestamp.csv"

    Add-ReportLine ""
    Add-ReportLine "============================================================"
    Add-ReportLine "SUMMARY"
    Add-ReportLine "============================================================"

    $failCount = @($script:Results | Where-Object { $_.Status -eq "FAIL" }).Count
    $okCount   = @($script:Results | Where-Object { $_.Status -eq "OK" }).Count

    Add-ReportLine "OK checks:   $okCount"
    Add-ReportLine "FAIL checks: $failCount"
    Add-ReportLine ""
    Add-ReportLine "Failed checks:"

    $failed = @($script:Results | Where-Object { $_.Status -eq "FAIL" })
    if ($failed.Count -gt 0) {
        foreach ($f in $failed) {
            Add-ReportLine ("FAIL | {0} | {1} | {2}" -f $f.Scope, $f.Host, $f.Check)
            if ($f.Details) { Add-ReportLine $f.Details }
        }
    }
    else {
        Add-ReportLine "None"
    }

    $script:ReportLines | Set-Content -Path $txt -Encoding UTF8
    $script:Results | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8

    Write-Step "Report files"
    Write-Host "TXT report:" -ForegroundColor Yellow
    Write-Host "  $txt"
    Write-Host "CSV report:" -ForegroundColor Yellow
    Write-Host "  $csv"

    Write-Step "Final summary"
    Write-Host "OK checks:   $okCount" -ForegroundColor Green
    if ($failCount -eq 0) {
        Write-Host "FAIL checks: 0" -ForegroundColor Green
        Write-Host "All checked hosts look ready for Vdbench distributed testing." -ForegroundColor Green
    }
    else {
        Write-Host "FAIL checks: $failCount" -ForegroundColor Red
        Write-Host "Fix failed checks before starting distributed Vdbench workload." -ForegroundColor Red
    }
}

Write-Step "Starting Vdbench host readiness check"
Write-Host "Master:             $env:COMPUTERNAME"
Write-Host "Windows hosts:      $($WindowsHosts -join ', ')"
Write-Host "Linux hosts:        $($LinuxHosts -join ', ')"
Write-Host "Windows user:       $WindowsUser"
Write-Host "Linux user:         $LinuxUser"
Write-Host "Master Vdbench:     $MasterVdbenchRoot"
Write-Host "Windows Vdbench:    $WindowsVdbenchRoot"
Write-Host "Linux Vdbench:      $LinuxVdbenchRoot"
Write-Host "OutputDir:          $OutputDir"

Check-Master

foreach ($h in $WindowsHosts) {
    if (-not [string]::IsNullOrWhiteSpace($h)) {
        Check-WindowsSlave -HostName $h.Trim()
    }
}

foreach ($h in $LinuxHosts) {
    if (-not [string]::IsNullOrWhiteSpace($h)) {
        Check-LinuxSlave -HostName $h.Trim()
    }
}

Write-Reports

# Exit non-zero when any check failed so the UI can map Ready vs Failed
# from the process exit code (exit 0 must mean every recorded check passed).
$script:FinalFailCount = @($script:Results | Where-Object { $_.Status -eq "FAIL" }).Count
if ($script:FinalFailCount -gt 0) {
    exit 1
}
exit 0
