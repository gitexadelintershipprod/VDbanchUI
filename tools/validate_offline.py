#!/usr/bin/env python3
"""Offline validation for the portable Vdbench UI project.

This validator intentionally uses only the Python standard library so it can run in
development environments that do not have Windows PowerShell available. It validates the
JSON contracts, module layout, golden config snippets, and renders representative Vdbench
parameter files from the same catalog shape used by the UI.
"""

from __future__ import annotations

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CATALOG_PATH = ROOT / "config" / "parameter-catalog.json"
SETTINGS_PATH = ROOT / "config" / "default-settings.json"
LAUNCHER_PATH = ROOT / "Launch-VdbenchUI.bat"
MODULE_ROOT = ROOT / "src" / "modules"
FIXTURE_ROOT = ROOT / "tests" / "fixtures"
FAKE_RUNNER_PATH = ROOT / "tools" / "FakeVdbench.ps1"
PACKAGE_SCRIPT_PATH = ROOT / "tools" / "Package-Portable.ps1"
SMOKE_SCRIPT_PATH = ROOT / "tools" / "Invoke-SmokeTest.ps1"
VERIFY_SCRIPT_PATH = ROOT / "tools" / "Verify-Portable.ps1"

REQUIRED_CATALOG_FIELDS = {
    "Key",
    "Section",
    "Label",
    "VdbenchName",
    "Line",
    "Type",
    "Default",
    "Options",
    "AppliesTo",
    "Required",
    "Help",
    "Example",
}

REQUIRED_SETTINGS = {
    "VdbenchRoot",
    "MasterVdbenchBat",
    "ReportsRoot",
    "RunMode",
    "ReadinessCheckerArguments",
    "SlaveShell",
}

REQUIRED_MODULES = [
    "Core.ps1",
    "Import-AppModules.ps1",
    "Metrics.ps1",
    "ProcessRunner.ps1",
    "State.ps1",
    "UiHelpers.ps1",
    "TargetDiscovery.ps1",
    "UiSlaveGrid.ps1",
    "UiTabs.ps1",
    "ConfigGeneration.ps1",
    "Runner.ps1",
    "SelfTest.ps1",
]

GOLDEN_FIXTURES = {
    "raw-local.txt": "sd=sd1,lun=C:\\vdbench\\testfile.dat",
    "raw-distributed.txt": "sd=sd_test_001,host=test-001,lun=/dev/sdb",
    "fs-local.txt": "fsd=fsd1,anchor=C:\\vdbench\\fs_test",
    "fs-distributed.txt": "fsd=fsd_test_002,host=test-002,anchor=/mnt/test",
}


def load_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def applies(definition: dict, test_kind: str) -> bool:
    target = definition["AppliesTo"]
    return target == "both" or (target == "raw" and test_kind == "Raw/block") or (
        target == "fs" and test_kind == "Filesystem"
    )


def default_profile(catalog: list[dict], name: str, test_kind: str) -> dict:
    params = {}
    for definition in catalog:
        value = str(definition.get("Default", ""))
        enabled = bool(definition.get("Required")) or bool(value.strip())
        params[definition["Key"]] = {"Enabled": enabled, "Value": value}
    return {
        "Name": name,
        "TestKind": test_kind,
        "Parameters": params,
        "AdvancedActive": "",
        "AdvancedDisabled": "",
    }


def param(profile: dict, key: str, default: str = "") -> str:
    item = profile["Parameters"].get(key)
    if not item:
        return default
    return str(item.get("Value") or default)


def enabled(profile: dict, key: str) -> bool:
    item = profile["Parameters"].get(key)
    return bool(item and item.get("Enabled"))


def add_params(parts: list[str], disabled: list[str], catalog: list[dict], profile: dict, line: str, test_kind: str):
    for definition in catalog:
        if definition["Line"] != line or not applies(definition, test_kind):
            continue
        key = definition["Key"]
        value = param(profile, key)
        if not value.strip():
            continue
        name = definition["VdbenchName"]
        if enabled(profile, key):
            if name == "openflags" and value == "none":
                continue
            parts.append(f"{name}={value}")
        else:
            disabled.append(f"* disabled: {name}={value} ({definition['Section']})")


COMMON_MIRRORS = {
    "common.xfersize": ["workload.xfersize", "fwd.xfersize"],
    "common.threads": ["workload.threads", "fwd.threads"],
    "common.rate": ["run.iorate", "run.fwdrate"],
}


def sync_common_parameters(profile: dict):
    params = profile.setdefault("Parameters", {})
    for common_key, mirrors in COMMON_MIRRORS.items():
        item = params.get(common_key)
        common_value = ""
        common_enabled = False
        if item:
            common_value = str(item.get("Value") or "")
            common_enabled = bool(item.get("Enabled"))
        if not common_value.strip():
            for mirror_key in mirrors:
                mirror_item = params.get(mirror_key)
                if not mirror_item:
                    continue
                mirror_value = str(mirror_item.get("Value") or "")
                if mirror_value.strip():
                    common_value = mirror_value
                    common_enabled = bool(mirror_item.get("Enabled"))
                    params[common_key] = {"Enabled": common_enabled, "Value": common_value}
                    break
        for mirror_key in mirrors:
            params[mirror_key] = {"Enabled": common_enabled, "Value": common_value}


