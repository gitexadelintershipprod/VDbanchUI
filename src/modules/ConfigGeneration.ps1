function Definition-AppliesToKind {
    param(
        [object]$Definition,
        [string]$TestKind
    )
    $applies = [string](Get-PropertyValue $Definition "AppliesTo" "both")
    if ($applies -eq "both") {
        return $true
    }
    if ($TestKind -eq "Raw/block" -and $applies -eq "raw") {
        return $true
    }
    if ($TestKind -eq "Filesystem" -and $applies -eq "fs") {
        return $true
    }
    return $false
}

function Add-FsdOpenflagsForOsType {
    param(
        [System.Collections.Generic.List[string]]$Parts,
        [string]$OsType
    )
    if (-not (Test-ProfileBypassOsCacheEnabled $script:CurrentProfile)) {
        return
    }
    [void]$Parts.Add(("openflags={0}" -f (Get-VdbenchOpenflagsForOsType $OsType)))
}

function Add-SdOpenflagsForOsType {
    param(
        [System.Collections.Generic.List[string]]$Parts,
        [string]$OsType
    )
    if (-not (Test-ProfileRawBypassOsCacheEnabled $script:CurrentProfile)) {
        return
    }
    [void]$Parts.Add(("openflags={0}" -f (Get-VdbenchOpenflagsForOsType $OsType)))
}

function Get-WorkloadSeekpctConfigValue {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }
    switch ($Value.Trim().ToLowerInvariant()) {
        "random" { return "random" }
        "sequential" { return "seq" }
        "seq" { return "seq" }
        "0" { return "seq" }
        "100" { return "random" }
        default {
            $parsed = 0.0
            if ([double]::TryParse($Value, [ref]$parsed)) {
                if ($parsed -ge 50) {
                    return "random"
                }
                return "seq"
            }
            return $Value
        }
    }
}

function Add-EnabledParameter {
    param(
        [System.Collections.Generic.List[string]]$Parts,
        [System.Collections.Generic.List[string]]$Disabled,
        [object]$Definition,
        [string]$ExpectedLine
    )
    $line = [string]$Definition.Line
    if ($line -ne $ExpectedLine) {
        return
    }
    $key = [string]$Definition.Key
    $value = Get-ProfileParamValue $script:CurrentProfile $key ""
    if ($key -eq "fsd.files") {
        $value = "1"
    } elseif ($key -eq "fsd.shared") {
        $value = "no"
    } elseif ($key -eq "fwd.fileio") {
        if ([string]::IsNullOrWhiteSpace($value) -or $value -eq "random") {
            $value = "(random,shared)"
        }
    } elseif ($key -eq "workload.seekpct") {
        $value = Get-WorkloadSeekpctConfigValue $value
    }
    if ([string]::IsNullOrWhiteSpace($value)) {
        return
    }
    $name = [string]$Definition.VdbenchName
    if (@("fsd.files", "fsd.shared", "fwd.fileio") -contains $key) {
        [void]$Parts.Add(("{0}={1}" -f $name, $value))
        return
    }
    if (@("fsd.openflags", "fwd.openflags", "fsd.bypassOsCache", "storage.openflags", "storage.bypassOsCache") -contains $key) {
        return
    }
    if (Get-ProfileParamEnabled $script:CurrentProfile $key) {
        if ($value -eq "none" -and $name -eq "openflags") {
            return
        }
        [void]$Parts.Add(("{0}={1}" -f $name, $value))
    } else {
        [void]$Disabled.Add(("* disabled: {0}={1} ({2})" -f $name, $value, $Definition.Section))
    }
}

function Get-DefinitionsForLine {
    param(
        [string]$Line,
        [string]$TestKind
    )
    return @($script:Catalog | Where-Object { $_.Line -eq $Line -and (Definition-AppliesToKind $_ $TestKind) })
}

function Test-RawDeviceTarget {
    param([string]$Target)
    if ([string]::IsNullOrWhiteSpace($Target)) {
        return $false
    }
    $value = $Target.Trim()
    if ($value -match '^\\\\\.\\PhysicalDrive\d+$') {
        return $true
    }
    if ($value -match '^\\\\\.\\[A-Za-z]:$') {
        return $true
    }
    if ($value -match '^/dev/(sd|hd|xvd|nvme|dm-|mapper/)') {
        return $true
    }
    return $false
}

function Test-FilesystemRootTarget {
    param([string]$Target)
    if ([string]::IsNullOrWhiteSpace($Target)) {
        return $false
    }
    $value = $Target.Trim()
    if ($value -match '^[A-Za-z]:\\?$') {
        return $true
    }
    if ($value -eq "/" -or $value -eq "\\") {
        return $true
    }
    return $false
}

