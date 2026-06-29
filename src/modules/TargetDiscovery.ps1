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

$script:TargetInventoryCache = @{}
$script:TargetInventoryCacheTtlSeconds = 45

function Clear-TargetInventoryCache {
    $script:TargetInventoryCache = @{}
}

function Get-CachedTargetInventory {
    param(
        [string]$CacheKey,
        [scriptblock]$Loader,
        [switch]$Force
    )
    $now = [datetime]::UtcNow
    if (-not $Force -and $script:TargetInventoryCache.ContainsKey($CacheKey)) {
        $entry = $script:TargetInventoryCache[$CacheKey]
        $ageSeconds = ($now - $entry.At).TotalSeconds
        if ($ageSeconds -lt $script:TargetInventoryCacheTtlSeconds) {
            return @($entry.Items)
        }
    }
    $items = @(& $Loader)
    $script:TargetInventoryCache[$CacheKey] = @{
        At = $now
        Items = @($items)
    }
    return @($items)
}

function Get-LocalTargetInventoryCore {
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

    $items += New-TargetRecord "Test file" (Get-DefaultTestFileTargetForOs "Windows") "Raw/file target; create/overwrite is controlled by the target checkbox."
    return @($items | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Target) })
}

function Get-LocalTargetInventory {
    param([switch]$Force)
    return @(Get-CachedTargetInventory "local" { Get-LocalTargetInventoryCore } -Force:$Force)
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
    param(
        [System.Windows.Forms.DataGridViewRow]$Row,
        [switch]$Force
    )
    if ($null -eq $Row -or $Row.IsNewRow) {
        return @()
    }
    $hostName = [string]$Row.Cells["Host"].Value
    if (Test-HostLooksLocal $hostName) {
        return @(Get-LocalTargetInventory -Force:$Force)
    }

    $systemName = [string]$Row.Cells["SshAlias"].Value
    if ([string]::IsNullOrWhiteSpace($systemName)) {
        $systemName = $hostName
    }
    if ([string]::IsNullOrWhiteSpace($systemName)) {
        throw "Slave Host or SshAlias is required for remote discovery."
    }

    $osType = [string]$Row.Cells["OsType"].Value
    $cacheKey = ("remote|{0}|{1}" -f $systemName.ToLowerInvariant(), $osType)
    return @(Get-CachedTargetInventory $cacheKey {
        Get-RemoteSlaveTargetInventoryCore -SystemName $systemName -OsType $osType -Row $Row
    } -Force:$Force)
}

