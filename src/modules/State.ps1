function Ensure-ProfileCatalogKeys {
    param([object]$Profile)
    if ($null -eq $Profile) {
        return
    }
    if ($null -eq $Profile.PSObject.Properties["Parameters"]) {
        $Profile | Add-Member -NotePropertyName "Parameters" -NotePropertyValue @()
    } else {
        $normalizedParameters = @()
        $rawParameters = $Profile.Parameters
        if ($rawParameters -is [System.Array]) {
            foreach ($item in @($rawParameters)) {
                if ($null -ne $item -and $null -ne $item.PSObject.Properties["Key"]) {
                    $normalizedParameters += [pscustomobject]@{
                        Key = [string]$item.Key
                        Enabled = [bool](Get-PropertyValue $item "Enabled" $true)
                        Value = [string](Get-PropertyValue $item "Value" "")
                    }
                }
            }
        } elseif ($null -ne $rawParameters -and $rawParameters -is [psobject]) {
            foreach ($prop in $rawParameters.PSObject.Properties) {
                $valueObject = $prop.Value
                if ($null -ne $valueObject -and $null -ne $valueObject.PSObject.Properties["Value"]) {
                    $normalizedParameters += [pscustomobject]@{
                        Key = [string]$prop.Name
                        Enabled = [bool](Get-PropertyValue $valueObject "Enabled" $true)
                        Value = [string](Get-PropertyValue $valueObject "Value" "")
                    }
                } else {
                    $normalizedParameters += [pscustomobject]@{
                        Key = [string]$prop.Name
                        Enabled = $true
                        Value = [string]$prop.Value
                    }
                }
            }
        }
        $Profile.Parameters = @($normalizedParameters)
    }
    foreach ($def in $script:Catalog) {
        $key = [string]$def.Key
        $found = $false
        foreach ($item in @($Profile.Parameters)) {
            if ($item.Key -eq $key) {
                $found = $true
                break
            }
        }
        if (-not $found) {
            $defaultValue = [string](Get-PropertyValue $def "Default" "")
            $required = [bool](Get-PropertyValue $def "Required" $false)
            $enabled = $required -or (-not [string]::IsNullOrWhiteSpace($defaultValue))
            $Profile.Parameters += [pscustomobject]@{
                Key = $key
                Enabled = $enabled
                Value = $defaultValue
            }
        }
    }
    if ($null -eq $Profile.PSObject.Properties["AdvancedActive"]) {
        $Profile | Add-Member -NotePropertyName "AdvancedActive" -NotePropertyValue ""
    }
    if ($null -eq $Profile.PSObject.Properties["AdvancedDisabled"]) {
        $Profile | Add-Member -NotePropertyName "AdvancedDisabled" -NotePropertyValue ""
    }
    Sync-CommonProfileParameters $Profile
}

$script:CommonParameterMirrors = @{
    "common.xfersize" = @("workload.xfersize", "fwd.xfersize")
    "common.threads" = @("workload.threads", "fwd.threads")
    "common.rate" = @("run.iorate", "run.fwdrate")
}

function Sync-CommonProfileParameters {
    param([object]$Profile)
    if ($null -eq $Profile) {
        return
    }
    foreach ($commonKey in $script:CommonParameterMirrors.Keys) {
        $mirrors = @($script:CommonParameterMirrors[$commonKey])
        $commonValue = Get-ProfileParamValue $Profile $commonKey ""
        $commonEnabled = Get-ProfileParamEnabled $Profile $commonKey
        if ([string]::IsNullOrWhiteSpace($commonValue)) {
            foreach ($mirrorKey in $mirrors) {
                $mirrorValue = Get-ProfileParamValue $Profile $mirrorKey ""
                if (-not [string]::IsNullOrWhiteSpace($mirrorValue)) {
                    $commonValue = $mirrorValue
                    $commonEnabled = Get-ProfileParamEnabled $Profile $mirrorKey
                    Set-ProfileParamValue $Profile $commonKey $commonValue
                    Set-ProfileParamEnabled $Profile $commonKey $commonEnabled
                    break
                }
            }
        }
        foreach ($mirrorKey in $mirrors) {
            Set-ProfileParamValue $Profile $mirrorKey $commonValue
            Set-ProfileParamEnabled $Profile $mirrorKey $commonEnabled
        }
    }
    Set-ProfileParamEnabled $Profile "storage.threads" $false
}

