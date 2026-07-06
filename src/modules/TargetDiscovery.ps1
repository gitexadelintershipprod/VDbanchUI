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

function Test-SelectableLinuxFilesystemMount {
    param([object]$Item)
    $target = [string](Get-PropertyValue $Item "Target" "")
    $description = [string](Get-PropertyValue $Item "Description" "")
    if ([string]::IsNullOrWhiteSpace($target)) {
        return $false
    }
    $skipTypes = @(
        "proc", "sysfs", "devtmpfs", "tmpfs", "pstore", "bpf", "debugfs", "tracefs",
        "mqueue", "hugetlbfs", "securityfs", "configfs", "fusectl", "autofs", "devpts",
        "ramfs", "nsfs", "binfmt_misc", "efivarfs", "squashfs", "overlay", "rpc_pipefs"
    )
    $fstype = ""
    if (-not [string]::IsNullOrWhiteSpace($description)) {
        $fstype = ([string]($description -split '\s+')[-1]).ToLowerInvariant()
    }
    if (-not [string]::IsNullOrWhiteSpace($fstype)) {
        foreach ($skip in $skipTypes) {
            if ($fstype -eq $skip -or $fstype -like ($skip + "*")) {
                return $false
            }
        }
    }
    if ($target -match '^/(proc|sys|dev|run)(/|$)') {
        return $false
    }
    return $true
}

