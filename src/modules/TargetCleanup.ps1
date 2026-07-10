function Test-TargetSupportsCleanup {
    param([object]$Target)
    $kind = [string](Get-PropertyValue $Target "Kind" "")
    return ($kind -eq "Filesystem")
}

# Must be a scriptblock that callers DOT-SOURCE (`. & $script:CleanupModuleDependencyLoader ...`),
# not a function. Dot-sourcing files from inside a function keeps the imported
# functions in that function's local scope only - they vanish when the function
# returns. That is exactly why the Clean progress window failed with
# "Normalize-TargetEntries is not recognized" after Import-CleanupModuleDependencies
# appeared to succeed.
$script:CleanupModuleDependencyLoader = {
    param([string]$ModuleRoot)
    if ([string]::IsNullOrWhiteSpace($ModuleRoot)) {
        throw "Cleanup module root is blank."
    }
    foreach ($moduleName in @("Core.ps1", "ProcessRunner.ps1", "State.ps1", "TargetDiscovery.ps1", "Runner.ps1")) {
        . (Join-Path $ModuleRoot $moduleName)
    }
}

function Write-CleanupProgressMessage {
    param(
        [string]$Message,
        [string]$Color = ""
    )
    if ([string]::IsNullOrWhiteSpace($Color)) {
        Write-Host $Message
        return
    }
    Write-Host $Message -ForegroundColor $Color
}

function Write-CleanupSummary {
    param([hashtable]$Result)
    $cleaned = @(Get-PropertyValue $Result "Cleaned" @())
    $skipped = @(Get-PropertyValue $Result "Skipped" @())
    $errors = @(Get-PropertyValue $Result "Errors" @())
    Write-CleanupProgressMessage "" 
    Write-CleanupProgressMessage "Summary" "Cyan"
    if ($cleaned.Count -eq 0 -and $skipped.Count -eq 0 -and $errors.Count -eq 0) {
        Write-CleanupProgressMessage "  (no filesystem targets were selected)" "DarkGray"
    }
    foreach ($line in $cleaned) {
        Write-CleanupProgressMessage ("  [OK] cleaned {0}" -f $line) "Green"
    }
    foreach ($line in $skipped) {
        Write-CleanupProgressMessage ("  [SKIP] {0}" -f $line) "DarkGray"
    }
    foreach ($line in $errors) {
        Write-CleanupProgressMessage ("  [FAIL] {0}" -f $line) "Red"
    }
}

function Export-CleanupSessionContext {
    param(
        [object]$Owner,
        [object[]]$Targets,
        [string]$ModuleRoot,
        [string]$ResultPath,
        [string]$Label
    )
    $targetPayload = @()
    foreach ($target in @(Normalize-TargetEntries $Targets)) {
        $targetPayload += @{
            Kind = [string](Get-PropertyValue $target "Kind" "")
            Target = [string](Get-PropertyValue $target "Target" "")
            Selected = [bool](Get-PropertyValue $target "Selected" $false)
            Description = [string](Get-PropertyValue $target "Description" "")
        }
    }
    return @{
        Owner = @{
            Host = [string](Get-PropertyValue $Owner "Host" "localhost")
            OsType = [string](Get-PropertyValue $Owner "OsType" (Get-LocalHostOsType))
            User = [string](Get-PropertyValue $Owner "User" "")
            SshAlias = [string](Get-PropertyValue $Owner "SshAlias" "")
            PrivateKey = [string](Get-PropertyValue $Owner "PrivateKey" "")
        }
        Targets = $targetPayload
        ModuleRoot = $ModuleRoot
        ResultPath = $ResultPath
        Label = $Label
    }
}

function Import-CleanupSessionContext {
    param([string]$ContextPath)
    $raw = Get-Content -LiteralPath $ContextPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $owner = [pscustomobject]@{
        Host = [string]$raw.Owner.Host
        OsType = [string]$raw.Owner.OsType
        User = [string]$raw.Owner.User
        SshAlias = [string]$raw.Owner.SshAlias
        PrivateKey = [string]$raw.Owner.PrivateKey
    }
    $targets = @()
    foreach ($item in @(Normalize-TargetEntries @($raw.Targets))) {
        if ($null -eq $item) {
            continue
        }
        $targets += (New-TargetSelection `
            -Kind ([string](Get-PropertyValue $item "Kind" "")) `
            -Target ([string](Get-PropertyValue $item "Target" "")) `
            -Description ([string](Get-PropertyValue $item "Description" "")) `
            -Selected ([bool](Get-PropertyValue $item "Selected" $false)))
    }
    return @{
        Owner = $owner
        Targets = $targets
        ModuleRoot = [string]$raw.ModuleRoot
        ResultPath = [string]$raw.ResultPath
        Label = [string](Get-PropertyValue $raw "Label" "")
    }
}