function Test-ParameterValueValid {
    param(
        [object]$Definition,
        [string]$Value
    )
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $true
    }
    $key = [string]$Definition.Key
    $numericKeys = @(
        "run.elapsed", "run.warmup", "run.interval",
        "storage.threads", "workload.threads", "workload.rdpct", "workload.skew",
        "workload.rhpct", "workload.whpct", "workload.priority", "workload.iorate",
        "common.threads",
        "fsd.depth", "fsd.width", "fsd.files", "fwd.threads", "fwd.rdpct", "fwd.skew", "fwd.stopafter"
    )
    if ($numericKeys -contains $key) {
        $parsed = 0.0
        if (-not [double]::TryParse($Value, [ref]$parsed)) {
            return $false
        }
        if ($parsed -lt 0) {
            return $false
        }
    }
    if ($key -eq "run.iorate" -or $key -eq "run.fwdrate" -or $key -eq "common.rate") {
        if ($Value -ne "max") {
            $parsed = 0.0
            if (-not [double]::TryParse($Value, [ref]$parsed) -or $parsed -le 0) {
                return $false
            }
        }
    }
    $type = [string](Get-PropertyValue $Definition "Type" "text")
    if ($type -eq "dropdown") {
        $options = @($Definition.Options | ForEach-Object { [string]$_ })
        if ($options.Count -gt 0 -and ($options -notcontains $Value)) {
            return $false
        }
    }
    return $true
}

function Add-ParameterValidationWarnings {
    param(
        [System.Collections.Generic.List[string]]$Warnings,
        [string]$TestKind
    )
    foreach ($def in @($script:Catalog | Where-Object { Definition-AppliesToKind $_ $TestKind })) {
        if ([bool](Get-PropertyValue $def "EditorHidden" $false)) {
            continue
        }
        $key = [string]$def.Key
        if (-not (Get-ProfileParamEnabled $script:CurrentProfile $key)) {
            continue
        }
        $value = Get-ProfileParamValue $script:CurrentProfile $key ""
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }
        if (-not (Test-ParameterValueValid $def $value)) {
            [void]$Warnings.Add(("Invalid value for {0}: '{1}'" -f $def.Label, $value))
        }
    }
}

function Add-TargetRiskWarnings {
    param(
        [System.Collections.Generic.List[string]]$Warnings,
        [string]$TestKind,
        [bool]$Distributed
    )
    if ($TestKind -eq "Raw/block") {
        if ($Distributed) {
            foreach ($slave in @(Get-EnabledSlaves)) {
                foreach ($target in @(Get-SelectedTargetEntries @(Get-PropertyValue $slave "Targets" @()) "raw")) {
                    $targetPath = [string](Get-PropertyValue $target "Target" "")
                    if (Test-RawDeviceTarget $targetPath) {
                        [void]$Warnings.Add(("RISK: slave '{0}' target '{1}' looks like a raw physical device." -f $slave.Name, $targetPath))
                    }
                }
            }
        } else {
            foreach ($target in @(Get-SelectedTargetEntries @(Get-LocalHostTargetStore) "raw")) {
                $targetPath = [string](Get-PropertyValue $target "Target" "")
                if (Test-RawDeviceTarget $targetPath) {
                    [void]$Warnings.Add(("RISK: local target '{0}' looks like a raw physical device." -f $targetPath))
                }
            }
        }
    } elseif ($TestKind -eq "Filesystem") {
        $format = Get-ProfileParamValue $script:CurrentProfile "run.format" "no"
        if (Get-ProfileParamEnabled $script:CurrentProfile "run.format" -and $format -ne "no") {
            [void]$Warnings.Add(("RISK: filesystem format is enabled with value '{0}'." -f $format))
        }
        if ($Distributed) {
            foreach ($slave in @(Get-EnabledSlaves)) {
                foreach ($target in @(Get-SelectedTargetEntries @(Get-PropertyValue $slave "Targets" @()) "fs")) {
                    $targetPath = [string](Get-PropertyValue $target "Target" "")
                    if (Test-FilesystemRootTarget $targetPath) {
                        [void]$Warnings.Add(("RISK: slave '{0}' filesystem target '{1}' looks like a root drive/path." -f $slave.Name, $targetPath))
                    }
                }
            }
        } else {
            foreach ($target in @(Get-SelectedTargetEntries @(Get-LocalHostTargetStore) "fs")) {
                $targetPath = [string](Get-PropertyValue $target "Target" "")
                if (Test-FilesystemRootTarget $targetPath) {
                    [void]$Warnings.Add(("RISK: filesystem anchor '{0}' looks like a root drive/path." -f $targetPath))
                }
            }
        }
    }
}