def render_config(
    catalog: list[dict],
    settings: dict,
    profile: dict,
    slaves: list[dict] | None = None,
    local_targets: list[dict] | None = None,
    test_kind: str | None = None,
) -> str:
    if test_kind is None:
        test_kind = profile.get("TestKind", "Raw/block")
    sync_common_parameters(profile)
    distributed = bool(slaves)
    disabled: list[str] = []
    lines: list[str] = [
        "* Generated by offline validator",
        f"* Profile={profile['Name']}",
        f"* Mode={'Master/Slave distributed run' if distributed else 'Single local run'}",
        "",
    ]
    local_target_rows = local_targets if local_targets is not None else profile.get("LocalTargets", [])

    if distributed:
        host_defaults = ["hd=default"]
        if settings.get("SlaveShell"):
            host_defaults.append(f"shell={settings['SlaveShell']}")
        lines.append("* Host definitions")
        lines.append(",".join(host_defaults))
        for slave in slaves or []:
            system = slave.get("SshAlias") or slave["Host"]
            host_parts = [f"hd={slave['Name']}", f"system={system}"]
            if slave.get("User"):
                host_parts.append(f"user={slave['User']}")
            host_parts.append(f"vdbench={slave['VdbenchPath']}")
            lines.append(",".join(host_parts))
        lines.append("")

    if test_kind == "Raw/block":
        sd_name = param(profile, "storage.name", "sd1")
        wd_name = param(profile, "workload.name", "wd1")
        rd_name = param(profile, "run.name", "rd1")

        lines.append("* Storage definitions")
        if distributed:
            for slave in slaves or []:
                safe_name = "".join(ch if ch.isalnum() or ch == "_" else "_" for ch in slave["Name"])
                raw_targets = [t for t in slave.get("Targets", []) if t.get("Selected") and t.get("Kind") != "Filesystem"]
                for index, target in enumerate(raw_targets, start=1):
                    parts = [f"sd=sd_{safe_name}_{index}", f"host={slave['Name']}", f"lun={target['Target']}"]
                    for definition in catalog:
                        if definition["Key"] == "storage.lun":
                            continue
                        if definition["Line"] == "storage" and applies(definition, test_kind):
                            add_params(parts, disabled, [definition], profile, "storage", test_kind)
                    lines.append(",".join(parts))
        else:
            raw_targets = [t for t in local_target_rows if t.get("Selected") and t.get("Kind") != "Filesystem"]
            for index, target in enumerate(raw_targets, start=1):
                name = sd_name if len(raw_targets) == 1 else f"{sd_name}_{index}"
                parts = [f"sd={name}", f"lun={target['Target']}"]
                for definition in catalog:
                    if definition["Key"] == "storage.lun":
                        continue
                    if definition["Line"] == "storage" and applies(definition, test_kind):
                        add_params(parts, disabled, [definition], profile, "storage", test_kind)
                lines.append(",".join(parts))
        lines.append("")

        local_raw_count = len([t for t in local_target_rows if t.get("Selected") and t.get("Kind") != "Filesystem"])
        parts = [f"wd={wd_name}", "sd=sd*" if distributed or local_raw_count > 1 else f"sd={sd_name}"]
        add_params(parts, disabled, catalog, profile, "workload", test_kind)
        lines.extend(["* Workload definitions", ",".join(parts), ""])

        parts = [f"rd={rd_name}", f"wd={wd_name}"]
        add_params(parts, disabled, catalog, profile, "run", test_kind)
        lines.extend(["* Run definition", ",".join(parts)])
    else:
        fsd_name = param(profile, "fsd.name", "fsd1")
        fwd_name = param(profile, "fwd.name", "fwd1")
        rd_name = param(profile, "run.name", "rd1")

        lines.append("* Filesystem definitions")
        if distributed:
            for slave in slaves or []:
                safe_name = "".join(ch if ch.isalnum() or ch == "_" else "_" for ch in slave["Name"])
                fs_targets = [t for t in slave.get("Targets", []) if t.get("Selected") and t.get("Kind") == "Filesystem"]
                for index, target in enumerate(fs_targets, start=1):
                    parts = [f"fsd=fsd_{safe_name}_{index}", f"host={slave['Name']}", f"anchor={target['Target']}"]
                    for definition in catalog:
                        if definition["Key"] == "fsd.anchor":
                            continue
                        if definition["Line"] == "fsd" and applies(definition, test_kind):
                            add_params(parts, disabled, [definition], profile, "fsd", test_kind)
                    lines.append(",".join(parts))
        else:
            fs_targets = [t for t in local_target_rows if t.get("Selected") and t.get("Kind") == "Filesystem"]
            for index, target in enumerate(fs_targets, start=1):
                name = fsd_name if len(fs_targets) == 1 else f"{fsd_name}_{index}"
                parts = [f"fsd={name}", f"anchor={target['Target']}"]
                for definition in catalog:
                    if definition["Key"] == "fsd.anchor":
                        continue
                    if definition["Line"] == "fsd" and applies(definition, test_kind):
                        add_params(parts, disabled, [definition], profile, "fsd", test_kind)
                lines.append(",".join(parts))
        lines.append("")

        local_fs_count = len([t for t in local_target_rows if t.get("Selected") and t.get("Kind") == "Filesystem"])
        parts = [f"fwd={fwd_name}", "fsd=fsd*" if distributed or local_fs_count > 1 else f"fsd={fsd_name}"]
        add_params(parts, disabled, catalog, profile, "fwd", test_kind)
        lines.extend(["* Filesystem workload", ",".join(parts), ""])

        parts = [f"rd={rd_name}", f"fwd={fwd_name}"]
        add_params(parts, disabled, catalog, profile, "run", test_kind)
        lines.extend(["* Run definition", ",".join(parts)])

    if disabled:
        lines.extend(["", "* Disabled parameters preserved by UI", *disabled])
    return "\n".join(lines)


def validate_catalog(catalog: list[dict]):
    keys = set()
    for index, item in enumerate(catalog):
        missing = REQUIRED_CATALOG_FIELDS - set(item)
        assert not missing, f"catalog item {index} missing fields: {sorted(missing)}"
        key = item["Key"]
        assert key not in keys, f"duplicate catalog key: {key}"
        keys.add(key)
        assert item["Type"] in {"text", "dropdown"}, f"unsupported type for {key}: {item['Type']}"
        assert item["AppliesTo"] in {"both", "raw", "fs"}, f"bad AppliesTo for {key}: {item['AppliesTo']}"
        if item["Type"] == "dropdown":
            assert item["Options"], f"dropdown parameter has no options: {key}"


def validate_modules():
    for name in REQUIRED_MODULES:
        path = MODULE_ROOT / name
        assert path.is_file(), f"missing module: {path}"
        if name.endswith(".ps1"):
            text = path.read_text(encoding="utf-8")
            assert text.count("{") == text.count("}"), f"unbalanced braces in module: {name}"


# `.Count` / `.Length` are PowerShell-provided members present on every array
# (even empty ones), so they never trigger the member-enumeration bug below.
_ARRAY_WRAP_PROPERTY_SAFE_MEMBERS = {"Count", "Length"}
_ARRAY_WRAP_PROPERTY_PATTERN = re.compile(r"@\([^()\n]*\)\.([A-Za-z_]\w*)\b(?!\s*\()")


def validate_no_array_wrap_property_access():
    """Statically ban `@(Expr).Property` for any Property other than Count/Length.

    Root cause of a real production bug (found 2026-07-01, see
    Get-SlaveRowTargets in UiSlaveGrid.ps1's git history): under
    `Set-StrictMode -Version 2.0` (enabled app-wide via VdbenchUI.ps1),
    wrapping a function call (or any single object) in the array
    sub-expression operator `@()` and then accessing a *custom* property on
    the result triggers PowerShell's per-element "member enumeration" on the
    resulting array instead of plain property access on the original object.
    When that property's value is itself an empty collection for every
    element (e.g. a freshly-added slave row with no targets picked yet),
    member enumeration collects zero results and PowerShell raises "The
    property 'X' cannot be found on this object" -- even though the property
    demonstrably exists. This reproduces with a two-line snippet with no
    WinForms/app code involved at all:

        Set-StrictMode -Version 2.0
        @(@{ Targets = @() }).Targets   # throws "cannot be found"
        (@{ Targets = @() }).Targets    # returns @() correctly

    The fix is always the same: access the property directly on the
    un-wrapped expression, e.g. `(Expr).Property`, and apply @() (if needed)
    to the *result* of that property access instead: `@((Expr).Property)`.
    This scan allows `.Count`/`.Length` (safe, see above) and method calls
    (`.Foo(...)`, which this bug does not affect) but fails the build on any
    other `@(...).Property` usage anywhere in src/.
    """
    violations = []
    for path in sorted(MODULE_ROOT.glob("*.ps1")) + sorted((ROOT / "src").glob("*.ps1")):
        text = path.read_text(encoding="utf-8")
        for lineno, line in enumerate(text.splitlines(), start=1):
            if line.strip().startswith("#"):
                continue
            for match in _ARRAY_WRAP_PROPERTY_PATTERN.finditer(line):
                member = match.group(1)
                if member in _ARRAY_WRAP_PROPERTY_SAFE_MEMBERS:
                    continue
                violations.append(f"{path.relative_to(ROOT)}:{lineno}: @(...).{member}  -->  {line.strip()}")
    assert not violations, (
        "Dangerous '@(Expr).Property' pattern found (member-enumeration bug under "
        "Set-StrictMode -Version 2.0 when Property is an empty collection for every "
        "element - see validate_no_array_wrap_property_access docstring):\n"
        + "\n".join(violations)
    )


def validate_golden_fixtures():
    for name, expected in GOLDEN_FIXTURES.items():
        path = FIXTURE_ROOT / name
        assert path.is_file(), f"missing golden fixture: {path}"
        content = path.read_text(encoding="utf-8").strip()
        assert content == expected, f"golden fixture drift in {name}"


