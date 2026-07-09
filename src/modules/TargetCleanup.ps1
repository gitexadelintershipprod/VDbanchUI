function Test-TargetSupportsCleanup {
    param([object]$Target)
    $kind = [string](Get-PropertyValue $Target "Kind" "")
    return ($kind -eq "Filesystem")
}

function Test-CleanupUiEnabled {
    $resolved = Resolve-RunTestKind
    return ([string]$resolved.TestKind -eq "Filesystem")
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
        [string]$Kind
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
        if ($osType -eq "Linux") {
            $result = Invoke-CapturedProcess "/bin/sh" ("-lc " + (Quote-ProcessArgument $script)) 120000
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
        [string]$OsType
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
    $result = Invoke-CapturedProcess "ssh.exe" ($sshParts -join " ") 120000
    if ($result.ExitCode -ne 0) {
        $detail = (($result.StdErr + " " + $result.StdOut).Trim())
        return @{ Ok = $false; Message = if ([string]::IsNullOrWhiteSpace($detail)) { "ssh exited $($result.ExitCode)" } else { $detail } }
    }
    return @{ Ok = $true; Message = "" }
}

function Invoke-CleanupTargets {
    param(
        [object]$Owner,
        [object[]]$Targets
    )
    $cleaned = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]
    $errors = New-Object System.Collections.Generic.List[string]
    $hostName = [string](Get-PropertyValue $Owner "Host" "localhost")
    $osType = [string](Get-PropertyValue $Owner "OsType" (Get-LocalHostOsType))
    foreach ($target in @(Get-SelectedTargetEntries $Targets)) {
        $kind = [string](Get-PropertyValue $target "Kind" "")
        $path = [string](Get-PropertyValue $target "Target" "")
        if (-not (Test-TargetSupportsCleanup $target)) {
            if (-not [string]::IsNullOrWhiteSpace($path)) {
                [void]$skipped.Add(("{0} ({1})" -f $path, $kind))
            }
            continue
        }
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }
        if (Test-HostLooksLocal $hostName) {
            $result = Remove-LocalCleanupTarget -Path $path -Kind $kind
        } else {
            $result = Invoke-RemoteCleanupTarget -Owner $Owner -Path $path -Kind $kind -OsType $osType
        }
        if ($result.Ok) {
            [void]$cleaned.Add(("{0} ({1})" -f $path, $kind))
        } else {
            [void]$errors.Add(("{0}: {1}" -f $path, [string]$result.Message))
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
    Update-LocalHostCleanButtonState
    if ($null -ne $script:SlaveGrid) {
        $script:SlaveGrid.Invalidate()
    }
}

function Invoke-LocalHostTargetCleanBackgroundWork {
    param([hashtable]$Context)
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
    if ($errors.Count -gt 0) {
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
    }
    Start-BackgroundUiWork `
        -Owner $script:LocalHostTab `
        -Context $context `
        -CommandName "Invoke-LocalHostTargetCleanBackgroundWork" `
        -OnCompleteCommandName "Complete-LocalHostTargetCleanBackgroundWork"
}

function Invoke-SlaveTargetCleanBackgroundWork {
    param([hashtable]$Context)
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
            $state.CleanInFlight = $false
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
        Show-Warning (("Clean failed for {0}:" -f $Context.HostName) + [Environment]::NewLine + ($errors -join [Environment]::NewLine))
    }
    Write-DebugLog ("Slave clean finished for host={0}: cleaned={1} skipped={2} errors={3}" -f $Context.HostName, $cleaned.Count, $skipped.Count, $errors.Count)
}

function Test-SlaveRowCleanEnabled {
    param($Row)
    if (-not (Test-CleanupUiEnabled)) {
        return $false
    }
    if ($null -eq $Row -or $Row.IsNewRow) {
        return $false
    }
    return (@(Get-CleanupEligibleTargets (Get-SlaveRowTargets $Row)).Count -gt 0)
}

function Start-SlaveTargetClean {
    param($Row)
    if (-not (Test-SlaveRowCleanEnabled $Row)) {
        return
    }
    $state = Get-SlaveRowState $Row
    if ([bool]$state.CleanInFlight) {
        return
    }
    $state.CleanInFlight = $true
    $context = @{
        RowIndex = $Row.Index
        HostName = [string]$Row.Cells["Host"].Value
        Owner = New-SlaveCleanupOwnerFromRow $Row
        Targets = @(Get-SlaveRowTargets $Row)
    }
    Write-DebugLog ("Clean started for host={0} row={1}" -f $context.HostName, $context.RowIndex)
    Start-BackgroundUiWork `
        -Owner $script:SlaveGrid `
        -Context $context `
        -CommandName "Invoke-SlaveTargetCleanBackgroundWork" `
        -OnCompleteCommandName "Complete-SlaveTargetCleanBackgroundWork"
}