function Get-EnabledSlaves {
    Capture-SlaveGrid
    return @($script:Slaves | Where-Object { [bool]$_.Enabled -and (Test-SlaveReadinessReady $_) })
}

function Get-SelectedRunTargets {
    if (Is-DistributedMode) {
        $targets = @()
        foreach ($slave in @(Get-EnabledSlaves)) {
            $targets += @(Get-SelectedTargetEntries @(Get-PropertyValue $slave "Targets" @()))
        }
        return @($targets)
    }
    return @(Get-SelectedTargetEntries @(Get-LocalHostTargetStore))
}

function Resolve-RunTestKind {
    $categories = @()
    foreach ($target in @(Get-SelectedRunTargets)) {
        $category = Get-TargetCategory $target
        if ($categories -notcontains $category) {
            $categories += $category
        }
    }
    if ($categories.Count -eq 0) {
        $resolved = [pscustomobject]@{
            TestKind = $null
            Error = "No targets selected for the current run mode."
        }
        Write-DebugLog ("Resolve-RunTestKind: testKind=; error={0}" -f $resolved.Error)
        return $resolved
    }
    if ($categories.Count -gt 1) {
        $resolved = [pscustomobject]@{
            TestKind = $null
            Error = "BLOCKER: mixed raw and filesystem targets in the same run."
        }
        Write-DebugLog ("Resolve-RunTestKind: testKind=; error={0}" -f $resolved.Error)
        return $resolved
    }
    if ($categories[0] -eq "fs") {
        $resolved = [pscustomobject]@{
            TestKind = "Filesystem"
            Error = $null
        }
        Write-DebugLog ("Resolve-RunTestKind: testKind={0}" -f $resolved.TestKind)
        return $resolved
    }
    $resolved = [pscustomobject]@{
        TestKind = "Raw/block"
        Error = $null
    }
    Write-DebugLog ("Resolve-RunTestKind: testKind={0}" -f $resolved.TestKind)
    return $resolved
}

function Get-ConfigTargetCategory {
    param([string]$TestKind)
    if ($TestKind -eq "Filesystem") {
        return "fs"
    }
    return "raw"
}

function Add-TargetSelectionWarnings {
    param(
        [System.Collections.Generic.List[string]]$Warnings,
        [string]$TestKind,
        [bool]$Distributed
    )
    $category = Get-ConfigTargetCategory $TestKind
    if ($Distributed) {
        Capture-SlaveGrid
        foreach ($slave in @(Get-EnabledSlaves)) {
            $selected = @(Get-SelectedTargetEntries @(Get-PropertyValue $slave "Targets" @()))
            if ($selected.Count -eq 0) {
                [void]$Warnings.Add(("BLOCKER: enabled slave '{0}' has no selected target." -f $slave.Name))
                continue
            }
            foreach ($target in $selected) {
                $targetCategory = Get-TargetCategory $target
                if ($targetCategory -ne $category) {
                    [void]$Warnings.Add(("BLOCKER: slave '{0}' target '{1}' is {2}, but the profile expects {3} targets." -f $slave.Name, $target.Target, $targetCategory, $category))
                }
            }
        }
        foreach ($slave in @($script:Slaves)) {
            if (-not [bool](Get-PropertyValue $slave "Enabled" $false)) {
                continue
            }
            if (-not (Test-SlaveReadinessReady $slave)) {
                [void]$Warnings.Add(("BLOCKER: slave '{0}' is enabled but readiness is '{1}'." -f $slave.Name, (Resolve-SlaveReadinessStatus $slave)))
            }
        }
    } else {
        $selected = @(Get-SelectedTargetEntries @(Get-LocalHostTargetStore))
        if ($selected.Count -eq 0) {
            [void]$Warnings.Add("BLOCKER: local run has no selected target in the Local Host tab.")
            return
        }
        foreach ($target in $selected) {
            $targetCategory = Get-TargetCategory $target
            if ($targetCategory -ne $category) {
                [void]$Warnings.Add(("BLOCKER: local target '{0}' is {1}, but the profile expects {2} targets." -f $target.Target, $targetCategory, $category))
            }
        }
    }
}

function Add-ManualLines {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [System.Collections.Generic.List[string]]$Disabled
    )
    $active = [string](Get-PropertyValue $script:CurrentProfile "AdvancedActive" "")
    if (-not [string]::IsNullOrWhiteSpace($active)) {
        [void]$Lines.Add("")
        [void]$Lines.Add("* Manual active lines")
        foreach ($line in ($active -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                [void]$Lines.Add($line)
            }
        }
    }
    $inactive = [string](Get-PropertyValue $script:CurrentProfile "AdvancedDisabled" "")
    if (-not [string]::IsNullOrWhiteSpace($inactive)) {
        foreach ($line in ($inactive -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                [void]$Disabled.Add(("* disabled manual: {0}" -f $line))
            }
        }
    }
}