function Filter-TargetInventoryRecords {
    param(
        [object[]]$Items,
        [string]$OsType = ""
    )
    $result = @()
    foreach ($item in @($Items)) {
        $kind = [string](Get-PropertyValue $item "Kind" "")
        if ($kind -eq "Filesystem" -and $OsType -eq "Linux") {
            if (-not (Test-SelectableLinuxFilesystemMount $item)) {
                continue
            }
        }
        $result += $item
    }
    return @($result)
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
    Add-CommonSshOptions -SshParts $sshParts -User ([string]$Row.Cells["User"].Value)
    [void]$sshParts.Add((Quote-ProcessArgument $SystemName))

    if ($OsType -eq "Linux") {
        $remoteScript = 'for d in /sys/block/*; do name=${d##*/}; case "$name" in loop*|ram*) continue;; esac; size=$(cat "$d/size" 2>/dev/null); bytes=$((size*512)); echo "Raw disk|/dev/$name|bytes=$bytes"; done; if command -v findmnt >/dev/null 2>&1; then findmnt -rn -o TARGET,SOURCE,FSTYPE | while read target source fstype; do case "$fstype" in proc|sysfs|devtmpfs|tmpfs|cgroup2|cgroup|pstore|bpf|debugfs|tracefs|mqueue|hugetlbfs|securityfs|configfs|fusectl|autofs|devpts|ramfs|nsfs|binfmt_misc|efivarfs|squashfs|overlay|rpc_pipefs) continue;; esac; case "$target" in /proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*) continue;; esac; echo "Filesystem|$target|$source $fstype"; done; fi'
    } else {
        $remoteScript = '$ErrorActionPreference="SilentlyContinue"; Get-CimInstance Win32_DiskDrive | ForEach-Object { "Raw disk|\\.\PhysicalDrive$($_.Index)|$($_.Model) $($_.Size)" }; Get-CimInstance Win32_Volume | Where-Object { $_.DriveLetter } | ForEach-Object { "Filesystem|$($_.DriveLetter)\|$($_.Label) $($_.FileSystem) $($_.Capacity)" }'
    }
    foreach ($token in @(Get-RemoteExecCommandParts -OsType $OsType -RemoteScript $remoteScript)) {
        [void]$sshParts.Add($token)
    }

    $result = Invoke-CapturedProcess "ssh.exe" ($sshParts -join " ") 20000
    if ($result.ExitCode -ne 0) {
        throw (($result.StdErr + [Environment]::NewLine + $result.StdOut).Trim())
    }
    $targets = @(Filter-TargetInventoryRecords (Convert-TargetInventoryOutput $result.StdOut) $OsType)
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
    Add-CommonSshOptions -SshParts $sshParts -User ([string]$Row.Cells["User"].Value)
    [void]$sshParts.Add((Quote-ProcessArgument $systemName))
    if ($osType -eq "Linux") {
        $remoteScript = "mkdir -p " + (Convert-ToShellSingleQuoted $Path)
    } else {
        $remoteScript = "New-Item -ItemType Directory -Path " + (Convert-ToPowerShellSingleQuoted $Path) + " -Force | Out-Null"
    }
    foreach ($token in @(Get-RemoteExecCommandParts -OsType $osType -RemoteScript $remoteScript)) {
        [void]$sshParts.Add($token)
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

function Get-DefaultBrowseRootForOs {
    param([string]$OsType)
    if ([string]$OsType -eq "Linux") {
        return "/"
    }
    return "C:\"
}

function Convert-HostDirectoryListingOutput {
    param([string]$Text)
    $items = @()
    foreach ($line in (($Text -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $parts = $line.Split(@("|"), 3, [System.StringSplitOptions]::None)
        if ($parts.Count -lt 2) {
            continue
        }
        $entryKind = $parts[0].Trim().ToLowerInvariant()
        $target = $parts[1].Trim()
        $description = ""
        if ($parts.Count -gt 2) {
            $description = $parts[2].Trim()
        }
        if ([string]::IsNullOrWhiteSpace($target)) {
            continue
        }
        $kind = "Filesystem"
        if ($entryKind -eq "file") {
            $kind = "Test file"
            if ([string]::IsNullOrWhiteSpace($description)) {
                $description = "File"
            } else {
                $description = "File " + $description
            }
        } elseif ($entryKind -eq "folder") {
            if ([string]::IsNullOrWhiteSpace($description)) {
                $description = "Folder"
            }
        } else {
            continue
        }
        $items += New-TargetRecord $kind $target $description
    }
    return @($items)
}

function Get-LocalHostDirectoryListing {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return @()
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        throw ("Path does not exist: {0}" -f $Path)
    }
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $items = @()
    foreach ($entry in @(Get-ChildItem -LiteralPath $resolved -Force -ErrorAction Stop)) {
        if ($entry.PSIsContainer) {
            $items += New-TargetRecord "Filesystem" $entry.FullName "Folder"
        } else {
            $items += New-TargetRecord "Test file" $entry.FullName ("File " + (Format-ByteSize $entry.Length))
        }
    }
    return @($items | Sort-Object { [string]$_.Kind }, { [string]$_.Target })
}

function Get-RemoteHostDirectoryListingCore {
    param(
        [string]$SystemName,
        [string]$OsType,
        [string]$Path,
        [string]$User
    )
    $sshParts = New-Object System.Collections.Generic.List[string]
    Add-CommonSshOptions -SshParts $sshParts -User $User
    [void]$sshParts.Add((Quote-ProcessArgument $SystemName))
    if ($OsType -eq "Linux") {
        $pathSq = Convert-ToShellSingleQuoted $Path
        $remoteScript = ("find {0} -mindepth 1 -maxdepth 1 \( -type d -o -type f \) -printf '%y|%p|%s\n'" -f $pathSq)
    } else {
        $pathSq = Convert-ToPowerShellSingleQuoted $Path
        $remoteScript = @"
if (-not (Test-Path -LiteralPath $pathSq -PathType Container)) { throw "Path does not exist: $pathSq" }
Get-ChildItem -LiteralPath $pathSq -Force | ForEach-Object {
  if (`$_.PSIsContainer) { 'folder|' + `$_.FullName + '|Folder' }
  else { 'file|' + `$_.FullName + '|' + `$_.Length }
}
"@
    }
    foreach ($token in @(Get-RemoteExecCommandParts -OsType $OsType -RemoteScript $remoteScript)) {
        [void]$sshParts.Add($token)
    }
    $result = Invoke-CapturedProcess "ssh.exe" ($sshParts -join " ") 20000
    if ($result.ExitCode -ne 0) {
        throw (($result.StdErr + [Environment]::NewLine + $result.StdOut).Trim())
    }
    return @(Convert-HostDirectoryListingOutput $result.StdOut)
}

function Get-HostDirectoryListing {
    param(
        $Row,
        [string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return @()
    }
    if ($null -eq $Row) {
        return @(Get-LocalHostDirectoryListing $Path)
    }
    $hostName = [string]$Row.Cells["Host"].Value
    if (Test-HostLooksLocal $hostName) {
        return @(Get-LocalHostDirectoryListing $Path)
    }
    $systemName = [string]$Row.Cells["SshAlias"].Value
    if ([string]::IsNullOrWhiteSpace($systemName)) {
        $systemName = $hostName
    }
    $osType = [string]$Row.Cells["OsType"].Value
    return @(Get-RemoteHostDirectoryListingCore -SystemName $systemName -OsType $osType -Path $Path -User ([string]$Row.Cells["User"].Value))
}

function Get-HostParentPath {
    param(
        [string]$Path,
        [string]$OsType
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }
    if ($OsType -eq "Linux") {
        $parent = [string](Split-Path -Path $Path.TrimEnd("/") -Parent)
        if ([string]::IsNullOrWhiteSpace($parent)) {
            return "/"
        }
        return $parent
    }
    $parent = [string](Split-Path -Path $Path -Parent)
    if ([string]::IsNullOrWhiteSpace($parent)) {
        return (Split-Path -Path $Path -Qualifier)
    }
    return $parent
}

function Show-HostPathBrowser {
    param(
        $Row,
        [string]$InitialPath = ""
    )
    $osType = "Windows"
    if ($null -ne $Row) {
        $osType = [string]$Row.Cells["OsType"].Value
    } elseif ($IsLinux) {
        $osType = "Linux"
    }
    $currentPath = [string]$InitialPath
    if ([string]::IsNullOrWhiteSpace($currentPath)) {
        $currentPath = Get-DefaultBrowseRootForOs $osType
    }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Browse folders and files"
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.Size = New-Object System.Drawing.Size -ArgumentList 980, 560
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $true

    $pathBox = New-TextBox $currentPath 70 12 780 24
    $dialog.Controls.Add((New-Label "Path:" 12 14 50 22))
    $dialog.Controls.Add($pathBox)

    $upButton = New-Button "Up" 860 10 45 28
    $goButton = New-Button "Go" 910 10 45 28
    $dialog.Controls.Add($upButton)
    $dialog.Controls.Add($goButton)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point -ArgumentList 12, 48
    $grid.Size = New-Object System.Drawing.Size -ArgumentList 944, 420
    $grid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
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
            $col.FillWeight = 180
        }
        $grid.Columns.Add($col) | Out-Null
    }
    $dialog.Controls.Add($grid)

    $buttonPanel = New-Object System.Windows.Forms.Panel
    $buttonPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $buttonPanel.Height = 46
    $dialog.Controls.Add($buttonPanel)

    $state = @{
        Row = $Row
        OsType = $osType
        Result = $null
        Grid = $grid
        PathBox = $pathBox
        Dialog = $dialog
    }
    $dialog.Tag = $state

    $loadPath = {
        param([string]$PathToLoad)
        $ctx = $this.Tag
        if ($null -eq $ctx) {
            $ctx = $state
        }
        $ctx.Grid.Rows.Clear()
        $items = @(Get-HostDirectoryListing -Row $ctx.Row -Path $PathToLoad)
        foreach ($item in $items) {
            $idx = $ctx.Grid.Rows.Add()
            $ctx.Grid.Rows[$idx].Cells["Kind"].Value = [string]$item.Kind
            $ctx.Grid.Rows[$idx].Cells["Target"].Value = [string]$item.Target
            $ctx.Grid.Rows[$idx].Cells["Description"].Value = [string]$item.Description
        }
        $ctx.PathBox.Text = $PathToLoad
    }.GetNewClosure()

    $upButton.Add_Click({
        $ctx = $dialog.Tag
        $parent = Get-HostParentPath ([string]$ctx.PathBox.Text) ([string]$ctx.OsType)
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            try {
                & $loadPath $parent
            } catch {
                Show-Warning ("Browse failed: " + $_.Exception.Message)
            }
        }
    }.GetNewClosure())
    $goButton.Add_Click({
        $ctx = $dialog.Tag
        try {
            & $loadPath ([string]$ctx.PathBox.Text.Trim())
        } catch {
            Show-Warning ("Browse failed: " + $_.Exception.Message)
        }
    }.GetNewClosure())
    $grid.Add_CellDoubleClick({
        param($sender, $eventArgs)
        $ctx = $dialog.Tag
        if ($eventArgs.RowIndex -lt 0) {
            return
        }
        $kind = [string]$sender.Rows[$eventArgs.RowIndex].Cells["Kind"].Value
        $target = [string]$sender.Rows[$eventArgs.RowIndex].Cells["Target"].Value
        if ($kind -eq "Filesystem") {
            try {
                & $loadPath $target
            } catch {
                Show-Warning ("Browse failed: " + $_.Exception.Message)
            }
            return
        }
        $ctx.Result = [pscustomobject]@{
            Kind = $kind
            Target = $target
            Description = [string]$sender.Rows[$eventArgs.RowIndex].Cells["Description"].Value
        }
        $ctx.Dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $ctx.Dialog.Close()
    }.GetNewClosure())

    $selectButton = New-Button "Use selected" 700 9 110 28
    $selectButton.Add_Click({
        $ctx = $dialog.Tag
        if ($ctx.Grid.SelectedRows.Count -eq 0) {
            Show-Warning "Select a folder or file first."
            return
        }
        $ctx.Result = [pscustomobject]@{
            Kind = [string]$ctx.Grid.SelectedRows[0].Cells["Kind"].Value
            Target = [string]$ctx.Grid.SelectedRows[0].Cells["Target"].Value
            Description = [string]$ctx.Grid.SelectedRows[0].Cells["Description"].Value
        }
        $ctx.Dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $ctx.Dialog.Close()
    }.GetNewClosure())
    $buttonPanel.Controls.Add($selectButton)
    $useFolderButton = New-Button "Use this folder" 560 9 120 28
    $useFolderButton.Add_Click({
        $ctx = $dialog.Tag
        $path = [string]$ctx.PathBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($path)) {
            return
        }
        $ctx.Result = [pscustomobject]@{
            Kind = "Filesystem"
            Target = $path
            Description = "Current folder"
        }
        $ctx.Dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $ctx.Dialog.Close()
    }.GetNewClosure())
    $buttonPanel.Controls.Add($useFolderButton)
    $cancelButton = New-Button "Cancel" 820 9 80 28
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $buttonPanel.Controls.Add($cancelButton)
    $dialog.AcceptButton = $selectButton
    $dialog.CancelButton = $cancelButton

    try {
        & $loadPath $currentPath
    } catch {
        Show-Warning ("Browse failed: " + $_.Exception.Message)
        return $null
    }

    if ($dialog.ShowDialog($script:Form) -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }
    return $state.Result
}