function Get-ProfileEditorContext {
    if (Get-Command Capture-LocalHostTargets -ErrorAction SilentlyContinue) {
        Capture-LocalHostTargets
    }
    if (Get-Command Capture-SlaveGrid -ErrorAction SilentlyContinue) {
        Capture-SlaveGrid
    }
    $resolved = Resolve-RunTestKind
    $locked = $false
    $message = ""
    $testKind = [string]$resolved.TestKind
    if ([string]::IsNullOrWhiteSpace($testKind)) {
        $locked = $true
        $errorText = [string]$resolved.Error
        if ($errorText -like "*mixed raw and filesystem*") {
            $message = "Mixed raw and filesystem targets are not allowed. Adjust selections on the Local Host or Master/Slave tab."
        } elseif ($errorText -like "*No targets selected*") {
            $message = "Select a target on the Local Host or Master/Slave tab to edit profile parameters."
        } elseif (-not [string]::IsNullOrWhiteSpace($errorText)) {
            $message = $errorText
        } else {
            $message = "Select a target on the Local Host or Master/Slave tab to edit profile parameters."
        }
    }
    $visibleSections = @("General")
    if (-not $locked) {
        if ($testKind -eq "Raw/block") {
            $visibleSections += "Raw / SD"
        } elseif ($testKind -eq "Filesystem") {
            $visibleSections += "Filesystem"
        }
    }
    return [pscustomobject]@{
        Locked = $locked
        Message = $message
        TestKind = $testKind
        VisibleSections = $visibleSections
        Resolved = $resolved
    }
}

function Test-ProfileEditorLocked {
    return [bool](Get-ProfileEditorContext).Locked
}

function Notify-ProfileTargetContextChanged {
    param([string]$Source = "unknown")
    Write-DebugLog ("Profile target context changed: source={0}" -f $Source)
    if (Get-Command Refresh-ProfileEditor -ErrorAction SilentlyContinue) {
        Refresh-ProfileEditor -ChangeSource $Source
    }
}

function Initialize-NewDraftProfile {
    if ($script:ProfileEditorLocked) {
        Write-DebugLog "Initialize-NewDraftProfile skipped because profile editor is locked"
        return
    }
    $script:CurrentProfile = New-DefaultProfile "New-Profile"
    if ($script:ProfileNameBox) {
        Refresh-ProfileEditor
    }
}

function Get-SelectedLibraryProfileName {
    if ($null -eq $script:RunProfileSelector) {
        return ""
    }
    return [string]$script:RunProfileSelector.Text
}

function Get-LocalHostTargetStore {
    return @(Normalize-TargetEntries $script:LocalHostTargets)
}

function Save-LocalHostTargets {
    $script:LocalHostTargets = @(Normalize-TargetEntries $script:LocalHostTargets)
    Write-JsonFile $script:LocalHostTargetsPath $script:LocalHostTargets -AsArray
}