function Import-CleanupResultFromJson {
    param([string]$ResultPath)
    if (-not (Test-Path -LiteralPath $ResultPath)) {
        return @{
            Cleaned = @()
            Skipped = @()
            Errors = @("Cleanup session did not produce a result file.")
        }
    }
    $raw = Get-Content -LiteralPath $ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    return @{
        Cleaned = @(Get-PropertyValue $raw "Cleaned" @())
        Skipped = @(Get-PropertyValue $raw "Skipped" @())
        Errors = @(Get-PropertyValue $raw "Errors" @())
    }
}

function Get-CleanupWindowWrapperCommand {
    param(
        [string]$InnerCommand,
        [string]$Title
    )
    $safeTitle = ($Title -replace "'", "''")
    return @"
`$Host.UI.RawUI.WindowTitle = '$safeTitle'
`$ErrorActionPreference = 'Stop'
Write-Host 'Vdbench target cleanup' -ForegroundColor Cyan
Write-Host ('Host: $safeTitle')
Write-Host 'Only filesystem anchor contents are removed; mounts and folders stay.'
Write-Host ''
try {
    $InnerCommand
    `$exitCode = if (`$null -ne `$LASTEXITCODE) { `$LASTEXITCODE } else { 0 }
} catch {
    Write-Host ''
    Write-Host 'Cleanup failed:' -ForegroundColor Red
    Write-Host `$_.Exception.Message -ForegroundColor Red
    `$exitCode = 1
}
Write-Host ''
Write-Host 'Review the output above, then press Enter to close this window...'
`$null = Read-Host
exit `$exitCode
"@
}