function Build-VdbenchConfig {
    param([switch]$UseDraftProfile)

    Capture-Settings
    Capture-SlaveGrid
    Capture-ProfileEditor
    Capture-LocalHostTargets

    $savedProfile = $script:CurrentProfile
    if ($UseDraftProfile) {
        $profile = $script:CurrentProfile
        if ($null -eq $profile) {
            throw "No draft profile is available for preview."
        }
        Sync-CommonProfileParameters $profile
    } else {
        Sync-RunProfileFromSelector
        $profile = Get-RunProfile
        if ($null -eq $profile) {
            throw "No profile selected for run."
        }
        Sync-CommonProfileParameters $profile
    }
    $script:CurrentProfile = $profile

    Apply-FilesystemProfileFixedDefaults $script:CurrentProfile
    Apply-RawProfileFixedDefaults $script:CurrentProfile

    try {
        $resolved = Resolve-RunTestKind
        $testKind = [string]$resolved.TestKind
        $distributed = Is-DistributedMode
        $warnings = New-Object System.Collections.Generic.List[string]
        $disabled = New-Object System.Collections.Generic.List[string]
        $lines = New-Object System.Collections.Generic.List[string]

        if (-not [string]::IsNullOrWhiteSpace([string]$resolved.Error)) {
            if ([string]$resolved.Error -like "BLOCKER:*") {
                [void]$warnings.Add([string]$resolved.Error)
            } else {
                [void]$warnings.Add(("BLOCKER: {0}" -f $resolved.Error))
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($testKind)) {
            foreach ($def in @($script:Catalog | Where-Object { Definition-AppliesToKind $_ $testKind })) {
                if ([bool](Get-PropertyValue $def "EditorHidden" $false)) {
                    continue
                }
                $required = [bool](Get-PropertyValue $def "Required" $false)
                if (-not $required) {
                    continue
                }
                $key = [string]$def.Key
                if (@("storage.lun", "fsd.anchor") -contains $key) {
                    continue
                }
                $value = Get-ProfileParamValue $script:CurrentProfile $key ""
                if (-not (Get-ProfileParamEnabled $script:CurrentProfile $key)) {
                    [void]$warnings.Add(("Required parameter is disabled: {0}" -f $def.Label))
                } elseif ([string]::IsNullOrWhiteSpace($value)) {
                    [void]$warnings.Add(("Required parameter is empty: {0}" -f $def.Label))
                }
            }
            Add-ParameterValidationWarnings $warnings $testKind
            Add-TargetSelectionWarnings $warnings $testKind $distributed
            Add-TargetRiskWarnings $warnings $testKind $distributed
        }

        [void]$lines.Add("* Generated by Vdbench UI")
        [void]$lines.Add(("* GeneratedAt={0}" -f (Get-Date).ToString("o")))
        [void]$lines.Add(("* Profile={0}" -f $script:CurrentProfile.Name))
        [void]$lines.Add(("* Mode={0}" -f (Get-Mode)))
        if (-not [string]::IsNullOrWhiteSpace($testKind)) {
            [void]$lines.Add(("* TestKind={0}" -f $testKind))
        }
        [void]$lines.Add("")

        if ($testKind -eq "Filesystem") {
            $createAnchorsValue = Get-ProfileParamValue $script:CurrentProfile "run.createAnchors" "yes"
            if (Get-ProfileParamEnabled $script:CurrentProfile "run.createAnchors") {
                if ($createAnchorsValue -eq "no") {
                    [void]$lines.Add("create_anchors=no")
                } else {
                    [void]$lines.Add("create_anchors=yes")
                }
            } elseif ($createAnchorsValue -eq "no") {
                [void]$disabled.Add("* disabled: create_anchors=no (General)")
            } else {
                [void]$disabled.Add("* disabled: create_anchors=yes (General)")
            }
            [void]$lines.Add("")
        }

    if ($distributed) {
        $slaves = @(Get-EnabledSlaves)
        if ($slaves.Count -eq 0) {
            [void]$warnings.Add("Master/Slave mode is enabled but no enabled slaves exist.")
        }
        [void]$lines.Add("* Host definitions")
        $hostDefaults = New-Object System.Collections.Generic.List[string]
        [void]$hostDefaults.Add("hd=default")
        $slaveShell = [string](Get-PropertyValue $script:Settings "SlaveShell" "ssh")
        if (-not [string]::IsNullOrWhiteSpace($slaveShell)) {
            [void]$hostDefaults.Add(("shell={0}" -f $slaveShell))
        }
        [void]$lines.Add(($hostDefaults -join ","))
        foreach ($slave in $slaves) {
            $name = [string]$slave.Name
            $hostName = [string]$slave.Host
            $slaveUser = [string](Get-PropertyValue $slave "User" "")
            $sshAlias = [string](Get-PropertyValue $slave "SshAlias" "")
            $vdPath = [string]$slave.VdbenchPath
            if ([string]::IsNullOrWhiteSpace($name)) {
                [void]$warnings.Add("Enabled slave with host '$hostName' has no Name.")
                continue
            }
            if ([string]::IsNullOrWhiteSpace($hostName)) {
                [void]$warnings.Add("Enabled slave '$name' has no Host.")
            }
            if ([string]::IsNullOrWhiteSpace($vdPath)) {
                [void]$warnings.Add("Enabled slave '$name' has no VdbenchPath.")
            }
            $systemName = $hostName
            if (-not [string]::IsNullOrWhiteSpace($sshAlias)) {
                $systemName = $sshAlias
            }
            $hostParts = New-Object System.Collections.Generic.List[string]
            [void]$hostParts.Add(("hd={0}" -f $name))
            [void]$hostParts.Add(("system={0}" -f $systemName))
            if (-not [string]::IsNullOrWhiteSpace($slaveUser)) {
                [void]$hostParts.Add(("user={0}" -f $slaveUser))
            }
            [void]$hostParts.Add(("vdbench={0}" -f $vdPath))
            [void]$lines.Add(($hostParts -join ","))
        }
        [void]$lines.Add("")
    }

    if ($testKind -eq "Raw/block") {
        $sdName = Get-ProfileParamValue $script:CurrentProfile "storage.name" "sd1"
        $wdName = Get-ProfileParamValue $script:CurrentProfile "workload.name" "wd1"
        $rdName = Get-ProfileParamValue $script:CurrentProfile "run.name" "rd1"

        [void]$lines.Add("* Storage definitions")
        if ($distributed) {
            $slaves = @(Get-EnabledSlaves)
            foreach ($slave in $slaves) {
                $safeName = ([string]$slave.Name) -replace "[^A-Za-z0-9_]", "_"
                $targets = @(Get-SelectedTargetEntries @(Get-PropertyValue $slave "Targets" @()) "raw")
                $targetIndex = 0
                foreach ($target in $targets) {
                    $targetIndex++
                    $parts = New-Object System.Collections.Generic.List[string]
                    [void]$parts.Add(("sd=sd_{0}_{1}" -f $safeName, $targetIndex))
                    [void]$parts.Add(("host={0}" -f $slave.Name))
                    [void]$parts.Add(("lun={0}" -f ([string]$target.Target)))
                    foreach ($def in Get-DefinitionsForLine "storage" $testKind) {
                        if ($def.Key -eq "storage.lun") {
                            continue
                        }
                        Add-EnabledParameter $parts $disabled $def "storage"
                    }
                    Add-SdOpenflagsForOsType $parts ([string]$slave.OsType)
                    [void]$lines.Add(($parts -join ","))
                }
            }
        } else {
            $targets = @(Get-SelectedTargetEntries @(Get-LocalHostTargetStore) "raw")
            $targetIndex = 0
            foreach ($target in $targets) {
                $targetIndex++
                $name = $sdName
                if ($targets.Count -gt 1) {
                    $name = ("{0}_{1}" -f $sdName, $targetIndex)
                }
                $parts = New-Object System.Collections.Generic.List[string]
                [void]$parts.Add(("sd={0}" -f $name))
                [void]$parts.Add(("lun={0}" -f ([string]$target.Target)))
                foreach ($def in Get-DefinitionsForLine "storage" $testKind) {
                    if ($def.Key -eq "storage.lun") {
                        continue
                    }
                    Add-EnabledParameter $parts $disabled $def "storage"
                }
                Add-SdOpenflagsForOsType $parts (Get-LocalHostOsType)
                [void]$lines.Add(($parts -join ","))
            }
        }
        [void]$lines.Add("")

        [void]$lines.Add("* Workload definitions")
        $wdParts = New-Object System.Collections.Generic.List[string]
        [void]$wdParts.Add(("wd={0}" -f $wdName))
        if ($distributed) {
            [void]$wdParts.Add("sd=sd*")
        } elseif (@(Get-SelectedTargetEntries @(Get-LocalHostTargetStore) "raw").Count -gt 1) {
            [void]$wdParts.Add("sd=sd*")
        } else {
            [void]$wdParts.Add(("sd={0}" -f $sdName))
        }
        foreach ($def in Get-DefinitionsForLine "workload" $testKind) {
            Add-EnabledParameter $wdParts $disabled $def "workload"
        }
        [void]$lines.Add(($wdParts -join ","))
        [void]$lines.Add("")

        [void]$lines.Add("* Run definition")
        $rdParts = New-Object System.Collections.Generic.List[string]
        [void]$rdParts.Add(("rd={0}" -f $rdName))
        [void]$rdParts.Add(("wd={0}" -f $wdName))
        foreach ($def in Get-DefinitionsForLine "run" $testKind) {
            Add-EnabledParameter $rdParts $disabled $def "run"
        }
        [void]$lines.Add(($rdParts -join ","))
    } else {
        $fsdName = Get-ProfileParamValue $script:CurrentProfile "fsd.name" "fsd1"
        $fwdName = Get-ProfileParamValue $script:CurrentProfile "fwd.name" "fwd1"
        $rdName = Get-ProfileParamValue $script:CurrentProfile "run.name" "rd1"

        [void]$lines.Add("* Filesystem definitions")
        if ($distributed) {
            $slaves = @(Get-EnabledSlaves)
            foreach ($slave in $slaves) {
                $safeName = ([string]$slave.Name) -replace "[^A-Za-z0-9_]", "_"
                $targets = @(Get-SelectedTargetEntries @(Get-PropertyValue $slave "Targets" @()) "fs")
                $targetIndex = 0
                foreach ($target in $targets) {
                    $targetIndex++
                    $parts = New-Object System.Collections.Generic.List[string]
                    [void]$parts.Add(("fsd=fsd_{0}_{1}" -f $safeName, $targetIndex))
                    [void]$parts.Add(("anchor={0}" -f ([string]$target.Target)))
                    Add-FsdOpenflagsForOsType $parts ([string]$slave.OsType)
                    foreach ($def in Get-DefinitionsForLine "fsd" $testKind) {
                        if ($def.Key -eq "fsd.anchor") {
                            continue
                        }
                        Add-EnabledParameter $parts $disabled $def "fsd"
                    }
                    [void]$lines.Add(($parts -join ","))
                }
            }
        } else {
            $targets = @(Get-SelectedTargetEntries @(Get-LocalHostTargetStore) "fs")
            $targetIndex = 0
            foreach ($target in $targets) {
                $targetIndex++
                $name = $fsdName
                if ($targets.Count -gt 1) {
                    $name = ("{0}_{1}" -f $fsdName, $targetIndex)
                }
                $parts = New-Object System.Collections.Generic.List[string]
                [void]$parts.Add(("fsd={0}" -f $name))
                [void]$parts.Add(("anchor={0}" -f ([string]$target.Target)))
                Add-FsdOpenflagsForOsType $parts (Get-LocalHostOsType)
                foreach ($def in Get-DefinitionsForLine "fsd" $testKind) {
                    if ($def.Key -eq "fsd.anchor") {
                        continue
                    }
                    Add-EnabledParameter $parts $disabled $def "fsd"
                }
                [void]$lines.Add(($parts -join ","))
            }
        }
        [void]$lines.Add("")

        [void]$lines.Add("* Filesystem workload")
        if ($distributed) {
            $slaves = @(Get-EnabledSlaves)
            foreach ($slave in $slaves) {
                $safeName = ([string]$slave.Name) -replace "[^A-Za-z0-9_]", "_"
                $targets = @(Get-SelectedTargetEntries @(Get-PropertyValue $slave "Targets" @()) "fs")
                $targetIndex = 0
                foreach ($target in $targets) {
                    $targetIndex++
                    $fsdId = ("fsd_{0}_{1}" -f $safeName, $targetIndex)
                    $fwdId = ("fwd_{0}_{1}" -f $safeName, $targetIndex)
                    $fwdParts = New-Object System.Collections.Generic.List[string]
                    [void]$fwdParts.Add(("fwd={0}" -f $fwdId))
                    [void]$fwdParts.Add(("fsd={0}" -f $fsdId))
                    [void]$fwdParts.Add(("host={0}" -f $slave.Name))
                    foreach ($def in Get-DefinitionsForLine "fwd" $testKind) {
                        Add-EnabledParameter $fwdParts $disabled $def "fwd"
                    }
                    [void]$lines.Add(($fwdParts -join ","))
                }
            }
        } else {
            $fwdParts = New-Object System.Collections.Generic.List[string]
            [void]$fwdParts.Add(("fwd={0}" -f $fwdName))
            if (@(Get-SelectedTargetEntries @(Get-LocalHostTargetStore) "fs").Count -gt 1) {
                [void]$fwdParts.Add("fsd=fsd*")
            } else {
                [void]$fwdParts.Add(("fsd={0}" -f $fsdName))
            }
            foreach ($def in Get-DefinitionsForLine "fwd" $testKind) {
                Add-EnabledParameter $fwdParts $disabled $def "fwd"
            }
            [void]$lines.Add(($fwdParts -join ","))
        }
        [void]$lines.Add("")

        [void]$lines.Add("* Run definition")
        $rdParts = New-Object System.Collections.Generic.List[string]
        [void]$rdParts.Add(("rd={0}" -f $rdName))
        if ($distributed) {
            [void]$rdParts.Add("fwd=fwd*")
        } else {
            [void]$rdParts.Add(("fwd={0}" -f $fwdName))
        }
        foreach ($def in Get-DefinitionsForLine "run" $testKind) {
            Add-EnabledParameter $rdParts $disabled $def "run"
        }
        [void]$lines.Add(($rdParts -join ","))
    }

    Add-ManualLines $lines $disabled

    if ([bool](Get-PropertyValue $script:Settings "CommentDisabledParameters" $true) -and $disabled.Count -gt 0) {
        [void]$lines.Add("")
        [void]$lines.Add("* Disabled parameters preserved by UI")
        foreach ($line in $disabled) {
            [void]$lines.Add($line)
        }
    }

    $masterBat = [string](Get-PropertyValue $script:Settings "MasterVdbenchBat" "")
    if ([string]::IsNullOrWhiteSpace($masterBat)) {
        [void]$warnings.Add("MasterVdbenchBat is empty.")
    } elseif (-not (Test-Path -LiteralPath $masterBat)) {
        [void]$warnings.Add("MasterVdbenchBat does not exist on this machine: $masterBat")
    }

    return [pscustomobject]@{
        Text = ($lines -join [Environment]::NewLine)
        Warnings = @($warnings)
        Disabled = @($disabled)
    }
    } finally {
        $script:CurrentProfile = $savedProfile
    }
}

function Refresh-ConfigPreview {
    if (-not $script:ConfigPreviewBox) {
        return
    }
    if ($script:RefreshingConfigPreview) {
        return
    }
    if ($null -eq (Get-RunProfile)) {
        $script:ConfigPreviewBox.Text = "Select a run profile to preview config."
        return
    }
    $script:RefreshingConfigPreview = $true
    try {
        $built = Build-VdbenchConfig
        $script:LastBuiltConfig = $built
        $prefix = ""
        if ($built.Warnings.Count -gt 0) {
            $prefix = ("* WARNINGS" + [Environment]::NewLine)
            foreach ($warning in $built.Warnings) {
                $prefix += ("* - " + $warning + [Environment]::NewLine)
            }
            $prefix += [Environment]::NewLine
        }
        $script:ConfigPreviewBox.Text = $prefix + $built.Text
    } catch {
        $script:ConfigPreviewBox.Text = "Preview error: " + $_.Exception.Message
        Write-AppLog ("Config preview error: {0}" -f $_.Exception.Message) "ERROR"
    } finally {
        $script:RefreshingConfigPreview = $false
    }
}

function Get-CleanConfigText {
    param([object]$BuiltConfig = $null)
    if ($null -eq $BuiltConfig) {
        Capture-Settings
        Capture-SlaveGrid
        Capture-ProfileEditor
        $BuiltConfig = Build-VdbenchConfig
    }
    return [string]$BuiltConfig.Text
}

function Select-MainTab {
    param([string]$TabTitle)
    if ($null -eq $script:MainTabControl) {
        return
    }
    foreach ($page in $script:MainTabControl.TabPages) {
        $fullTitle = Get-MainTabFullTitle $page
        if ($fullTitle -eq $TabTitle -or [string]$page.Text -eq $TabTitle) {
            $script:MainTabControl.SelectedTab = $page
            return
        }
    }
}

function Update-RunModeIndicator {
    if ($null -eq $script:RunModeIndicator) {
        return
    }
    $mode = Get-Mode
    $profileName = Get-RunProfileName
    $resolved = Resolve-RunTestKind
    $testKindText = "(pending targets)"
    if (-not [string]::IsNullOrWhiteSpace([string]$resolved.TestKind)) {
        $testKindText = [string]$resolved.TestKind
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$resolved.Error)) {
        $testKindText = [string]$resolved.Error
    }
    $script:RunModeIndicator.Text = ("Profile: {0}  |  Test kind: {1}" -f $profileName, $testKindText)
    Update-RunModeTabs
    Refresh-RunTabSummary
}

