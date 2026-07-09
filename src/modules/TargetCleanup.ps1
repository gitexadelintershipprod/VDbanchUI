function Test-TargetSupportsCleanup {
    param([object]$Target)
    $kind = [string](Get-PropertyValue $Target "Kind" "")
    return ($kind -eq "Filesystem")
}

if (-not (Get-Variable -Name CleanupUiEnabledCache -Scope Script -ErrorAction SilentlyContinue)) {
    $script:CleanupUiEnabledCache = $false
}
if (-not (Get-Variable -Name CleanupUiStateInitialized -Scope Script -ErrorAction SilentlyContinue)) {
    $script:CleanupUiStateInitialized = $false
}

function Test-CleanupUiEnabled {
    if ($script:CleanupUiStateInitialized) {
        return [bool]$script:CleanupUiEnabledCache
    }
    $resolved = Resolve-RunTestKind
    return ([string]$resolved.TestKind -eq "Filesystem")
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
        return "rm -rf -- $quotedPath/* $quotedPath/.[!.]* $quotedPath/..?* 2>/dev/null || true"
    }
    $quotedPath = Convert-ToPowerShellSingleQuoted $Path
    return @"
if (Test-Path -LiteralPath $quotedPath) {
    Get-ChildItem -LiteralPath $quotedPath -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
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

function Update-LocalHostCleanButtonState {
    if ($null -eq $script:LocalHostCleanButton) {
        return
    }
    $enabled = Test-CleanupUiEnabled
    $script:LocalHostCleanButton.Enabled = $enabled
    if ($enabled) {
        $script:LocalHostCleanButton.ForeColor = [System.Drawing.SystemColors]::ControlText
    } else {
        $script:LocalHostCleanButton.ForeColor = [System.Drawing.Color]::DimGray
    }
}

function Update-CleanupUiState {
    $resolved = Resolve-RunTestKind
    $script:CleanupUiEnabledCache = ([string]$resolved.TestKind -eq "Filesystem")
    $script:CleanupUiStateInitialized = $true
    Update-LocalHostCleanButtonState
    if ($null -ne $script:SlaveGrid) {
        $script:SlaveGrid.Invalidate()
    }
}

function Invoke-LocalHostTargetCleanBackgroundWork {
    param([hashtable]$Context)
    if ([bool](Get-PropertyValue $Context "ShowCleanupWindow" $false)) {
        return Invoke-CleanupTargetsInVisibleWindow `
            -Owner $Context.Owner `
            -Targets $Context.Targets `
            -Label "Local Host"
    }
    Invoke-CleanupTargets -Owner $Context.Owner -Targets $Context.Targets
}

function Complete-LocalHostTargetCleanBackgroundWork {
    param(
        $Result,
        $ErrorMessage,
        $Context
    )
    $script:LocalHostCleanInFlight = $false
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
    $showedWindow = [bool](Get-PropertyValue $Context "ShowCleanupWindow" $false)
    if (-not $showedWindow -and $errors.Count -gt 0) {
        Show-Warning (("Clean failed for one or more targets:" + [Environment]::NewLine + ($errors -join [Environment]::NewLine)))
    }
    Write-DebugLog ("Local host clean finished: cleaned={0} skipped={1} errors={2}" -f $cleaned.Count, $skipped.Count, $errors.Count)
}

function Start-LocalHostTargetClean {
    if (-not (Test-CleanupUiEnabled)) {
        return
    }
    if ($script:LocalHostCleanInFlight) {
        return
    }
    Capture-LocalHostTargets
    $selected = @(Get-CleanupEligibleTargets @(Get-LocalHostTargetStore))
    if ($selected.Count -eq 0) {
        Show-Warning "No selected filesystem targets to clean on Local Host."
        return
    }
    $script:LocalHostCleanInFlight = $true
    $context = @{
        Owner = New-LocalHostCleanupOwner
        Targets = @(Get-LocalHostTargetStore)
        ShowCleanupWindow = $true
    }
    Start-BackgroundUiWork `
        -Owner $script:LocalHostTab `
        -Context $context `
        -CommandName "Invoke-LocalHostTargetCleanBackgroundWork" `
        -OnCompleteCommandName "Complete-LocalHostTargetCleanBackgroundWork"
}
