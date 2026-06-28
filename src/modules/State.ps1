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
}

function Normalize-SlaveEntry {
    param([object]$Item)
    return [pscustomobject]@{
        Enabled = [bool](Get-PropertyValue $Item "Enabled" $true)
        Name = [string](Get-PropertyValue $Item "Name" "")
        Host = [string](Get-PropertyValue $Item "Host" "")
        OsType = [string](Get-PropertyValue $Item "OsType" "Windows")
        VdbenchPath = [string](Get-PropertyValue $Item "VdbenchPath" (Get-PropertyValue $script:Settings "WindowsVdbench" "C:\vdbench"))
        TestTarget = [string](Get-PropertyValue $Item "TestTarget" "")
        SshAlias = [string](Get-PropertyValue $Item "SshAlias" "")
        PrivateKey = [string](Get-PropertyValue $Item "PrivateKey" (Get-PropertyValue $script:Settings "PrivateKey" ""))
        Status = [string](Get-PropertyValue $Item "Status" "Not checked")
        Notes = [string](Get-PropertyValue $Item "Notes" "")
    }
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
    } elseif (Merge-DefaultProperties $script:Settings $defaultSettings) {
        Write-JsonFile $script:SettingsPath $script:Settings
    }

    $script:Catalog = @(Read-JsonFile $script:CatalogPath @())
    $loadedSlaves = @(Read-JsonFile $script:SlavesPath @())
    $script:Slaves = @()
    foreach ($slave in $loadedSlaves) {
        $script:Slaves += Normalize-SlaveEntry $slave
    }
    if ($script:Slaves.Count -eq 0) {
        $script:Slaves = @(
            [pscustomobject]@{
                Enabled = $true
                Name = "test-001"
                Host = "test-001"
                OsType = "Windows"
                VdbenchPath = (Get-PropertyValue $script:Settings "WindowsVdbench" "C:\vdbench")
                TestTarget = "C:\vdbench\testfile.dat"
                SshAlias = "test-001"
                PrivateKey = (Get-PropertyValue $script:Settings "PrivateKey" "")
                Status = "Not checked"
                Notes = ""
            }
        )
        Write-JsonFile $script:SlavesPath $script:Slaves -AsArray
    }

    Ensure-DefaultProfiles
}

function Ensure-DefaultProfiles {
    $rawPath = Join-Path $script:ProfileRoot "Default-4K-Random-Read.json"
    if (-not [System.IO.File]::Exists($rawPath)) {
        $profileObject = New-DefaultProfile "Default-4K-Random-Read" "Raw/block"
        Set-ProfileParamValue $profileObject "workload.rdpct" "100"
        Set-ProfileParamValue $profileObject "workload.seekpct" "100"
        Set-ProfileParamValue $profileObject "workload.xfersize" "4k"
        Write-JsonFile $rawPath $profileObject
    }

    $mixPath = Join-Path $script:ProfileRoot "Default-70-30-Random-Mix.json"
    if (-not [System.IO.File]::Exists($mixPath)) {
        $profileObject = New-DefaultProfile "Default-70-30-Random-Mix" "Raw/block"
        Set-ProfileParamValue $profileObject "workload.rdpct" "70"
        Set-ProfileParamValue $profileObject "workload.seekpct" "100"
        Set-ProfileParamValue $profileObject "workload.xfersize" "4k"
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
        [string]$TestKind
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
    return $profile
}

function Save-CurrentProfile {
    if ($null -eq $script:CurrentProfile) {
        return
    }
    Ensure-ProfileCatalogKeys $script:CurrentProfile
    Capture-ProfileEditor
    $script:CurrentProfile.UpdatedAt = (Get-Date).ToString("o")
    Write-JsonFile (Get-ProfilePath $script:CurrentProfile.Name) $script:CurrentProfile
    Refresh-ProfileList
}

function Open-ProfileFolder {
    if (Test-Path -LiteralPath $script:ProfileRoot) {
        Start-Process $script:ProfileRoot
    }
}

function Duplicate-CurrentProfile {
    if ($null -eq $script:CurrentProfile) {
        Show-Warning "No profile is loaded."
        return
    }
    Capture-ProfileEditor
    $copy = Copy-ObjectJson $script:CurrentProfile
    $baseName = [string]$copy.Name
    if ([string]::IsNullOrWhiteSpace($baseName)) {
        $baseName = "Profile"
    }
    $copy.Name = ("{0}-Copy-{1}" -f $baseName, (Get-Date).ToString("yyyyMMdd-HHmmss"))
    $copy.CreatedAt = (Get-Date).ToString("o")
    $copy.UpdatedAt = (Get-Date).ToString("o")
    Ensure-ProfileCatalogKeys $copy
    Write-JsonFile (Get-ProfilePath $copy.Name) $copy
    $script:CurrentProfile = $copy
    Refresh-ProfileList
    $script:ProfileSelector.Text = [string]$copy.Name
    Refresh-ProfileEditor
}

function Export-CurrentProfile {
    if ($null -eq $script:CurrentProfile) {
        Show-Warning "No profile is loaded."
        return
    }
    Capture-ProfileEditor
    Ensure-ProfileCatalogKeys $script:CurrentProfile
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = "Profile JSON (*.json)|*.json|All files (*.*)|*.*"
    $dialog.FileName = (Sanitize-FileName $script:CurrentProfile.Name) + ".json"
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Write-JsonFile $dialog.FileName $script:CurrentProfile
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
        if ($null -eq $importedProfile.PSObject.Properties["TestKind"]) {
            $importedProfile | Add-Member -NotePropertyName "TestKind" -NotePropertyValue "Raw/block"
        }
        Ensure-ProfileCatalogKeys $importedProfile
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
        $script:CurrentProfile = $importedProfile
        Refresh-ProfileList
        $script:ProfileSelector.Text = [string]$importedProfile.Name
        Refresh-ProfileEditor
    } catch {
        Show-Warning ("Profile import failed: " + $_.Exception.Message)
    }
}

function Delete-SelectedProfile {
    $name = [string]$script:ProfileSelector.Text
    if ([string]::IsNullOrWhiteSpace($name)) {
        Show-Warning "Select a profile to delete."
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
    Refresh-ProfileList
    $names = Get-ProfileNames
    if ($names.Count -gt 0) {
        $script:CurrentProfile = Load-ProfileByName $names[0]
        $script:ProfileSelector.Text = $names[0]
    } else {
        $script:CurrentProfile = New-DefaultProfile "New-Profile" "Raw/block"
        $script:ProfileSelector.Text = ""
    }
    Refresh-ProfileEditor
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
            $normalizedItem.Status = "Imported"
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
    if ($script:SettingsControls.ContainsKey("RunMode")) {
        return [string]$script:SettingsControls["RunMode"].Text
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
    Write-JsonFile $script:SettingsPath $script:Settings
    Show-Info "Settings saved."
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