function Invoke-CleanupSessionRunner {
    param([string]$ContextPath)
    # The cleanup progress window is a fresh powershell.exe process that only
    # dot-sources TargetCleanup.ps1. Load Core/State/etc. BEFORE reading the
    # session JSON - Import-CleanupSessionContext needs Normalize-TargetEntries
    # / New-TargetSelection / Get-PropertyValue from those modules. Loading
    # after Import-CleanupSessionContext was the real bug behind:
    # "The term 'Normalize-TargetEntries' is not recognized..."
    $raw = Get-Content -LiteralPath $ContextPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $script:ModuleRoot = [string]$raw.ModuleRoot
    if ([string]::IsNullOrWhiteSpace($script:ModuleRoot) -or -not (Test-Path -LiteralPath $script:ModuleRoot)) {
        throw ("Cleanup session ModuleRoot is missing or invalid: '{0}'" -f $script:ModuleRoot)
    }
    . $script:CleanupModuleDependencyLoader $script:ModuleRoot
    $session = Import-CleanupSessionContext $ContextPath
    if (-not [string]::IsNullOrWhiteSpace([string]$session.Label)) {
        Write-CleanupProgressMessage ("Cleaning filesystem targets for {0}" -f $session.Label) "Cyan"
    }
    $result = Invoke-CleanupTargets -Owner $session.Owner -Targets $session.Targets -VerboseOutput
    Write-CleanupSummary $result
    @{
        Cleaned = @($result.Cleaned)
        Skipped = @($result.Skipped)
        Errors = @($result.Errors)
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $session.ResultPath -Encoding UTF8
    if (@($result.Errors).Count -gt 0) {
        exit 1
    }
}

function Invoke-CleanupTargetsInVisibleWindow {
    param(
        [object]$Owner,
        [object[]]$Targets,
        [string]$Label
    )
    $sessionDir = Join-Path ([System.IO.Path]::GetTempPath()) ("vdbench-cleanup-" + [guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null
    $contextPath = Join-Path $sessionDir "context.json"
    $resultPath = Join-Path $sessionDir "result.json"
    try {
        $payload = Export-CleanupSessionContext `
            -Owner $Owner `
            -Targets $Targets `
            -ModuleRoot $script:ModuleRoot `
            -ResultPath $resultPath `
            -Label $Label
        $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $contextPath -Encoding UTF8

        $moduleRootQuoted = Convert-ToPowerShellSingleQuoted $script:ModuleRoot
        $contextPathQuoted = Convert-ToPowerShellSingleQuoted $contextPath
        $innerCommand = ". (Join-Path $moduleRootQuoted 'TargetCleanup.ps1'); Invoke-CleanupSessionRunner -ContextPath $contextPathQuoted"
        $wrapperCommand = Get-CleanupWindowWrapperCommand $innerCommand $Label
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "powershell.exe"
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command " + (Quote-ProcessArgument $wrapperCommand)
        $psi.UseShellExecute = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Normal
        $process = [System.Diagnostics.Process]::Start($psi)
        $process.WaitForExit()
        return (Import-CleanupResultFromJson $resultPath)
    } finally {
        Remove-Item -LiteralPath $sessionDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-CleanupEligibleTargets {
    param([object[]]$Targets)
    return @(Get-SelectedTargetEntries $Targets | Where-Object { Test-TargetSupportsCleanup $_ })
}

function Get-FilesystemCleanupContentsScript {
    param(
        [string]$Path,
        [string]$OsType
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }
    if ($OsType -eq "Linux") {
        $quotedPath = Convert-ToShellSingleQuoted $Path
        # find+rm so empty anchors succeed, real delete failures surface (no || true).
        return "find $quotedPath -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +"
    }
    $quotedPath = Convert-ToPowerShellSingleQuoted $Path
    return @"
if (Test-Path -LiteralPath $quotedPath) {
    Get-ChildItem -LiteralPath $quotedPath -Force -ErrorAction Stop | Remove-Item -Recurse -Force -ErrorAction Stop
}
"@
}

function Get-TargetCleanupRemoteScript {
    param(
        [string]$Path,
        [string]$Kind,
        [string]$OsType
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }
    if ($Kind -ne "Filesystem") {
        return ""
    }
    return Get-FilesystemCleanupContentsScript -Path $Path -OsType $OsType
}

function Remove-LocalCleanupTarget {
    param(
        [string]$Path,
        [string]$Kind,
        [switch]$VerboseOutput
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return @{ Ok = $false; Message = "Path is blank." }
    }
    try {
        $osType = Get-LocalHostOsType
        $script = Get-TargetCleanupRemoteScript -Path $Path -Kind $Kind -OsType $osType
        if ([string]::IsNullOrWhiteSpace($script)) {
            return @{ Ok = $false; Message = "No cleanup script for '$Path'." }
        }
        if ($VerboseOutput) {
            Write-CleanupProgressMessage ("  Local command ({0}):" -f $osType) "DarkGray"
            Write-CleanupProgressMessage ("  $script") "DarkGray"
        }
        if ($osType -eq "Linux") {
            $result = Invoke-CapturedProcess "/bin/sh" ("-lc " + (Quote-ProcessArgument $script)) 120000
            if ($VerboseOutput) {
                if (-not [string]::IsNullOrWhiteSpace($result.StdOut)) {
                    Write-CleanupProgressMessage $result.StdOut
                }
                if (-not [string]::IsNullOrWhiteSpace($result.StdErr)) {
                    Write-CleanupProgressMessage $result.StdErr "Yellow"
                }
            }
            if ($result.ExitCode -ne 0) {
                $detail = (($result.StdErr + " " + $result.StdOut).Trim())
                return @{ Ok = $false; Message = if ([string]::IsNullOrWhiteSpace($detail)) { "cleanup exited $($result.ExitCode)" } else { $detail } }
            }
            return @{ Ok = $true; Message = "" }
        }
        Invoke-Expression $script
        return @{ Ok = $true; Message = "" }
    } catch {
        return @{ Ok = $false; Message = $_.Exception.Message }
    }
}

function Invoke-RemoteCleanupTarget {
    param(
        [object]$Owner,
        [string]$Path,
        [string]$Kind,
        [string]$OsType,
        [switch]$VerboseOutput
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return @{ Ok = $false; Message = "Path is blank." }
    }
    $remote = Get-TargetCleanupRemoteScript -Path $Path -Kind $Kind -OsType $OsType
    if ([string]::IsNullOrWhiteSpace($remote)) {
        return @{ Ok = $false; Message = "No cleanup script for '$Path'." }
    }
    $sshParts = New-RemoteSshArguments $Owner
    foreach ($token in @(Get-RemoteExecCommandParts -OsType $OsType -RemoteScript $remote)) {
        [void]$sshParts.Add($token)
    }
    if ($VerboseOutput) {
        Write-CleanupProgressMessage ("  ssh {0}" -f ($sshParts -join " ")) "DarkGray"
    }
    $result = Invoke-CapturedProcess "ssh.exe" ($sshParts -join " ") 120000
    if ($VerboseOutput) {
        if (-not [string]::IsNullOrWhiteSpace($result.StdOut)) {
            Write-CleanupProgressMessage $result.StdOut
        }
        if (-not [string]::IsNullOrWhiteSpace($result.StdErr)) {
            Write-CleanupProgressMessage $result.StdErr "Yellow"
        }
    }
    if ($result.ExitCode -ne 0) {
        $detail = (($result.StdErr + " " + $result.StdOut).Trim())
        return @{ Ok = $false; Message = if ([string]::IsNullOrWhiteSpace($detail)) { "ssh exited $($result.ExitCode)" } else { $detail } }
    }
    return @{ Ok = $true; Message = "" }
}

function Invoke-CleanupTargets {
    param(
        [object]$Owner,
        [object[]]$Targets,
        [switch]$VerboseOutput
    )
    $cleaned = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]
    $errors = New-Object System.Collections.Generic.List[string]
    $hostName = [string](Get-PropertyValue $Owner "Host" "localhost")
    $osType = [string](Get-PropertyValue $Owner "OsType" (Get-LocalHostOsType))
    if ($VerboseOutput) {
        Write-CleanupProgressMessage ("Host {0} ({1})" -f $hostName, $osType) "Cyan"
    }
    foreach ($target in @(Get-SelectedTargetEntries $Targets)) {
        $kind = [string](Get-PropertyValue $target "Kind" "")
        $path = [string](Get-PropertyValue $target "Target" "")
        if (-not (Test-TargetSupportsCleanup $target)) {
            if (-not [string]::IsNullOrWhiteSpace($path)) {
                [void]$skipped.Add(("{0} ({1})" -f $path, $kind))
                if ($VerboseOutput) {
                    Write-CleanupProgressMessage ("Skipping {0} ({1}) - filesystem only" -f $path, $kind) "DarkGray"
                }
            }
            continue
        }
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }
        if ($VerboseOutput) {
            Write-CleanupProgressMessage ""
            Write-CleanupProgressMessage ("Cleaning contents inside {0}" -f $path) "Yellow"
        }
        if (Test-HostLooksLocal $hostName) {
            $result = Remove-LocalCleanupTarget -Path $path -Kind $kind -VerboseOutput:$VerboseOutput
        } else {
            $result = Invoke-RemoteCleanupTarget -Owner $Owner -Path $path -Kind $kind -OsType $osType -VerboseOutput:$VerboseOutput
        }
        if ($result.Ok) {
            [void]$cleaned.Add(("{0} ({1})" -f $path, $kind))
            if ($VerboseOutput) {
                Write-CleanupProgressMessage "  [OK]" "Green"
            }
        } else {
            [void]$errors.Add(("{0}: {1}" -f $path, [string]$result.Message))
            if ($VerboseOutput) {
                Write-CleanupProgressMessage ("  [FAIL] {0}" -f [string]$result.Message) "Red"
            }
        }
    }
    return @{
        Cleaned = @($cleaned)
        Skipped = @($skipped)
        Errors = @($errors)
    }
}

function New-LocalHostCleanupOwner {
    return [pscustomobject]@{
        Host = "localhost"
        OsType = Get-LocalHostOsType
    }
}

function New-SlaveCleanupOwnerFromRow {
    param($Row)
    Capture-Settings
    return [pscustomobject]@{
        Host = [string]$Row.Cells["Host"].Value
        OsType = [string]$Row.Cells["OsType"].Value
        User = [string]$Row.Cells["User"].Value
        SshAlias = [string]$Row.Cells["SshAlias"].Value
        PrivateKey = [string](Get-PropertyValue $script:Settings "PrivateKey" "")
    }
}

function Update-CleanupUiState {
    # Refresh Clean button enabled/grey styling after target selection changes.
    if ($null -ne $script:SlaveGrid) {
        $script:SlaveGrid.Invalidate()
    }
}

function Invoke-SlaveTargetCleanBackgroundWork {
    param([hashtable]$Context)
    if ([bool](Get-PropertyValue $Context "ShowCleanupWindow" $false)) {
        return Invoke-CleanupTargetsInVisibleWindow `
            -Owner $Context.Owner `
            -Targets $Context.Targets `
            -Label ([string](Get-PropertyValue $Context "HostName" "slave"))
    }
    Invoke-CleanupTargets -Owner $Context.Owner -Targets $Context.Targets
}

function Complete-SlaveTargetCleanBackgroundWork {
    param(
        $Result,
        $ErrorMessage,
        $Context
    )
    if ($null -ne $script:SlaveGrid -and $Context.RowIndex -ge 0 -and $Context.RowIndex -lt $script:SlaveGrid.Rows.Count) {
        $row = $script:SlaveGrid.Rows[$Context.RowIndex]
        if ($null -ne $row -and -not $row.IsNewRow) {
            $state = Get-SlaveRowState $row
            $state["CleanInFlight"] = $false
        }
    }
    if ($null -ne $ErrorMessage) {
        Show-Warning $ErrorMessage
        return
    }
    if ($null -eq $Result) {
        return
    }
    $errors = @(Get-PropertyValue $Result "Errors" @())
    $cleaned = @(Get-PropertyValue $Result "Cleaned" @())
    $skipped = @(Get-PropertyValue $Result "Skipped" @())
    if ($errors.Count -gt 0) {
        Show-Warning (("Clean finished with errors for {0}:" -f $Context.HostName) + [Environment]::NewLine + ($errors -join [Environment]::NewLine))
    }
    Write-DebugLog ("Slave clean finished for host={0}: cleaned={1} skipped={2} errors={3}" -f $Context.HostName, $cleaned.Count, $skipped.Count, $errors.Count)
}

function Test-SlaveRowCleanEnabled {
    param($Row)
    if ($null -eq $Row -or $Row.IsNewRow) {
        return $false
    }
    # Per-row only: Clean must work for this slave's selected filesystem
    # anchors even when no slaves are Enabled/Ready for the current run yet.
    return (@(Get-CleanupEligibleTargets (Get-SlaveRowTargets $Row)).Count -gt 0)
}

function Start-SlaveTargetClean {
    param($Row)
    if ($null -eq $Row -or $Row.IsNewRow) {
        return
    }
    $eligible = @(Get-CleanupEligibleTargets (Get-SlaveRowTargets $Row))
    if ($eligible.Count -eq 0) {
        Show-Warning "No selected filesystem targets to clean on this host. Browse and tick Use on a filesystem anchor first."
        return
    }
    $state = Get-SlaveRowState $Row
    if ([bool](Get-PropertyValue $state "CleanInFlight" $false)) {
        Show-Warning "Clean is already running for this host."
        return
    }
    $hostLabel = [string]$Row.Cells["Host"].Value
    $targetList = @($eligible | ForEach-Object { [string](Get-PropertyValue $_ "Target" "") } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $confirmMsg = ("Delete ALL contents of these filesystem anchors on {0}?`n`n{1}`n`nThis cannot be undone." -f $hostLabel, ($targetList -join [Environment]::NewLine))
    if (-not (Ask-YesNo $confirmMsg "Confirm Clean")) {
        return
    }
    $state["CleanInFlight"] = $true
    $context = @{
        RowIndex = $Row.Index
        HostName = [string]$Row.Cells["Host"].Value
        Owner = New-SlaveCleanupOwnerFromRow $Row
        Targets = @(Get-SlaveRowTargets $Row)
        ShowCleanupWindow = $true
    }
    Write-AppLog ("Clean started for host={0} row={1} targets={2}" -f $context.HostName, $context.RowIndex, $eligible.Count) "INFO"
    try {
        Start-BackgroundUiWork `
            -Owner $script:SlaveGrid `
            -Context $context `
            -CommandName "Invoke-SlaveTargetCleanBackgroundWork" `
            -OnCompleteCommandName "Complete-SlaveTargetCleanBackgroundWork"
    } catch {
        $state["CleanInFlight"] = $false
        Write-AppLog ("Clean failed to start for host={0}: {1}" -f $context.HostName, $_.Exception.Message) "ERROR" $_.Exception
        Show-Warning ("Clean failed to start: " + $_.Exception.Message)
    }
}
