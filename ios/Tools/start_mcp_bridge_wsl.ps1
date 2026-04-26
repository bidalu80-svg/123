param(
    [string]$Distro = "Ubuntu",
    [int]$Port = 8790,
    [string]$Token = "",
    [string]$WorkspaceRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Convert-ToWslPath {
    param([Parameter(Mandatory = $true)][string]$WindowsPath)
    $resolved = [System.IO.Path]::GetFullPath($WindowsPath)
    $normalized = $resolved.Replace("\", "/")
    if ($normalized -match '^([A-Za-z]):/(.*)$') {
        return "/mnt/$($Matches[1].ToLowerInvariant())/$($Matches[2])"
    }
    throw "Unable to convert path to a WSL path: $WindowsPath"
}

function Escape-ForBashSingleQuote {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    return $Value.Replace("'", "'""'""'")
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$workspaceWindowsRoot =
    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        $repoRoot
    } elseif ([System.IO.Path]::IsPathRooted($WorkspaceRoot)) {
        [System.IO.Path]::GetFullPath($WorkspaceRoot)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $repoRoot $WorkspaceRoot))
    }

$repoRootWsl = Convert-ToWslPath -WindowsPath $repoRoot
$workspaceRootWsl = Convert-ToWslPath -WindowsPath $workspaceWindowsRoot
$escapedRepoRootWsl = Escape-ForBashSingleQuote -Value $repoRootWsl
$escapedWorkspaceRootWsl = Escape-ForBashSingleQuote -Value $workspaceRootWsl
$escapedToken = Escape-ForBashSingleQuote -Value $Token

$distroListRaw = (& wsl.exe -l -q 2>$null | Out-String)
$installedDistros = $distroListRaw.Replace("`0", "").Split([Environment]::NewLine, [System.StringSplitOptions]::RemoveEmptyEntries)
if (-not ($installedDistros -contains $Distro)) {
    throw "WSL distro '$Distro' was not found."
}

$wslIpRaw = (& wsl.exe -d $Distro -- hostname -I 2>$null | Out-String).Replace("`0", "").Trim()
$wslIp = ($wslIpRaw -split "\s+" | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1)
if (-not $wslIp) {
    throw "Unable to determine WSL IPv4 address for distro '$Distro'."
}

try {
    netsh interface portproxy delete v4tov4 listenport=$Port listenaddress=0.0.0.0 > $null 2>&1
    netsh interface portproxy add v4tov4 listenport=$Port listenaddress=0.0.0.0 connectport=$Port connectaddress=$wslIp > $null
} catch {
    Write-Warning "Failed to update Windows portproxy: $($_.Exception.Message)"
}

try {
    $ruleName = "ChatApp WSL MCP Bridge $Port"
    $rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if (-not $rule) {
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port | Out-Null
    }
} catch {
    Write-Warning "Failed to update Windows Firewall rule: $($_.Exception.Message)"
}

Write-Host "[mcp-bridge] repo root: $repoRoot"
Write-Host "[mcp-bridge] workspace root: $workspaceWindowsRoot"
Write-Host "[mcp-bridge] distro: $Distro"
Write-Host "[mcp-bridge] port: $Port"
Write-Host "[mcp-bridge] wsl ip: $wslIp"
Write-Host "[mcp-bridge] app URL: http://$wslIp`:$Port/v1/mcp/call_tool"

$tempScriptWindows = Join-Path $env:TEMP "chatapp-mcp-bridge-start.sh"
$tempScriptWsl = Convert-ToWslPath -WindowsPath $tempScriptWindows
$scriptContent = @"
#!/usr/bin/env bash
set -e
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found in WSL distro '$Distro'. Please install python3 first."
  exit 1
fi
mkdir -p '$escapedWorkspaceRootWsl'
cd '$escapedRepoRootWsl'
MCP_BRIDGE_HOST='0.0.0.0' MCP_BRIDGE_PORT='$Port' MCP_BRIDGE_TOKEN='$escapedToken' MCP_BRIDGE_ROOT='$escapedWorkspaceRootWsl' python3 'ios/Tools/mcp_bridge_server.py'
"@

[System.IO.File]::WriteAllText(
    $tempScriptWindows,
    $scriptContent,
    (New-Object System.Text.UTF8Encoding($false))
)
wsl.exe -d $Distro -- bash $tempScriptWsl