function Resize-RunTabSummaryArea {
    if ($null -eq $script:RunTabLayout) {
        return
    }
    $boxes = @()
    if ($null -ne $script:RunSummaryBox) {
        $boxes += $script:RunSummaryBox
    }
    if ($null -ne $script:RunResultSummaryBox) {
        $boxes += $script:RunResultSummaryBox
    }
    if ($boxes.Count -eq 0) {
        return
    }
    $maxContentHeight = 52
    foreach ($box in $boxes) {
        $text = [string]$box.Text
        if ([string]::IsNullOrWhiteSpace($text)) {
            $text = " "
        }
        $font = $box.Font
        $width = $box.ClientSize.Width
        if ($width -lt 160) {
            $width = [Math]::Max(160, [int](($script:RunTabLayout.ClientSize.Width - 48) * 0.80))
        }
        $lineCount = @(($text -split "`r?`n")).Count
        if ($lineCount -lt 1) {
            $lineCount = 1
        }
        # Prefer line-count sizing for monospace tables (WordWrap off on results).
        $lineHeight = [Math]::Max(12, [int][Math]::Ceiling($font.GetHeight()))
        $contentHeight = ($lineCount * $lineHeight) + 16
        if ([bool]$box.WordWrap) {
            $flags = [System.Windows.Forms.TextFormatFlags]::WordBreak -bor [System.Windows.Forms.TextFormatFlags]::TextBoxControl
            $measured = [System.Windows.Forms.TextRenderer]::MeasureText(
                $text,
                $font,
                (New-Object System.Drawing.Size($width, [int]::MaxValue)),
                $flags
            )
            $contentHeight = [Math]::Max($contentHeight, $measured.Height + 16)
        }
        $contentHeight = [Math]::Max($contentHeight, 52)
        if ($contentHeight -gt $maxContentHeight) {
            $maxContentHeight = $contentHeight
        }
    }
    $rowHeight = 22 + 12 + $maxContentHeight + 16
    # Grow with host count so the compact results table stays visible without scrolling.
    $rowHeight = [Math]::Min([Math]::Max($rowHeight, 170), 420)
    $script:RunTabLayout.RowStyles[1].Height = [single]$rowHeight
}