def run_powershell_checks() -> bool:
    """Actually parse and execute PowerShell where possible.

    This project's real logic runs in Windows PowerShell/WinForms, which the
    string-matching checks above cannot execute. When `pwsh` (PowerShell 7+)
    is available on PATH -- e.g. after installing it via
    https://aka.ms/install-powershell.sh -- this parses every .ps1 file for
    syntax errors and runs the headless self-test (Invoke-AppSelfTest), which
    exercises Initialize-AppState, profile creation, and config generation
    end-to-end without requiring System.Windows.Forms.

    Returns True if checks ran and passed, False if pwsh was unavailable
    (checks are skipped, not failed, so this still works in CI without
    PowerShell installed).
    """
    import shutil
    import subprocess
    import tempfile

    pwsh = shutil.which("pwsh")
    if not pwsh:
        print("pwsh not found on PATH; skipping real PowerShell syntax/self-test checks")
        print("  (install via https://aka.ms/install-powershell.sh for stronger validation)")
        return False

    ps1_files = sorted(MODULE_ROOT.glob("*.ps1")) + sorted((ROOT / "src").glob("*.ps1")) + sorted((ROOT / "tools").glob("*.ps1"))
    parse_script = r"""
$hadErrors = $false
foreach ($path in $args) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        $hadErrors = $true
        Write-Host "PARSE ERROR: $path"
        foreach ($e in $errors) { Write-Host ("  " + $e.Message + " at line " + $e.Extent.StartLineNumber) }
    }
}
if ($hadErrors) { exit 1 }
Write-Host "All $($args.Count) .ps1 files parsed without syntax errors."
"""
    with tempfile.TemporaryDirectory(prefix="vdbench-parsecheck-") as parse_tmp_dir:
        parse_script_path = Path(parse_tmp_dir) / "parse-check.ps1"
        parse_script_path.write_text(parse_script, encoding="utf-8")
        result = subprocess.run(
            [pwsh, "-NoProfile", "-File", str(parse_script_path), *[str(p) for p in ps1_files]],
            capture_output=True, text=True,
        )
    print(result.stdout.strip())
    if result.returncode != 0:
        print(result.stderr.strip())
        raise AssertionError("PowerShell syntax check failed (see PARSE ERROR lines above)")

    with tempfile.TemporaryDirectory(prefix="vdbench-selftest-") as tmp_dir:
        selftest_script = r"""
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$script:AppRoot = "{app_root}"
$script:ConfigRoot = Join-Path $script:AppRoot "config"
$script:DataRoot = "{tmp_dir}/data"
$script:ProfileRoot = "{tmp_dir}/profiles"
$script:RunStateRoot = Join-Path $script:DataRoot "runs"
$script:LogRoot = "{tmp_dir}/logs"
$script:SettingsPath = Join-Path $script:DataRoot "settings.json"
$script:SlavesPath = Join-Path $script:DataRoot "slaves.json"
$script:LocalHostTargetsPath = Join-Path $script:DataRoot "localhost.json"
$script:CatalogPath = Join-Path $script:ConfigRoot "parameter-catalog.json"
$script:Settings = $null
$script:Slaves = @()
$script:LocalHostTargets = @()
$script:Catalog = @()
$script:CurrentProfile = $null
$script:RunProfile = $null
$script:ParameterControls = @{{}}
$script:SettingsControls = @{{}}
$script:RefreshingProfileEditor = $false
$script:CurrentProcess = $null
$script:CurrentRunId = $null
$script:KillRequested = $false
$script:LogQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$script:Form = $null
$script:SettingsStatusBox = $null
$script:SlaveGrid = $null
$script:ProfileNameBox = $null
$script:ProfileParamTabs = $null
$script:RunModeCombo = $null
$script:RunProfileSelector = $null
$script:RunSummaryBox = $null
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
$script:MainTabControl = $null
$script:LocalHostTab = $null
$script:MasterSlaveTab = $null
$script:LocalHostInfoBox = $null
$script:LocalHostTargetGrid = $null
$script:RefreshingLocalTargets = $false
$script:RunModeIndicator = $null
$script:AppToolTip = $null
$script:RunFinishedNotified = $false
$script:MainTabToolTipText = ""
$script:UiRefreshTimer = $null
$script:DpiAwarenessInitialized = $false
$script:AppExceptionLoggingRegistered = $false
$script:ProfileEditorLocked = $true
$script:ProfileEditorTestKind = ""
$script:ProfileEditorLastTestKind = ""
$script:ProfileNewButton = $null
$script:ProfileSaveButton = $null
$script:ProfilePreviewButton = $null
$script:ProfileEditorBanner = $null
$script:ModuleRoot = "{module_root}"
foreach ($m in @("Core.ps1","Metrics.ps1","ProcessRunner.ps1","State.ps1","UiHelpers.ps1","TargetDiscovery.ps1","UiSlaveGrid.ps1","UiTabs.ps1","ConfigGeneration.ps1","Runner.ps1","SelfTest.ps1")) {{
    . (Join-Path $script:ModuleRoot $m)
}}
Invoke-AppSelfTest
""".format(app_root=str(ROOT), tmp_dir=tmp_dir.replace("\\", "/"), module_root=str(MODULE_ROOT))
        selftest_path = Path(tmp_dir) / "run-selftest.ps1"
        selftest_path.write_text(selftest_script, encoding="utf-8")
        result = subprocess.run(
            [pwsh, "-NoProfile", "-File", str(selftest_path)],
            capture_output=True, text=True,
        )
        print(result.stdout.strip())
        if result.returncode != 0:
            print(result.stderr.strip())
            raise AssertionError("Invoke-AppSelfTest failed under real PowerShell execution")

    _run_readiness_regression_check(pwsh)
    _run_slave_targets_regression_check(pwsh)
    _run_readiness_window_regression_check(pwsh)
    return True


def _run_slave_targets_regression_check(pwsh: str) -> None:
    """Reproduce the "property 'Targets' cannot be found" crash end-to-end.

    Root cause (found 2026-07-01): Get-SlaveRowTargets used to read
    `@(Get-SlaveRowState $Row).Targets` -- wrapping the function call in @()
    before accessing .Targets. Under Set-StrictMode -Version 2.0, that
    triggers PowerShell's per-element "member enumeration" on the resulting
    1-item array instead of plain property access; when .Targets is an empty
    array (true for every slave row until the user picks targets via
    Browse), member enumeration collects zero results and PowerShell raises
    "The property 'Targets' cannot be found on this object" -- even though
    the property demonstrably exists. This broke essentially every
    interaction with a freshly-added slave (tab switches, Save, Browse,
    Readiness, Enabled toggling) since Capture-SlaveGrid calls
    Get-SlaveRowTargets for every row on every call.

    This check drives the real Capture-SlaveGrid/Get-EnabledSlaves/
    Get-ProfileEditorContext/Resolve-RunTestKind/Get-SlaveRowTargets
    functions against a mocked SlaveGrid containing rows with zero targets
    selected (the exact state right after "Add slave"), which is exactly
    the scenario that used to crash.
    """
    import subprocess
    import tempfile

    with tempfile.TemporaryDirectory(prefix="vdbench-targets-check-") as tmp_dir:
        tmp_path = Path(tmp_dir)
        harness_script = tmp_path / "run-targets-check.ps1"
        harness_script.write_text(
            """
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$script:AppRoot = "{app_root}"
$script:ConfigRoot = Join-Path $script:AppRoot "config"
$script:DataRoot = "{tmp_dir}/data"
$script:ProfileRoot = "{tmp_dir}/profiles"
$script:RunStateRoot = Join-Path $script:DataRoot "runs"
$script:LogRoot = "{tmp_dir}/logs"
$script:SettingsPath = Join-Path $script:DataRoot "settings.json"
$script:SlavesPath = Join-Path $script:DataRoot "slaves.json"
$script:LocalHostTargetsPath = Join-Path $script:DataRoot "localhost.json"
$script:CatalogPath = Join-Path $script:ConfigRoot "parameter-catalog.json"
$script:Settings = $null
$script:Slaves = @()
$script:LocalHostTargets = @()
$script:Catalog = @()
$script:CurrentProfile = $null
$script:RunProfile = $null
$script:ProfileEditorLocked = $true
$script:LocalHostTargetGrid = $null
$script:RefreshingLocalTargets = $false
$script:RunModeCombo = $null
$script:ModuleRoot = "{module_root}"
foreach ($m in @("Core.ps1","Metrics.ps1","ProcessRunner.ps1","State.ps1","UiHelpers.ps1","TargetDiscovery.ps1","UiSlaveGrid.ps1","UiTabs.ps1","ConfigGeneration.ps1","Runner.ps1")) {{
    . (Join-Path $script:ModuleRoot $m)
}}
Initialize-AppState
Set-PropertyValue $script:Settings "RunMode" "Master/Slave distributed run"

function New-MockCellCollection {{
    $cells = @{{}}
    foreach ($col in @("Enabled","Name","Host","OsType","User","VdbenchPath","SshAlias","Targets","Readiness","CheckedAt","PingStatus","PingAt","Notes")) {{
        $cells[$col] = [pscustomobject]@{{ Value = "" }}
    }}
    return $cells
}}
function New-MockSlaveRow {{
    param([string]$SlaveName, [string]$HostName)
    $row = [pscustomobject]@{{ Tag = $null; IsNewRow = $false; Index = 0; Cells = (New-MockCellCollection) }}
    $row.Cells["Name"].Value = $SlaveName
    $row.Cells["Host"].Value = $HostName
    $row.Cells["Enabled"].Value = $false
    $row.Cells["OsType"].Value = "Windows"
    return $row
}}

# Exact state right after clicking "Add slave" twice and entering a Host,
# before ever touching Browse - zero targets selected on every row.
$row1 = New-MockSlaveRow "slave-1" "10.50.11.183"
$row2 = New-MockSlaveRow "slave-2" "10.50.11.184"
$script:SlaveGrid = [pscustomobject]@{{ Rows = @($row1, $row2) }}

$errors = @()
function Test-Step {{
    param([string]$Label, [scriptblock]$Action)
    try {{
        & $Action
    }} catch {{
        $script:errors += "$Label -- $($_.Exception.Message)"
    }}
}}

Test-Step "Capture-SlaveGrid" {{ Capture-SlaveGrid }}
Test-Step "Get-EnabledSlaves" {{ $null = @(Get-EnabledSlaves) }}
Test-Step "Get-ProfileEditorContext" {{ $null = Get-ProfileEditorContext }}
Test-Step "Resolve-RunTestKind" {{ $null = Resolve-RunTestKind }}
Test-Step "Get-SlaveRowTargets (Browse button path)" {{ $null = @(Get-SlaveRowTargets $row1) }}
Test-Step "Get-SelectedTargetEntries(Get-SlaveRowTargets) (Readiness button path)" {{ $null = @(Get-SelectedTargetEntries (Get-SlaveRowTargets $row1)) }}

if ($errors.Count -gt 0) {{
    foreach ($e in $errors) {{ Write-Host "STEP FAILED: $e" }}
    exit 1
}}
Write-Host "All slave-targets regression steps passed"
""".format(app_root=str(ROOT), tmp_dir=tmp_dir.replace("\\", "/"), module_root=str(MODULE_ROOT)),
            encoding="utf-8",
        )
        result = subprocess.run(
            [pwsh, "-NoProfile", "-File", str(harness_script)],
            capture_output=True, text=True,
        )
        print(result.stdout.strip())
        if result.returncode != 0:
            print(result.stderr.strip())
            raise AssertionError(
                "Slave-targets regression check failed: a freshly-added slave row with "
                "no targets selected yet crashed one of Capture-SlaveGrid/Get-EnabledSlaves/"
                "Get-ProfileEditorContext/Resolve-RunTestKind/Get-SlaveRowTargets"
            )