function Get-RemoteSlaveTargetInventoryCore {
    param(
        [string]$SystemName,
        [string]$OsType,
        [System.Windows.Forms.DataGridViewRow]$Row
    )
    $sshParts = New-Object System.Collections.Generic.List[string]
    $sshConfig = [string](Get-PropertyValue $script:Settings "SshConfig" "")
    if (-not [string]::IsNullOrWhiteSpace($sshConfig) -and (Test-Path -LiteralPath $sshConfig)) {
        [void]$sshParts.Add("-F")
        [void]$sshParts.Add((Quote-ProcessArgument $sshConfig))
    }
    $privateKey = [string](Get-PropertyValue $script:Settings "PrivateKey" "")
    if (-not [string]::IsNullOrWhiteSpace($privateKey) -and (Test-Path -LiteralPath $privateKey)) {
        [void]$sshParts.Add("-i")
        [void]$sshParts.Add((Quote-ProcessArgument $privateKey))
    }
    [void]$sshParts.Add("-o")
    [void]$sshParts.Add("BatchMode=yes")
    [void]$sshParts.Add("-o")
    [void]$sshParts.Add("ConnectTimeout=8")
    [void]$sshParts.Add((Quote-ProcessArgument $SystemName))

    if ($OsType -eq "Linux") {
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
    $targets += New-TargetRecord "Test file" (Get-DefaultTestFileTargetForOs $OsType) "Raw/file target; create/overwrite is controlled by the target checkbox."
    if ($targets.Count -eq 0) {
        throw "Remote discovery returned no targets."
    }
    return $targets
}

function Prompt-HostPathEntry {
    param([System.Windows.Forms.DataGridViewRow]$Row)
    $osType = [string]$Row.Cells["OsType"].Value
    $defaultPath = if ($osType -eq "Linux") { "/mnt/test" } else { "C:\vdbench\test" }
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Add target path"
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.Size = New-Object System.Drawing.Size -ArgumentList 560, 130
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $label = New-Label "Path on host:" 12 14 80 22
    $box = New-TextBox $defaultPath 96 12 440 24
    $dialog.Controls.Add($label)
    $dialog.Controls.Add($box)
    $ok = New-Button "OK" 360 52 75 28
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $cancel = New-Button "Cancel" 441 52 75 28
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($ok)
    $dialog.Controls.Add($cancel)
    $dialog.AcceptButton = $ok
    $dialog.CancelButton = $cancel
    if ($dialog.ShowDialog($script:Form) -ne [System.Windows.Forms.DialogResult]::OK) {
        return ""
    }
    return [string]$box.Text.Trim()
}

function Prompt-HostFolderPath {
    param([System.Windows.Forms.DataGridViewRow]$Row)
    $osType = [string]$Row.Cells["OsType"].Value
    $defaultPath = if ($osType -eq "Linux") { "/mnt/vdbench-test" } else { "C:\vdbench\fs_test" }
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "New folder on host"
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.Size = New-Object System.Drawing.Size -ArgumentList 560, 130
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $label = New-Label "Folder path:" 12 14 80 22
    $box = New-TextBox $defaultPath 96 12 440 24
    $dialog.Controls.Add($label)
    $dialog.Controls.Add($box)
    $ok = New-Button "Create" 360 52 75 28
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $cancel = New-Button "Cancel" 441 52 75 28
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($ok)
    $dialog.Controls.Add($cancel)
    $dialog.AcceptButton = $ok
    $dialog.CancelButton = $cancel
    if ($dialog.ShowDialog($script:Form) -ne [System.Windows.Forms.DialogResult]::OK) {
        return ""
    }
    return [string]$box.Text.Trim()
}

function New-HostFolderPath {
    param(
        [System.Windows.Forms.DataGridViewRow]$Row,
        [string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Folder path is required."
    }
    $hostName = [string]$Row.Cells["Host"].Value
    if (Test-HostLooksLocal $hostName) {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
        }
        return
    }
    $systemName = [string]$Row.Cells["SshAlias"].Value
    if ([string]::IsNullOrWhiteSpace($systemName)) {
        $systemName = $hostName
    }
    $osType = [string]$Row.Cells["OsType"].Value
    $sshParts = New-Object System.Collections.Generic.List[string]
    $sshConfig = [string](Get-PropertyValue $script:Settings "SshConfig" "")
    if (-not [string]::IsNullOrWhiteSpace($sshConfig) -and (Test-Path -LiteralPath $sshConfig)) {
        [void]$sshParts.Add("-F")
        [void]$sshParts.Add((Quote-ProcessArgument $sshConfig))
    }
    $privateKey = [string](Get-PropertyValue $script:Settings "PrivateKey" "")
    if (-not [string]::IsNullOrWhiteSpace($privateKey) -and (Test-Path -LiteralPath $privateKey)) {
        [void]$sshParts.Add("-i")
        [void]$sshParts.Add((Quote-ProcessArgument $privateKey))
    }
    [void]$sshParts.Add("-o")
    [void]$sshParts.Add("BatchMode=yes")
    [void]$sshParts.Add((Quote-ProcessArgument $systemName))
    if ($osType -eq "Linux") {
        $remoteScript = "mkdir -p " + (Quote-ProcessArgument $Path)
        [void]$sshParts.Add("sh")
        [void]$sshParts.Add("-lc")
        [void]$sshParts.Add((Quote-ProcessArgument $remoteScript))
    } else {
        $remoteScript = "New-Item -ItemType Directory -Path " + (Quote-ProcessArgument $Path) + " -Force | Out-Null"
        [void]$sshParts.Add("powershell.exe")
        [void]$sshParts.Add("-NoProfile")
        [void]$sshParts.Add("-Command")
        [void]$sshParts.Add((Quote-ProcessArgument $remoteScript))
    }
    $result = Invoke-CapturedProcess "ssh.exe" ($sshParts -join " ") 20000
    if ($result.ExitCode -ne 0) {
        throw (($result.StdErr + [Environment]::NewLine + $result.StdOut).Trim())
    }
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