function Update-RunResultSummaryPanel {
    if ($null -eq $script:RunResultSummaryBox) {
        return
    }
    if ($null -eq $script:RunResultSummary) {
        $script:RunResultSummary = New-EmptyRunResultSummary
    }
    $script:RunResultSummaryBox.Text = Format-RunResultSummaryText $script:RunResultSummary
    if ([bool](Get-PropertyValue $script:RunResultSummary "Success" $false)) {
        $script:RunResultSummaryBox.ForeColor = [System.Drawing.Color]::DarkGreen
    } elseif ([string](Get-PropertyValue $script:RunResultSummary "Status" "") -eq "Failed") {
        $script:RunResultSummaryBox.ForeColor = [System.Drawing.Color]::Firebrick
    } else {
        $script:RunResultSummaryBox.ForeColor = [System.Drawing.SystemColors]::ControlText
    }
    Resize-RunTabSummaryArea
}

function Refresh-RunTabSummary {
    if ($null -eq $script:RunSummaryBox) {
        return
    }
    if (Get-Command Test-RunMonitorTabSelected -ErrorAction SilentlyContinue) {
        if (-not (Test-RunMonitorTabSelected)) {
            return
        }
    }
    Capture-LocalHostTargets
    Sync-RunProfileFromSelector
    $mode = Get-Mode
    $resolved = Resolve-RunTestKind
    $targets = @(Get-SelectedRunTargets)
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add(("Run mode: {0}" -f $mode))
    [void]$lines.Add(("Run profile: {0}" -f (Get-RunProfileName)))
    if (-not [string]::IsNullOrWhiteSpace([string]$resolved.TestKind)) {
        [void]$lines.Add(("Derived test kind: {0}" -f $resolved.TestKind))
    } else {
        [void]$lines.Add(("Derived test kind: {0}" -f $resolved.Error))
    }
    [void]$lines.Add(("Selected targets: {0}" -f $targets.Count))
    foreach ($target in $targets) {
        [void]$lines.Add(("  - [{0}] {1}" -f (Get-TargetCategory $target), [string]$target.Target))
    }
    if ($targets.Count -eq 0) {
        if ($mode -eq "Single local run") {
            [void]$lines.Add("  Configure targets on the Local Host tab.")
        } else {
            [void]$lines.Add("  Enable ready slaves with selected targets on the Master / Slave tab.")
        }
    }
    $script:RunSummaryBox.Text = ($lines -join [Environment]::NewLine)
    Update-RunResultSummaryPanel
}
