# Pester tests for config generation logic.
# Run on Windows with: Invoke-Pester -Path .\tests\ConfigGeneration.Tests.ps1

BeforeAll {
    $script:AppRoot = Split-Path -Parent $PSScriptRoot
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
    $script:SlaveGrid = $null
    $script:ConfigPreviewBox = $null

    $moduleRoot = Join-Path $script:AppRoot "src\modules"
    . (Join-Path $moduleRoot "Core.ps1")
    Import-AppModules $moduleRoot
}

Describe "Golden config snippets" {
    It "renders raw local storage line" {
        $script:Settings = Read-JsonFile $script:SettingsPath (Read-JsonFile (Join-Path $script:ConfigRoot "default-settings.json") ([pscustomobject]@{}))
        $script:Catalog = @(Read-JsonFile $script:CatalogPath @())
        $script:CurrentProfile = New-DefaultProfile "Pester-Raw" "Raw/block"
        $built = Build-VdbenchConfig
        $expected = Get-Content -LiteralPath (Join-Path $PSScriptRoot "fixtures\raw-local.txt") -Raw
        $built.Text | Should -Match ([regex]::Escape($expected.Trim()))
    }

    It "renders distributed raw storage line" {
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
                Status = "Pester"
                Notes = ""
            }
        )
        $built = Build-VdbenchConfig
        $expected = Get-Content -LiteralPath (Join-Path $PSScriptRoot "fixtures\raw-distributed.txt") -Raw
        $built.Text | Should -Match ([regex]::Escape($expected.Trim()))
    }

    It "renders distributed filesystem definition" {
        $script:CurrentProfile = New-DefaultProfile "Pester-FS" "Filesystem"
        $script:Slaves = @(
            [pscustomobject]@{
                Enabled = $true
                Name = "test-002"
                Host = "10.0.0.12"
                OsType = "Linux"
                VdbenchPath = "/opt/vdbench"
                TestTarget = "/mnt/test"
                SshAlias = "test-002"
                PrivateKey = ""
                Status = "Pester"
                Notes = ""
            }
        )
        $built = Build-VdbenchConfig
        $expected = Get-Content -LiteralPath (Join-Path $PSScriptRoot "fixtures\fs-distributed.txt") -Raw
        $built.Text | Should -Match ([regex]::Escape($expected.Trim()))
    }
}

Describe "Metric parsing" {
    It "parses Vdbench timestamp output" {
        $metric = Get-MetricValuesFromLine "07:02:41.012          1     6389    99.80  40960240    70    0.015"
        $metric.Iops | Should -Be 6389
        $metric.Mbps | Should -Be 99.80
    }
}
