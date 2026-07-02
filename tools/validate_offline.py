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
    _run_readiness_wrapper_pause_regression_check(pwsh)
    _run_get_property_value_endinvoke_regression_check(pwsh)
    _run_remote_ssh_quoting_regression_check(pwsh)
    _run_ssh_user_regression_check(pwsh)
    _run_auto_target_selection_regression_check(pwsh)
    _run_ssh_alias_default_regression_check(pwsh)
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
    """Reproduce the real Readiness-check bugs end-to-end and prove the fixes.

    Root cause v1 (found by actually installing pwsh and running the code,
    2026-07-01): the originally-shipped ReadinessCheckerArguments default
    ("-HostName {Host} -VdbenchPath {VdbenchPath} -Target {Target}") throws
    "A parameter cannot be found that matches parameter name 'HostName'."
    against the real checker script, which uses [CmdletBinding()] and does
    not declare those parameters at all.

    Root cause v2 (found later the same day, from the user manually running
    the real checker script and reporting back its actual parameters): the
    checker was fixed to take an empty args template ("most checker scripts
    take no arguments"), but that was wrong for THIS checker - it genuinely
    needs -WindowsHosts/-LinuxHosts (chosen by the row's OS) to know which
    remote host to check over SSH. With no host argument at all, it silently
    only checked the Master's own local prerequisites and never validated
    the specific slave a user clicked Readiness for. Confirmed real syntax:
        ...04-Check-Vdbench-Hosts-Readiness.ps1 -WindowsHosts 10.50.11.xxx
        ...04-Check-Vdbench-Hosts-Readiness.ps1 -LinuxHosts 10.50.11.xxx

    This regression check builds a fake checker that actually declares
    -WindowsHosts/-LinuxHosts (matching the real one), calls the real
    Get-SlaveReadinessResult with the v1 legacy template (must still fail
    the same way), the current {HostFlag} default against a Windows-OS row
    (must expand to -WindowsHosts and succeed), and again against a
    Linux-OS row (must expand to -LinuxHosts and succeed) - plus verifies
    the checker's own working directory is set deterministically (its own
    folder) rather than inherited from whatever launched the UI, and drives
    the full v1->v2->v3 Migrate-LegacySettings chain plus its new
    checker-path safety guard.
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
            "param(\n"
            "    [string[]]$WindowsHosts = @(),\n"
            "    [string[]]$LinuxHosts = @()\n"
            ")\n"
            "Write-Host 'Checking Master readiness'\n"
            "Write-Host '[OK]  MASTER  fake host check'\n"
            "foreach ($h in $WindowsHosts) { Write-Host \"[OK]  WINDOWS-SLAVE  $h  fake host check\" }\n"
            "foreach ($h in $LinuxHosts) { Write-Host \"[OK]  LINUX-SLAVE  $h  fake host check\" }\n"
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

$legacy = Get-SlaveReadinessResult "10.0.0.1" "C:\\vdbench" "C:\\vdbench\\test" "{checker_path}" "-HostName {{Host}} -VdbenchPath {{VdbenchPath}} -Target {{Target}}" $false "Windows"
$currentWindows = Get-SlaveReadinessResult "10.0.0.1" "C:\\vdbench" "C:\\vdbench\\test" "{checker_path}" "{{HostFlag}}" $false "Windows"
$currentLinux = Get-SlaveReadinessResult "10.0.0.2" "/opt/vdbench" "/dev/sdb" "{checker_path}" "{{HostFlag}}" $false "Linux"

# A machine that already ran an earlier version has data/settings.json seeded
# with an old default forever, since Merge-DefaultProperties only ever ADDS
# missing keys. Prove Migrate-LegacySettings actually fast-forwards all the
# way from the v1 named-params default through empty to the current
# {{HostFlag}} default, that a bare v2 (empty) default also advances to
# {{HostFlag}} on its own, that the same empty default is LEFT ALONE when
# ReadinessChecker points at a different (non-stock) script, and that a
# deliberately customized non-empty value is always left alone regardless of
# which checker script is configured.
$stockChecker = "C:\\install\\04-Check-Vdbench-Hosts-Readiness.ps1"
$v1Settings = [pscustomobject]@{{ ReadinessCheckerArguments = "-HostName {{Host}} -VdbenchPath {{VdbenchPath}} -Target {{Target}}"; ReadinessChecker = $stockChecker }}
$migratedV1 = Migrate-LegacySettings $v1Settings
$v2StockSettings = [pscustomobject]@{{ ReadinessCheckerArguments = ""; ReadinessChecker = $stockChecker }}
$migratedV2Stock = Migrate-LegacySettings $v2StockSettings
$v2CustomCheckerSettings = [pscustomobject]@{{ ReadinessCheckerArguments = ""; ReadinessChecker = "C:\\install\\SomeOtherChecker.ps1" }}
$migratedV2CustomChecker = Migrate-LegacySettings $v2CustomCheckerSettings
$customSettings = [pscustomobject]@{{ ReadinessCheckerArguments = "-MyCustomFlag foo"; ReadinessChecker = $stockChecker }}
$migratedCustom = Migrate-LegacySettings $customSettings

$results = [pscustomobject]@{{
    LegacyStatus = $legacy.Status
    LegacyOutput = $legacy.Output
    CurrentWindowsStatus = $currentWindows.Status
    CurrentLinuxStatus = $currentLinux.Status
    MarkerNextToChecker = (Test-Path (Join-Path "{checker_dir}" "relative-output/marker.txt"))
    MarkerInWrongDir = (Test-Path (Join-Path "{wrong_launch_dir}" "relative-output"))
    MigratedV1Changed = [bool]$migratedV1
    MigratedV1Value = $v1Settings.ReadinessCheckerArguments
    MigratedV2StockChanged = [bool]$migratedV2Stock
    MigratedV2StockValue = $v2StockSettings.ReadinessCheckerArguments
    MigratedV2CustomCheckerChanged = [bool]$migratedV2CustomChecker
    MigratedV2CustomCheckerValue = $v2CustomCheckerSettings.ReadinessCheckerArguments
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
            f"expected legacy (v1) ReadinessCheckerArguments default to fail against a "
            f"[CmdletBinding()] checker that does not declare -HostName, got "
            f"status={parsed.get('LegacyStatus')!r}"
        )
        assert "parameter cannot be found" in str(parsed.get("LegacyOutput", "")), (
            f"expected the exact PowerShell parameter-binding error, got: {parsed.get('LegacyOutput')!r}"
        )
        assert parsed.get("CurrentWindowsStatus") == "Ready", (
            f"expected {{HostFlag}} to expand to -WindowsHosts for a Windows-OS row and "
            f"succeed against the real checker contract, got status="
            f"{parsed.get('CurrentWindowsStatus')!r}"
        )
        assert parsed.get("CurrentLinuxStatus") == "Ready", (
            f"expected {{HostFlag}} to expand to -LinuxHosts for a Linux-OS row and "
            f"succeed against the real checker contract, got status="
            f"{parsed.get('CurrentLinuxStatus')!r}"
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
        assert parsed.get("MigratedV1Changed") and parsed.get("MigratedV1Value") == "{HostFlag}", (
            f"Migrate-LegacySettings should fast-forward the v1 named-params default all "
            f"the way to the current {{HostFlag}} default in one call, got "
            f"changed={parsed.get('MigratedV1Changed')!r} value={parsed.get('MigratedV1Value')!r}"
        )
        assert parsed.get("MigratedV2StockChanged") and parsed.get("MigratedV2StockValue") == "{HostFlag}", (
            f"Migrate-LegacySettings should advance a bare empty (v2) default to "
            f"{{HostFlag}} when ReadinessChecker still points at the stock script, got "
            f"changed={parsed.get('MigratedV2StockChanged')!r} value={parsed.get('MigratedV2StockValue')!r}"
        )
        assert not parsed.get("MigratedV2CustomCheckerChanged") and parsed.get("MigratedV2CustomCheckerValue") == "", (
            f"Migrate-LegacySettings must NOT touch an empty template when "
            f"ReadinessChecker points at a non-stock script (that script may "
            f"genuinely take no arguments), got "
            f"changed={parsed.get('MigratedV2CustomCheckerChanged')!r} "
            f"value={parsed.get('MigratedV2CustomCheckerValue')!r}"
        )
        assert not parsed.get("MigratedCustomChanged") and parsed.get("MigratedCustomValue") == "-MyCustomFlag foo", (
            f"Migrate-LegacySettings must not touch a deliberately customized value, "
            f"got changed={parsed.get('MigratedCustomChanged')!r} value={parsed.get('MigratedCustomValue')!r}"
        )
        print("readiness regression check: v1 legacy template still fails as expected, {HostFlag} resolves to -WindowsHosts/-LinuxHosts by OS, full migration chain + checker-path safety guard verified")


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

    Root cause #2 (same screenshot, and reconfirmed 2026-07-01 later the same day from a
    second, near-identical screenshot - a wall of ~20 stacked "Readiness output" dialogs
    all reading "exit code 0"): every completed Readiness check run with -ShowOutput
    popped its own "ran in a separate PowerShell window" confirmation dialog even though
    the user had just watched the real output live in that window; clicking Readiness
    repeatedly (the natural reaction when nothing visibly happens right away) queued one
    background job - and one such popup - per click, and they all piled up once
    finished. The first attempt at a fix added an AlreadyShown flag so the caller could
    conditionally skip that popup for the separate-window path - but since ShowOutput and
    ShowCheckerWindow are always the same value (see Start-SlaveReadinessCheck), that
    popup is ALWAYS skippable whenever it would fire, making the flag pure dead weight.
    Final fix: removed the "Ready"/"Failed" app-level popup unconditionally instead of
    conditionally, and removed the now-provably-unused AlreadyShown field entirely rather
    than leave dead code that looks load-bearing but is not.

    Root cause #3 (found from the SAME second screenshot, alongside #2): the checker
    window was also closing itself immediately/automatically right after the check
    finished, even though the report inside it showed a [FAIL] line (Master vdbench.bat
    exists) - the user never got a chance to read it. Get-ReadinessCheckerWrapperCommand
    only paused for Enter when the WRAPPER's own $exitCode was non-zero. But the shipped
    checker script exits 0 unconditionally regardless of whether its own internal
    [OK]/[FAIL] checks passed - exit code 0 means "the script ran to completion", not
    "every check inside it passed" - so a run with one or more failing internal checks
    still hit the old code's auto-close path. Fix: Get-ReadinessCheckerWrapperCommand now
    ALWAYS pauses for Enter before exiting, regardless of exit code.

    This check calls the real Get-SlaveReadinessResult end-to-end with
    ShowCheckerWindow=$true (proving UseShellExecute=$true does not hang/throw in this
    sandbox and still honors the WorkingDirectory fix from the check above), then calls
    the real Start-SlaveReadinessCheck/Start-SlavePingCheck twice in a row - against a
    stubbed Start-BackgroundUiWork, since the real one lazily creates a
    System.Windows.Forms.Timer that cannot be instantiated on Linux pwsh at all - to
    prove the in-flight guard stops the second click from starting another background
    job for either button. The "always pauses regardless of exit code" fix for root
    cause #3 is verified separately and more precisely in
    _run_readiness_wrapper_pause_regression_check below, by running the exact generated
    wrapper command text for both a success (exit 0) and a failure (exit 5) checker and
    asserting the pause prompt appears in both.
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
# throw on this Linux sandbox, and must still honor WorkingDirectory. ---
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
            "no app-level popup for Ready/Failed, repeat-click guard verified for "
            "Readiness + Ping"
        )


def _run_readiness_wrapper_pause_regression_check(pwsh: str) -> None:
    """Prove Get-ReadinessCheckerWrapperCommand ALWAYS pauses before closing.

    Root cause (found 2026-07-01 from a user screenshot: the checker window closed
    itself automatically right after finishing, even though its own report inside
    showed a [FAIL] line for "Master vdbench.bat exists" that the user never got a
    chance to read): the wrapper only paused for Enter when its own $exitCode was
    non-zero. The shipped checker script exits 0 unconditionally regardless of whether
    its internal [OK]/[FAIL] checks passed - exit code 0 means "the script ran to
    completion", not "every check inside it passed" - so a run with one or more failing
    internal checks (exactly the user's case) still hit the old auto-close path.

    This runs the EXACT generated wrapper command text directly through pwsh (bypassing
    Get-SlaveReadinessResult/Process.Start entirely, so this test is independent of and
    complementary to the UseShellExecute/window-sharing fix verified elsewhere) for both
    a checker that exits 0 and one that exits with a non-zero code, and asserts the
    "press Enter to close" prompt - and, crucially, the fact that the process only exits
    after that prompt is reached - shows up in BOTH cases. stdin=DEVNULL makes the
    inevitable Read-Host return immediately (confirmed empirically before writing this
    test - see AGENTS.md), so this cannot hang even though every run now reaches it.
    """
    import subprocess
    import tempfile

    with tempfile.TemporaryDirectory(prefix="vdbench-wrapper-pause-check-") as tmp_dir:
        tmp_path = Path(tmp_dir)

        def run_wrapper_for_exit_code(exit_code: int) -> subprocess.CompletedProcess:
            fake_checker = tmp_path / f"fake-checker-{exit_code}.ps1"
            fake_checker.write_text(
                "param()\n"
                f"Write-Host '[FAIL]  MASTER  fake failing check'\n"
                f"exit {exit_code}\n",
                encoding="utf-8",
            )
            get_wrapper_script = tmp_path / f"get-wrapper-{exit_code}.ps1"
            get_wrapper_script.write_text(
                """
$script:ModuleRoot = "{module_root}"
. (Join-Path $script:ModuleRoot "UiSlaveGrid.ps1")
$quotedChecker = '"{fake_checker}"'
Get-ReadinessCheckerWrapperCommand $quotedChecker ""
""".format(module_root=str(MODULE_ROOT), fake_checker=str(fake_checker)),
                encoding="utf-8",
            )
            wrapper_result = subprocess.run(
                [pwsh, "-NoProfile", "-File", str(get_wrapper_script)],
                capture_output=True, text=True, timeout=30,
            )
            if wrapper_result.returncode != 0:
                print(wrapper_result.stdout.strip())
                print(wrapper_result.stderr.strip())
                raise AssertionError("Get-ReadinessCheckerWrapperCommand itself failed to run")
            wrapper_text = wrapper_result.stdout

            wrapper_script_path = tmp_path / f"wrapper-{exit_code}.ps1"
            wrapper_script_path.write_text(wrapper_text, encoding="utf-8")
            return subprocess.run(
                [pwsh, "-NoProfile", "-File", str(wrapper_script_path)],
                capture_output=True, text=True,
                stdin=subprocess.DEVNULL, timeout=30,
            )

        success_run = run_wrapper_for_exit_code(0)
        assert success_run.returncode == 0, (
            f"expected the wrapper to exit 0 when the checker itself exits 0, got "
            f"{success_run.returncode}; stdout={success_run.stdout!r}"
        )
        assert "Readiness checker finished (exit code 0)." in success_run.stdout, (
            f"expected the exit-0 success message, got stdout={success_run.stdout!r}"
        )
        assert "press Enter to close this window" in success_run.stdout, (
            "the wrapper must prompt for Enter even when the checker exits 0 - "
            "otherwise a checker whose own internal [OK]/[FAIL] checks failed, but "
            "which itself still exits 0 (exactly the shipped checker's behavior), "
            "auto-closes the window before the user can read the failing check(s); "
            f"got stdout={success_run.stdout!r}"
        )

        failure_run = run_wrapper_for_exit_code(5)
        assert failure_run.returncode == 5, (
            f"expected the wrapper to propagate the checker's own non-zero exit code, "
            f"got {failure_run.returncode}; stdout={failure_run.stdout!r}"
        )
        assert "non-zero exit code (5)" in failure_run.stdout, (
            f"expected the non-zero exit message, got stdout={failure_run.stdout!r}"
        )
        assert "press Enter to close this window" in failure_run.stdout, (
            f"expected the pause prompt on failure too, got stdout={failure_run.stdout!r}"
        )
        print("readiness wrapper pause regression check: window pauses for Enter on both exit code 0 and non-zero, never auto-closes")


def _run_get_property_value_endinvoke_regression_check(pwsh: str) -> None:
    """Prove Get-PropertyValue correctly reads properties off a REAL EndInvoke() result.

    Root cause (found 2026-07-01 while investigating why a user's screenshot still
    showed a "Readiness output" popup wall even on code that should have suppressed it
    via an AlreadyShown flag checked through Get-PropertyValue): [powershell]::EndInvoke()
    wraps even a single output object in a PSDataCollection<PSObject> - confirmed
    empirically in this sandbox - not the raw object. Direct dot-notation property
    access ($Result.Status) transparently "reaches into" a collection with exactly one
    element (PowerShell's own member-access adapter does this), but Get-PropertyValue's
    own explicit `$Object.PSObject.Properties[$Name]` lookup does NOT get that same
    treatment: it queries the wrapper collection's own properties (which of course never
    has $Name), silently returning $DefaultValue every single time regardless of what the
    real value inside actually was. This meant ANY call of the shape
    `Get-PropertyValue $Result "SomeFlag" $false` against a Start-BackgroundUiWork/
    EndInvoke() OnComplete "$Result" always returned $false, no matter what was really
    set - which is exactly why the app's earlier AlreadyShown-based popup-suppression
    fix could never have worked through that real code path (a bug that predated, and
    was independent of, the specific AlreadyShown field itself - now removed entirely in
    favor of never showing that popup at all, see
    _run_readiness_window_regression_check). None of this project's other tests caught
    this because they either called Get-SlaveReadinessResult directly (bypassing
    EndInvoke() entirely) or stubbed out Start-BackgroundUiWork itself (also bypassing
    EndInvoke() entirely) - this is the only test that drives a REAL RunspacePool +
    BeginInvoke() + EndInvoke() and feeds its REAL return value into the REAL
    Get-PropertyValue, matching the actual production code path exactly.

    Fix: Get-PropertyValue now unwraps a same single-item, non-string, non-dictionary
    ICollection before doing its property lookup, matching what direct dot-notation
    access already does for that exact scenario - this protects every current and future
    caller uniformly, not just the one call site that surfaced the bug.
    """
    import subprocess
    import tempfile

    with tempfile.TemporaryDirectory(prefix="vdbench-getpropertyvalue-check-") as tmp_dir:
        harness_script = Path(tmp_dir) / "run-getpropertyvalue-check.ps1"
        harness_script.write_text(
            """
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
. (Join-Path "{module_root}" "Core.ps1")

$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$pool = [runspacefactory]::CreateRunspacePool(1, 2, $iss, $Host)
$pool.Open()
$ps = [powershell]::Create()
$ps.RunspacePool = $pool
[void]$ps.AddScript({{ [pscustomobject]@{{ Status = "Ready"; SomeFlag = $true }} }})
$async = $ps.BeginInvoke()
while (-not $async.IsCompleted) {{ Start-Sleep -Milliseconds 10 }}
$Result = $ps.EndInvoke($async)
$ps.Dispose()
$pool.Close()

$results = [pscustomobject]@{{
    ResultTypeName = $Result.GetType().Name
    ResultCount = $Result.Count
    DirectDotNotation = [bool]$Result.SomeFlag
    ViaGetPropertyValue = [bool](Get-PropertyValue $Result "SomeFlag" $false)
    MissingPropDefault = (Get-PropertyValue $Result "TotallyMissingProperty" "THE_DEFAULT")
}}
$results | ConvertTo-Json
""".format(module_root=str(MODULE_ROOT)),
            encoding="utf-8",
        )
        result = subprocess.run(
            [pwsh, "-NoProfile", "-File", str(harness_script)],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            print(result.stdout.strip())
            print(result.stderr.strip())
            raise AssertionError("Get-PropertyValue/EndInvoke regression harness itself failed to run")

        try:
            parsed = json.loads(result.stdout.strip()) if result.stdout.strip() else {}
        except json.JSONDecodeError:
            print(result.stdout.strip())
            raise AssertionError("Could not parse Get-PropertyValue/EndInvoke harness output as JSON")

        assert parsed.get("ResultTypeName") == "PSDataCollection`1" and parsed.get("ResultCount") == 1, (
            f"expected EndInvoke() to wrap the single output object in a 1-item "
            f"PSDataCollection`1 (confirming the premise of this test still holds for "
            f"this PowerShell version) - got type={parsed.get('ResultTypeName')!r} "
            f"count={parsed.get('ResultCount')!r}"
        )
        assert parsed.get("DirectDotNotation") is True, (
            "sanity check failed: direct dot-notation property access on the "
            "EndInvoke() result should transparently unwrap the 1-item collection"
        )
        assert parsed.get("ViaGetPropertyValue") is True, (
            "Get-PropertyValue must return the REAL property value when given a "
            "1-item EndInvoke() collection wrapper, not silently fall back to the "
            "default - this is exactly the bug that made an AlreadyShown-style "
            "flag check against a background job's $Result always read as false"
        )
        assert parsed.get("MissingPropDefault") == "THE_DEFAULT", (
            "Get-PropertyValue must still return the caller's default for a property "
            "that genuinely does not exist on the unwrapped object, and must not "
            "throw under Set-StrictMode -Version 2.0 while checking that"
        )
        print("Get-PropertyValue/EndInvoke regression check: property lookup against a real background-job result now matches direct dot-notation access")


def _run_remote_ssh_quoting_regression_check(pwsh: str) -> None:
    """Reproduce the "'ForEach-Object' is not recognized..." bug end-to-end and prove the fix.

    Root cause (found 2026-07-01, from a user screenshot showing exactly that error
    after clicking Browse on a Windows slave, with the SSH host-key warning visible
    right above it - confirming the SSH connection itself succeeded and the failure was
    in what got executed afterward): OpenSSH's client concatenates ALL "remote command"
    arguments together with a single space before sending them to the server (confirmed
    via Win32-OpenSSH GitHub issue #1082 and multiple other independent, authoritative
    sources - see docs/MASTER_SLAVE_MODEL.md and Get-RemoteExecCommandParts's docstring
    in Core.ps1 for the full writeup). This codebase built its remote commands as
    SEPARATE argv elements - "powershell.exe", "-NoProfile", "-Command", "<script>" (or
    "sh", "-lc", "<script>" for Linux) - each individually quoted only for THIS side's
    own local ssh.exe argv construction. That local quoting is consumed by ssh.exe's own
    argv parsing and never reapplied once ssh.exe rejoins the remaining pieces with
    plain spaces for the wire. On Windows, the joined, now-unquoted script text
    (containing PowerShell's own pipe operator `|`) then reaches an intermediate cmd.exe
    layer that Windows OpenSSH always interposes (confirmed via the same GitHub issue,
    even when the configured DefaultShell is something else) - cmd.exe interprets that
    bare pipe as ITS OWN operator and tries to launch a separate program literally named
    after whatever cmdlet follows it (ForEach-Object), which fails with exactly
    "'ForEach-Object' is not recognized as an internal or external command, operable
    program or batch file." The same underlying "outer quoting lost across the rejoin"
    problem affects the Linux path too, independently confirmed broken in this exact
    sandbox by literally running the old wire string through a real `sh -c` (see below) -
    dash raises a hard "Syntax error: \"do\" unexpected", since the intended "sh -lc"
    isolation never reaches the remote shell.

    Fix (Get-RemoteExecCommandParts in Core.ps1): for Windows, use `-EncodedCommand`
    (Base64 of the UTF-16LE script text) - the resulting command line contains zero
    shell-special characters in any shell dialect, so it survives any number of naive
    space-join/re-parse layers unmangled. For Linux, pass "sh -lc '<script>'" as ONE
    single, already-fully-formed string instead of three separate tokens, so ssh.exe's
    rejoin step becomes a no-op and the remote login shell's one, intentional re-parse of
    the whole "-c" argument sees the unmangled invocation exactly as written.

    This check builds an `ssh.exe` shim that simulates OpenSSH's own documented
    behavior (skip recognized option flags/values and exactly one hostname token, then
    rejoin all remaining "remote command" arguments with a single space) and runs the
    REAL Get-RemoteExecCommandParts (Core.ps1) through Invoke-CapturedProcess against it
    for both OS types, in both the old (broken) and new (fixed) argument-token shapes -
    proving: the old Windows shape genuinely loses its quoting and exposes a raw pipe;
    the new Windows shape round-trips its Base64 payload back to the exact original
    script; the old Linux shape, when actually executed via a real `sh -c` (exactly how
    a remote sshd hands the joined string to the login shell), fails with a real syntax
    error; and the new Linux shape, run the same way, succeeds and produces correct
    disk-listing output.
    """
    import os
    import subprocess
    import tempfile

    win_script = '$ErrorActionPreference="SilentlyContinue"; Get-CimInstance Win32_DiskDrive | ForEach-Object { "Raw disk|test" }'
    linux_script = 'for d in /sys/block/*; do name=${d##*/}; case "$name" in loop*|ram*) continue;; esac; echo "Raw disk|/dev/$name"; done'

    with tempfile.TemporaryDirectory(prefix="vdbench-ssh-quoting-check-") as tmp_dir:
        tmp_path = Path(tmp_dir)

        shim_dir = tmp_path / "shim"
        shim_dir.mkdir()
        ssh_shim = shim_dir / "ssh.exe"
        ssh_shim.write_text(
            "#!/bin/sh\n"
            "skip_next=0\n"
            "past_hostname=0\n"
            "remote_parts=\"\"\n"
            "for arg in \"$@\"; do\n"
            "    if [ \"$skip_next\" = \"1\" ]; then skip_next=0; continue; fi\n"
            "    if [ \"$past_hostname\" = \"0\" ]; then\n"
            "        case \"$arg\" in\n"
            "            -F|-i|-o) skip_next=1; continue;;\n"
            "            -*) continue;;\n"
            "            *) past_hostname=1; continue;;\n"
            "        esac\n"
            "    fi\n"
            "    if [ -z \"$remote_parts\" ]; then remote_parts=\"$arg\"; else remote_parts=\"$remote_parts $arg\"; fi\n"
            "done\n"
            "printf '%s' \"$remote_parts\"\n",
            encoding="utf-8",
        )
        ssh_shim.chmod(0o755)

        harness_script = tmp_path / "run-ssh-quoting-check.ps1"
        harness_script.write_text(
            """
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
. (Join-Path "{module_root}" "Core.ps1")

$winScript = @'
{win_script}
'@
$linuxScript = @'
{linux_script}
'@

function Build-WireString {{
    param([string]$OsType, [string]$RemoteScript, [switch]$UseOldBuggyPattern)
    $sshParts = New-Object System.Collections.Generic.List[string]
    [void]$sshParts.Add("-o")
    [void]$sshParts.Add("BatchMode=yes")
    [void]$sshParts.Add((Quote-ProcessArgument "some-host"))
    if ($UseOldBuggyPattern) {{
        if ($OsType -eq "Linux") {{
            [void]$sshParts.Add("sh")
            [void]$sshParts.Add("-lc")
            [void]$sshParts.Add((Quote-ProcessArgument $RemoteScript))
        }} else {{
            [void]$sshParts.Add("powershell.exe")
            [void]$sshParts.Add("-NoProfile")
            [void]$sshParts.Add("-Command")
            [void]$sshParts.Add((Quote-ProcessArgument $RemoteScript))
        }}
    }} else {{
        foreach ($token in @(Get-RemoteExecCommandParts -OsType $OsType -RemoteScript $RemoteScript)) {{
            [void]$sshParts.Add($token)
        }}
    }}
    $result = Invoke-CapturedProcess "ssh.exe" ($sshParts -join " ") 5000
    return $result.StdOut
}}

$oldWindowsWire = Build-WireString -OsType "Windows" -RemoteScript $winScript -UseOldBuggyPattern
$newWindowsWire = Build-WireString -OsType "Windows" -RemoteScript $winScript
$oldLinuxWire = Build-WireString -OsType "Linux" -RemoteScript $linuxScript -UseOldBuggyPattern
$newLinuxWire = Build-WireString -OsType "Linux" -RemoteScript $linuxScript

$newWindowsTokens = $newWindowsWire -split " "
$base64Token = $newWindowsTokens[-1]
$decodedWindowsScript = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($base64Token))

$results = [pscustomobject]@{{
    OldWindowsWire = $oldWindowsWire
    NewWindowsWire = $newWindowsWire
    DecodedWindowsScript = $decodedWindowsScript
    OldLinuxWire = $oldLinuxWire
    NewLinuxWire = $newLinuxWire
}}
$results | ConvertTo-Json | Set-Content -LiteralPath "{results_path}" -Encoding UTF8
""".format(
                module_root=str(MODULE_ROOT),
                win_script=win_script,
                linux_script=linux_script,
                results_path=str(tmp_path / "results.json"),
            ),
            encoding="utf-8",
        )

        env = dict(os.environ)
        env["PATH"] = str(shim_dir) + ":" + env.get("PATH", "")
        result = subprocess.run(
            [pwsh, "-NoProfile", "-File", str(harness_script)],
            capture_output=True, text=True, env=env, timeout=30,
        )
        if result.returncode != 0:
            print(result.stdout.strip())
            print(result.stderr.strip())
            raise AssertionError("SSH quoting regression harness itself failed to run")

        results_path = tmp_path / "results.json"
        try:
            parsed = json.loads(results_path.read_text(encoding="utf-8")) if results_path.is_file() else {}
        except json.JSONDecodeError:
            print(result.stdout.strip())
            raise AssertionError("Could not parse SSH quoting regression harness output as JSON")

        old_windows_wire = parsed.get("OldWindowsWire", "")
        new_windows_wire = parsed.get("NewWindowsWire", "")
        old_linux_wire = parsed.get("OldLinuxWire", "")
        new_linux_wire = parsed.get("NewLinuxWire", "")

        # Sanity-check the OLD pattern really is broken (so a regression back to it
        # would be caught): the OUTER quote that was meant to delimit the entire
        # -Command argument is gone once ssh.exe's rejoin runs (the script's own
        # internal double-quotes, e.g. around "SilentlyContinue", are expected and
        # harmless on their own - the bug is that nothing wraps the WHOLE argument
        # together anymore), exposing PowerShell's own pipe operator completely
        # unquoted to whatever naively re-parses the wire string next.
        assert not old_windows_wire.startswith('powershell.exe -NoProfile -Command "'), (
            f"sanity check failed: expected the OLD pattern's wire string to have lost "
            f"the outer quote wrapping the entire -Command argument once rejoined, "
            f"got: {old_windows_wire!r}"
        )
        assert "| ForEach-Object" in old_windows_wire, (
            "sanity check failed: expected the OLD pattern's wire string to expose a "
            "raw, unquoted pipe before ForEach-Object - this is exactly what makes an "
            "intermediate cmd.exe try to launch a program literally named "
            "ForEach-Object and fail with 'is not recognized as an internal or "
            "external command'"
        )

        assert new_windows_wire.startswith("powershell.exe -NoProfile -EncodedCommand "), (
            f"expected the new Windows wire string to be a plain -EncodedCommand "
            f"invocation, got: {new_windows_wire!r}"
        )
        assert "|" not in new_windows_wire and '"' not in new_windows_wire, (
            "the new Windows wire string must contain zero shell-special characters "
            "(no pipes, no quotes) so it is immune to being mangled by any number of "
            "naive re-parsing layers"
        )
        assert parsed.get("DecodedWindowsScript") == win_script, (
            f"the new Windows wire string's -EncodedCommand payload must decode back "
            f"to the exact original script; got: {parsed.get('DecodedWindowsScript')!r}"
        )

        # Sanity-check the OLD Linux pattern is genuinely broken too, by literally
        # running its wire string through a real `sh -c` - exactly how a remote sshd
        # hands the joined command string to the login shell.
        old_linux_run = subprocess.run(
            ["sh", "-c", old_linux_wire], capture_output=True, text=True, timeout=10,
        )
        assert old_linux_run.returncode != 0, (
            f"sanity check failed: expected the OLD Linux pattern's wire string to be "
            f"broken shell syntax once actually run through a real login shell's -c "
            f"(proving this is a genuine, reproducible bug, not just theoretical) - "
            f"wire={old_linux_wire!r}"
        )

        new_linux_run = subprocess.run(
            ["sh", "-c", new_linux_wire], capture_output=True, text=True, timeout=10,
        )
        assert new_linux_run.returncode == 0, (
            f"expected the new Linux pattern to run successfully via a real shell -c, "
            f"got exit code {new_linux_run.returncode}, stderr={new_linux_run.stderr!r}, "
            f"wire={new_linux_wire!r}"
        )
        assert "Raw disk|/dev/" in new_linux_run.stdout, (
            f"expected disk listing output containing 'Raw disk|/dev/', got: "
            f"{new_linux_run.stdout!r}"
        )
        print("SSH quoting regression check: old Windows/Linux patterns confirmed broken via real re-parsing, new -EncodedCommand/single-token patterns confirmed correct via real execution")


def _run_ssh_user_regression_check(pwsh: str) -> None:
    """Reproduce the "Administrator@linux-001: Permission denied" bug end-to-end.

    Root cause (found 2026-07-01, from a user screenshot: SSH host-key warning
    followed immediately by "Administrator@linux-001: Permission denied
    (publickey,gssapi-keyex,gssapi-with-mic,password)" for a Linux slave - proving the
    connection itself succeeded and the failure was purely an authentication/username
    problem): Get-RemoteSlaveTargetInventoryCore, New-HostFolderPath, and
    New-RemoteSshArguments each built their ssh.exe destination argument from ONLY the
    slave's SshAlias/Host, with no explicit username anywhere in the command line - so
    ssh.exe fell back to its own default of "whatever OS user is running this process"
    (the Windows account running the UI, e.g. "Administrator"), completely ignoring the
    per-slave User value this app already tracks (Get-DefaultSlaveUserForOs even
    defaults it to "root" for Linux specifically) and already correctly passes through
    as vdbench's own hd=...,user=... parameter for the actual distributed run (see
    ConfigGeneration.ps1) - just never for this app's OWN direct ssh.exe calls used for
    Browse/New folder/test-file prep. Windows slaves often still "worked" by
    coincidence (the configured "administrator" User default happening to match the
    account actually running the UI), which is exactly why this was reported for a
    Linux slave specifically, not a Windows one.

    Fix: new shared Add-CommonSshOptions (Core.ps1) adds -l <user> whenever a non-blank
    User is available, and is now used by all three call sites instead of each
    inlining its own (User-less) copy of the same option-building logic.

    This check drives the real Add-CommonSshOptions end-to-end through a real ssh.exe
    shim (reporting back exactly what argv it received, the same technique used in
    _run_remote_ssh_quoting_regression_check) and asserts -l <user> is present as a
    genuine, distinct argument when a user is configured, and asserts it is correctly
    OMITTED (falling through to whatever ssh.exe/SshConfig would otherwise resolve, the
    prior behavior) when the configured user is blank.
    """
    import os
    import subprocess
    import tempfile

    with tempfile.TemporaryDirectory(prefix="vdbench-ssh-user-check-") as tmp_dir:
        tmp_path = Path(tmp_dir)

        shim_dir = tmp_path / "shim"
        shim_dir.mkdir()
        ssh_shim = shim_dir / "ssh.exe"
        ssh_shim.write_text(
            "#!/bin/sh\n"
            "echo \"ARGS_RECEIVED:$@\"\n",
            encoding="utf-8",
        )
        ssh_shim.chmod(0o755)

        harness_script = tmp_path / "run-ssh-user-check.ps1"
        harness_script.write_text(
            """
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
. (Join-Path "{module_root}" "Core.ps1")
$script:Settings = [pscustomobject]@{{ SshConfig = ""; PrivateKey = "" }}

