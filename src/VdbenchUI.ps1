param(
    [switch]$NoGui,
    [switch]$SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
try {
    Add-Type -AssemblyName System.Windows.Forms.DataVisualization
    $script:ChartAvailable = $true
} catch {
    $script:ChartAvailable = $false
}
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:AppRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$script:ConfigRoot = Join-Path $script:AppRoot "config"
$script:DataRoot = Join-Path $script:AppRoot "data"
$script:ProfileRoot = Join-Path $script:AppRoot "profiles"
$script:RunStateRoot = Join-Path $script:DataRoot "runs"
$script:LogRoot = Join-Path $script:AppRoot "logs"
$script:SettingsPath = Join-Path $script:DataRoot "settings.json"
$script:SlavesPath = Join-Path $script:DataRoot "slaves.json"
$script:CatalogPath = Join-Path $script:ConfigRoot "parameter-catalog.json"

$script:Settings = $null
$script:Slaves = @()
$script:Catalog = @()
$script:CurrentProfile = $null
$script:ParameterControls = @{}
$script:SettingsControls = @{}
$script:RefreshingProfileEditor = $false
$script:CurrentProcess = $null
$script:CurrentRunId = $null
$script:KillRequested = $false
$script:LogQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:Form = $null
$script:SettingsStatusBox = $null
$script:SlaveGrid = $null
$script:ProfileSelector = $null
$script:ProfileNameBox = $null
$script:ProfileKindCombo = $null
$script:ProfileParamTabs = $null
$script:AdvancedActiveBox = $null
$script:AdvancedDisabledBox = $null
$script:ConfigPreviewBox = $null
$script:RunLogBox = $null
$script:RunStatusLabel = $null
$script:RunChart = $null
$script:RunMetricIndex = 0
$script:ReportsGrid = $null
$script:ReportDetailBox = $null
$script:ActiveStdoutPath = $null
$script:ActiveStderrPath = $null

function Ensure-Directory {
    param([string]$Path)
    if (-not [System.IO.Directory]::Exists($Path)) {
        [System.IO.Directory]::CreateDirectory($Path) | Out-Null
    }
}

function Read-TextFile {
    param([string]$Path)
    if (-not [System.IO.File]::Exists($Path)) {
        return $null
    }
    return [System.IO.File]::ReadAllText($Path)
}

function Read-JsonFile {
    param(
        [string]$Path,
        [object]$Fallback
    )
    $text = Read-TextFile $Path
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $Fallback
    }
    return ($text | ConvertFrom-Json)
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value,
        [switch]$AsArray
    )
    $dir = Split-Path -Parent $Path
    Ensure-Directory $dir
    if ($AsArray) {
        $json = ConvertTo-Json -InputObject @($Value) -Depth 20
    } else {
        $json = ConvertTo-Json -InputObject $Value -Depth 20
    }
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.Encoding]::UTF8)
}

function Copy-ObjectJson {
    param([object]$Value)
    return (($Value | ConvertTo-Json -Depth 20) | ConvertFrom-Json)
}

function Get-PropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$DefaultValue = $null
    )
    if ($null -eq $Object) {
        return $DefaultValue
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        return $DefaultValue
    }
    return $prop.Value
}

function Set-PropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Value
    )
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    } else {
        $Object.$Name = $Value
    }
}

function Quote-ProcessArgument {
    param([string]$Value)
    if ($null -eq $Value) {
        return '""'
    }
    return '"' + ($Value.Replace('"', '\"')) + '"'
}

function Get-VdbenchProcessStartInfo {
    param(
        [string]$ExecutablePath,
        [string]$ParameterFile,
        [string]$OutputDirectory,
        [string]$WorkingDirectory
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $extension = [System.IO.Path]::GetExtension($ExecutablePath).ToLowerInvariant()
    $parmArg = Quote-ProcessArgument $ParameterFile
    $outArg = Quote-ProcessArgument $OutputDirectory

    if ($extension -eq ".bat" -or $extension -eq ".cmd") {
        $command = "{0} -f {1} -o {2}" -f (Quote-ProcessArgument $ExecutablePath), $parmArg, $outArg
        $psi.FileName = "cmd.exe"
        $psi.Arguments = '/d /c "' + $command + '"'
    } elseif ($extension -eq ".ps1") {
        $psi.FileName = "powershell.exe"
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File {0} -f {1} -o {2}" -f (Quote-ProcessArgument $ExecutablePath), $parmArg, $outArg
    } else {
        $psi.FileName = $ExecutablePath
        $psi.Arguments = "-f {0} -o {1}" -f $parmArg, $outArg
    }

    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    return $psi
}

function Merge-DefaultProperties {
    param(
        [object]$Target,
        [object]$Defaults
    )
    $changed = $false
    foreach ($prop in $Defaults.PSObject.Properties) {
        if ($null -eq $Target.PSObject.Properties[$prop.Name]) {
            $Target | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value
            $changed = $true
        }
    }
    return $changed
}

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
        $profile = New-DefaultProfile "Default-4K-Random-Read" "Raw/block"
        Set-ProfileParamValue $profile "workload.rdpct" "100"
        Set-ProfileParamValue $profile "workload.seekpct" "100"
        Set-ProfileParamValue $profile "workload.xfersize" "4k"
        Write-JsonFile $rawPath $profile
    }

    $mixPath = Join-Path $script:ProfileRoot "Default-70-30-Random-Mix.json"
    if (-not [System.IO.File]::Exists($mixPath)) {
        $profile = New-DefaultProfile "Default-70-30-Random-Mix" "Raw/block"
        Set-ProfileParamValue $profile "workload.rdpct" "70"
        Set-ProfileParamValue $profile "workload.seekpct" "100"
        Set-ProfileParamValue $profile "workload.xfersize" "4k"
        Write-JsonFile $mixPath $profile
    }

    $fsPath = Join-Path $script:ProfileRoot "Default-Filesystem-Random-Read.json"
    if (-not [System.IO.File]::Exists($fsPath)) {
        $profile = New-DefaultProfile "Default-Filesystem-Random-Read" "Filesystem"
        Set-ProfileParamValue $profile "fwd.operation" "read"
        Set-ProfileParamValue $profile "fwd.fileio" "random"
        Set-ProfileParamValue $profile "run.format" "no"
        Write-JsonFile $fsPath $profile
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
        $profile = Read-JsonFile $dialog.FileName $null
        if ($null -eq $profile -or $null -eq $profile.PSObject.Properties["Name"]) {
            throw "Selected JSON is not a Vdbench UI profile."
        }
        if ($null -eq $profile.PSObject.Properties["TestKind"]) {
            $profile | Add-Member -NotePropertyName "TestKind" -NotePropertyValue "Raw/block"
        }
        Ensure-ProfileCatalogKeys $profile
        $baseName = [string]$profile.Name
        if ([string]::IsNullOrWhiteSpace($baseName)) {
            $baseName = "Imported-Profile"
        }
        $targetPath = Get-ProfilePath $baseName
        if (Test-Path -LiteralPath $targetPath) {
            $profile.Name = ("{0}-Imported-{1}" -f $baseName, (Get-Date).ToString("yyyyMMdd-HHmmss"))
        }
        $profile.UpdatedAt = (Get-Date).ToString("o")
        Write-JsonFile (Get-ProfilePath $profile.Name) $profile
        $script:CurrentProfile = $profile
        Refresh-ProfileList
        $script:ProfileSelector.Text = [string]$profile.Name
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

function New-Label {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$W = 160,
        [int]$H = 22
    )
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point -ArgumentList $X, $Y
    $label.Size = New-Object System.Drawing.Size -ArgumentList $W, $H
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    return $label
}

function New-TextBox {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$W = 320,
        [int]$H = 24
    )
    $box = New-Object System.Windows.Forms.TextBox
    $box.Text = $Text
    $box.Location = New-Object System.Drawing.Point -ArgumentList $X, $Y
    $box.Size = New-Object System.Drawing.Size -ArgumentList $W, $H
    return $box
}

function New-Button {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$W = 110,
        [int]$H = 28
    )
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point -ArgumentList $X, $Y
    $button.Size = New-Object System.Drawing.Size -ArgumentList $W, $H
    return $button
}

function New-ComboBox {
    param(
        [string[]]$Items,
        [string]$Selected,
        [int]$X,
        [int]$Y,
        [int]$W = 180,
        [int]$H = 24
    )
    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
    $combo.Location = New-Object System.Drawing.Point -ArgumentList $X, $Y
    $combo.Size = New-Object System.Drawing.Size -ArgumentList $W, $H
    foreach ($item in $Items) {
        [void]$combo.Items.Add($item)
    }
    $combo.Text = $Selected
    return $combo
}