function Import-LocalHostTargetsFromProfiles {
    if (@(Get-LocalHostTargetStore).Count -gt 0) {
        return
    }
    foreach ($file in @(Get-ChildItem -Path $script:ProfileRoot -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
        $profile = Read-JsonFile $file.FullName $null
        if ($null -eq $profile) {
            continue
        }
        $legacyTargets = @(Get-PropertyValue $profile "LocalTargets" @())
        if ($legacyTargets.Count -eq 0) {
            continue
        }
        $script:LocalHostTargets = @(Normalize-TargetEntries $legacyTargets)
        Save-LocalHostTargets
        return
    }
}

function Get-RunProfile {
    return $script:RunProfile
}

function Get-RunProfileName {
    $profile = Get-RunProfile
    if ($null -eq $profile -or [string]::IsNullOrWhiteSpace([string]$profile.Name)) {
        return "(none)"
    }
    return [string]$profile.Name
}

function Sync-RunProfileFromSelector {
    if ($null -eq $script:RunProfileSelector) {
        return
    }
    $name = [string]$script:RunProfileSelector.Text
    if ([string]::IsNullOrWhiteSpace($name)) {
        return
    }
    $loaded = Load-ProfileByName $name
    if ($null -ne $loaded) {
        $script:RunProfile = $loaded
    }
}

function Sync-RunModeToSettings {
    $mode = Get-Mode
    Set-PropertyValue $script:Settings "RunMode" $mode
    Write-JsonFile $script:SettingsPath $script:Settings
}

function Apply-RunModeFromSettings {
    $mode = [string](Get-PropertyValue $script:Settings "RunMode" "Single local run")
    if ($null -ne $script:RunModeCombo) {
        $script:RunModeCombo.Text = $mode
    }
}

function Get-DefaultVdbenchPathForOs {
    param([string]$OsType)
    if ([string]$OsType -eq "Linux") {
        return [string](Get-PropertyValue $script:Settings "LinuxVdbench" "/opt/vdbench")
    }
    return [string](Get-PropertyValue $script:Settings "WindowsVdbench" "C:\vdbench")
}

function Get-DefaultSlaveUserForOs {
    param([string]$OsType)
    if ([string]$OsType -eq "Linux") {
        return "root"
    }
    return "administrator"
}

function Get-DefaultTestTargetForOs {
    param([string]$OsType)
    if ([string]$OsType -eq "Linux") {
        return "/dev/sdb"
    }
    return "C:\vdbench\testfile.dat"
}

function Get-DefaultTestFileTargetForOs {
    param([string]$OsType)
    if ([string]$OsType -eq "Linux") {
        return "/var/tmp/vdbench-testfile.dat"
    }
    return "C:\vdbench\testfile.dat"
}

function Get-TargetCategory {
    param([object]$Target)
    $kind = [string](Get-PropertyValue $Target "Kind" "")
    if ($kind -match "Filesystem") {
        return "fs"
    }
    return "raw"
}

function New-TargetSelection {
    param(
        [string]$Kind,
        [string]$Target,
        [string]$Description = "",
        [bool]$Selected = $false,
        [bool]$CreateFile = $false
    )
    return [pscustomobject]@{
        Kind = $Kind
        Target = $Target
        Description = $Description
        Selected = $Selected
        CreateFile = $CreateFile
    }
}

function Normalize-TargetEntry {
    param([object]$Item)
    $target = [string](Get-PropertyValue $Item "Target" "")
    if ([string]::IsNullOrWhiteSpace($target)) {
        return $null
    }
    $kind = [string](Get-PropertyValue $Item "Kind" "")
    if ([string]::IsNullOrWhiteSpace($kind)) {
        $kind = "Raw disk"
    }
    return (New-TargetSelection `
        -Kind $kind `
        -Target $target `
        -Description ([string](Get-PropertyValue $Item "Description" "")) `
        -Selected ([bool](Get-PropertyValue $Item "Selected" $false)) `
        -CreateFile ([bool](Get-PropertyValue $Item "CreateFile" $false)))
}

function Normalize-TargetEntries {
    param([object[]]$Items)
    $result = @()
    foreach ($item in @($Items)) {
        $normalized = Normalize-TargetEntry $item
        if ($null -ne $normalized) {
            $result += $normalized
        }
    }
    return @($result)
}

function Get-SelectedTargetEntries {
    param(
        [object[]]$Targets,
        [string]$Category = ""
    )
    $selected = @()
    foreach ($target in @(Normalize-TargetEntries $Targets)) {
        if (-not [bool](Get-PropertyValue $target "Selected" $false)) {
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($Category) -and (Get-TargetCategory $target) -ne $Category) {
            continue
        }
        $selected += $target
    }
    return @($selected)
}

function Get-TargetSummary {
    param([object[]]$Targets)
    $selected = @(Get-SelectedTargetEntries $Targets)
    if ($selected.Count -eq 0) {
        return ""
    }
    if ($selected.Count -eq 1) {
        return [string]$selected[0].Target
    }
    return ("{0} targets selected" -f $selected.Count)
}

function Get-LegacyTargetEntries {
    param(
        [string]$Target,
        [string]$Kind = "Raw disk"
    )
    if ([string]::IsNullOrWhiteSpace($Target)) {
        return @()
    }
    return @((New-TargetSelection -Kind $Kind -Target $Target -Selected $true))
}

function Get-DefaultSshAliasForSlave {
    param(
        [string]$Name,
        [string]$HostName
    )
    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        return $Name.Trim()
    }
    if (-not [string]::IsNullOrWhiteSpace($HostName)) {
        return $HostName.Trim()
    }
    return ""
}

function Test-SlaveHasHost {
    param([object]$Slave)
    $hostName = [string](Get-PropertyValue $Slave "Host" "")
    return -not [string]::IsNullOrWhiteSpace($hostName)
}

function Resolve-SlaveReadinessStatus {
    param([object]$Slave)
    $status = [string](Get-PropertyValue $Slave "ReadinessStatus" "")
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        return $status
    }
    $legacy = [string](Get-PropertyValue $Slave "Status" "")
    if ($legacy -eq "Ready" -or $legacy -eq "Target selected") {
        return "Ready"
    }
    if ($legacy -eq "Checking..." -or $legacy -eq "Pinging...") {
        return "Checking"
    }
    if ([string]::IsNullOrWhiteSpace($legacy) -or $legacy -eq "Not checked") {
        return "Not checked"
    }
    return $legacy
}

function Test-SlaveReadinessReady {
    param([object]$Slave)
    return (Resolve-SlaveReadinessStatus $Slave) -eq "Ready"
}

function Test-SlaveIsUsable {
    param([object]$Slave)
    if (-not (Test-SlaveReadinessReady $Slave)) {
        return $false
    }
    return (@(Get-SelectedTargetEntries @(Get-PropertyValue $Slave "Targets" @())).Count -gt 0)
}

function Apply-SlaveDefaults {
    param([object]$Slave)
    $osType = [string](Get-PropertyValue $Slave "OsType" "Windows")
    $name = [string](Get-PropertyValue $Slave "Name" "")
    $hostName = [string](Get-PropertyValue $Slave "Host" "")
    $user = [string](Get-PropertyValue $Slave "User" "")
    $vdbenchPath = [string](Get-PropertyValue $Slave "VdbenchPath" "")
    # TestTarget exists ONLY to migrate a slave saved by a much older version
    # of this app (before the richer Targets array existed) into the current
    # Targets format, exactly once, when genuinely non-blank on input. It
    # must NEVER be defaulted-then-written-back here: doing so used to make
    # an untouched, freshly-added slave (Targets still empty, TestTarget
    # never set by the user) look, on the very NEXT call to this function -
    # which happens on almost any UI interaction, since both
    # Capture-SlaveGrid and Populate-SlaveGrid call this - EXACTLY like a
    # genuine legacy slave that already had a custom TestTarget, silently
    # auto-selecting a default target the user never touched via Browse
    # (real bug, found 2026-07-01, from a user report that a brand new
    # slave row's Targets cell already showed something selected). Read the
    # raw value once, use it only for the one-time migration check/call
    # below, and pass it straight through unchanged for the returned
    # object - never widen it with a computed default.
    $testTarget = [string](Get-PropertyValue $Slave "TestTarget" "")
    $targets = @(Normalize-TargetEntries @(Get-PropertyValue $Slave "Targets" @()))
    if ($targets.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($testTarget)) {
        $targets = @(Get-LegacyTargetEntries $testTarget)
    }
    $sshAlias = [string](Get-PropertyValue $Slave "SshAlias" "")
    if ([string]::IsNullOrWhiteSpace($user)) {
        $user = Get-DefaultSlaveUserForOs $osType
    }
    if ([string]::IsNullOrWhiteSpace($vdbenchPath)) {
        $vdbenchPath = Get-DefaultVdbenchPathForOs $osType
    }
    if ([string]::IsNullOrWhiteSpace($sshAlias)) {
        $sshAlias = Get-DefaultSshAliasForSlave $name $hostName
    }
    $readinessStatus = Resolve-SlaveReadinessStatus $Slave
    $readinessCheckedAt = [string](Get-PropertyValue $Slave "ReadinessCheckedAt" "")
    if ([string]::IsNullOrWhiteSpace($readinessCheckedAt)) {
        $readinessCheckedAt = [string](Get-PropertyValue $Slave "CheckedAt" "")
    }
    $pingStatus = [string](Get-PropertyValue $Slave "PingStatus" "")
    if ([string]::IsNullOrWhiteSpace($pingStatus) -and [string](Get-PropertyValue $Slave "Status" "") -match "^Ping") {
        $pingStatus = [string](Get-PropertyValue $Slave "Status" "")
    }
    $pingCheckedAt = [string](Get-PropertyValue $Slave "PingCheckedAt" "")
    $readinessOutput = [string](Get-PropertyValue $Slave "ReadinessOutput" "")
    $enabled = [bool](Get-PropertyValue $Slave "Enabled" $false)
    if ($readinessStatus -ne "Ready") {
        $enabled = $false
    }
    return [pscustomobject]@{
        Enabled = $enabled
        Name = $name
        Host = $hostName
        OsType = $osType
        User = $user
        VdbenchPath = $vdbenchPath
        TestTarget = $testTarget
        Targets = @($targets)
        SshAlias = $sshAlias
        PrivateKey = [string](Get-PropertyValue $script:Settings "PrivateKey" "")
        ReadinessStatus = $readinessStatus
        ReadinessCheckedAt = $readinessCheckedAt
        ReadinessOutput = $readinessOutput
        PingStatus = $pingStatus
        PingCheckedAt = $pingCheckedAt
        Status = $readinessStatus
        Notes = [string](Get-PropertyValue $Slave "Notes" "")
    }
}

function Normalize-SlaveEntry {
    param([object]$Item)
    if (-not (Test-SlaveHasHost $Item)) {
        return $null
    }
    return Apply-SlaveDefaults $Item
}

function Migrate-LegacySettings {
    # Settings values that shipped as defaults in earlier versions but turned out
    # to be broken/harmful. Merge-DefaultProperties only fills in MISSING keys, so
    # a machine whose data/settings.json was already seeded with a bad default
    # would otherwise keep it forever. Each migration below is only applied if the
    # current value(s) still exactly match the old default being replaced, so
    # intentional user customizations are never overwritten.
    param([object]$Settings)
    $changed = $false

    # v1 -> v2 (2026-07-01): real-world readiness checker scripts commonly use
    # [CmdletBinding()], which makes PowerShell throw "A parameter cannot be
    # found that matches parameter name 'HostName'." for ANY unrecognized named
    # parameter, so the original named-params default broke against them.
    # Replaced with an empty template.
    $legacyReadinessArgsV1 = "-HostName {Host} -VdbenchPath {VdbenchPath} -Target {Target}"
    if ([string](Get-PropertyValue $Settings "ReadinessCheckerArguments" "") -eq $legacyReadinessArgsV1) {
        Set-PropertyValue $Settings "ReadinessCheckerArguments" ""
        Write-DebugLog "Migrated legacy default setting 'ReadinessCheckerArguments' (v1 named-params template) to empty string"
        $changed = $true
    }

    # v2 -> v3 (2026-07-01, same day): turns out the shipped default checker
    # (04-Check-Vdbench-Hosts-Readiness.ps1) DOES take an argument after all -
    # just not the ones v1 assumed. It needs -WindowsHosts/-LinuxHosts (chosen
    # by the row's OS) to know which host to actually check remotely; with no
    # host argument at all it silently only checks the Master's own local
    # prerequisites and never validates the specific slave a user clicked
    # Readiness for. Only migrate when ReadinessChecker still points at the
    # stock shipped script - a user who already pointed it at a different
    # checker may have deliberately left this empty for a script that really
    # does take no arguments, and must not be overwritten.
    $stockChecker = "C:\install\04-Check-Vdbench-Hosts-Readiness.ps1"
    $currentChecker = [string](Get-PropertyValue $Settings "ReadinessChecker" "")
    if ([string](Get-PropertyValue $Settings "ReadinessCheckerArguments" "") -eq "" -and $currentChecker -eq $stockChecker) {
        Set-PropertyValue $Settings "ReadinessCheckerArguments" "{HostFlag}"
        Write-DebugLog "Migrated legacy default setting 'ReadinessCheckerArguments' (v2 empty template) to {HostFlag}"
        $changed = $true
    }

    return $changed
}

function Initialize-AppState {
    Ensure-Directory $script:DataRoot
    Ensure-Directory $script:ProfileRoot
    Ensure-Directory $script:RunStateRoot
    Ensure-Directory $script:LogRoot

    $defaultSettingsPath = Join-Path $script:ConfigRoot "default-settings.json"
    $defaultSettings = Read-JsonFile $defaultSettingsPath ([pscustomobject]@{})
    $script:Settings = Read-JsonFile $script:SettingsPath $null
    if ($null -eq $script:Settings) {
        $script:Settings = $defaultSettings
        Write-JsonFile $script:SettingsPath $script:Settings
    } else {
        $mergedChanged = Merge-DefaultProperties $script:Settings $defaultSettings
        $migratedChanged = Migrate-LegacySettings $script:Settings
        if ($mergedChanged -or $migratedChanged) {
            Write-JsonFile $script:SettingsPath $script:Settings
        }
    }

    $script:Catalog = @(Read-JsonFile $script:CatalogPath @())
    $loadedSlaves = @(Read-JsonFile $script:SlavesPath @())
    $script:Slaves = @()
    foreach ($slave in $loadedSlaves) {
        $normalized = Normalize-SlaveEntry $slave
        if ($null -ne $normalized) {
            $script:Slaves += $normalized
        }
    }
    if ($script:Slaves.Count -eq 0) {
        $script:Slaves = @(
            Apply-SlaveDefaults ([pscustomobject]@{
                Enabled = $true
                Name = "test-001"
                Host = "test-001"
                OsType = "Windows"
                User = ""
                VdbenchPath = ""
                TestTarget = ""
                SshAlias = ""
                PrivateKey = (Get-PropertyValue $script:Settings "PrivateKey" "")
                Status = "Not checked"
                Notes = ""
            })
        )
        Write-JsonFile $script:SlavesPath $script:Slaves -AsArray
    }

    $script:LocalHostTargets = @(Read-JsonFile $script:LocalHostTargetsPath @())
    $script:LocalHostTargets = @(Normalize-TargetEntries $script:LocalHostTargets)
    Import-LocalHostTargetsFromProfiles
    if (@(Get-LocalHostTargetStore).Count -eq 0) {
        Save-LocalHostTargets
    }

    Ensure-DefaultProfiles
}

function Ensure-DefaultProfiles {
    $rawPath = Join-Path $script:ProfileRoot "Default-4K-Random-Read.json"
    if (-not [System.IO.File]::Exists($rawPath)) {
        $profileObject = New-DefaultProfile "Default-4K-Random-Read" "Raw/block"
        Set-ProfileParamValue $profileObject "workload.rdpct" "100"
        Set-ProfileParamValue $profileObject "workload.seekpct" "100"
        Set-ProfileParamValue $profileObject "common.xfersize" "4k"
        Write-JsonFile $rawPath $profileObject
    }

    $mixPath = Join-Path $script:ProfileRoot "Default-70-30-Random-Mix.json"
    if (-not [System.IO.File]::Exists($mixPath)) {
        $profileObject = New-DefaultProfile "Default-70-30-Random-Mix" "Raw/block"
        Set-ProfileParamValue $profileObject "workload.rdpct" "70"
        Set-ProfileParamValue $profileObject "workload.seekpct" "100"
        Set-ProfileParamValue $profileObject "common.xfersize" "4k"
        Write-JsonFile $mixPath $profileObject
    }

    $fsPath = Join-Path $script:ProfileRoot "Default-Filesystem-Random-Read.json"
    if (-not [System.IO.File]::Exists($fsPath)) {
        $profileObject = New-DefaultProfile "Default-Filesystem-Random-Read" "Filesystem"
        Set-ProfileParamValue $profileObject "fwd.operation" "read"
        Set-ProfileParamValue $profileObject "fwd.fileio" "random"
        Set-ProfileParamValue $profileObject "run.format" "no"
        Write-JsonFile $fsPath $profileObject
    }
}

function New-DefaultProfile {
    param(
        [string]$Name,
        [string]$TestKind = ""
    )
    $items = @()
    foreach ($def in $script:Catalog) {
        $defaultValue = [string](Get-PropertyValue $def "Default" "")
        $required = [bool](Get-PropertyValue $def "Required" $false)
        $enabled = $required -or (-not [string]::IsNullOrWhiteSpace($defaultValue))
        $items += [pscustomobject]@{
            Key = [string]$def.Key
            Enabled = $enabled
            Value = $defaultValue
        }
    }
    return [pscustomobject]@{
        Name = $Name
        TestKind = $TestKind
        CreatedAt = (Get-Date).ToString("o")
        UpdatedAt = (Get-Date).ToString("o")
        Parameters = $items
        AdvancedActive = ""
        AdvancedDisabled = ""
    }
}

function Get-ProfileParam {
    param(
        [object]$Profile,
        [string]$Key
    )
    foreach ($item in @($Profile.Parameters)) {
        if ($item.Key -eq $Key) {
            return $item
        }
    }
    $newItem = [pscustomobject]@{ Key = $Key; Enabled = $false; Value = "" }
    $Profile.Parameters += $newItem
    return $newItem
}

function Get-ProfileParamValue {
    param(
        [object]$Profile,
        [string]$Key,
        [string]$DefaultValue = ""
    )
    $item = Get-ProfileParam $Profile $Key
    if ($null -eq $item.Value) {
        return $DefaultValue
    }
    return [string]$item.Value
}

function Set-ProfileParamValue {
    param(
        [object]$Profile,
        [string]$Key,
        [string]$Value
    )
    $item = Get-ProfileParam $Profile $Key
    $item.Value = $Value
}

function Get-ProfileParamEnabled {
    param(
        [object]$Profile,
        [string]$Key
    )
    $item = Get-ProfileParam $Profile $Key
    return [bool]$item.Enabled
}

function Set-ProfileParamEnabled {
    param(
        [object]$Profile,
        [string]$Key,
        [bool]$Enabled
    )
    $item = Get-ProfileParam $Profile $Key
    $item.Enabled = $Enabled
}

function Sanitize-FileName {
    param([string]$Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $result = $Name
    foreach ($char in $invalid) {
        $result = $result.Replace([string]$char, "-")
    }
    return $result.Trim()
}

function Get-ProfilePath {
    param([string]$Name)
    $fileName = (Sanitize-FileName $Name)
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        $fileName = "profile"
    }
    return (Join-Path $script:ProfileRoot ($fileName + ".json"))
}

function Get-ProfileNames {
    $files = @(Get-ChildItem -Path $script:ProfileRoot -Filter "*.json" -File -ErrorAction SilentlyContinue)
    return @($files | ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) } | Sort-Object)
}

function Load-ProfileByName {
    param([string]$Name)
    $path = Get-ProfilePath $Name
    if (-not [System.IO.File]::Exists($path)) {
        return $null
    }
    $profile = Read-JsonFile $path $null
    Ensure-ProfileCatalogKeys $profile
    $legacyTargets = @(Get-PropertyValue $profile "LocalTargets" @())
    if ($legacyTargets.Count -gt 0 -and @(Get-LocalHostTargetStore).Count -eq 0) {
        $script:LocalHostTargets = @(Normalize-TargetEntries $legacyTargets)
        Save-LocalHostTargets
    }
    if ($null -ne $profile.PSObject.Properties["LocalTargets"]) {
        $profile.PSObject.Properties.Remove("LocalTargets")
    }
    return $profile
}

function Save-CurrentProfile {
    if ($script:ProfileEditorLocked) {
        Show-Warning "Select a target before saving a profile."
        return
    }
    if ($null -eq $script:CurrentProfile) {
        return
    }
    Ensure-ProfileCatalogKeys $script:CurrentProfile
    Capture-ProfileEditor
    Sync-CommonProfileParameters $script:CurrentProfile
    if ($null -ne $script:CurrentProfile.PSObject.Properties["LocalTargets"]) {
        $script:CurrentProfile.PSObject.Properties.Remove("LocalTargets")
    }
    if ($null -ne $script:CurrentProfile.PSObject.Properties["TestKind"]) {
        $script:CurrentProfile.PSObject.Properties.Remove("TestKind")
    }
    $savedName = [string]$script:CurrentProfile.Name
    if ([string]::IsNullOrWhiteSpace($savedName)) {
        Show-Warning "Enter a profile name before saving."
        return
    }
    $script:CurrentProfile.UpdatedAt = (Get-Date).ToString("o")
    Write-JsonFile (Get-ProfilePath $savedName) $script:CurrentProfile
    Refresh-RunProfileList
    if ($script:RunProfileSelector) {
        $script:RunProfileSelector.Text = $savedName
        Sync-RunProfileFromSelector
    }
    Initialize-NewDraftProfile
}

function Open-ProfileFolder {
    if (Test-Path -LiteralPath $script:ProfileRoot) {
        Start-Process $script:ProfileRoot
    }
}

function Duplicate-RunProfile {
    $profile = Get-RunProfile
    if ($null -eq $profile) {
        Show-Warning "Select a run profile to duplicate."
        return
    }
    $copy = Copy-ObjectJson $profile
    $baseName = [string]$copy.Name
    if ([string]::IsNullOrWhiteSpace($baseName)) {
        $baseName = "Profile"
    }
    $copy.Name = ("{0}-Copy-{1}" -f $baseName, (Get-Date).ToString("yyyyMMdd-HHmmss"))
    $copy.CreatedAt = (Get-Date).ToString("o")
    $copy.UpdatedAt = (Get-Date).ToString("o")
    Ensure-ProfileCatalogKeys $copy
    Sync-CommonProfileParameters $copy
    Write-JsonFile (Get-ProfilePath $copy.Name) $copy
    Refresh-RunProfileList
    if ($script:RunProfileSelector) {
        $script:RunProfileSelector.Text = [string]$copy.Name
        Sync-RunProfileFromSelector
    }
    Refresh-RunTabSummary
    Refresh-ConfigPreview
}

function Export-RunProfile {
    $profile = Get-RunProfile
    if ($null -eq $profile) {
        Show-Warning "Select a run profile to export."
        return
    }
    Sync-CommonProfileParameters $profile
    Ensure-ProfileCatalogKeys $profile
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = "Profile JSON (*.json)|*.json|All files (*.*)|*.*"
    $dialog.FileName = (Sanitize-FileName $profile.Name) + ".json"
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Write-JsonFile $dialog.FileName $profile
    }
}

function Import-Profile {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = "Profile JSON (*.json)|*.json|All files (*.*)|*.*"
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return
    }
    try {
        $importedProfile = Read-JsonFile $dialog.FileName $null
        if ($null -eq $importedProfile -or $null -eq $importedProfile.PSObject.Properties["Name"]) {
            throw "Selected JSON is not a Vdbench UI profile."
        }
        Ensure-ProfileCatalogKeys $importedProfile
        $legacyTargets = @(Get-PropertyValue $importedProfile "LocalTargets" @())
        if ($legacyTargets.Count -gt 0) {
            $script:LocalHostTargets = @(Normalize-TargetEntries $legacyTargets)
            Save-LocalHostTargets
        }
        if ($null -ne $importedProfile.PSObject.Properties["LocalTargets"]) {
            $importedProfile.PSObject.Properties.Remove("LocalTargets")
        }
        if ($null -ne $importedProfile.PSObject.Properties["TestKind"]) {
            $importedProfile.PSObject.Properties.Remove("TestKind")
        }
        $baseName = [string]$importedProfile.Name
        if ([string]::IsNullOrWhiteSpace($baseName)) {
            $baseName = "Imported-Profile"
        }
        $targetPath = Get-ProfilePath $baseName
        if (Test-Path -LiteralPath $targetPath) {
            $importedProfile.Name = ("{0}-Imported-{1}" -f $baseName, (Get-Date).ToString("yyyyMMdd-HHmmss"))
        }
        $importedProfile.UpdatedAt = (Get-Date).ToString("o")
        Write-JsonFile (Get-ProfilePath $importedProfile.Name) $importedProfile
        Refresh-RunProfileList
        if ($script:RunProfileSelector) {
            $script:RunProfileSelector.Text = [string]$importedProfile.Name
            Sync-RunProfileFromSelector
        }
        Refresh-RunTabSummary
        Refresh-ConfigPreview
    } catch {
        Show-Warning ("Profile import failed: " + $_.Exception.Message)
    }
}

function Delete-SelectedProfile {
    $name = Get-SelectedLibraryProfileName
    if ([string]::IsNullOrWhiteSpace($name)) {
        Show-Warning "Select a run profile to delete."
        return
    }
    $path = Get-ProfilePath $name
    if (-not (Test-Path -LiteralPath $path)) {
        Show-Warning "Profile file does not exist: $path"
        return
    }
    if (-not (Ask-YesNo ("Delete profile '{0}'?" -f $name) "Delete profile")) {
        return
    }
    Remove-Item -LiteralPath $path -Force
    Refresh-RunProfileList
    Refresh-RunTabSummary
    Refresh-ConfigPreview
    Update-RunModeIndicator
}

function Reload-RunProfile {
    Sync-RunProfileFromSelector
    Refresh-RunTabSummary
    Refresh-ConfigPreview
    Update-RunModeIndicator
}

function Export-SlaveInventory {
    Capture-SlaveGrid
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = "Slave inventory JSON (*.json)|*.json|All files (*.*)|*.*"
    $dialog.FileName = "vdbench-slaves.json"
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Write-JsonFile $dialog.FileName $script:Slaves -AsArray
    }
}

function Import-SlaveInventory {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = "Slave inventory JSON (*.json)|*.json|All files (*.*)|*.*"
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return
    }
    try {
        $items = @(Read-JsonFile $dialog.FileName @())
        $normalized = @()
        foreach ($item in $items) {
            if ([string]::IsNullOrWhiteSpace([string](Get-PropertyValue $item "Name" "")) -and [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $item "Host" ""))) {
                continue
            }
            $normalizedItem = Normalize-SlaveEntry $item
            $normalizedItem.ReadinessStatus = "Not checked"
            $normalizedItem.ReadinessCheckedAt = ""
            $normalized += $normalizedItem
        }
        $script:Slaves = @($normalized)
        Populate-SlaveGrid
        Save-Slaves
    } catch {
        Show-Warning ("Slave import failed: " + $_.Exception.Message)
    }
}
function Get-Mode {
    if ($null -ne $script:RunModeCombo) {
        return [string]$script:RunModeCombo.Text
    }
    return [string](Get-PropertyValue $script:Settings "RunMode" "Single local run")
}

function Is-DistributedMode {
    return ((Get-Mode) -eq "Master/Slave distributed run")
}

function Capture-Settings {
    foreach ($key in $script:SettingsControls.Keys) {
        $control = $script:SettingsControls[$key]
        if ($control -is [System.Windows.Forms.CheckBox]) {
            Set-PropertyValue $script:Settings $key ([bool]$control.Checked)
        } else {
            Set-PropertyValue $script:Settings $key ([string]$control.Text)
        }
    }
}

function Save-Settings {
    Capture-Settings
    Sync-RunModeToSettings
    Write-JsonFile $script:SettingsPath $script:Settings
    Show-Info "Settings saved."
    Update-RunModeIndicator
    Refresh-ConfigPreview
}

function Refresh-SettingsControls {
    foreach ($key in $script:SettingsControls.Keys) {
        $control = $script:SettingsControls[$key]
        if ($control -is [System.Windows.Forms.CheckBox]) {
            $control.Checked = [bool](Get-PropertyValue $script:Settings $key $false)
        } else {
            $control.Text = [string](Get-PropertyValue $script:Settings $key "")
        }
    }
    Validate-SettingsPaths
    Refresh-ConfigPreview
}

function Export-Settings {
    Capture-Settings
    Sync-RunModeToSettings
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = "Settings JSON (*.json)|*.json|All files (*.*)|*.*"
    $dialog.FileName = "vdbench-ui-settings.json"
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Write-JsonFile $dialog.FileName $script:Settings
    }
}

function Import-Settings {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = "Settings JSON (*.json)|*.json|All files (*.*)|*.*"
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return
    }
    try {
        $imported = Read-JsonFile $dialog.FileName $null
        if ($null -eq $imported -or $null -eq $imported.PSObject.Properties["RunMode"]) {
            throw "Selected JSON is not a Vdbench UI settings file."
        }
        $defaults = Read-JsonFile (Join-Path $script:ConfigRoot "default-settings.json") ([pscustomobject]@{})
        Merge-DefaultProperties $imported $defaults | Out-Null
        $script:Settings = $imported
        Write-JsonFile $script:SettingsPath $script:Settings
        Refresh-SettingsControls
        Apply-RunModeFromSettings
        Update-RunModeIndicator
        Update-RunModeTabs
        Show-Info "Settings imported."
    } catch {
        Show-Warning ("Settings import failed: " + $_.Exception.Message)
    }
}

function Browse-FileForControl {
    param([System.Windows.Forms.TextBox]$TextBox)
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.CheckFileExists = $false
    if (-not [string]::IsNullOrWhiteSpace($TextBox.Text)) {
        $dialog.FileName = $TextBox.Text
    }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $TextBox.Text = $dialog.FileName
    }
}

function Browse-FolderForControl {
    param([System.Windows.Forms.TextBox]$TextBox)
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    if (-not [string]::IsNullOrWhiteSpace($TextBox.Text)) {
        $dialog.SelectedPath = $TextBox.Text
    }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $TextBox.Text = $dialog.SelectedPath
    }
}

function Validate-SettingsPaths {
    Capture-Settings
    $items = @(
        @{ Name = "Vdbench root"; Path = (Get-PropertyValue $script:Settings "VdbenchRoot" "") },
        @{ Name = "Master vdbench.bat"; Path = (Get-PropertyValue $script:Settings "MasterVdbenchBat" "") },
        @{ Name = "Reports root"; Path = (Get-PropertyValue $script:Settings "ReportsRoot" "") },
        @{ Name = "Readiness checker"; Path = (Get-PropertyValue $script:Settings "ReadinessChecker" "") },
        @{ Name = "SSH config"; Path = (Get-PropertyValue $script:Settings "SshConfig" "") },
        @{ Name = "Private key"; Path = (Get-PropertyValue $script:Settings "PrivateKey" "") }
    )

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("Master prerequisite status")
    [void]$lines.Add("==========================")
    [void]$lines.Add("")
    foreach ($item in $items) {
        $exists = $false
        if (-not [string]::IsNullOrWhiteSpace($item.Path)) {
            $exists = Test-Path -LiteralPath $item.Path
        }
        [void]$lines.Add(("{0,-22} {1,-60} Exists={2}" -f $item.Name, $item.Path, $exists))
    }
    $script:SettingsStatusBox.Text = ($lines -join [Environment]::NewLine)
}

function Use-FakeRunnerSettings {
    $fakeRunner = Join-Path $script:AppRoot "tools\FakeVdbench.ps1"
    if ($script:SettingsControls.ContainsKey("MasterVdbenchBat")) {
        $script:SettingsControls["MasterVdbenchBat"].Text = $fakeRunner
    }
    if ($script:SettingsControls.ContainsKey("VdbenchRoot")) {
        $script:SettingsControls["VdbenchRoot"].Text = $script:AppRoot
    }
    if ($script:SettingsControls.ContainsKey("ReportsRoot")) {
        $script:SettingsControls["ReportsRoot"].Text = Join-Path $script:AppRoot "runs"
    }
    Capture-Settings
    Validate-SettingsPaths
    Refresh-ConfigPreview
}