def _run_readiness_regression_check(pwsh: str) -> None:
    """Reproduce the real Readiness-check bug end-to-end and prove the fix.

    Root cause (found by actually installing pwsh and running the code,
    2026-07-01): the shipped ReadinessCheckerArguments default
    ("-HostName {Host} -VdbenchPath {VdbenchPath} -Target {Target}") throws
    "A parameter cannot be found that matches parameter name 'HostName'."
    against any checker script using [CmdletBinding()] with no matching
    parameters declared -- which is exactly how real-world "check every
    configured host in one run" checker scripts are commonly written (see
    docs/MASTER_SLAVE_MODEL.md). This regression check builds such a fake
    checker, calls the real Get-SlaveReadinessResult with both the legacy and
    current default, and asserts the legacy one fails with that exact message
    while the current default succeeds -- plus verifies the checker's own
    working directory is set deterministically (its own folder) rather than
    inherited from whatever launched the UI, which is what let stray output
    end up outside the real Vdbench install.
    """
    import os
    import subprocess
    import tempfile

    with tempfile.TemporaryDirectory(prefix="vdbench-readiness-check-") as tmp_dir:
        tmp_path = Path(tmp_dir)

        # powershell.exe does not exist on Linux; Get-SlaveReadinessResult
        # hardcodes that filename (matching the real Windows target), so give
        # subprocess a PATH-resolvable shim that forwards to pwsh.
        shim_dir = tmp_path / "shim"
        shim_dir.mkdir()
        shim_path = shim_dir / "powershell.exe"
        shim_path.write_text(f"#!/bin/sh\nexec \"{pwsh}\" \"$@\"\n", encoding="utf-8")
        shim_path.chmod(0o755)

        checker_dir = tmp_path / "checker-home"
        checker_dir.mkdir()
        checker_path = checker_dir / "04-Check-Vdbench-Hosts-Readiness.ps1"
        checker_path.write_text(
            "[CmdletBinding()]\n"
            "param()\n"
            "Write-Host 'Checking Master readiness'\n"
            "Write-Host '[OK]  MASTER  fake host check'\n"
            "New-Item -ItemType Directory -Path '.\\relative-output' -Force | Out-Null\n"
            "Set-Content -Path '.\\relative-output\\marker.txt' -Value 'created by fake checker'\n"
            "exit 0\n",
            encoding="utf-8",
        )

        wrong_launch_dir = tmp_path / "wrong-launch-dir"
        wrong_launch_dir.mkdir()

        harness_script = tmp_path / "run-readiness-check.ps1"
        harness_script.write_text(
            """
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$script:ModuleRoot = "{module_root}"
foreach ($m in @("Core.ps1","Metrics.ps1","ProcessRunner.ps1","State.ps1","UiHelpers.ps1","TargetDiscovery.ps1","UiSlaveGrid.ps1","UiTabs.ps1","ConfigGeneration.ps1","Runner.ps1")) {{
    . (Join-Path $script:ModuleRoot $m)
}}
Set-Location "{wrong_launch_dir}"

$legacy = Get-SlaveReadinessResult "10.0.0.1" "C:\\vdbench" "C:\\vdbench\\test" "{checker_path}" "-HostName {{Host}} -VdbenchPath {{VdbenchPath}} -Target {{Target}}" $false
$current = Get-SlaveReadinessResult "10.0.0.1" "C:\\vdbench" "C:\\vdbench\\test" "{checker_path}" "" $false

# A machine that already ran an earlier version has data/settings.json seeded
# with the old broken default forever, since Merge-DefaultProperties only ever
# ADDS missing keys. Prove Migrate-LegacySettings actually cleans that up, and
# leaves a deliberately-customized value alone.
$legacySettings = [pscustomobject]@{{ ReadinessCheckerArguments = "-HostName {{Host}} -VdbenchPath {{VdbenchPath}} -Target {{Target}}" }}
$migratedLegacy = Migrate-LegacySettings $legacySettings
$customSettings = [pscustomobject]@{{ ReadinessCheckerArguments = "-MyCustomFlag foo" }}
$migratedCustom = Migrate-LegacySettings $customSettings

$results = [pscustomobject]@{{
    LegacyStatus = $legacy.Status
    LegacyOutput = $legacy.Output
    CurrentStatus = $current.Status
    MarkerNextToChecker = (Test-Path (Join-Path "{checker_dir}" "relative-output/marker.txt"))
    MarkerInWrongDir = (Test-Path (Join-Path "{wrong_launch_dir}" "relative-output"))
    MigratedLegacyChanged = [bool]$migratedLegacy
    MigratedLegacyValue = $legacySettings.ReadinessCheckerArguments
    MigratedCustomChanged = [bool]$migratedCustom
    MigratedCustomValue = $customSettings.ReadinessCheckerArguments
}}
$results | ConvertTo-Json
""".format(
                module_root=str(MODULE_ROOT),
                wrong_launch_dir=str(wrong_launch_dir),
                checker_path=str(checker_path),
                checker_dir=str(checker_dir),
            ),
            encoding="utf-8",
        )

        env = dict(os.environ)
        env["PATH"] = str(shim_dir) + ":" + env.get("PATH", "")
        result = subprocess.run(
            [pwsh, "-NoProfile", "-File", str(harness_script)],
            capture_output=True, text=True, cwd=str(wrong_launch_dir), env=env,
        )
        if result.returncode != 0:
            print(result.stdout.strip())
            print(result.stderr.strip())
            raise AssertionError("Readiness regression harness itself failed to run")

        try:
            parsed = json.loads(result.stdout.strip()) if result.stdout.strip() else {}
        except json.JSONDecodeError:
            print(result.stdout.strip())
            print(result.stderr.strip())
            raise AssertionError("Could not parse readiness regression harness output as JSON")

        assert parsed.get("LegacyStatus") == "Failed", (
            f"expected legacy ReadinessCheckerArguments default to fail against a "
            f"[CmdletBinding()] checker, got status={parsed.get('LegacyStatus')!r}"
        )
        assert "parameter cannot be found" in str(parsed.get("LegacyOutput", "")), (
            f"expected the exact PowerShell parameter-binding error, got: {parsed.get('LegacyOutput')!r}"
        )
        assert parsed.get("CurrentStatus") == "Ready", (
            f"expected empty-args current default to succeed, got status={parsed.get('CurrentStatus')!r}"
        )
        assert not parsed.get("MarkerInWrongDir"), (
            "checker's relative-path output leaked into the directory the UI happened "
            "to be launched from instead of staying next to the checker script"
        )
        assert parsed.get("MarkerNextToChecker"), (
            "checker's relative-path output should land next to the checker script "
            "itself (WorkingDirectory fix), matching how it behaves when a user runs "
            "it manually from Explorer"
        )
        assert parsed.get("MigratedLegacyChanged") and parsed.get("MigratedLegacyValue") == "", (
            f"Migrate-LegacySettings should clear the legacy default to empty, "
            f"got changed={parsed.get('MigratedLegacyChanged')!r} value={parsed.get('MigratedLegacyValue')!r}"
        )
        assert not parsed.get("MigratedCustomChanged") and parsed.get("MigratedCustomValue") == "-MyCustomFlag foo", (
            f"Migrate-LegacySettings must not touch a deliberately customized value, "
            f"got changed={parsed.get('MigratedCustomChanged')!r} value={parsed.get('MigratedCustomValue')!r}"
        )
        print("readiness regression check: legacy default fails as expected, current default + WorkingDirectory fix verified")