function Show-Info {
    param(
        [string]$Message,
        [string]$Title = "Vdbench UI"
    )
    [System.Windows.Forms.MessageBox]::Show($Message, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

function Show-Warning {
    param(
        [string]$Message,
        [string]$Title = "Vdbench UI"
    )
    [System.Windows.Forms.MessageBox]::Show($Message, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
}

function Ask-YesNo {
    param(
        [string]$Message,
        [string]$Title = "Confirm"
    )
    $result = [System.Windows.Forms.MessageBox]::Show($Message, $Title, [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
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

function Build-SettingsTab {
    $tab = New-Object System.Windows.Forms.TabPage
    $tab.Text = "Settings / Paths"

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $panel.AutoScroll = $true
    $tab.Controls.Add($panel)

    $fields = @(
        @{ Key = "InstallRoot"; Label = "Install root"; Browse = "folder" },
        @{ Key = "VdbenchRoot"; Label = "Vdbench root"; Browse = "folder" },
        @{ Key = "ManagerRoot"; Label = "Manager root"; Browse = "folder" },
        @{ Key = "ReportsRoot"; Label = "Reports root"; Browse = "folder" },
        @{ Key = "ReadinessChecker"; Label = "Readiness checker"; Browse = "file" },
        @{ Key = "MasterVdbenchBat"; Label = "Master vdbench.bat"; Browse = "file" },
        @{ Key = "WindowsVdbench"; Label = "Windows Vdbench path"; Browse = "folder" },
        @{ Key = "LinuxVdbench"; Label = "Linux Vdbench path"; Browse = "none" },
        @{ Key = "SshConfig"; Label = "SSH config"; Browse = "file" },
        @{ Key = "PrivateKey"; Label = "Private key"; Browse = "file" },
        @{ Key = "ReadinessCheckerArguments"; Label = "Readiness args template"; Browse = "none" },
        @{ Key = "SlaveShell"; Label = "Slave shell"; Browse = "none" },
        @{ Key = "SlaveUser"; Label = "Slave user"; Browse = "none" }
    )

    $y = 18
    foreach ($field in $fields) {
        $panel.Controls.Add((New-Label $field.Label 18 $y 180))
        $box = New-TextBox ([string](Get-PropertyValue $script:Settings $field.Key "")) 210 $y 520
        $panel.Controls.Add($box)
        $script:SettingsControls[$field.Key] = $box
        if ($field.Browse -ne "none") {
            $button = New-Button "Browse" 740 ($y - 2) 80 26
            if ($field.Browse -eq "folder") {
                $button.Add_Click({
                    param($sender, $eventArgs)
                    Browse-FolderForControl $sender.Tag
                })
            } else {
                $button.Add_Click({
                    param($sender, $eventArgs)
                    Browse-FileForControl $sender.Tag
                })
            }
            $button.Tag = $box
            $panel.Controls.Add($button)
        }
        $y += 34
    }

    $panel.Controls.Add((New-Label "Run mode" 18 $y 180))
    $mode = New-ComboBox @("Single local run", "Master/Slave distributed run") ([string](Get-PropertyValue $script:Settings "RunMode" "Single local run")) 210 $y 250
    $mode.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $mode.Add_SelectedIndexChanged({
        Capture-Settings
        Refresh-ConfigPreview
    })
    $panel.Controls.Add($mode)
    $script:SettingsControls["RunMode"] = $mode
    $y += 34

    $commentDisabled = New-Object System.Windows.Forms.CheckBox
    $commentDisabled.Text = "Render disabled parameters as comments"
    $commentDisabled.Checked = [bool](Get-PropertyValue $script:Settings "CommentDisabledParameters" $true)
    $commentDisabled.Location = New-Object System.Drawing.Point -ArgumentList 210, $y
    $commentDisabled.Size = New-Object System.Drawing.Size -ArgumentList 300, 24
    $panel.Controls.Add($commentDisabled)
    $script:SettingsControls["CommentDisabledParameters"] = $commentDisabled
    $y += 30

    $requirePreview = New-Object System.Windows.Forms.CheckBox
    $requirePreview.Text = "Require preview confirmation before run"
    $requirePreview.Checked = [bool](Get-PropertyValue $script:Settings "RequirePreviewBeforeRun" $true)
    $requirePreview.Location = New-Object System.Drawing.Point -ArgumentList 210, $y
    $requirePreview.Size = New-Object System.Drawing.Size -ArgumentList 300, 24
    $panel.Controls.Add($requirePreview)
    $script:SettingsControls["RequirePreviewBeforeRun"] = $requirePreview
    $y += 42

    $saveButton = New-Button "Save settings" 18 $y 120 30
    $saveButton.Add_Click({ Save-Settings })
    $panel.Controls.Add($saveButton)

    $validateButton = New-Button "Validate paths" 150 $y 120 30
    $validateButton.Add_Click({ Validate-SettingsPaths })
    $panel.Controls.Add($validateButton)

    $fakeButton = New-Button "Use fake runner" 282 $y 125 30
    $fakeButton.Add_Click({ Use-FakeRunnerSettings })
    $panel.Controls.Add($fakeButton)

    $importSettingsButton = New-Button "Import settings" 418 $y 125 30
    $importSettingsButton.Add_Click({ Import-Settings })
    $panel.Controls.Add($importSettingsButton)

    $exportSettingsButton = New-Button "Export settings" 554 $y 125 30
    $exportSettingsButton.Add_Click({ Export-Settings })
    $panel.Controls.Add($exportSettingsButton)

    $y += 46
    $script:SettingsStatusBox = New-Object System.Windows.Forms.TextBox
    $script:SettingsStatusBox.Multiline = $true
    $script:SettingsStatusBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
    $script:SettingsStatusBox.ReadOnly = $true
    $script:SettingsStatusBox.Font = New-Object System.Drawing.Font -ArgumentList "Consolas", 10
    $script:SettingsStatusBox.Location = New-Object System.Drawing.Point -ArgumentList 18, $y
    $script:SettingsStatusBox.Size = New-Object System.Drawing.Size -ArgumentList 1120, 250
    $panel.Controls.Add($script:SettingsStatusBox)
    Validate-SettingsPaths
    return $tab
}

function Build-SlaveGrid {
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = [System.Windows.Forms.DockStyle]::Fill
    $grid.AllowUserToAddRows = $true
    $grid.AllowUserToDeleteRows = $true
    $grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
    $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $grid.MultiSelect = $false

    $enabledCol = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $enabledCol.Name = "Enabled"
    $enabledCol.HeaderText = "Enabled"
    $enabledCol.FillWeight = 55
    $grid.Columns.Add($enabledCol) | Out-Null

    foreach ($name in @("Name", "Host")) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.Name = $name
        $col.HeaderText = $name
        $grid.Columns.Add($col) | Out-Null
    }

    $osCol = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
    $osCol.Name = "OsType"
    $osCol.HeaderText = "OS"
    [void]$osCol.Items.Add("Windows")
    [void]$osCol.Items.Add("Linux")
    $grid.Columns.Add($osCol) | Out-Null

    foreach ($name in @("VdbenchPath", "TestTarget", "SshAlias", "PrivateKey", "Status", "Notes")) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.Name = $name
        $col.HeaderText = $name
        if ($name -eq "Status") {
            $col.ReadOnly = $true
            $col.FillWeight = 80
        }
        $grid.Columns.Add($col) | Out-Null
    }
    return $grid
}

function Populate-SlaveGrid {
    $script:SlaveGrid.Rows.Clear()
    foreach ($slave in @($script:Slaves)) {
        $idx = $script:SlaveGrid.Rows.Add()
        $row = $script:SlaveGrid.Rows[$idx]
        foreach ($col in @("Enabled", "Name", "Host", "OsType", "VdbenchPath", "TestTarget", "SshAlias", "PrivateKey", "Status", "Notes")) {
            $row.Cells[$col].Value = Get-PropertyValue $slave $col ""
        }
    }
}

function Capture-SlaveGrid {
    if ($null -eq $script:SlaveGrid) {
        return
    }
    $items = @()
    foreach ($row in $script:SlaveGrid.Rows) {
        if ($row.IsNewRow) {
            continue
        }
        $name = [string]$row.Cells["Name"].Value
        $hostName = [string]$row.Cells["Host"].Value
        if ([string]::IsNullOrWhiteSpace($name) -and [string]::IsNullOrWhiteSpace($hostName)) {
            continue
        }
        $items += [pscustomobject]@{
            Enabled = [bool]$row.Cells["Enabled"].Value
            Name = $name
            Host = $hostName
            OsType = [string]$row.Cells["OsType"].Value
            VdbenchPath = [string]$row.Cells["VdbenchPath"].Value
            TestTarget = [string]$row.Cells["TestTarget"].Value
            SshAlias = [string]$row.Cells["SshAlias"].Value
            PrivateKey = [string]$row.Cells["PrivateKey"].Value
            Status = [string]$row.Cells["Status"].Value
            Notes = [string]$row.Cells["Notes"].Value
        }
    }
    $script:Slaves = @($items)
}

function Save-Slaves {
    Capture-SlaveGrid
    Write-JsonFile $script:SlavesPath $script:Slaves -AsArray
    Show-Info "Slave inventory saved."
    Refresh-ConfigPreview
}

function Get-SelectedSlaveRow {
    if ($script:SlaveGrid.SelectedRows.Count -gt 0) {
        return $script:SlaveGrid.SelectedRows[0]
    }
    if ($script:SlaveGrid.CurrentRow -and -not $script:SlaveGrid.CurrentRow.IsNewRow) {
        return $script:SlaveGrid.CurrentRow
    }
    return $null
}

function Test-SelectedSlaveConnection {
    $row = Get-SelectedSlaveRow
    if ($null -eq $row) {
        Show-Warning "Select a slave row first."
        return
    }
    Test-SlaveRowConnection $row
}

function Test-SlaveRowConnection {
    param([System.Windows.Forms.DataGridViewRow]$Row)
    if ($null -eq $Row -or $Row.IsNewRow) {
        return
    }
    $hostName = [string]$Row.Cells["Host"].Value
    if ([string]::IsNullOrWhiteSpace($hostName)) {
        $Row.Cells["Status"].Value = "Missing host"
        return
    }

    try {
        $result = Test-Connection -ComputerName $hostName -Count 1 -Quiet -ErrorAction Stop
        if ($result) {
            $Row.Cells["Status"].Value = "Ping OK"
        } else {
            $Row.Cells["Status"].Value = "Ping failed"
        }
    } catch {
        $Row.Cells["Status"].Value = "Ping error: " + $_.Exception.Message
    }
}

function Test-AllSlaveConnections {
    foreach ($row in $script:SlaveGrid.Rows) {
        if ($row.IsNewRow) {
            continue
        }
        Test-SlaveRowConnection $row
    }
}

function Check-SelectedSlaveReadiness {
    Capture-Settings
    $row = Get-SelectedSlaveRow
    if ($null -eq $row) {
        Show-Warning "Select a slave row first."
        return
    }
    Check-SlaveRowReadiness $row $true
}

function Check-SlaveRowReadiness {
    param(
        [System.Windows.Forms.DataGridViewRow]$Row,
        [bool]$ShowOutput
    )
    if ($null -eq $Row -or $Row.IsNewRow) {
        return
    }
    $checker = [string](Get-PropertyValue $script:Settings "ReadinessChecker" "")
    if ([string]::IsNullOrWhiteSpace($checker) -or -not (Test-Path -LiteralPath $checker)) {
        $Row.Cells["Status"].Value = "Readiness checker missing"
        if ($ShowOutput) {
            Show-Warning "Readiness checker path is missing or does not exist."
        }
        return
    }
    $hostName = [string]$Row.Cells["Host"].Value
    $vdbenchPath = [string]$Row.Cells["VdbenchPath"].Value
    $target = [string]$Row.Cells["TestTarget"].Value

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $template = [string](Get-PropertyValue $script:Settings "ReadinessCheckerArguments" "-HostName `"{Host}`" -VdbenchPath `"{VdbenchPath}`" -Target `"{Target}`"")
    $checkerArgs = $template.Replace("{Host}", $hostName).Replace("{VdbenchPath}", $vdbenchPath).Replace("{Target}", $target)
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$checker`" $checkerArgs"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        if ($p.ExitCode -eq 0) {
            $Row.Cells["Status"].Value = "Ready"
        } else {
            $Row.Cells["Status"].Value = "Readiness failed"
        }
        if ($ShowOutput) {
            Show-Info (($out + [Environment]::NewLine + $err).Trim()) "Readiness output"
        }
    } catch {
        $Row.Cells["Status"].Value = "Readiness error"
        if ($ShowOutput) {
            Show-Warning $_.Exception.Message
        }
    }
}

function Check-AllSlaveReadiness {
    Capture-Settings
    foreach ($row in $script:SlaveGrid.Rows) {
        if ($row.IsNewRow) {
            continue
        }
        Check-SlaveRowReadiness $row $false
    }
}

function Format-ByteSize {
    param([object]$Bytes)
    $value = 0.0
    if ($null -ne $Bytes) {
        [void][double]::TryParse([string]$Bytes, [ref]$value)
    }
    if ($value -ge 1tb) {
        return ("{0:N2} TB" -f ($value / 1tb))
    }
    if ($value -ge 1gb) {
        return ("{0:N2} GB" -f ($value / 1gb))
    }
    if ($value -ge 1mb) {
        return ("{0:N2} MB" -f ($value / 1mb))
    }
    return ("{0:N0} bytes" -f $value)
}

function New-TargetRecord {
    param(
        [string]$Kind,
        [string]$Target,
        [string]$Description
    )
    return [pscustomobject]@{
        Kind = $Kind
        Target = $Target
        Description = $Description
    }
}

function Convert-TargetInventoryOutput {
    param([string]$Text)
    $items = @()
    foreach ($line in (($Text -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $parts = $line.Split(@("|"), 3, [System.StringSplitOptions]::None)
        if ($parts.Count -lt 2) {
            continue
        }
        $kind = $parts[0].Trim()
        $target = $parts[1].Trim()
        $description = ""
        if ($parts.Count -gt 2) {
            $description = $parts[2].Trim()
        }
        if (-not [string]::IsNullOrWhiteSpace($target)) {
            $items += New-TargetRecord $kind $target $description
        }
    }
    return @($items)
}

function Get-LocalTargetInventory {
    $items = @()
    try {
        foreach ($disk in @(Get-CimInstance Win32_DiskDrive -ErrorAction Stop | Sort-Object Index)) {
            $index = [string](Get-PropertyValue $disk "Index" "")
            if ([string]::IsNullOrWhiteSpace($index)) {
                continue
            }
            $descriptionParts = @()
            foreach ($value in @($disk.Model, (Format-ByteSize $disk.Size), $disk.InterfaceType, $disk.MediaType)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
                    $descriptionParts += [string]$value
                }
            }
            $items += New-TargetRecord "Raw disk" ("\\.\PhysicalDrive{0}" -f $index) ($descriptionParts -join " | ")
        }
    } catch {
        $items += New-TargetRecord "Info" "" ("Disk discovery failed: " + $_.Exception.Message)
    }

    try {
        foreach ($volume in @(Get-CimInstance Win32_Volume -ErrorAction Stop | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.DriveLetter) } | Sort-Object DriveLetter)) {
            $descriptionParts = @()
            foreach ($value in @($volume.Label, $volume.FileSystem, (Format-ByteSize $volume.Capacity), ("Free " + (Format-ByteSize $volume.FreeSpace)))) {
                if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
                    $descriptionParts += [string]$value
                }
            }
            $items += New-TargetRecord "Filesystem" (($volume.DriveLetter) + "\") ($descriptionParts -join " | ")
        }
    } catch {
        foreach ($drive in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $items += New-TargetRecord "Filesystem" $drive.Root ("PSDrive " + $drive.Name)
        }
    }

    $rawDefault = Get-ProfileParamValue $script:CurrentProfile "storage.lun" ""
    if (-not [string]::IsNullOrWhiteSpace($rawDefault)) {
        $items += New-TargetRecord "Current profile" $rawDefault "Current raw/block target"
    }
    $fsDefault = Get-ProfileParamValue $script:CurrentProfile "fsd.anchor" ""
    if (-not [string]::IsNullOrWhiteSpace($fsDefault)) {
        $items += New-TargetRecord "Current profile" $fsDefault "Current filesystem anchor"
    }
    return @($items | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Target) })
}

function Invoke-CapturedProcess {
    param(
        [string]$FileName,
        [string]$Arguments,
        [int]$TimeoutMs = 20000
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($psi)
    $finished = $process.WaitForExit($TimeoutMs)
    if (-not $finished) {
        try {
            $process.Kill()
        } catch {
        }
        throw ("Command timed out: {0} {1}" -f $FileName, $Arguments)
    }
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut = $process.StandardOutput.ReadToEnd()
        StdErr = $process.StandardError.ReadToEnd()
    }
}

function Test-HostLooksLocal {
    param([string]$HostName)
    if ([string]::IsNullOrWhiteSpace($HostName)) {
        return $true
    }
    $value = $HostName.Trim().ToLowerInvariant()
    if (@("localhost", "127.0.0.1", "::1", ".") -contains $value) {
        return $true
    }
    if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME) -and $value -eq $env:COMPUTERNAME.ToLowerInvariant()) {
        return $true
    }
    return $false
}

function Get-SlaveTargetInventory {
    param([System.Windows.Forms.DataGridViewRow]$Row)
    if ($null -eq $Row -or $Row.IsNewRow) {
        return @()
    }
    $hostName = [string]$Row.Cells["Host"].Value
    if (Test-HostLooksLocal $hostName) {
        return Get-LocalTargetInventory
    }

    $systemName = [string]$Row.Cells["SshAlias"].Value
    if ([string]::IsNullOrWhiteSpace($systemName)) {
        $systemName = $hostName
    }
    if ([string]::IsNullOrWhiteSpace($systemName)) {
        throw "Slave Host or SshAlias is required for remote discovery."
    }

    $osType = [string]$Row.Cells["OsType"].Value
    $sshParts = New-Object System.Collections.Generic.List[string]
    $sshConfig = [string](Get-PropertyValue $script:Settings "SshConfig" "")
    if (-not [string]::IsNullOrWhiteSpace($sshConfig) -and (Test-Path -LiteralPath $sshConfig)) {
        [void]$sshParts.Add("-F")
        [void]$sshParts.Add((Quote-ProcessArgument $sshConfig))
    }
    $privateKey = [string]$Row.Cells["PrivateKey"].Value
    if ([string]::IsNullOrWhiteSpace($privateKey)) {
        $privateKey = [string](Get-PropertyValue $script:Settings "PrivateKey" "")
    }
    if (-not [string]::IsNullOrWhiteSpace($privateKey) -and (Test-Path -LiteralPath $privateKey)) {
        [void]$sshParts.Add("-i")
        [void]$sshParts.Add((Quote-ProcessArgument $privateKey))
    }
    [void]$sshParts.Add("-o")
    [void]$sshParts.Add("BatchMode=yes")
    [void]$sshParts.Add("-o")
    [void]$sshParts.Add("ConnectTimeout=8")
    [void]$sshParts.Add((Quote-ProcessArgument $systemName))

    if ($osType -eq "Linux") {
        $remoteScript = 'for d in /sys/block/*; do name=${d##*/}; case "$name" in loop*|ram*) continue;; esac; size=$(cat "$d/size" 2>/dev/null); bytes=$((size*512)); echo "Raw disk|/dev/$name|bytes=$bytes"; done; if command -v findmnt >/dev/null 2>&1; then findmnt -rn -o TARGET,SOURCE,FSTYPE | while read target source fstype; do echo "Filesystem|$target|$source $fstype"; done; fi'
        [void]$sshParts.Add("sh")
        [void]$sshParts.Add("-lc")
        [void]$sshParts.Add((Quote-ProcessArgument $remoteScript))
    } else {
        $remoteScript = '$ErrorActionPreference="SilentlyContinue"; Get-CimInstance Win32_DiskDrive | ForEach-Object { "Raw disk|\\.\PhysicalDrive$($_.Index)|$($_.Model) $($_.Size)" }; Get-CimInstance Win32_Volume | Where-Object { $_.DriveLetter } | ForEach-Object { "Filesystem|$($_.DriveLetter)\|$($_.Label) $($_.FileSystem) $($_.Capacity)" }'
        [void]$sshParts.Add("powershell.exe")
        [void]$sshParts.Add("-NoProfile")
        [void]$sshParts.Add("-Command")
        [void]$sshParts.Add((Quote-ProcessArgument $remoteScript))
    }

    $result = Invoke-CapturedProcess "ssh.exe" ($sshParts -join " ") 20000
    if ($result.ExitCode -ne 0) {
        throw (($result.StdErr + [Environment]::NewLine + $result.StdOut).Trim())
    }
    $targets = @(Convert-TargetInventoryOutput $result.StdOut)
    if ($targets.Count -eq 0) {
        throw "Remote discovery returned no targets."
    }
    return $targets
}

function Select-TargetFromList {
    param(
        [object[]]$Targets,
        [string]$Title
    )
    $validTargets = @($Targets | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Target) })
    if ($validTargets.Count -eq 0) {
        Show-Warning "No selectable targets were found."
        return $null
    }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.Size = New-Object System.Drawing.Size -ArgumentList 880, 480
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $false

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = [System.Windows.Forms.DockStyle]::Fill
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $grid.MultiSelect = $false
    $grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
    foreach ($name in @("Kind", "Target", "Description")) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.Name = $name
        $col.HeaderText = $name
        if ($name -eq "Target") {
            $col.FillWeight = 140
        }
        $grid.Columns.Add($col) | Out-Null
    }
    foreach ($item in $validTargets) {
        $idx = $grid.Rows.Add()
        $grid.Rows[$idx].Cells["Kind"].Value = [string]$item.Kind
        $grid.Rows[$idx].Cells["Target"].Value = [string]$item.Target
        $grid.Rows[$idx].Cells["Description"].Value = [string]$item.Description
    }
    $dialog.Controls.Add($grid)

    $buttonPanel = New-Object System.Windows.Forms.Panel
    $buttonPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $buttonPanel.Height = 46
    $dialog.Controls.Add($buttonPanel)

    $okButton = New-Button "Use selected" 650 9 110 28
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $buttonPanel.Controls.Add($okButton)
    $cancelButton = New-Button "Cancel" 770 9 80 28
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $buttonPanel.Controls.Add($cancelButton)
    $dialog.AcceptButton = $okButton
    $dialog.CancelButton = $cancelButton
    $grid.Add_CellDoubleClick({
        param($sender, $eventArgs)
        if ($eventArgs.RowIndex -ge 0) {
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dialog.Close()
        }
    })
    if ($grid.Rows.Count -gt 0) {
        $grid.Rows[0].Selected = $true
    }

    $result = $dialog.ShowDialog($script:Form)
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }
    if ($grid.SelectedRows.Count -eq 0) {
        return $null
    }
    return [string]$grid.SelectedRows[0].Cells["Target"].Value
}

function Pick-TargetForSelectedSlave {
    Capture-Settings
    $row = Get-SelectedSlaveRow
    if ($null -eq $row) {
        Show-Warning "Select a slave row first."
        return
    }
    try {
        $targets = @(Get-SlaveTargetInventory $row)
        $selected = Select-TargetFromList $targets "Select slave test target"
        if (-not [string]::IsNullOrWhiteSpace($selected)) {
            $row.Cells["TestTarget"].Value = $selected
            $row.Cells["Status"].Value = "Target selected"
            Capture-SlaveGrid
            Refresh-ConfigPreview
        }
    } catch {
        Show-Warning ("Target discovery failed: " + $_.Exception.Message)
    }
}

function Build-MasterSlaveTab {
    $tab = New-Object System.Windows.Forms.TabPage
    $tab.Text = "Master / Slave"

    $container = New-Object System.Windows.Forms.TableLayoutPanel
    $container.Dock = [System.Windows.Forms.DockStyle]::Fill
    $container.RowCount = 2
    $container.ColumnCount = 1
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 52)) | Out-Null
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100)) | Out-Null
    $tab.Controls.Add($container)

    $toolbar = New-Object System.Windows.Forms.Panel
    $toolbar.Dock = [System.Windows.Forms.DockStyle]::Fill
    $container.Controls.Add($toolbar, 0, 0)

    $addButton = New-Button "Add slave" 10 12 95 28
    $addButton.Add_Click({
        $idx = $script:SlaveGrid.Rows.Add()
        $row = $script:SlaveGrid.Rows[$idx]
        $row.Cells["Enabled"].Value = $true
        $row.Cells["Name"].Value = "slave-" + ($idx + 1)
        $row.Cells["Host"].Value = "host-or-ip"
        $row.Cells["OsType"].Value = "Windows"
        $row.Cells["VdbenchPath"].Value = (Get-PropertyValue $script:Settings "WindowsVdbench" "C:\vdbench")
        $row.Cells["TestTarget"].Value = "C:\vdbench\testfile.dat"
        $row.Cells["Status"].Value = "Not checked"
    })
    $toolbar.Controls.Add($addButton)

    $removeButton = New-Button "Remove" 112 12 80 28
    $removeButton.Add_Click({
        $row = Get-SelectedSlaveRow
        if ($row -and -not $row.IsNewRow) {
            $script:SlaveGrid.Rows.Remove($row)
        }
    })
    $toolbar.Controls.Add($removeButton)

    $saveButton = New-Button "Save" 200 12 80 28
    $saveButton.Add_Click({ Save-Slaves })
    $toolbar.Controls.Add($saveButton)

    $testButton = New-Button "Test ping" 288 12 95 28
    $testButton.Add_Click({ Test-SelectedSlaveConnection })
    $toolbar.Controls.Add($testButton)

    $pingAllButton = New-Button "Ping all" 390 12 80 28
    $pingAllButton.Add_Click({ Test-AllSlaveConnections })
    $toolbar.Controls.Add($pingAllButton)

    $readyButton = New-Button "Check readiness" 478 12 125 28
    $readyButton.Add_Click({ Check-SelectedSlaveReadiness })
    $toolbar.Controls.Add($readyButton)

    $readyAllButton = New-Button "Readiness all" 610 12 105 28
    $readyAllButton.Add_Click({ Check-AllSlaveReadiness })
    $toolbar.Controls.Add($readyAllButton)

    $exportButton = New-Button "Export" 723 12 75 28
    $exportButton.Add_Click({ Export-SlaveInventory })
    $toolbar.Controls.Add($exportButton)

    $importButton = New-Button "Import" 806 12 75 28
    $importButton.Add_Click({ Import-SlaveInventory })
    $toolbar.Controls.Add($importButton)

    $pickTargetButton = New-Button "Pick target" 889 12 95 28
    $pickTargetButton.Add_Click({ Pick-TargetForSelectedSlave })
    $toolbar.Controls.Add($pickTargetButton)

    $note = New-Label "TestTarget is the slave disk/device/directory. Disabled rows are omitted from config." 995 15 330 24
    $toolbar.Controls.Add($note)

    $script:SlaveGrid = Build-SlaveGrid
    $container.Controls.Add($script:SlaveGrid, 0, 1)
    Populate-SlaveGrid
    return $tab
}

function Show-ParameterHelp {
    param([object]$Definition)
    $message = @(
        ("Parameter: {0}" -f $Definition.Label),
        ("Vdbench name: {0}" -f $Definition.VdbenchName),
        ("Section: {0}" -f $Definition.Section),
        "",
        [string]$Definition.Help,
        "",
        ("Example: {0}" -f $Definition.Example),
        "",
        "Disable behavior: clearing Enabled keeps the value in the profile but comments it out in generated config."
    ) -join [Environment]::NewLine
    Show-Info $message "Parameter help"
}

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

function Add-ParameterRow {
    param(
        [System.Windows.Forms.Panel]$Panel,
        [object]$Definition,
        [int]$Y
    )
    $key = [string]$Definition.Key
    $param = Get-ProfileParam $script:CurrentProfile $key

    $enabled = New-Object System.Windows.Forms.CheckBox
    $enabled.Text = "Enabled"
    $enabled.Checked = [bool]$param.Enabled
    $enabled.Location = New-Object System.Drawing.Point -ArgumentList 12, $Y
    $enabled.Size = New-Object System.Drawing.Size -ArgumentList 78, 24
    $Panel.Controls.Add($enabled)

    $label = New-Label ([string]$Definition.Label) 96 $Y 210
    $Panel.Controls.Add($label)

    $helpButton = New-Button "?" 310 ($Y - 1) 28 24
    $helpButton.Tag = $Definition
    $helpButton.Add_Click({
        param($sender, $eventArgs)
        Show-ParameterHelp $sender.Tag
    })
    $Panel.Controls.Add($helpButton)

    $type = [string](Get-PropertyValue $Definition "Type" "text")
    $valueControl = $null
    if ($type -eq "dropdown") {
        $items = @()
        foreach ($option in @($Definition.Options)) {
            $items += [string]$option
        }
        $valueControl = New-ComboBox $items ([string]$param.Value) 350 $Y 220
    } else {
        $valueControl = New-TextBox ([string]$param.Value) 350 $Y 220
    }
    $Panel.Controls.Add($valueControl)

    $vdName = New-Label ([string]$Definition.VdbenchName) 590 $Y 120
    $vdName.ForeColor = [System.Drawing.Color]::DimGray
    $Panel.Controls.Add($vdName)

    $line = New-Label ([string]$Definition.Line) 720 $Y 120
    $line.ForeColor = [System.Drawing.Color]::DimGray
    $Panel.Controls.Add($line)

    $script:ParameterControls[$key] = [pscustomobject]@{
        Enabled = $enabled
        Value = $valueControl
        Definition = $Definition
    }
}

function Capture-ProfileEditor {
    if ($null -eq $script:CurrentProfile) {
        return
    }
    if ($script:ProfileNameBox) {
        $script:CurrentProfile.Name = [string]$script:ProfileNameBox.Text
    }
    if ($script:ProfileKindCombo) {
        $script:CurrentProfile.TestKind = [string]$script:ProfileKindCombo.Text
    }
    foreach ($key in $script:ParameterControls.Keys) {
        $entry = $script:ParameterControls[$key]
        Set-ProfileParamEnabled $script:CurrentProfile $key ([bool]$entry.Enabled.Checked)
        Set-ProfileParamValue $script:CurrentProfile $key ([string]$entry.Value.Text)
    }
    if ($script:AdvancedActiveBox) {
        $script:CurrentProfile.AdvancedActive = $script:AdvancedActiveBox.Text
    }
    if ($script:AdvancedDisabledBox) {
        $script:CurrentProfile.AdvancedDisabled = $script:AdvancedDisabledBox.Text
    }
}

function Refresh-ProfileEditor {
    if ($null -eq $script:CurrentProfile) {
        $script:CurrentProfile = New-DefaultProfile "New-Profile" "Raw/block"
    }
    $script:RefreshingProfileEditor = $true
    $script:ParameterControls = @{}
    $script:ProfileNameBox.Text = [string]$script:CurrentProfile.Name
    $script:ProfileKindCombo.Text = [string]$script:CurrentProfile.TestKind
    $script:ProfileParamTabs.TabPages.Clear()

    $testKind = [string]$script:CurrentProfile.TestKind
    $sections = @($script:Catalog | Where-Object { Definition-AppliesToKind $_ $testKind } | Select-Object -ExpandProperty Section -Unique)
    foreach ($section in $sections) {
        $tab = New-Object System.Windows.Forms.TabPage
        $tab.Text = $section
        $panel = New-Object System.Windows.Forms.Panel
        $panel.Dock = [System.Windows.Forms.DockStyle]::Fill
        $panel.AutoScroll = $true
        $tab.Controls.Add($panel)

        $y = 16
        $headers = @(
            @{ Text = "State"; X = 12; W = 75 },
            @{ Text = "Parameter"; X = 96; W = 210 },
            @{ Text = "Help"; X = 310; W = 40 },
            @{ Text = "Value"; X = 350; W = 220 },
            @{ Text = "Vdbench"; X = 590; W = 120 },
            @{ Text = "Line"; X = 720; W = 120 }
        )
        foreach ($header in $headers) {
            $h = New-Label $header.Text $header.X $y $header.W
            $h.Font = New-Object System.Drawing.Font -ArgumentList $h.Font, ([System.Drawing.FontStyle]::Bold)
            $panel.Controls.Add($h)
        }
        $y += 30
        foreach ($def in @($script:Catalog | Where-Object { $_.Section -eq $section -and (Definition-AppliesToKind $_ $testKind) })) {
            Add-ParameterRow $panel $def $y
            $y += 32
        }
        $script:ProfileParamTabs.TabPages.Add($tab) | Out-Null
    }

    $advTab = New-Object System.Windows.Forms.TabPage
    $advTab.Text = "Advanced manual lines"
    $advPanel = New-Object System.Windows.Forms.Panel
    $advPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $advPanel.AutoScroll = $true
    $advTab.Controls.Add($advPanel)

    $advPanel.Controls.Add((New-Label "Active manual Vdbench lines" 12 12 260))
    $script:AdvancedActiveBox = New-Object System.Windows.Forms.TextBox
    $script:AdvancedActiveBox.Multiline = $true
    $script:AdvancedActiveBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
    $script:AdvancedActiveBox.Font = New-Object System.Drawing.Font -ArgumentList "Consolas", 10
    $script:AdvancedActiveBox.Text = [string](Get-PropertyValue $script:CurrentProfile "AdvancedActive" "")
    $script:AdvancedActiveBox.Location = New-Object System.Drawing.Point -ArgumentList 12, 40
    $script:AdvancedActiveBox.Size = New-Object System.Drawing.Size -ArgumentList 950, 190
    $advPanel.Controls.Add($script:AdvancedActiveBox)

    $advPanel.Controls.Add((New-Label "Disabled/commented manual lines" 12 250 260))
    $script:AdvancedDisabledBox = New-Object System.Windows.Forms.TextBox
    $script:AdvancedDisabledBox.Multiline = $true
    $script:AdvancedDisabledBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
    $script:AdvancedDisabledBox.Font = New-Object System.Drawing.Font -ArgumentList "Consolas", 10
    $script:AdvancedDisabledBox.Text = [string](Get-PropertyValue $script:CurrentProfile "AdvancedDisabled" "")
    $script:AdvancedDisabledBox.Location = New-Object System.Drawing.Point -ArgumentList 12, 278
    $script:AdvancedDisabledBox.Size = New-Object System.Drawing.Size -ArgumentList 950, 190
    $advPanel.Controls.Add($script:AdvancedDisabledBox)

    $script:ProfileParamTabs.TabPages.Add($advTab) | Out-Null
    $script:RefreshingProfileEditor = $false
    Refresh-ConfigPreview
}

function Refresh-ProfileList {
    if (-not $script:ProfileSelector) {
        return
    }
    $current = [string]$script:ProfileSelector.Text
    $script:ProfileSelector.Items.Clear()
    foreach ($name in Get-ProfileNames) {
        [void]$script:ProfileSelector.Items.Add($name)
    }
    if (-not [string]::IsNullOrWhiteSpace($current)) {
        $script:ProfileSelector.Text = $current
    }
}

function Pick-TargetForCurrentProfile {
    if ($null -eq $script:CurrentProfile) {
        Show-Warning "Create or load a profile first."
        return
    }
    Capture-ProfileEditor
    try {
        $targets = @(Get-LocalTargetInventory)
        $selected = Select-TargetFromList $targets "Select local profile target"
        if ([string]::IsNullOrWhiteSpace($selected)) {
            return
        }
        $key = "storage.lun"
        if ([string]$script:CurrentProfile.TestKind -eq "Filesystem") {
            $key = "fsd.anchor"
        }
        Set-ProfileParamValue $script:CurrentProfile $key $selected
        Set-ProfileParamEnabled $script:CurrentProfile $key $true
        if ($script:ParameterControls.ContainsKey($key)) {
            $entry = $script:ParameterControls[$key]
            $entry.Value.Text = $selected
            $entry.Enabled.Checked = $true
        }
        Refresh-ConfigPreview
    } catch {
        Show-Warning ("Target discovery failed: " + $_.Exception.Message)
    }
}

function Build-ProfileTab {
    $tab = New-Object System.Windows.Forms.TabPage
    $tab.Text = "Profile Builder"

    $container = New-Object System.Windows.Forms.TableLayoutPanel
    $container.Dock = [System.Windows.Forms.DockStyle]::Fill
    $container.RowCount = 2
    $container.ColumnCount = 1
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 78)) | Out-Null
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100)) | Out-Null
    $tab.Controls.Add($container)

    $toolbar = New-Object System.Windows.Forms.Panel
    $toolbar.Dock = [System.Windows.Forms.DockStyle]::Fill
    $container.Controls.Add($toolbar, 0, 0)

    $toolbar.Controls.Add((New-Label "Profile" 10 12 60))
    $script:ProfileSelector = New-ComboBox @() "" 72 10 230
    $toolbar.Controls.Add($script:ProfileSelector)

    $loadButton = New-Button "Load" 310 9 70 27
    $loadButton.Add_Click({
        $profile = Load-ProfileByName ([string]$script:ProfileSelector.Text)
        if ($profile) {
            $script:CurrentProfile = $profile
            Refresh-ProfileEditor
        }
    })
    $toolbar.Controls.Add($loadButton)

    $newRawButton = New-Button "New raw" 388 9 80 27
    $newRawButton.Add_Click({
        $script:CurrentProfile = New-DefaultProfile "New-Raw-Profile" "Raw/block"
        Refresh-ProfileEditor
    })
    $toolbar.Controls.Add($newRawButton)

    $newFsButton = New-Button "New fs" 476 9 75 27
    $newFsButton.Add_Click({
        $script:CurrentProfile = New-DefaultProfile "New-Filesystem-Profile" "Filesystem"
        Refresh-ProfileEditor
    })
    $toolbar.Controls.Add($newFsButton)

    $saveButton = New-Button "Save profile" 560 9 105 27
    $saveButton.Add_Click({ Save-CurrentProfile })
    $toolbar.Controls.Add($saveButton)

    $previewButton = New-Button "Refresh preview" 674 9 120 27
    $previewButton.Add_Click({
        Capture-ProfileEditor
        Refresh-ConfigPreview
    })
    $toolbar.Controls.Add($previewButton)

    $duplicateButton = New-Button "Duplicate" 804 9 90 27
    $duplicateButton.Add_Click({ Duplicate-CurrentProfile })
    $toolbar.Controls.Add($duplicateButton)

    $deleteButton = New-Button "Delete" 902 9 80 27
    $deleteButton.Add_Click({ Delete-SelectedProfile })
    $toolbar.Controls.Add($deleteButton)

    $folderButton = New-Button "Folder" 990 9 75 27
    $folderButton.Add_Click({ Open-ProfileFolder })
    $toolbar.Controls.Add($folderButton)

    $importButton = New-Button "Import" 1074 9 75 27
    $importButton.Add_Click({ Import-Profile })
    $toolbar.Controls.Add($importButton)

    $exportButton = New-Button "Export" 1156 9 75 27
    $exportButton.Add_Click({ Export-CurrentProfile })
    $toolbar.Controls.Add($exportButton)

    $toolbar.Controls.Add((New-Label "Name" 10 46 50))
    $script:ProfileNameBox = New-TextBox "" 72 44 230
    $toolbar.Controls.Add($script:ProfileNameBox)

    $toolbar.Controls.Add((New-Label "Type" 318 46 40))
    $script:ProfileKindCombo = New-ComboBox @("Raw/block", "Filesystem") "Raw/block" 360 44 150
    $script:ProfileKindCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $script:ProfileKindCombo.Add_SelectedIndexChanged({
        if ($script:RefreshingProfileEditor) {
            return
        }
        if ($script:CurrentProfile) {
            Capture-ProfileEditor
            $script:CurrentProfile.TestKind = [string]$script:ProfileKindCombo.Text
            Refresh-ProfileEditor
        }
    })
    $toolbar.Controls.Add($script:ProfileKindCombo)

    $pickLocalTargetButton = New-Button "Pick target" 530 43 95 27
    $pickLocalTargetButton.Add_Click({ Pick-TargetForCurrentProfile })
    $toolbar.Controls.Add($pickLocalTargetButton)

    $note = New-Label "Every parameter has help. Clear Enabled to preserve values but comment them in generated config." 635 46 590
    $toolbar.Controls.Add($note)

    $script:ProfileParamTabs = New-Object System.Windows.Forms.TabControl
    $script:ProfileParamTabs.Dock = [System.Windows.Forms.DockStyle]::Fill
    $container.Controls.Add($script:ProfileParamTabs, 0, 1)

    Refresh-ProfileList
    $names = Get-ProfileNames
    if ($names.Count -gt 0) {
        $script:CurrentProfile = Load-ProfileByName $names[0]
        $script:ProfileSelector.Text = $names[0]
    } else {
        $script:CurrentProfile = New-DefaultProfile "New-Profile" "Raw/block"
    }
    Refresh-ProfileEditor
    return $tab
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
    if ([string]::IsNullOrWhiteSpace($value)) {
        return
    }
    $name = [string]$Definition.VdbenchName
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

function Add-TargetRiskWarnings {
    param(
        [System.Collections.Generic.List[string]]$Warnings,
        [string]$TestKind,
        [bool]$Distributed
    )
    if ($TestKind -eq "Raw/block") {
        if ($Distributed) {
            foreach ($slave in @(Get-EnabledSlaves)) {
                $target = [string](Get-PropertyValue $slave "TestTarget" "")
                if (Test-RawDeviceTarget $target) {
                    [void]$Warnings.Add(("RISK: slave '{0}' target '{1}' looks like a raw physical device." -f $slave.Name, $target))
                }
            }
        } else {
            $target = Get-ProfileParamValue $script:CurrentProfile "storage.lun" ""
            if (Test-RawDeviceTarget $target) {
                [void]$Warnings.Add(("RISK: local target '{0}' looks like a raw physical device." -f $target))
            }
        }
    } elseif ($TestKind -eq "Filesystem") {
        $format = Get-ProfileParamValue $script:CurrentProfile "run.format" "no"
        if (Get-ProfileParamEnabled $script:CurrentProfile "run.format" -and $format -ne "no") {
            [void]$Warnings.Add(("RISK: filesystem format is enabled with value '{0}'." -f $format))
        }
        if ($Distributed) {
            foreach ($slave in @(Get-EnabledSlaves)) {
                $target = [string](Get-PropertyValue $slave "TestTarget" "")
                if (Test-FilesystemRootTarget $target) {
                    [void]$Warnings.Add(("RISK: slave '{0}' filesystem target '{1}' looks like a root drive/path." -f $slave.Name, $target))
                }
            }
        } else {
            $target = Get-ProfileParamValue $script:CurrentProfile "fsd.anchor" ""
            if (Test-FilesystemRootTarget $target) {
                [void]$Warnings.Add(("RISK: filesystem anchor '{0}' looks like a root drive/path." -f $target))
            }
        }
    }
}

function Get-RiskWarnings {
    param([object]$BuiltConfig)
    return @($BuiltConfig.Warnings | Where-Object { [string]$_ -like "RISK:*" })
}

function Get-EnabledSlaves {
    Capture-SlaveGrid
    return @($script:Slaves | Where-Object { [bool]$_.Enabled })
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
    Capture-Settings
    Capture-ProfileEditor

    $testKind = [string]$script:CurrentProfile.TestKind
    $distributed = Is-DistributedMode
    $warnings = New-Object System.Collections.Generic.List[string]
    $disabled = New-Object System.Collections.Generic.List[string]
    $lines = New-Object System.Collections.Generic.List[string]

    foreach ($def in @($script:Catalog | Where-Object { Definition-AppliesToKind $_ $testKind })) {
        $required = [bool](Get-PropertyValue $def "Required" $false)
        if (-not $required) {
            continue
        }
        $key = [string]$def.Key
        $value = Get-ProfileParamValue $script:CurrentProfile $key ""
        if (-not (Get-ProfileParamEnabled $script:CurrentProfile $key)) {
            [void]$warnings.Add(("Required parameter is disabled: {0}" -f $def.Label))
        } elseif ([string]::IsNullOrWhiteSpace($value)) {
            [void]$warnings.Add(("Required parameter is empty: {0}" -f $def.Label))
        }
    }
    Add-TargetRiskWarnings $warnings $testKind $distributed

    [void]$lines.Add("* Generated by Vdbench UI")
    [void]$lines.Add(("* GeneratedAt={0}" -f (Get-Date).ToString("o")))
    [void]$lines.Add(("* Profile={0}" -f $script:CurrentProfile.Name))
    [void]$lines.Add(("* Mode={0}" -f (Get-Mode)))
    [void]$lines.Add("")

    if ($distributed) {
        $slaves = @(Get-EnabledSlaves)
        if ($slaves.Count -eq 0) {
            [void]$warnings.Add("Master/Slave mode is enabled but no enabled slaves exist.")
        }
        [void]$lines.Add("* Host definitions")
        $hostDefaults = New-Object System.Collections.Generic.List[string]
        [void]$hostDefaults.Add("hd=default")
        $slaveShell = [string](Get-PropertyValue $script:Settings "SlaveShell" "ssh")
        $slaveUser = [string](Get-PropertyValue $script:Settings "SlaveUser" "")
        if (-not [string]::IsNullOrWhiteSpace($slaveShell)) {
            [void]$hostDefaults.Add(("shell={0}" -f $slaveShell))
        }
        if (-not [string]::IsNullOrWhiteSpace($slaveUser)) {
            [void]$hostDefaults.Add(("user={0}" -f $slaveUser))
        }
        [void]$lines.Add(($hostDefaults -join ","))
        foreach ($slave in $slaves) {
            $name = [string]$slave.Name
            $hostName = [string]$slave.Host
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
            [void]$lines.Add(("hd={0},system={1},vdbench={2}" -f $name, $systemName, $vdPath))
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
                $parts = New-Object System.Collections.Generic.List[string]
                $safeName = ([string]$slave.Name) -replace "[^A-Za-z0-9_]", "_"
                [void]$parts.Add(("sd=sd_{0}" -f $safeName))
                [void]$parts.Add(("host={0}" -f $slave.Name))
                if ([string]::IsNullOrWhiteSpace([string]$slave.TestTarget)) {
                    [void]$warnings.Add("Enabled slave '$($slave.Name)' has no TestTarget.")
                } else {
                    [void]$parts.Add(("lun={0}" -f $slave.TestTarget))
                }
                foreach ($def in Get-DefinitionsForLine "storage" $testKind) {
                    if ($def.Key -eq "storage.lun") {
                        continue
                    }
                    Add-EnabledParameter $parts $disabled $def "storage"
                }
                [void]$lines.Add(($parts -join ","))
            }
        } else {
            $parts = New-Object System.Collections.Generic.List[string]
            [void]$parts.Add(("sd={0}" -f $sdName))
            foreach ($def in Get-DefinitionsForLine "storage" $testKind) {
                Add-EnabledParameter $parts $disabled $def "storage"
            }
            [void]$lines.Add(($parts -join ","))
        }
        [void]$lines.Add("")

        [void]$lines.Add("* Workload definitions")
        $wdParts = New-Object System.Collections.Generic.List[string]
        [void]$wdParts.Add(("wd={0}" -f $wdName))
        if ($distributed) {
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
                $parts = New-Object System.Collections.Generic.List[string]
                $safeName = ([string]$slave.Name) -replace "[^A-Za-z0-9_]", "_"
                [void]$parts.Add(("fsd=fsd_{0}" -f $safeName))
                [void]$parts.Add(("host={0}" -f $slave.Name))
                if ([string]::IsNullOrWhiteSpace([string]$slave.TestTarget)) {
                    [void]$warnings.Add("Enabled slave '$($slave.Name)' has no TestTarget.")
                } else {
                    [void]$parts.Add(("anchor={0}" -f $slave.TestTarget))
                }
                foreach ($def in Get-DefinitionsForLine "fsd" $testKind) {
                    if ($def.Key -eq "fsd.anchor") {
                        continue
                    }
                    Add-EnabledParameter $parts $disabled $def "fsd"
                }
                [void]$lines.Add(($parts -join ","))
            }
        } else {
            $parts = New-Object System.Collections.Generic.List[string]
            [void]$parts.Add(("fsd={0}" -f $fsdName))
            foreach ($def in Get-DefinitionsForLine "fsd" $testKind) {
                Add-EnabledParameter $parts $disabled $def "fsd"
            }
            [void]$lines.Add(($parts -join ","))
        }
        [void]$lines.Add("")

        [void]$lines.Add("* Filesystem workload")
        $fwdParts = New-Object System.Collections.Generic.List[string]
        [void]$fwdParts.Add(("fwd={0}" -f $fwdName))
        if ($distributed) {
            [void]$fwdParts.Add("fsd=fsd*")
        } else {
            [void]$fwdParts.Add(("fsd={0}" -f $fsdName))
        }
        foreach ($def in Get-DefinitionsForLine "fwd" $testKind) {
            Add-EnabledParameter $fwdParts $disabled $def "fwd"
        }
        [void]$lines.Add(($fwdParts -join ","))
        [void]$lines.Add("")

        [void]$lines.Add("* Run definition")
        $rdParts = New-Object System.Collections.Generic.List[string]
        [void]$rdParts.Add(("rd={0}" -f $rdName))
        [void]$rdParts.Add(("fwd={0}" -f $fwdName))
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
}

function Refresh-ConfigPreview {
    if (-not $script:ConfigPreviewBox -or $null -eq $script:CurrentProfile) {
        return
    }
    try {
        $built = Build-VdbenchConfig
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
    }
}

function Build-PreviewTab {
    $tab = New-Object System.Windows.Forms.TabPage
    $tab.Text = "Config Preview"

    $container = New-Object System.Windows.Forms.TableLayoutPanel
    $container.Dock = [System.Windows.Forms.DockStyle]::Fill
    $container.RowCount = 2
    $container.ColumnCount = 1
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 44)) | Out-Null
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100)) | Out-Null
    $tab.Controls.Add($container)

    $toolbar = New-Object System.Windows.Forms.Panel
    $toolbar.Dock = [System.Windows.Forms.DockStyle]::Fill
    $container.Controls.Add($toolbar, 0, 0)

    $refreshButton = New-Button "Refresh" 10 8 85 28
    $refreshButton.Add_Click({ Refresh-ConfigPreview })
    $toolbar.Controls.Add($refreshButton)

    $copyButton = New-Button "Copy config" 104 8 100 28
    $copyButton.Add_Click({
        [System.Windows.Forms.Clipboard]::SetText($script:ConfigPreviewBox.Text)
    })
    $toolbar.Controls.Add($copyButton)

    $saveButton = New-Button "Save .parm" 214 8 100 28
    $saveButton.Add_Click({
        $dialog = New-Object System.Windows.Forms.SaveFileDialog
        $dialog.Filter = "Vdbench parameter file (*.parm)|*.parm|Text file (*.txt)|*.txt|All files (*.*)|*.*"
        $dialog.FileName = ((Sanitize-FileName $script:CurrentProfile.Name) + ".parm")
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            [System.IO.File]::WriteAllText($dialog.FileName, $script:ConfigPreviewBox.Text, [System.Text.Encoding]::ASCII)
        }
    })
    $toolbar.Controls.Add($saveButton)

    $script:ConfigPreviewBox = New-Object System.Windows.Forms.TextBox
    $script:ConfigPreviewBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ConfigPreviewBox.Multiline = $true
    $script:ConfigPreviewBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
    $script:ConfigPreviewBox.Font = New-Object System.Drawing.Font -ArgumentList "Consolas", 10
    $script:ConfigPreviewBox.WordWrap = $false
    $container.Controls.Add($script:ConfigPreviewBox, 0, 1)
    return $tab
}

function Queue-RunLog {
    param([string]$Message)
    $script:LogQueue.Enqueue($Message)
}

function Flush-RunLog {
    if (-not $script:RunLogBox) {
        return
    }
    $msg = $null
    $count = 0
    while ($script:LogQueue.TryDequeue([ref]$msg)) {
        $script:RunLogBox.AppendText($msg + [Environment]::NewLine)
        Add-MetricPointFromLine $msg
        $count++
        if ($count -gt 250) {
            break
        }
    }
}

function Reset-RunChart {
    $script:RunMetricIndex = 0
    if ($script:RunChart) {
        foreach ($series in $script:RunChart.Series) {
            $series.Points.Clear()
        }
    }
}

function Add-MetricPointFromLine {
    param([string]$Line)
    if (-not $script:RunChart) {
        return
    }
    $metrics = Get-MetricValuesFromLine $Line
    if ($null -eq $metrics) {
        return
    }
    try {
        $x = [double]$metrics.Interval
        if ($x -le 0) {
            $script:RunMetricIndex++
            $x = $script:RunMetricIndex
        }
        [void]$script:RunChart.Series["IOPS"].Points.AddXY($x, [double]$metrics.Iops)
        [void]$script:RunChart.Series["MB/s"].Points.AddXY($x, [double]$metrics.Mbps)
        [void]$script:RunChart.Series["Latency"].Points.AddXY($x, [double]$metrics.Latency)
        foreach ($series in $script:RunChart.Series) {
            while ($series.Points.Count -gt 300) {
                $series.Points.RemoveAt(0)
            }
        }
    } catch {
        return
    }
}

function Get-MetricValuesFromLine {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $null
    }
    if ($Line -notmatch '^\s*\d+\s+') {
        return $null
    }
    $matches = [System.Text.RegularExpressions.Regex]::Matches($Line, '[-+]?\d+(\.\d+)?')
    if ($matches.Count -lt 6) {
        return $null
    }
    try {
        return [pscustomobject]@{
            Interval = [double]$matches[0].Value
            Iops = [double]$matches[1].Value
            Mbps = [double]$matches[2].Value
            Latency = [double]$matches[5].Value
        }
    } catch {
        return $null
    }
}

function Get-RunSummaryFromFile {
    param([string]$StdoutPath)
    if ([string]::IsNullOrWhiteSpace($StdoutPath) -or -not (Test-Path -LiteralPath $StdoutPath)) {
        return @{}
    }
    $last = $null
    foreach ($line in [System.IO.File]::ReadLines($StdoutPath)) {
        $metrics = Get-MetricValuesFromLine $line
        if ($null -ne $metrics) {
            $last = $metrics
        }
    }
    if ($null -eq $last) {
        return @{}
    }
    return @{
        LastInterval = [string]$last.Interval
        LastIops = ("{0:n2}" -f [double]$last.Iops)
        LastMbps = ("{0:n2}" -f [double]$last.Mbps)
        LastLatency = ("{0:n3}" -f [double]$last.Latency)
    }
}

function New-RunChart {
    if (-not $script:ChartAvailable) {
        return $null
    }
    $chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
    $chart.Dock = [System.Windows.Forms.DockStyle]::Fill
    $area = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea
    $area.Name = "RunMetrics"
    $area.AxisX.Title = "Interval"
    $area.AxisY.Title = "IOPS / MB per sec"
    $area.AxisY2.Title = "Latency"
    $area.AxisY2.Enabled = [System.Windows.Forms.DataVisualization.Charting.AxisEnabled]::True
    $area.AxisX.MajorGrid.LineColor = [System.Drawing.Color]::Gainsboro
    $area.AxisY.MajorGrid.LineColor = [System.Drawing.Color]::Gainsboro
    [void]$chart.ChartAreas.Add($area)

    $legend = New-Object System.Windows.Forms.DataVisualization.Charting.Legend
    $legend.Docking = [System.Windows.Forms.DataVisualization.Charting.Docking]::Top
    [void]$chart.Legends.Add($legend)

    foreach ($item in @(
        @{ Name = "IOPS"; Axis = "Y"; Color = [System.Drawing.Color]::SteelBlue },
        @{ Name = "MB/s"; Axis = "Y"; Color = [System.Drawing.Color]::SeaGreen },
        @{ Name = "Latency"; Axis = "Y2"; Color = [System.Drawing.Color]::Firebrick }
    )) {
        $series = New-Object System.Windows.Forms.DataVisualization.Charting.Series
        $series.Name = $item.Name
        $series.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
        $series.BorderWidth = 2
        $series.Color = $item.Color
        if ($item.Axis -eq "Y2") {
            $series.YAxisType = [System.Windows.Forms.DataVisualization.Charting.AxisType]::Secondary
        }
        [void]$chart.Series.Add($series)
    }
    return $chart
}

function Set-RunMetadata {
    param(
        [string]$RunId,
        [hashtable]$Updates
    )
    $path = Join-Path $script:RunStateRoot ($RunId + ".json")
    $state = Read-JsonFile $path ([pscustomobject]@{ Id = $RunId })
    foreach ($key in $Updates.Keys) {
        Set-PropertyValue $state $key $Updates[$key]
    }
    Write-JsonFile $path $state
}

function Get-RunOutputRoot {
    $reportsRoot = [string](Get-PropertyValue $script:Settings "ReportsRoot" "")
    if (-not [string]::IsNullOrWhiteSpace($reportsRoot)) {
        return $reportsRoot
    }
    return (Join-Path $script:AppRoot "runs")
}

function Get-NewRunContext {
    param([object]$BuiltConfig)
    $runId = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $runRoot = Get-RunOutputRoot
    $runDir = Join-Path $runRoot $runId
    try {
        Ensure-Directory $runDir
    } catch {
        $runRoot = Join-Path $script:AppRoot "runs"
        Ensure-Directory $runRoot
        $runDir = Join-Path $runRoot $runId
        Ensure-Directory $runDir
    }

    $parmPath = Join-Path $runDir "profile.parm"
    $stdoutPath = Join-Path $runDir "stdout.log"
    $stderrPath = Join-Path $runDir "stderr.log"
    [System.IO.File]::WriteAllText($parmPath, $BuiltConfig.Text, [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText($stdoutPath, "")
    [System.IO.File]::WriteAllText($stderrPath, "")

    return [pscustomobject]@{
        RunId = $runId
        RunRoot = $runRoot
        RunDir = $runDir
        ParmPath = $parmPath
        StdoutPath = $stdoutPath
        StderrPath = $stderrPath
    }
}

function New-RunMetadataMap {
    param(
        [object]$Context,
        [object]$BuiltConfig,
        [string]$Status,
        [string]$Command
    )
    return @{
        Id = [string]$Context.RunId
        StartedAt = (Get-Date).ToString("o")
        CompletedAt = ""
        Status = $Status
        ExitCode = ""
        Profile = [string]$script:CurrentProfile.Name
        Mode = (Get-Mode)
        TestKind = [string]$script:CurrentProfile.TestKind
        RunDir = [string]$Context.RunDir
        ParmPath = [string]$Context.ParmPath
        StdoutPath = [string]$Context.StdoutPath
        StderrPath = [string]$Context.StderrPath
        Command = $Command
        Warnings = @($BuiltConfig.Warnings)
    }
}

function New-ConfigOnlyRun {
    Capture-Settings
    Capture-SlaveGrid
    Capture-ProfileEditor
    $built = Build-VdbenchConfig
    Save-CurrentProfile
    $context = Get-NewRunContext $built
    Set-RunMetadata $context.RunId (New-RunMetadataMap $context $built "Config generated" "No process started")
    $script:CurrentRunId = [string]$context.RunId
    if ($script:RunLogBox) {
        $script:RunLogBox.Clear()
        Queue-RunLog ("Generated config-only run {0}" -f $context.RunId)
        Queue-RunLog ("Config: {0}" -f $context.ParmPath)
        Queue-RunLog ("Output folder: {0}" -f $context.RunDir)
    }
    if ($script:RunStatusLabel) {
        $script:RunStatusLabel.Text = "Config generated: " + $context.RunId
    }
    Refresh-Reports
}

function Start-VdbenchRun {
    if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
        Show-Warning "A run is already active."
        return
    }
    Capture-Settings
    Capture-SlaveGrid
    Capture-ProfileEditor
    $built = Build-VdbenchConfig
    $riskWarnings = @(Get-RiskWarnings $built)
    if ($riskWarnings.Count -gt 0) {
        $riskMessage = "This run has risk warnings:" + [Environment]::NewLine + (($riskWarnings | ForEach-Object { "- " + $_ }) -join [Environment]::NewLine) + [Environment]::NewLine + [Environment]::NewLine + "Continue with this Vdbench run?"
        if (-not (Ask-YesNo $riskMessage "Risk confirmation")) {
            return
        }
    }
    if ($built.Warnings.Count -gt 0) {
        $message = "Config has warnings:" + [Environment]::NewLine + (($built.Warnings | ForEach-Object { "- " + $_ }) -join [Environment]::NewLine) + [Environment]::NewLine + [Environment]::NewLine + "Start anyway?"
        if (-not (Ask-YesNo $message "Config warnings")) {
            return
        }
    }
    if ([bool](Get-PropertyValue $script:Settings "RequirePreviewBeforeRun" $true)) {
        if (-not (Ask-YesNo "Review Config Preview before running. Start Vdbench now?" "Start run")) {
            return
        }
    }

    $masterBat = [string](Get-PropertyValue $script:Settings "MasterVdbenchBat" "")
    if ([string]::IsNullOrWhiteSpace($masterBat) -or -not (Test-Path -LiteralPath $masterBat)) {
        Show-Warning "Master Vdbench batch file does not exist: $masterBat"
        return
    }

    $context = Get-NewRunContext $built
    $runId = [string]$context.RunId
    $runDir = [string]$context.RunDir
    $parmPath = [string]$context.ParmPath
    $stdoutPath = [string]$context.StdoutPath
    $stderrPath = [string]$context.StderrPath
    $script:CurrentRunId = $runId
    $script:KillRequested = $false
    Save-CurrentProfile
    $commandText = ("`"{0}`" -f `"{1}`" -o `"{2}`"" -f $masterBat, $parmPath, $runDir)
    Set-RunMetadata $runId (New-RunMetadataMap $context $built "Running" $commandText)

    $script:RunLogBox.Clear()
    Reset-RunChart
    Queue-RunLog ("Starting run {0}" -f $runId)
    Queue-RunLog ("Command: {0}" -f $commandText)
    Queue-RunLog ("Output: {0}" -f $runDir)
    $script:RunStatusLabel.Text = "Running: " + $runId

    $psi = Get-VdbenchProcessStartInfo $masterBat $parmPath $runDir ([string](Get-PropertyValue $script:Settings "VdbenchRoot" $script:AppRoot))

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $process.EnableRaisingEvents = $true
    $process.add_OutputDataReceived({
        param($sender, $eventArgs)
        if ($eventArgs.Data) {
            $script:LogQueue.Enqueue($eventArgs.Data)
            [System.IO.File]::AppendAllText($script:ActiveStdoutPath, $eventArgs.Data + [Environment]::NewLine)
        }
    })
    $process.add_ErrorDataReceived({
        param($sender, $eventArgs)
        if ($eventArgs.Data) {
            $script:LogQueue.Enqueue("[stderr] " + $eventArgs.Data)
            [System.IO.File]::AppendAllText($script:ActiveStderrPath, $eventArgs.Data + [Environment]::NewLine)
        }
    })
    $process.add_Exited({
        param($sender, $eventArgs)
        $exitCode = $sender.ExitCode
        $status = "Failed"
        if ($script:KillRequested) {
            $status = "Killed"
        } elseif ($exitCode -eq 0) {
            $status = "Completed"
        }
        $script:LogQueue.Enqueue(("Run exited with code {0}" -f $exitCode))
        $updates = @{
            CompletedAt = (Get-Date).ToString("o")
            Status = $status
            ExitCode = [string]$exitCode
        }
        $summary = Get-RunSummaryFromFile $script:ActiveStdoutPath
        foreach ($key in $summary.Keys) {
            $updates[$key] = $summary[$key]
        }
        Set-RunMetadata $script:CurrentRunId $updates
    })

    $script:ActiveStdoutPath = $stdoutPath
    $script:ActiveStderrPath = $stderrPath

    try {
        [void]$process.Start()
        $script:CurrentProcess = $process
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()
    } catch {
        Set-RunMetadata $runId @{
            CompletedAt = (Get-Date).ToString("o")
            Status = "Start failed"
            ExitCode = ""
        }
        Queue-RunLog ("Start failed: " + $_.Exception.Message)
        $script:RunStatusLabel.Text = "Start failed"
        Refresh-Reports
    }
}

function Stop-VdbenchRun {
    if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
        if (Ask-YesNo "Kill the active Vdbench process?" "Stop run") {
            try {
                $script:KillRequested = $true
                $script:CurrentProcess.Kill()
                Queue-RunLog "Kill requested."
                Set-RunMetadata $script:CurrentRunId @{
                    CompletedAt = (Get-Date).ToString("o")
                    Status = "Killed"
                }
                $script:RunStatusLabel.Text = "Killed: " + $script:CurrentRunId
            } catch {
                Show-Warning $_.Exception.Message
            }
        }
    } else {
        Show-Info "No active run."
    }
}

function Open-CurrentRunFolder {
    if ([string]::IsNullOrWhiteSpace($script:CurrentRunId)) {
        Show-Warning "No current run."
        return
    }
    $path = Join-Path $script:RunStateRoot ($script:CurrentRunId + ".json")
    $state = Read-JsonFile $path $null
    $runDir = [string](Get-PropertyValue $state "RunDir" "")
    if ($state -and -not [string]::IsNullOrWhiteSpace($runDir) -and (Test-Path -LiteralPath $runDir)) {
        Start-Process $runDir
    }
}

function Build-RunTab {
    $tab = New-Object System.Windows.Forms.TabPage
    $tab.Text = "Run Monitor"

    $container = New-Object System.Windows.Forms.TableLayoutPanel
    $container.Dock = [System.Windows.Forms.DockStyle]::Fill
    $container.RowCount = 3
    $container.ColumnCount = 1
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 48)) | Out-Null
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 210)) | Out-Null
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 100)) | Out-Null
    $tab.Controls.Add($container)

    $toolbar = New-Object System.Windows.Forms.Panel
    $toolbar.Dock = [System.Windows.Forms.DockStyle]::Fill
    $container.Controls.Add($toolbar, 0, 0)

    $startButton = New-Button "Start" 10 10 80 28
    $startButton.Add_Click({ Start-VdbenchRun })
    $toolbar.Controls.Add($startButton)

    $configOnlyButton = New-Button "Config only" 100 10 95 28
    $configOnlyButton.Add_Click({ New-ConfigOnlyRun })
    $toolbar.Controls.Add($configOnlyButton)

    $stopButton = New-Button "Stop/Kill" 205 10 90 28
    $stopButton.Add_Click({ Stop-VdbenchRun })
    $toolbar.Controls.Add($stopButton)

    $openButton = New-Button "Open folder" 305 10 100 28
    $openButton.Add_Click({ Open-CurrentRunFolder })
    $toolbar.Controls.Add($openButton)

    $script:RunStatusLabel = New-Label "Idle" 425 13 600
    $toolbar.Controls.Add($script:RunStatusLabel)

    $script:RunChart = New-RunChart
    if ($script:RunChart) {
        $container.Controls.Add($script:RunChart, 0, 1)
    } else {
        $chartFallback = New-Object System.Windows.Forms.TextBox
        $chartFallback.Dock = [System.Windows.Forms.DockStyle]::Fill
        $chartFallback.Multiline = $true
        $chartFallback.ReadOnly = $true
        $chartFallback.Text = "Chart assembly is not available. Live Vdbench stdout is still shown below."
        $container.Controls.Add($chartFallback, 0, 1)
    }

    $script:RunLogBox = New-Object System.Windows.Forms.TextBox
    $script:RunLogBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:RunLogBox.Multiline = $true
    $script:RunLogBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
    $script:RunLogBox.Font = New-Object System.Drawing.Font -ArgumentList "Consolas", 10
    $script:RunLogBox.WordWrap = $false
    $container.Controls.Add($script:RunLogBox, 0, 2)

    return $tab
}

function Get-RunStates {
    $items = @()
    foreach ($file in @(Get-ChildItem -Path $script:RunStateRoot -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
        $state = Read-JsonFile $file.FullName $null
        if ($state) {
            $items += $state
        }
    }
    return @($items | Sort-Object StartedAt -Descending)
}

function Refresh-Reports {
    if (-not $script:ReportsGrid) {
        return
    }
    $script:ReportsGrid.Rows.Clear()
    foreach ($state in Get-RunStates) {
        $idx = $script:ReportsGrid.Rows.Add()
        $row = $script:ReportsGrid.Rows[$idx]
        foreach ($name in @("Id", "StartedAt", "Status", "ExitCode", "Profile", "Mode", "TestKind", "LastIops", "LastMbps", "LastLatency", "RunDir")) {
            $row.Cells[$name].Value = [string](Get-PropertyValue $state $name "")
        }
    }
}

function Open-SelectedReportFolder {
    if ($script:ReportsGrid.SelectedRows.Count -eq 0) {
        return
    }
    $row = $script:ReportsGrid.SelectedRows[0]
    $dir = [string]$row.Cells["RunDir"].Value
    if (-not [string]::IsNullOrWhiteSpace($dir) -and (Test-Path -LiteralPath $dir)) {
        Start-Process $dir
    }
}

function Export-SelectedRunBundle {
    if ($script:ReportsGrid.SelectedRows.Count -eq 0) {
        Show-Warning "Select a run first."
        return
    }
    $row = $script:ReportsGrid.SelectedRows[0]
    $runId = [string]$row.Cells["Id"].Value
    $dir = [string]$row.Cells["RunDir"].Value
    if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir)) {
        Show-Warning "Selected run folder does not exist."
        return
    }
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = "ZIP archive (*.zip)|*.zip|All files (*.*)|*.*"
    $dialog.FileName = ("vdbench-run-{0}.zip" -f (Sanitize-FileName $runId))
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return
    }
    try {
        if (Test-Path -LiteralPath $dialog.FileName) {
            Remove-Item -LiteralPath $dialog.FileName -Force
        }
        $source = Join-Path $dir "*"
        Compress-Archive -Path $source -DestinationPath $dialog.FileName -Force
        Show-Info ("Exported run bundle: {0}" -f $dialog.FileName)
    } catch {
        Show-Warning ("Run bundle export failed: " + $_.Exception.Message)
    }
}

function Show-SelectedRunConfig {
    if ($script:ReportsGrid.SelectedRows.Count -eq 0) {
        return
    }
    $id = [string]$script:ReportsGrid.SelectedRows[0].Cells["Id"].Value
    $state = Read-JsonFile (Join-Path $script:RunStateRoot ($id + ".json")) $null
    $parmPath = [string](Get-PropertyValue $state "ParmPath" "")
    if ($state -and -not [string]::IsNullOrWhiteSpace($parmPath) -and (Test-Path -LiteralPath $parmPath)) {
        $script:ReportDetailBox.Text = [System.IO.File]::ReadAllText($parmPath)
    }
}

function Show-SelectedRunLog {
    if ($script:ReportsGrid.SelectedRows.Count -eq 0) {
        return
    }
    $id = [string]$script:ReportsGrid.SelectedRows[0].Cells["Id"].Value
    $state = Read-JsonFile (Join-Path $script:RunStateRoot ($id + ".json")) $null
    $stdoutPath = [string](Get-PropertyValue $state "StdoutPath" "")
    $stderrPath = [string](Get-PropertyValue $state "StderrPath" "")
    if ($state -and -not [string]::IsNullOrWhiteSpace($stdoutPath) -and (Test-Path -LiteralPath $stdoutPath)) {
        $text = [System.IO.File]::ReadAllText($stdoutPath)
        if (-not [string]::IsNullOrWhiteSpace($stderrPath) -and (Test-Path -LiteralPath $stderrPath)) {
            $text += [Environment]::NewLine + "===== stderr =====" + [Environment]::NewLine
            $text += [System.IO.File]::ReadAllText($stderrPath)
        }
        $script:ReportDetailBox.Text = $text
    }
}

function Build-ReportsTab {
    $tab = New-Object System.Windows.Forms.TabPage
    $tab.Text = "Status / Reports"

    $container = New-Object System.Windows.Forms.TableLayoutPanel
    $container.Dock = [System.Windows.Forms.DockStyle]::Fill
    $container.RowCount = 3
    $container.ColumnCount = 1
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Absolute), 44)) | Out-Null
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 45)) | Out-Null
    $container.RowStyles.Add((New-Object System.Windows.Forms.RowStyle -ArgumentList ([System.Windows.Forms.SizeType]::Percent), 55)) | Out-Null
    $tab.Controls.Add($container)

    $toolbar = New-Object System.Windows.Forms.Panel
    $toolbar.Dock = [System.Windows.Forms.DockStyle]::Fill
    $container.Controls.Add($toolbar, 0, 0)

    $refreshButton = New-Button "Refresh" 10 8 80 28
    $refreshButton.Add_Click({ Refresh-Reports })
    $toolbar.Controls.Add($refreshButton)

    $openButton = New-Button "Open folder" 100 8 100 28
    $openButton.Add_Click({ Open-SelectedReportFolder })
    $toolbar.Controls.Add($openButton)

    $configButton = New-Button "Show config" 210 8 100 28
    $configButton.Add_Click({ Show-SelectedRunConfig })
    $toolbar.Controls.Add($configButton)

    $logButton = New-Button "Show logs" 320 8 90 28
    $logButton.Add_Click({ Show-SelectedRunLog })
    $toolbar.Controls.Add($logButton)

    $bundleButton = New-Button "Export ZIP" 420 8 95 28
    $bundleButton.Add_Click({ Export-SelectedRunBundle })
    $toolbar.Controls.Add($bundleButton)

    $script:ReportsGrid = New-Object System.Windows.Forms.DataGridView
    $script:ReportsGrid.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ReportsGrid.AllowUserToAddRows = $false
    $script:ReportsGrid.AllowUserToDeleteRows = $false
    $script:ReportsGrid.ReadOnly = $true
    $script:ReportsGrid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $script:ReportsGrid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
    foreach ($name in @("Id", "StartedAt", "Status", "ExitCode", "Profile", "Mode", "TestKind", "LastIops", "LastMbps", "LastLatency", "RunDir")) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.Name = $name
        $col.HeaderText = $name
        $script:ReportsGrid.Columns.Add($col) | Out-Null
    }
    $container.Controls.Add($script:ReportsGrid, 0, 1)

    $script:ReportDetailBox = New-Object System.Windows.Forms.TextBox
    $script:ReportDetailBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:ReportDetailBox.Multiline = $true
    $script:ReportDetailBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
    $script:ReportDetailBox.Font = New-Object System.Drawing.Font -ArgumentList "Consolas", 10
    $script:ReportDetailBox.WordWrap = $false
    $container.Controls.Add($script:ReportDetailBox, 0, 2)

    Refresh-Reports
    return $tab
}

function Build-MainForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Vdbench UI - Portable Manager"
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.Size = New-Object System.Drawing.Size -ArgumentList 1280, 820
    $form.MinimumSize = New-Object System.Drawing.Size -ArgumentList 1100, 700

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = [System.Windows.Forms.DockStyle]::Fill
    $form.Controls.Add($tabs)

    $tabs.TabPages.Add((Build-SettingsTab)) | Out-Null
    $tabs.TabPages.Add((Build-MasterSlaveTab)) | Out-Null
    $tabs.TabPages.Add((Build-ProfileTab)) | Out-Null
    $tabs.TabPages.Add((Build-PreviewTab)) | Out-Null
    $tabs.TabPages.Add((Build-RunTab)) | Out-Null
    $tabs.TabPages.Add((Build-ReportsTab)) | Out-Null

    $tabs.Add_SelectedIndexChanged({
        Refresh-ConfigPreview
        Refresh-Reports
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250
    $timer.Add_Tick({
        Flush-RunLog
        if ($script:CurrentProcess -and $script:CurrentProcess.HasExited) {
            $script:RunStatusLabel.Text = "Finished: " + $script:CurrentRunId
            Refresh-Reports
        }
    })
    $timer.Start()

    $form.Add_FormClosing({
        param($sender, $eventArgs)
        if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
            if (-not (Ask-YesNo "A Vdbench run is active. Close UI and leave/kill process manually?" "Active run")) {
                $eventArgs.Cancel = $true
            }
        }
    })

    return $form
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

function Invoke-AppSelfTest {
    Initialize-AppState

    Set-PropertyValue $script:Settings "MasterVdbenchBat" (Join-Path $script:AppRoot "tools\FakeVdbench.ps1")
    Set-PropertyValue $script:Settings "RunMode" "Single local run"

    $script:CurrentProfile = New-DefaultProfile "SelfTest-Raw" "Raw/block"
    Set-ProfileParamValue $script:CurrentProfile "storage.dedupratio" "2"
    Set-ProfileParamEnabled $script:CurrentProfile "storage.dedupratio" $false
    $raw = Build-VdbenchConfig
    Assert-SelfTestContains $raw.Text "sd=sd1,lun=C:\vdbench\testfile.dat" "raw storage line"
    Assert-SelfTestContains $raw.Text "wd=wd1,sd=sd1,xfersize=4k,rdpct=70,seekpct=100" "raw workload line"
    Assert-SelfTestContains $raw.Text "rd=rd1,wd=wd1,elapsed=300,warmup=30,interval=1,iorate=max" "raw run line"
    Assert-SelfTestContains $raw.Text "* disabled: dedupratio=2" "disabled parameter rendering"

    Set-ProfileParamValue $script:CurrentProfile "storage.lun" "\\.\PhysicalDrive1"
    $rawRisk = Build-VdbenchConfig
    Assert-SelfTestContains (($rawRisk.Warnings -join "`n")) "RISK: local target '\\.\PhysicalDrive1' looks like a raw physical device." "raw risk warning"
    Set-ProfileParamValue $script:CurrentProfile "storage.lun" "C:\vdbench\testfile.dat"

    Set-PropertyValue $script:Settings "RunMode" "Master/Slave distributed run"
    $script:Slaves = @(
        [pscustomobject]@{
            Enabled = $true
            Name = "test-001"
            Host = "10.0.0.11"
            OsType = "Linux"
            VdbenchPath = "/opt/vdbench"
            TestTarget = "/dev/sdb"
            SshAlias = "test-001"
            PrivateKey = ""
            Status = "Self-test"
            Notes = ""
        }
    )
    $distributed = Build-VdbenchConfig
    Assert-SelfTestContains $distributed.Text "hd=default,shell=ssh" "distributed host defaults"
    Assert-SelfTestContains $distributed.Text "hd=test-001,system=test-001,vdbench=/opt/vdbench" "distributed host line"
    Assert-SelfTestContains $distributed.Text "sd=sd_test_001,host=test-001,lun=/dev/sdb" "distributed storage line"
    Assert-SelfTestContains $distributed.Text "wd=wd1,sd=sd*" "distributed workload fanout"
    Assert-SelfTestContains (($distributed.Warnings -join "`n")) "RISK: slave 'test-001' target '/dev/sdb' looks like a raw physical device." "distributed raw risk warning"

    Set-PropertyValue $script:Settings "RunMode" "Single local run"
    $script:CurrentProfile = New-DefaultProfile "SelfTest-Filesystem" "Filesystem"
    $fs = Build-VdbenchConfig
    Assert-SelfTestContains $fs.Text "fsd=fsd1,anchor=C:\vdbench\fs_test" "filesystem definition"
    Assert-SelfTestContains $fs.Text "fwd=fwd1,fsd=fsd1,operation=read" "filesystem workload"
    Assert-SelfTestContains $fs.Text "rd=rd1,fwd=fwd1,elapsed=300,warmup=30,interval=1,fwdrate=max,format=no" "filesystem run"

    Set-ProfileParamValue $script:CurrentProfile "fsd.anchor" "C:\"
    Set-ProfileParamValue $script:CurrentProfile "run.format" "yes"
    $fsRisk = Build-VdbenchConfig
    $fsRiskWarnings = $fsRisk.Warnings -join "`n"
    Assert-SelfTestContains $fsRiskWarnings "RISK: filesystem format is enabled with value 'yes'." "filesystem format risk"
    Assert-SelfTestContains $fsRiskWarnings "RISK: filesystem anchor 'C:\' looks like a root drive/path." "filesystem anchor risk"

    $parsedTargets = @(Convert-TargetInventoryOutput "Raw disk|\\.\PhysicalDrive2|Test model`nFilesystem|C:\|NTFS")
    Assert-SelfTestEquals $parsedTargets.Count 2 "target inventory parser count"
    Assert-SelfTestEquals $parsedTargets[0].Target "\\.\PhysicalDrive2" "target inventory raw target"
    Assert-SelfTestEquals $parsedTargets[1].Target "C:\" "target inventory filesystem target"

    $psiPs1 = Get-VdbenchProcessStartInfo (Join-Path $script:AppRoot "tools\FakeVdbench.ps1") "C:\tmp\profile.parm" "C:\tmp\out folder" $script:AppRoot
    Assert-SelfTestEquals $psiPs1.FileName "powershell.exe" "ps1 runner executable"
    Assert-SelfTestContains $psiPs1.Arguments "-ExecutionPolicy Bypass -File" "ps1 runner arguments"
    Assert-SelfTestContains $psiPs1.Arguments "-f `"C:\tmp\profile.parm`" -o `"C:\tmp\out folder`"" "ps1 runner quoted paths"

    $psiBat = Get-VdbenchProcessStartInfo "C:\Program Files\vdbench\vdbench.bat" "C:\tmp\profile.parm" "C:\tmp\out folder" "C:\Program Files\vdbench"
    Assert-SelfTestEquals $psiBat.FileName "cmd.exe" "bat runner executable"
    Assert-SelfTestContains $psiBat.Arguments "/d /c" "bat runner cmd switch"
    Assert-SelfTestContains $psiBat.Arguments "`"C:\Program Files\vdbench\vdbench.bat`"" "bat runner quoted executable"

    Write-Host "VdbenchUI self-test OK."
}

try {
    if ($SelfTest) {
        Invoke-AppSelfTest
        return
    }
    if (-not $NoGui) {
        Initialize-AppState
        $script:Form = Build-MainForm
        Refresh-ConfigPreview
        [System.Windows.Forms.Application]::Run($script:Form)
    }
} catch {
    if (-not $NoGui -and -not $SelfTest) {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Vdbench UI fatal error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
    throw
}