$partsWithUser = New-Object System.Collections.Generic.List[string]
Add-CommonSshOptions -SshParts $partsWithUser -User "root"
[void]$partsWithUser.Add("linux-001")
$resultWithUser = Invoke-CapturedProcess "ssh.exe" ($partsWithUser -join " ") 5000

$partsNoUser = New-Object System.Collections.Generic.List[string]
Add-CommonSshOptions -SshParts $partsNoUser -User ""
[void]$partsNoUser.Add("some-host")
$resultNoUser = Invoke-CapturedProcess "ssh.exe" ($partsNoUser -join " ") 5000

$results = [pscustomobject]@{{
    WithUserArgs = $resultWithUser.StdOut
    NoUserArgs = $resultNoUser.StdOut
}}
$results | ConvertTo-Json | Set-Content -LiteralPath "{results_path}" -Encoding UTF8
""".format(
                module_root=str(MODULE_ROOT),
                results_path=str(tmp_path / "results.json"),
            ),
            encoding="utf-8",
        )

        env = dict(os.environ)
        env["PATH"] = str(shim_dir) + ":" + env.get("PATH", "")
        result = subprocess.run(
            [pwsh, "-NoProfile", "-File", str(harness_script)],
            capture_output=True, text=True, env=env, timeout=30,
        )
        if result.returncode != 0:
            print(result.stdout.strip())
            print(result.stderr.strip())
            raise AssertionError("SSH user regression harness itself failed to run")

        results_path = tmp_path / "results.json"
        try:
            parsed = json.loads(results_path.read_text(encoding="utf-8")) if results_path.is_file() else {}
        except json.JSONDecodeError:
            print(result.stdout.strip())
            raise AssertionError("Could not parse SSH user regression harness output as JSON")

        with_user_args = parsed.get("WithUserArgs", "")
        no_user_args = parsed.get("NoUserArgs", "")

        assert "-l root" in with_user_args, (
            f"expected ssh.exe to actually receive '-l root' as a distinct argument "
            f"when the slave's configured User is 'root', got argv: {with_user_args!r} "
            f"- this is exactly the missing piece that made ssh.exe silently fall back "
            f"to the local Windows account (e.g. 'Administrator') instead of the "
            f"slave's own configured user, producing "
            f"'Administrator@host: Permission denied'"
        )
        assert "-l" not in no_user_args.split(), (
            f"expected -l to be omitted entirely when the configured User is blank "
            f"(falling through to whatever ssh.exe/SshConfig would otherwise resolve, "
            f"matching prior behavior for slaves with no User set) - got argv: "
            f"{no_user_args!r}"
        )
        print("SSH user regression check: -l <user> correctly included when configured, correctly omitted when blank")


def _run_auto_target_selection_regression_check(pwsh: str) -> None:
    """Reproduce the "a target shows as selected but I never picked one" bug end-to-end.

    Root cause (found 2026-07-01, from a user report that a Targets cell already showed
    a selection right after adding a new slave, with no Browse click at all):
    Apply-SlaveDefaults (State.ps1) used to default a blank TestTarget (a legacy,
    pre-Targets-array field with no UI representation anymore) to
    Get-DefaultTestTargetForOs(...) and then WRITE THAT COMPUTED DEFAULT BACK into the
    returned object's own TestTarget field. Apply-SlaveDefaults runs on almost every UI
    interaction (Capture-SlaveGrid on save/edit, Populate-SlaveGrid on load/refresh), so
    the very NEXT call to it - which happens almost immediately after adding any new
    slave - saw a now non-blank TestTarget (from the PREVIOUS call's own defaulting) and
    treated it as if it were genuine, pre-existing legacy data requiring migration into
    the Targets array, unconditionally marking it Selected=true - with zero Browse click,
    zero user interaction of any kind.

    Fix: Apply-SlaveDefaults reads the raw TestTarget once for the one-time legacy
    migration check/call only, and passes it straight through unchanged into the
    returned object - it is never widened with a computed default, so a genuinely blank
    TestTarget stays blank forever (matching what Capture-SlaveGrid already explicitly
    sets it to on every save), and the migration path only ever fires for a TRULY
    pre-existing (never-computed) legacy value.

    This check drives the real Apply-SlaveDefaults through a real pwsh process for a
    freshly-added-slave shape across 10 repeated calls (simulating many UI interactions
    in a row) and asserts Targets never becomes non-empty, while a genuinely
    pre-populated legacy TestTarget (the ACTUAL, intended migration scenario) still
    correctly migrates into a Selected Targets entry exactly once, without duplicating
    on subsequent calls.
    """
    import subprocess
    import tempfile

    with tempfile.TemporaryDirectory(prefix="vdbench-auto-target-check-") as tmp_dir:
        harness_script = Path(tmp_dir) / "run-auto-target-check.ps1"
        harness_script.write_text(
            """
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$script:Settings = [pscustomobject]@{{ PrivateKey = "" }}
. (Join-Path "{module_root}" "Core.ps1")
. (Join-Path "{module_root}" "State.ps1")

# Exact shape of a freshly-added slave: Add-NewSlaveRow sets Targets to @() via
# Set-SlaveRowTargets and never touches TestTarget at all.
$fresh = [pscustomobject]@{{
    Enabled = $false; Name = "Windows-001"; Host = "10.50.11.176"; OsType = "Windows"
    User = "administrator"; VdbenchPath = "C:\\vdbench"; SshAlias = "Windows-001"; Targets = @()
}}
$maxTargetsSeenAcrossPasses = 0
for ($i = 1; $i -le 10; $i++) {{
    $fresh = Apply-SlaveDefaults $fresh
    if ($fresh.Targets.Count -gt $maxTargetsSeenAcrossPasses) {{
        $maxTargetsSeenAcrossPasses = $fresh.Targets.Count
    }}
}}

# Genuine legacy migration scenario: an old-format slave saved by a much older
# version of this app, with ONLY TestTarget set and no Targets array at all -
# THIS is the one case that must still correctly migrate.
$legacy = [pscustomobject]@{{
    Enabled = $true; Name = "legacy-001"; Host = "10.0.0.50"; OsType = "Linux"
    VdbenchPath = "/opt/vdbench"; TestTarget = "/dev/sdc"; SshAlias = "legacy-001"
}}
$migrated = Apply-SlaveDefaults $legacy
$migratedAgain = Apply-SlaveDefaults $migrated

$results = [pscustomobject]@{{
    FreshSlaveFinalTargetsCount = $fresh.Targets.Count
    FreshSlaveMaxTargetsSeenAcrossPasses = $maxTargetsSeenAcrossPasses
    FreshSlaveFinalTestTarget = $fresh.TestTarget
    MigratedTargetsCount = $migrated.Targets.Count
    MigratedTargetValue = if ($migrated.Targets.Count -gt 0) {{ [string]$migrated.Targets[0].Target }} else {{ "" }}
    MigratedTargetSelected = if ($migrated.Targets.Count -gt 0) {{ [bool]$migrated.Targets[0].Selected }} else {{ $false }}
    MigratedAgainTargetsCount = $migratedAgain.Targets.Count
}}
$results | ConvertTo-Json | Set-Content -LiteralPath "{results_path}" -Encoding UTF8
""".format(
                module_root=str(MODULE_ROOT),
                results_path=str(Path(tmp_dir) / "results.json"),
            ),
            encoding="utf-8",
        )
        result = subprocess.run(
            [pwsh, "-NoProfile", "-File", str(harness_script)],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            print(result.stdout.strip())
            print(result.stderr.strip())
            raise AssertionError("Auto-target-selection regression harness itself failed to run")

        results_path = Path(tmp_dir) / "results.json"
        try:
            parsed = json.loads(results_path.read_text(encoding="utf-8")) if results_path.is_file() else {}
        except json.JSONDecodeError:
            print(result.stdout.strip())
            raise AssertionError("Could not parse auto-target-selection harness output as JSON")

        assert parsed.get("FreshSlaveMaxTargetsSeenAcrossPasses") == 0, (
            f"a freshly-added slave (Targets=@(), TestTarget never set by the user) "
            f"must NEVER end up with a non-empty Targets array after any number of "
            f"repeated Apply-SlaveDefaults calls (which happen on almost every UI "
            f"interaction) - got max Targets.Count={parsed.get('FreshSlaveMaxTargetsSeenAcrossPasses')!r} "
            f"across 10 passes; this is exactly the bug where a target appeared "
            f"Selected=true on a brand new slave row with zero Browse clicks"
        )
        assert parsed.get("FreshSlaveFinalTargetsCount") == 0
        assert parsed.get("FreshSlaveFinalTestTarget") == "", (
            f"a freshly-added slave's TestTarget must stay blank forever (never widened "
            f"with a computed default) - got {parsed.get('FreshSlaveFinalTestTarget')!r}"
        )

        assert parsed.get("MigratedTargetsCount") == 1, (
            f"a genuinely pre-existing legacy TestTarget must still migrate into exactly "
            f"one Targets entry - got count={parsed.get('MigratedTargetsCount')!r}"
        )
        assert parsed.get("MigratedTargetValue") == "/dev/sdc"
        assert parsed.get("MigratedTargetSelected") is True, (
            "the genuinely migrated legacy target must be marked Selected=true (this "
            "is the one legitimate case the whole migration mechanism exists for)"
        )
        assert parsed.get("MigratedAgainTargetsCount") == 1, (
            f"re-running Apply-SlaveDefaults on an already-migrated slave must not "
            f"duplicate the migrated target - got count={parsed.get('MigratedAgainTargetsCount')!r}"
        )
        print("auto-target-selection regression check: fresh slaves never auto-select a target across repeated calls, genuine legacy migration still works exactly once")


def _run_ssh_alias_default_regression_check(pwsh: str) -> None:
    """Reproduce the "couldn't connect to the server by name" bug end-to-end.

    Root cause (found 2026-07-02, from a direct user report: after adding a slave with
    both a Host/IP and a Name, clicking Browse failed because the app tried to connect
    by the NAME, which is not resolvable on their network - only the IP is a real,
    directly-connectable address): Get-DefaultSshAliasForSlave (State.ps1) preferred the
    slave's Name over its Host/IP when defaulting SshAlias - the one field every
    SSH-based connection in this app actually uses (this app's own direct ssh.exe calls
    for Browse/New folder/test-file prep, AND vdbench's own "system=" parameter for the
    real distributed run). Name is purely a display label typed into the grid with no
    guaranteed relationship to anything resolvable on the network, unlike Host, which is
    explicitly labeled "Host / IP" and expected to be directly connectable. Every
    freshly-added slave (Add-NewSlaveRow always calls Apply-SlaveGridRowDefaults with
    -RefreshSshAlias) - or any slave with its Name/Host subsequently edited - got its
    SshAlias silently defaulted to its own Name, so any connection attempt was made
    against an arbitrary label instead of the real address right next to it in the grid.

    Fix: Get-DefaultSshAliasForSlave now prefers Host over Name, so a slave connects by
    its own IP/hostname by default, and only ever uses Name as a last resort when Host
    itself is blank. SshAlias remains a user-editable override for anyone who genuinely
    has a matching `Host <alias>` entry in their own ssh config and wants to use it
    instead.

    This check drives the real Get-DefaultSshAliasForSlave and the real
    Apply-SlaveDefaults (matching Add-NewSlaveRow's exact shape: Host and Name both
    provided, Targets empty) through a real pwsh process and asserts the resulting
    SshAlias is the Host/IP, not the Name - plus confirms Name is still used as a
    fallback when Host is genuinely blank.
    """
    import subprocess
    import tempfile

    with tempfile.TemporaryDirectory(prefix="vdbench-sshalias-check-") as tmp_dir:
        harness_script = Path(tmp_dir) / "run-sshalias-check.ps1"
        harness_script.write_text(
            """
Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$script:Settings = [pscustomobject]@{{ PrivateKey = "" }}
. (Join-Path "{module_root}" "Core.ps1")
. (Join-Path "{module_root}" "State.ps1")

$aliasWithBothHostAndName = Get-DefaultSshAliasForSlave "linux-002" "10.50.11.183"
$aliasWithBlankHost = Get-DefaultSshAliasForSlave "linux-002" ""
$aliasWithBothBlank = Get-DefaultSshAliasForSlave "" ""

# Exact shape of Add-NewSlaveRow's freshly-added slave: Host and Name both provided,
# Targets empty, going through the real Apply-SlaveDefaults normalization.
$freshSlave = [pscustomobject]@{{
    Enabled = $false; Name = "linux-002"; Host = "10.50.11.183"; OsType = "Linux"; Targets = @()
}}
$normalized = Apply-SlaveDefaults $freshSlave

$results = [pscustomobject]@{{
    AliasWithBothHostAndName = $aliasWithBothHostAndName
    AliasWithBlankHost = $aliasWithBlankHost
    AliasWithBothBlank = $aliasWithBothBlank
    NormalizedSshAlias = $normalized.SshAlias
}}
$results | ConvertTo-Json | Set-Content -LiteralPath "{results_path}" -Encoding UTF8
""".format(
                module_root=str(MODULE_ROOT),
                results_path=str(Path(tmp_dir) / "results.json"),
            ),
            encoding="utf-8",
        )
        result = subprocess.run(
            [pwsh, "-NoProfile", "-File", str(harness_script)],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            print(result.stdout.strip())
            print(result.stderr.strip())
            raise AssertionError("SSH alias default regression harness itself failed to run")

        results_path = Path(tmp_dir) / "results.json"
        try:
            parsed = json.loads(results_path.read_text(encoding="utf-8")) if results_path.is_file() else {}
        except json.JSONDecodeError:
            print(result.stdout.strip())
            raise AssertionError("Could not parse SSH alias default harness output as JSON")

        assert parsed.get("AliasWithBothHostAndName") == "10.50.11.183", (
            f"when both a Host/IP and a Name are provided (the normal 'Add slave' case), "
            f"the default SshAlias must be the Host/IP, not the Name - got "
            f"{parsed.get('AliasWithBothHostAndName')!r}. This is exactly the bug that "
            f"made Browse/New folder/the real distributed run try to connect by an "
            f"arbitrary display label instead of the real, directly-connectable address"
        )
        assert parsed.get("AliasWithBlankHost") == "linux-002", (
            f"Name must still be used as a fallback when Host is genuinely blank - got "
            f"{parsed.get('AliasWithBlankHost')!r}"
        )
        assert parsed.get("AliasWithBothBlank") == "", (
            f"expected an empty default when both Host and Name are blank, got "
            f"{parsed.get('AliasWithBothBlank')!r}"
        )
        assert parsed.get("NormalizedSshAlias") == "10.50.11.183", (
            f"end-to-end: a freshly-added slave (matching Add-NewSlaveRow's exact "
            f"shape) must have its SshAlias default to its own Host/IP after "
            f"Apply-SlaveDefaults, got {parsed.get('NormalizedSshAlias')!r}"
        )
        print("SSH alias default regression check: a freshly-added slave now connects by Host/IP by default, not by its display Name")


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
    core_module_full = (MODULE_ROOT / "Core.ps1").read_text(encoding="utf-8")
    assert "function Write-DebugLog" in core_module_full
    # See _run_get_property_value_endinvoke_regression_check docstring: EndInvoke()
    # wraps even a single output object in a 1-item PSDataCollection, which
    # Get-PropertyValue's property lookup did not account for, silently returning the
    # default for every property of every Start-BackgroundUiWork OnComplete "$Result".
    assert "ICollection" in core_module_full and "$Object.Count -eq 1" in core_module_full, (
        "Get-PropertyValue must unwrap a same single-item, non-string, non-dictionary "
        "collection before its property lookup, or every call site reading a property "
        "off a background job's EndInvoke() result silently gets the default value back "
        "no matter what was really set"
    )
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
    target_discovery_module = (MODULE_ROOT / "TargetDiscovery.ps1").read_text(encoding="utf-8")
    assert "function Get-CachedTargetInventory" in target_discovery_module
    runner_module_full = (MODULE_ROOT / "Runner.ps1").read_text(encoding="utf-8")
    core_module_for_ssh = (MODULE_ROOT / "Core.ps1").read_text(encoding="utf-8")
    # See _run_remote_ssh_quoting_regression_check docstring: OpenSSH rejoins all
    # "remote command" arguments with plain spaces before sending them to the server,
    # which silently strips any LOCAL-only quoting used to keep e.g.
    # "powershell.exe"/"-Command"/"<script>" together as separate argv elements on this
    # side - exposing PowerShell's own pipe operator to an intermediate cmd.exe on
    # Windows (which then tries to launch a program literally named after whatever
    # cmdlet follows the pipe, e.g. ForEach-Object) and breaking POSIX shell isolation
    # on Linux. Get-RemoteExecCommandParts is the one, shared, correct way to build
    # this - guard against the old broken 3/4-separate-token pattern reappearing
    # anywhere it is used.
    assert "function Get-RemoteExecCommandParts" in core_module_for_ssh
    assert "function Convert-ToShellSingleQuoted" in core_module_for_ssh
    assert "function Convert-ToPowerShellSingleQuoted" in core_module_for_ssh
    assert "-EncodedCommand" in core_module_for_ssh, (
        "Get-RemoteExecCommandParts must use -EncodedCommand for the Windows remote "
        "shell path - -Command with a quoted script string does not survive OpenSSH's "
        "own argument rejoining"
    )
    # See _run_ssh_user_regression_check docstring: every direct ssh.exe call this app
    # makes used to omit the slave's configured User entirely, silently falling back to
    # ssh's own default of "whatever OS user is running the UI process" - producing
    # e.g. "Administrator@linux-001: Permission denied" for a Linux slave whose User is
    # "root". Guard the shared fix and its usage at every call site.
    assert "function Add-CommonSshOptions" in core_module_for_ssh
    assert '[void]$SshParts.Add("-l")' in core_module_for_ssh, (
        "Add-CommonSshOptions must pass the slave's configured User to ssh.exe via -l - "
        "without it, ssh.exe silently connects as whatever local OS account is running "
        "the UI process instead of the slave's own configured user"
    )
    for module_name, module_text in (
        ("TargetDiscovery.ps1", target_discovery_module),
        ("Runner.ps1", runner_module_full),
    ):
        assert "Add-CommonSshOptions" in module_text, (
            f"{module_name} must build its ssh.exe options via the shared "
            f"Add-CommonSshOptions helper (which includes -l <user>), not by inlining "
            f"its own copy that silently omits the configured User"
        )
        assert "Get-RemoteExecCommandParts" in module_text, (
            f"{module_name} must build remote SSH commands via the shared "
            f"Get-RemoteExecCommandParts helper, not inline argument construction"
        )
        assert '[void]$sshParts.Add("-lc")' not in module_text, (
            f"{module_name} must not reintroduce the old, broken pattern of adding "
            f"'sh'/'-lc'/'<script>' as separate ssh argv tokens - OpenSSH's client-side "
            f"rejoining loses the outer quoting that kept them together, breaking the "
            f"intended 'sh -lc' isolation on the remote end (confirmed via a real "
            f"dash 'Syntax error: \"do\" unexpected' in this sandbox)"
        )
        assert '[void]$sshParts.Add("-Command")' not in module_text, (
            f"{module_name} must not reintroduce the old, broken pattern of adding "
            f"'powershell.exe'/'-NoProfile'/'-Command'/'<script>' as separate ssh argv "
            f"tokens - OpenSSH's client-side rejoining loses the outer quoting, exposing "
            f"any pipe in the script to an intermediate cmd.exe which then fails with "
            f"\"'X' is not recognized as an internal or external command\""
        )
        # Get-RemoteExecCommandParts's Linux branch returns a single-element array;
        # PowerShell silently collapses a function's single-item array return value
        # back to the bare scalar across the function-call boundary unless the CALL
        # SITE (not just the function's own internal `return @(...)`) is also wrapped
        # in @() - confirmed empirically 2026-07-01. Guard every call site.
        assert "foreach ($token in (Get-RemoteExecCommandParts" not in module_text, (
            f"{module_name} must wrap the Get-RemoteExecCommandParts call site itself "
            f"in @() (foreach ($token in @(Get-RemoteExecCommandParts ...))) - "
            f"PowerShell collapses a function's single-item array return value back to "
            f"a bare scalar across the call boundary unless the call site also forces "
            f"array context"
        )
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
    assert "press Enter to close this window" in ui_slave_module

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
    # AlreadyShown was a first-pass fix for the duplicate-popup bug that turned out to be
    # provably dead code (ShowOutput and ShowCheckerWindow are always the same value in
    # the only caller, so the flag it gated was always true whenever read) - removed
    # entirely in favor of unconditionally never showing that popup. Guard against it
    # (or an equivalent dead flag under a different name) creeping back in.
    assert "AlreadyShown" not in ui_slave_module, (
        "AlreadyShown was removed as dead code (see git history) - do not reintroduce a "
        "flag that only ever gates a popup no caller can reach the 'false' branch of"
    )
    assert 'Show-Info ([string]$Result.Output) "Readiness output"' not in ui_slave_module, (
        "Start-SlaveReadinessCheck must not pop an app-level info dialog for a "
        "Ready/Failed separate-window result - the checker's own window (which now "
        "always pauses for Enter, see Get-ReadinessCheckerWrapperCommand) is already "
        "sufficient, and a second popup per completed check is what piled up into a "
        "wall of stacked dialogs when several checks completed close together"
    )
    # Get-ReadinessCheckerWrapperCommand must pause for Enter unconditionally, not only
    # when its own $exitCode is non-zero - the shipped checker script exits 0
    # unconditionally regardless of whether its own internal [OK]/[FAIL] checks passed,
    # so gating the pause behind a non-zero exit code auto-closed the window before the
    # user could read a failing check inside an exit-0 run.
    assert "if (`$exitCode -ne 0) {" not in ui_slave_module, (
        "the pause-for-Enter prompt must not be gated behind a non-zero exit code check "
        "- the shipped checker script can exit 0 even when its own internal checks "
        "reported [FAIL], so this condition auto-closed the window before those "
        "failures could be read"
    )
    assert "Readiness checker finished (exit code 0)." in ui_slave_module, (
        "expected an explicit exit-0 success message distinct from the non-zero-exit "
        "message, printed just before the now-unconditional pause prompt"
    )
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
    # v1: the original default broke any checker script using [CmdletBinding()]
    # (PowerShell throws "A parameter cannot be found..." for unknown named
    # params). The shipped default and the migration for already-initialized
    # settings.json files must agree on the same legacy value being replaced.
    legacy_readiness_args_v1 = "-HostName {Host} -VdbenchPath {VdbenchPath} -Target {Target}"
    assert legacy_readiness_args_v1 in state_module_full
    # v2->v3: confirmed by manually running the real shipped checker script
    # that it DOES take an argument - -WindowsHosts/-LinuxHosts, chosen by the
    # row's OS - so an empty template silently never checked the specific
    # slave a user clicked Readiness for. {HostFlag} is the current default,
    # and the migration only advances a bare empty template while
    # ReadinessChecker still points at the stock shipped script.
    assert '"{HostFlag}"' in state_module_full and "stockChecker" in state_module_full, (
        "Migrate-LegacySettings must advance a bare empty ReadinessCheckerArguments "
        "to {HostFlag}, guarded by ReadinessChecker still pointing at the stock script"
    )
    assert settings.get("ReadinessCheckerArguments") == "{HostFlag}", (
        "default-settings.json should ship ReadinessCheckerArguments={HostFlag}: the "
        "real shipped checker script needs -WindowsHosts/-LinuxHosts (chosen by the "
        "row's OS) to know which host to actually check, confirmed by manually "
        "running it; an empty template silently skips checking the specific slave"
    )
    # See _run_auto_target_selection_regression_check docstring: Apply-SlaveDefaults
    # must never default a blank TestTarget and write that COMPUTED value back into the
    # returned object - doing so poisoned the very next call (which happens on almost
    # every UI interaction) into treating it as genuine pre-existing legacy data,
    # silently auto-selecting a target the user never touched via Browse.
    assert "Get-DefaultTestTargetForOs $osType" not in state_module_full, (
        "Apply-SlaveDefaults must not default a blank TestTarget via "
        "Get-DefaultTestTargetForOs and write it back into the returned object - the "
        "computed default becomes indistinguishable from genuine legacy data on the "
        "very next call, silently auto-selecting a target with zero user interaction"
    )
    # See _run_ssh_alias_default_regression_check docstring: Get-DefaultSshAliasForSlave
    # must prefer Host/IP over the purely-cosmetic display Name, or every SSH-based
    # connection (this app's own ssh.exe calls AND vdbench's own "system=" parameter)
    # tries to connect by an arbitrary label instead of a real, resolvable address.
    ssh_alias_fn_match = re.search(
        r"function Get-DefaultSshAliasForSlave \{.*?\n\}", state_module_full, re.DOTALL,
    )
    assert ssh_alias_fn_match, "Get-DefaultSshAliasForSlave function not found in State.ps1"
    ssh_alias_fn_body = ssh_alias_fn_match.group(0)
    host_check_pos = ssh_alias_fn_body.find("IsNullOrWhiteSpace($HostName)")
    name_check_pos = ssh_alias_fn_body.find("IsNullOrWhiteSpace($Name)")
    assert host_check_pos != -1 and name_check_pos != -1 and host_check_pos < name_check_pos, (
        "Get-DefaultSshAliasForSlave must check $HostName before $Name, so a slave's "
        "SshAlias defaults to its own Host/IP rather than its display Name - the exact "
        "bug that made Browse/New folder/the real distributed run try to connect by an "
        "arbitrary label the user typed instead of the real address next to it"
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