def _run_readiness_window_regression_check(pwsh: str) -> None:
    """Reproduce the "no separate window opens" / stacked-dialog bug end-to-end.

    Root cause #1 (found 2026-07-01 from a user screenshot showing dozens of stacked
    confirmation dialogs behind a shared console window): Get-SlaveReadinessResult
    started the checker with UseShellExecute=$false + CreateNoWindow=$false whenever
    -ShowCheckerWindow was requested. Per Win32 CreateProcess semantics (and Microsoft's
    own ProcessStartInfo.CreateNoWindow docs/blog post on this exact gotcha), that
    combination does NOT create a new console - it only avoids *suppressing* one, so the
    checker silently shared/inherited whatever console (if any) the UI's own host process
    was already attached to (e.g. when launched from a .bat/console shortcut). Fix:
    UseShellExecute=$true, which Windows always honors as "open a brand-new window"
    regardless of CreateNoWindow.

    Root cause #2 (same screenshot): every completed Readiness check run with
    -ShowOutput popped its own "ran in a separate PowerShell window" confirmation dialog
    even though the user had just watched the real output live in that window; clicking
    Readiness repeatedly (the natural reaction when nothing visibly happens right away)
    queued one background job - and one such popup - per click, and they all piled up
    once finished. Fix: Get-SlaveReadinessResult now returns AlreadyShown=$true for the
    separate-window path so the caller skips the redundant popup, AND
    Start-SlaveReadinessCheck/Start-SlavePingCheck now ignore repeat clicks while a check
    for that row is already in flight (Readiness/PingStatus cell already reads
    "Checking..."/"Pinging...").

    This check calls the real Get-SlaveReadinessResult end-to-end with
    ShowCheckerWindow=$true (proving UseShellExecute=$true does not hang/throw in this
    sandbox and still honors the WorkingDirectory fix from the check above), then calls
    the real Start-SlaveReadinessCheck/Start-SlavePingCheck twice in a row - against a
    stubbed Start-BackgroundUiWork, since the real one lazily creates a
    System.Windows.Forms.Timer that cannot be instantiated on Linux pwsh at all - to
    prove the in-flight guard stops the second click from starting another background
    job for either button.
    """
    import os
    import subprocess
    import tempfile

    with tempfile.TemporaryDirectory(prefix="vdbench-readiness-window-check-") as tmp_dir:
        tmp_path = Path(tmp_dir)

        # powershell.exe does not exist on Linux; Get-SlaveReadinessResult hardcodes
        # that filename (matching the real Windows target), so give the subprocess a
        # PATH-resolvable shim that forwards to pwsh.
        shim_dir = tmp_path / "shim"
        shim_dir.mkdir()
        shim_path = shim_dir / "powershell.exe"
        shim_path.write_text(f"#!/bin/sh\nexec \"{pwsh}\" \"$@\"\n", encoding="utf-8")
        shim_path.chmod(0o755)

        checker_dir = tmp_path / "checker-home"
        checker_dir.mkdir()
        ok_checker = checker_dir / "04-Check-Vdbench-Hosts-Readiness.ps1"
        ok_checker.write_text(
            "param()\n"
            "Write-Host 'Checking Master readiness'\n"
            "New-Item -ItemType Directory -Path '.\\relative-output' -Force | Out-Null\n"
            "Set-Content -Path '.\\relative-output\\marker.txt' -Value 'created by fake checker'\n"
            "exit 0\n",
            encoding="utf-8",
        )

        data_dir = tmp_path / "data"
        harness_script = tmp_path / "run-window-check.ps1"
        harness_script.write_text(
            """
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$script:AppRoot = "{app_root}"
$script:ConfigRoot = Join-Path $script:AppRoot "config"
$script:DataRoot = "{data_dir}"
$script:ProfileRoot = Join-Path $script:DataRoot "profiles"
$script:RunStateRoot = Join-Path $script:DataRoot "runs"
$script:LogRoot = Join-Path $script:DataRoot "logs"
$script:SettingsPath = Join-Path $script:DataRoot "settings.json"
$script:SlavesPath = Join-Path $script:DataRoot "slaves.json"
$script:LocalHostTargetsPath = Join-Path $script:DataRoot "localhost.json"
$script:CatalogPath = Join-Path $script:ConfigRoot "parameter-catalog.json"
$script:ModuleRoot = "{module_root}"
foreach ($m in @("Core.ps1","Metrics.ps1","ProcessRunner.ps1","State.ps1","UiHelpers.ps1","TargetDiscovery.ps1","UiSlaveGrid.ps1","UiTabs.ps1","ConfigGeneration.ps1","Runner.ps1")) {{
    . (Join-Path $script:ModuleRoot $m)
}}
Initialize-AppState
Set-PropertyValue $script:Settings "ReadinessChecker" "{ok_checker}"
Set-PropertyValue $script:Settings "ReadinessCheckerArguments" ""
$script:SettingsControls = @{{}}

$errors = @()
function Test-Step {{
    param([string]$Label, [scriptblock]$Action)
    try {{
        & $Action
    }} catch {{
        $script:errors += "$Label -- $($_.Exception.Message)"
    }}
}}

# --- Part 1: Get-SlaveReadinessResult with ShowCheckerWindow=$true must not hang or
# throw on this Linux sandbox, must still honor WorkingDirectory, and must mark the
# result AlreadyShown so the caller skips a duplicate confirmation dialog. ---
$okResult = $null
Test-Step "Get-SlaveReadinessResult ShowCheckerWindow=true" {{
    $script:okResult = Get-SlaveReadinessResult "10.0.0.1" "C:\\vdbench" "C:\\vdbench\\test" "{ok_checker}" "" $true
}}

# --- Part 2: repeat-click guard for Readiness / Ping. Start-BackgroundUiWork is
# stubbed out (plain function redefinition, resolved at call time - not a .NET event
# closure) because the real one would reach Initialize-BackgroundUiPollTimer, which
# needs System.Windows.Forms.Timer - unavailable on Linux pwsh. ---
function New-MockCellCollection {{
    $cells = @{{}}
    foreach ($col in @("Enabled","Name","Host","OsType","User","VdbenchPath","SshAlias","Targets","Readiness","CheckedAt","PingStatus","PingAt","Notes")) {{
        $cells[$col] = [pscustomobject]@{{ Value = "" }}
    }}
    return $cells
}}
function New-MockSlaveRow {{
    param([string]$SlaveName, [string]$HostName)
    $row = [pscustomobject]@{{ Tag = $null; IsNewRow = $false; Index = 0; Cells = (New-MockCellCollection) }}
    $row.Cells["Name"].Value = $SlaveName
    $row.Cells["Host"].Value = $HostName
    $row.Cells["Enabled"].Value = $false
    $row.Cells["OsType"].Value = "Windows"
    return $row
}}

$script:StartBackgroundUiWorkCalls = New-Object 'System.Collections.Generic.List[string]'
function Start-BackgroundUiWork {{
    param($Owner, [scriptblock]$OnComplete, [hashtable]$Context = @{{}}, [scriptblock]$Work = $null, [string]$CommandName = "")
    $script:StartBackgroundUiWorkCalls.Add($CommandName)
}}
function Get-BackgroundUiWorkCallCount {{
    param([string]$CommandName)
    return @($script:StartBackgroundUiWorkCalls | Where-Object {{ $_ -eq $CommandName }}).Count
}}

function New-MockSlaveGrid {{
    param([object[]]$Rows)
    $grid = [pscustomobject]@{{ Rows = $Rows }}
    # Update-SlaveRowReadiness calls $script:SlaveGrid.InvalidateRow(...) to repaint
    # after a status change; give the mock grid a harmless no-op so it can be called
    # without a real DataGridView.
    $grid | Add-Member -MemberType ScriptMethod -Name InvalidateRow -Value {{ param($RowIndex) }}
    return $grid
}}

$readyRow = New-MockSlaveRow "slave-1" "10.50.11.183"
$script:SlaveGrid = New-MockSlaveGrid @($readyRow)
Test-Step "Start-SlaveReadinessCheck (1st click)" {{ Start-SlaveReadinessCheck -Row $readyRow -ShowOutput:$false }}
$readinessCountAfterFirst = Get-BackgroundUiWorkCallCount "Invoke-SlaveReadinessBackgroundWork"
Test-Step "Start-SlaveReadinessCheck (2nd click while Checking...)" {{ Start-SlaveReadinessCheck -Row $readyRow -ShowOutput:$false }}
$readinessCountAfterSecond = Get-BackgroundUiWorkCallCount "Invoke-SlaveReadinessBackgroundWork"

$pingRow = New-MockSlaveRow "slave-2" "10.50.11.184"
$script:SlaveGrid = New-MockSlaveGrid @($pingRow)
Test-Step "Start-SlavePingCheck (1st click)" {{ Start-SlavePingCheck -Row $pingRow }}
$pingCountAfterFirst = Get-BackgroundUiWorkCallCount "Invoke-SlavePingBackgroundWork"
Test-Step "Start-SlavePingCheck (2nd click while Pinging...)" {{ Start-SlavePingCheck -Row $pingRow }}
$pingCountAfterSecond = Get-BackgroundUiWorkCallCount "Invoke-SlavePingBackgroundWork"

if ($errors.Count -gt 0) {{
    foreach ($e in $errors) {{ Write-Host "STEP FAILED: $e" }}
    exit 1
}}

$results = [pscustomobject]@{{
    OkStatus = $okResult.Status
    OkAlreadyShown = [bool]$okResult.AlreadyShown
    OkOutput = $okResult.Output
    OkMarkerNextToChecker = (Test-Path (Join-Path "{checker_dir}" "relative-output/marker.txt"))
    ReadinessCountAfterFirst = $readinessCountAfterFirst
    ReadinessCountAfterSecond = $readinessCountAfterSecond
    PingCountAfterFirst = $pingCountAfterFirst
    PingCountAfterSecond = $pingCountAfterSecond
    ReadyRowStatus = [string]$readyRow.Cells["Readiness"].Value
    PingRowStatus = [string]$pingRow.Cells["PingStatus"].Value
}}
# Write results to a dedicated file rather than stdout: with ShowCheckerWindow=$true
# and UseShellExecute=$true, the checker's own Write-Host output is NOT redirected
# (by design - that is the whole point of the separate-window path) and on Linux
# (no real console/window subsystem) it is inherited straight onto this harness's
# own stdout, interleaving with - and corrupting - any JSON printed there.
$results | ConvertTo-Json | Set-Content -LiteralPath "{results_path}" -Encoding UTF8
""".format(
                app_root=str(ROOT),
                data_dir=str(data_dir).replace("\\", "/"),
                module_root=str(MODULE_ROOT),
                ok_checker=str(ok_checker),
                checker_dir=str(checker_dir),
                results_path=str(tmp_path / "results.json"),
            ),
            encoding="utf-8",
        )

        env = dict(os.environ)
        env["PATH"] = str(shim_dir) + ":" + env.get("PATH", "")
        # stdin=DEVNULL: the real success path never blocks on input, but this keeps
        # the harness safe against ever accidentally reaching a Read-Host prompt (e.g.
        # in the wrapper's failure branch) instead of hanging indefinitely.
        result = subprocess.run(
            [pwsh, "-NoProfile", "-File", str(harness_script)],
            capture_output=True, text=True, cwd=str(checker_dir), env=env,
            stdin=subprocess.DEVNULL, timeout=60,
        )
        if result.returncode != 0:
            print(result.stdout.strip())
            print(result.stderr.strip())
            raise AssertionError("Readiness window/guard regression harness itself failed to run")

        results_path = tmp_path / "results.json"
        try:
            parsed = json.loads(results_path.read_text(encoding="utf-8")) if results_path.is_file() else {}
        except json.JSONDecodeError:
            print(result.stdout.strip())
            print(result.stderr.strip())
            raise AssertionError("Could not parse readiness window/guard harness output as JSON")

        assert parsed.get("OkStatus") == "Ready", (
            f"expected an exit-0 checker run with ShowCheckerWindow=$true to report "
            f"Ready, got status={parsed.get('OkStatus')!r}"
        )
        assert parsed.get("OkAlreadyShown") is True, (
            "the separate-window run must set AlreadyShown=$true so the caller skips a "
            "duplicate 'ran in a separate window' popup"
        )
        assert "separate PowerShell window" in str(parsed.get("OkOutput", "")), (
            f"unexpected confirmation message: {parsed.get('OkOutput')!r}"
        )
        assert parsed.get("OkMarkerNextToChecker"), (
            "switching to UseShellExecute=$true must not break the WorkingDirectory fix "
            "- the checker's own relative-path output should still land next to it"
        )
        assert parsed.get("ReadinessCountAfterFirst") == 1, (
            f"the first Readiness click must start exactly one background job, got "
            f"{parsed.get('ReadinessCountAfterFirst')!r}"
        )
        assert parsed.get("ReadinessCountAfterSecond") == 1, (
            f"clicking Readiness again while the row still reads 'Checking...' must be "
            f"ignored, got count={parsed.get('ReadinessCountAfterSecond')!r} (expected "
            f"still 1)"
        )
        assert parsed.get("ReadyRowStatus") == "Checking...", (
            f"expected the row to still read Checking..., got {parsed.get('ReadyRowStatus')!r}"
        )
        assert parsed.get("PingCountAfterFirst") == 1, (
            f"the first Ping click must start exactly one background job, got "
            f"{parsed.get('PingCountAfterFirst')!r}"
        )
        assert parsed.get("PingCountAfterSecond") == 1, (
            f"clicking Ping again while the row still reads 'Pinging...' must be "
            f"ignored, got count={parsed.get('PingCountAfterSecond')!r} (expected still 1)"
        )
        assert parsed.get("PingRowStatus") == "Pinging...", (
            f"expected the row to still read Pinging..., got {parsed.get('PingRowStatus')!r}"
        )
        print(
            "readiness window/guard regression check: UseShellExecute=$true verified end-to-end, "
            "AlreadyShown suppresses the duplicate popup, repeat-click guard verified for "
            "Readiness + Ping"
        )


def main() -> int:
    settings = load_json(SETTINGS_PATH)
    catalog = load_json(CATALOG_PATH)

    validate_catalog(catalog)
    validate_modules()
    validate_no_array_wrap_property_access()
    validate_golden_fixtures()
    powershell_checks_ran = run_powershell_checks()

    missing_settings = REQUIRED_SETTINGS - set(settings)
    assert not missing_settings, f"missing default settings: {sorted(missing_settings)}"
    assert "-STA" in LAUNCHER_PATH.read_text(encoding="utf-8"), "launcher must use -STA"
    assert (ROOT / ".gitignore").is_file(), ".gitignore must exist"

    ui_source = (ROOT / "src" / "VdbenchUI.ps1").read_text(encoding="utf-8")
    assert "Import-AppModules" in ui_source
    assert "src/modules" in ui_source or "modules" in ui_source
    assert "$this" not in ui_source, "event handlers should use sender arguments, not $this"
    assert "[switch]$SelfTest" in ui_source

    config_module = (MODULE_ROOT / "ConfigGeneration.ps1").read_text(encoding="utf-8")
    assert "function Build-VdbenchConfig" in config_module
    assert "function Add-ParameterValidationWarnings" in config_module
    assert "function Get-CleanConfigText" in config_module
    assert "function Show-ConfigPreviewConfirmation" in config_module
    assert "function Update-RunModeIndicator" in config_module

    runner_module = (MODULE_ROOT / "Runner.ps1").read_text(encoding="utf-8")
    assert "function Stop-ProcessTree" in (MODULE_ROOT / "ProcessRunner.ps1").read_text(encoding="utf-8")
    assert "Stop-ProcessTree -Process" in runner_module
    assert "capturedRunId" in runner_module
    assert "Config warnings" not in runner_module
    assert "Risk confirmation" not in runner_module

    metrics_module = (MODULE_ROOT / "Metrics.ps1").read_text(encoding="utf-8")
    assert "function Get-MetricDataLine" in metrics_module
    assert "Test-MetricHeaderLine" in metrics_module

    ui_tabs_module = (MODULE_ROOT / "UiTabs.ps1").read_text(encoding="utf-8")
    assert 'Key = "InstallRoot"; Label = "Install root"; Browse = "none"' in ui_tabs_module
    assert 'Key = "ManagerRoot"; Label = "Manager root"; Browse = "none"' in ui_tabs_module
    ui_slave_module = (MODULE_ROOT / "UiSlaveGrid.ps1").read_text(encoding="utf-8")
    assert "function Build-MasterSlaveTab" in ui_slave_module
    assert "function Browse-SlaveTargetsForRow" in ui_slave_module
    assert "function Start-SlaveReadinessCheck" in ui_slave_module
    assert "function Show-AddSlaveDialog" in ui_slave_module
    assert "function Reset-SlaveRowReadiness" in ui_slave_module
    assert "Schedule-SlaveReadinessCheck" not in ui_slave_module
    assert "SlaveReadinessTimerRows" not in ui_slave_module
    assert "Readiness runs automatically" not in ui_slave_module
    assert "function Invoke-SlavePingBackgroundWork" in ui_slave_module
    assert "function Invoke-SlaveReadinessBackgroundWork" in ui_slave_module
    assert '@{ Name = "ReadinessRun"; Text = "Readiness" }' in ui_slave_module
    assert "$timer.Tag" not in ui_slave_module
    assert "capturedIndex" not in ui_slave_module
    assert 'New-Button "Test ping"' not in ui_slave_module
    assert 'New-Button "Pick target"' not in ui_slave_module
    assert "function Set-SelectedSlavePrivateKey" not in ui_tabs_module
    assert "No log available for selected run." in ui_tabs_module
    assert "No config available for selected run." in ui_tabs_module
    assert "$layout.Controls.Add($tabs, 0, 1)" in ui_tabs_module
    assert '"User", "VdbenchPath"' in ui_slave_module
    assert '"SlaveUser"' not in ui_tabs_module

    assert "function Test-SlaveReadinessReady" in (MODULE_ROOT / "State.ps1").read_text(encoding="utf-8")
    assert "Get-DefaultSshAliasForSlave" in (MODULE_ROOT / "State.ps1").read_text(encoding="utf-8")
    assert "AllowUserToAddRows = $false" in ui_tabs_module
    assert "function Build-LocalHostTab" in ui_tabs_module
    assert "function Update-RunModeTabs" in ui_tabs_module
    assert "$script:RunModeCombo" in ui_tabs_module
    assert 'New-Button "New raw"' not in ui_tabs_module
    assert '$script:ProfileSelector' not in ui_tabs_module
    assert "Refresh-ProfileList" not in ui_tabs_module
    assert "Duplicate-RunProfile" in (MODULE_ROOT / "State.ps1").read_text(encoding="utf-8")
    assert "function Preview-DraftProfile" in ui_tabs_module
    assert "function Get-ProfileEditorContext" in (MODULE_ROOT / "State.ps1").read_text(encoding="utf-8")
    assert "function Write-DebugLog" in (MODULE_ROOT / "Core.ps1").read_text(encoding="utf-8")
    assert "function Notify-ProfileTargetContextChanged" in (MODULE_ROOT / "State.ps1").read_text(encoding="utf-8")
    assert "ProfileEditorBanner" in ui_tabs_module
    assert "LogLevel" in settings
    assert "ProfileKindCombo" not in ui_tabs_module
    assert "function Refresh-RunTabSummary" in config_module
    assert "function Resolve-RunTestKind" in config_module
    assert "localhost.json" in (ROOT / "src" / "VdbenchUI.ps1").read_text(encoding="utf-8")
    assert "function Get-LocalHostTargetStore" in (MODULE_ROOT / "State.ps1").read_text(encoding="utf-8")
    assert "Pick-TargetForCurrentProfile" not in ui_tabs_module
    assert 'New-Button "Pick target" 760' not in ui_tabs_module
    assert '@("storage.lun", "fsd.anchor")' in ui_tabs_module
    assert "DrawMode = [System.Windows.Forms.TabDrawMode]::OwnerDrawFixed" in ui_tabs_module
    assert "GetTabRect" in ui_tabs_module
    assert "TextRenderer]::DrawText" in ui_tabs_module
    assert "tabs.Add_SelectedIndexChanged({\n        param($sender, $eventArgs)" in ui_tabs_module.replace("\r\n", "\n")
    assert "function New-FlowToolbar" in (MODULE_ROOT / "UiHelpers.ps1").read_text(encoding="utf-8")
    assert "function Get-CachedTargetInventory" in (MODULE_ROOT / "TargetDiscovery.ps1").read_text(encoding="utf-8")
    assert "function Invoke-GridBatchUpdate" in (MODULE_ROOT / "UiHelpers.ps1").read_text(encoding="utf-8")
    ui_helpers_module = (MODULE_ROOT / "UiHelpers.ps1").read_text(encoding="utf-8")
    assert "function Start-BackgroundUiWork" in ui_helpers_module
    assert "function Initialize-BackgroundRunspace" in ui_helpers_module
    assert "BackgroundUiWorkerJobs" not in ui_helpers_module
    assert "BackgroundUiCompletionQueue" not in ui_helpers_module
    assert "$script:BackgroundRunspacePool" in ui_helpers_module
    assert "CreateRunspacePool" in ui_helpers_module
    assert "StartupScripts" in ui_helpers_module
    assert "$script:BackgroundUiJobs" in ui_helpers_module
    assert "function Initialize-BackgroundUiPollTimer" in ui_helpers_module
    assert "InnerException" in ui_helpers_module
    assert "BackgroundWorker" not in ui_helpers_module
    assert "$ps.BeginInvoke()" in ui_helpers_module
    assert "CommandName" in ui_helpers_module

    assert "function Get-ReadinessCheckerWrapperCommand" in ui_slave_module
    assert "$psi.WorkingDirectory = $checkerDir" in ui_slave_module
    assert "Split-Path -Parent $Checker" in ui_slave_module
    assert "Press Enter to close this window" in ui_slave_module

    # UseShellExecute=$true is required to guarantee the checker opens a genuinely new,
    # separate console window instead of silently sharing the UI's own (see
    # Get-SlaveReadinessResult / AGENTS.md for the full CreateNoWindow gotcha writeup).
    # Guard against regressing back to the old UseShellExecute=$false + CreateNoWindow=
    # $false combination, which does NOT open a new window at all.
    assert "$psi.UseShellExecute = $true" in ui_slave_module, (
        "Get-SlaveReadinessResult must launch the checker window with UseShellExecute="
        "$true - UseShellExecute=$false does not create a new console, it silently "
        "shares whatever console (if any) the UI's own process is attached to"
    )
    assert "AlreadyShown = $true" in ui_slave_module and "AlreadyShown = $false" in ui_slave_module, (
        "Get-SlaveReadinessResult must mark separate-window results AlreadyShown=$true "
        "so the caller does not pop a duplicate confirmation dialog"
    )
    assert 'Get-PropertyValue $Result "AlreadyShown" $false' in ui_slave_module
    assert 'Row.Cells["Readiness"].Value -eq "Checking..."' in ui_slave_module, (
        "Start-SlaveReadinessCheck must ignore repeat clicks while a check for that row "
        "is already in flight, or repeated clicking piles up one background job + one "
        "popup per click"
    )
    assert 'Row.Cells["PingStatus"].Value -eq "Pinging..."' in ui_slave_module, (
        "Start-SlavePingCheck must ignore repeat clicks while a ping for that row is "
        "already in flight"
    )

    state_module_full = (MODULE_ROOT / "State.ps1").read_text(encoding="utf-8")
    assert "function Migrate-LegacySettings" in state_module_full
    assert "Migrate-LegacySettings $script:Settings" in state_module_full
    # The old default broke any checker script using [CmdletBinding()] (PowerShell
    # throws "A parameter cannot be found..." for unknown named params). Both the
    # shipped default AND the migration for already-initialized settings.json
    # files must agree on the same legacy value being replaced with "".
    legacy_readiness_args = "-HostName {Host} -VdbenchPath {VdbenchPath} -Target {Target}"
    assert legacy_readiness_args in state_module_full
    assert settings.get("ReadinessCheckerArguments") == "", (
        "default-settings.json should ship an empty ReadinessCheckerArguments: "
        "most checker scripts check every configured host in one run and take "
        "no arguments, and scripts using [CmdletBinding()] hard-error on any "
        "unrecognized named parameter"
    )
    assert "readyRowIndex" not in ui_slave_module
    assert "pingRowIndex" not in ui_slave_module
    assert "-Context $readyContext" in ui_slave_module
    assert 'CommandName "Invoke-SlaveReadinessBackgroundWork"' in ui_slave_module
    assert 'CommandName "Invoke-SlavePingBackgroundWork"' in ui_slave_module
    assert "param($Result, $ErrorMessage, $Context)" in ui_slave_module
    assert "$WorkError.Exception.Message" not in ui_slave_module
    assert "$timer.Tag" not in ui_slave_module
    assert "function Initialize-DpiAwareness" in (MODULE_ROOT / "Core.ps1").read_text(encoding="utf-8")
    assert 'New-MainTabPage "Config Preview" "Preview"' in ui_tabs_module
    assert "$script:UiRefreshTimer.Interval = 500" in ui_tabs_module
    assert "SlaveUser" not in settings
    assert "BLOCKER: enabled slave" in config_module
    assert "Initialize-TestFilesForRun" in runner_module

    self_test_module = (MODULE_ROOT / "SelfTest.ps1").read_text(encoding="utf-8")
    assert "Use-SelfTestPaths" in self_test_module
    assert "distributed filesystem definition" in self_test_module

    fake_runner = FAKE_RUNNER_PATH.read_text(encoding="utf-8")
    assert "Fake Vdbench runner" in fake_runner
    assert "HH:mm:ss.fff" in fake_runner
    assert "Fake Vdbench completed successfully" in fake_runner

    package_script = PACKAGE_SCRIPT_PATH.read_text(encoding="utf-8")
    assert "Compress-Archive -Path" in package_script
    assert "src" in package_script

    smoke_script = SMOKE_SCRIPT_PATH.read_text(encoding="utf-8")
    assert "Fake Vdbench completed successfully" in smoke_script

    verify_script = VERIFY_SCRIPT_PATH.read_text(encoding="utf-8")
    assert "Portable verification complete" in verify_script
    validate_project_script = (ROOT / "tools" / "Validate-Project.ps1").read_text(encoding="utf-8")
    assert '"UiSlaveGrid.ps1"' in validate_project_script

    raw = default_profile(catalog, "Offline-Raw", "Raw/block")
    raw_local_targets = [{"Kind": "Test file", "Target": "C:\\vdbench\\testfile.dat", "Selected": True}]
    raw["Parameters"]["storage.dedupratio"]["Enabled"] = False
    raw["Parameters"]["storage.dedupratio"]["Value"] = "2"
    raw_config = render_config(catalog, settings, raw, local_targets=raw_local_targets, test_kind="Raw/block")
    assert GOLDEN_FIXTURES["raw-local.txt"] in raw_config
    assert "wd=wd1,sd=sd1" in raw_config
    assert "xfersize=4k" in raw_config
    assert "rdpct=70" in raw_config
    assert "seekpct=100" in raw_config
    assert "rd=rd1,wd=wd1" in raw_config
    assert "elapsed=300" in raw_config
    assert "warmup=30" in raw_config
    assert "interval=1" in raw_config
    assert "iorate=max" in raw_config
    assert "* disabled: dedupratio=2" in raw_config

    slave_config = render_config(
        catalog,
        settings,
        raw,
        [
            {
                "Name": "test-001",
                "Host": "10.0.0.11",
                "SshAlias": "test-001",
                "User": "linuxuser",
                "VdbenchPath": "/opt/vdbench",
                "Targets": [{"Kind": "Raw disk", "Target": "/dev/sdb", "Selected": True}],
            }
        ],
    )
    assert "hd=default,shell=ssh" in slave_config
    assert "hd=test-001,system=test-001,user=linuxuser,vdbench=/opt/vdbench" in slave_config
    assert "sd=sd_test_001_1,host=test-001,lun=/dev/sdb" in slave_config
    assert "wd=wd1,sd=sd*" in slave_config

    fs = default_profile(catalog, "Offline-FS", "Filesystem")
    fs_local_targets = [{"Kind": "Filesystem", "Target": "C:\\vdbench\\fs_test", "Selected": True}]
    fs_config = render_config(catalog, settings, fs, local_targets=fs_local_targets, test_kind="Filesystem")
    assert GOLDEN_FIXTURES["fs-local.txt"] in fs_config
    assert "fwd=fwd1,fsd=fsd1" in fs_config
    assert "operation=read" in fs_config
    assert "rd=rd1,fwd=fwd1" in fs_config
    assert "elapsed=300" in fs_config
    assert "warmup=30" in fs_config
    assert "interval=1" in fs_config
    assert "fwdrate=max" in fs_config
    assert "format=no" in fs_config

    fs_distributed = render_config(
        catalog,
        settings,
        fs,
        [
            {
                "Name": "test-002",
                "Host": "10.0.0.12",
                "SshAlias": "test-002",
                "VdbenchPath": "/opt/vdbench",
                "Targets": [{"Kind": "Filesystem", "Target": "/mnt/test", "Selected": True}],
            }
        ],
    )
    assert "fsd=fsd_test_002_1,host=test-002,anchor=/mnt/test" in fs_distributed
    assert "fwd=fwd1,fsd=fsd*" in fs_distributed

    print("offline validation ok")
    print(f"catalog parameters: {len(catalog)}")
    print(f"modules: {len(REQUIRED_MODULES)}")
    print("sample configs: raw local, raw distributed, filesystem local, filesystem distributed")
    print(f"real PowerShell syntax + self-test checks: {'ran' if powershell_checks_ran else 'skipped (pwsh not installed)'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
