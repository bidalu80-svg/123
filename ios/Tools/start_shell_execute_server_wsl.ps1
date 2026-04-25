param(
    [string]$Distro = "Ubuntu",
    [int]$Port = 8787,
    [string]$Token = "",
    [string]$WorkspaceRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Convert-ToWslPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WindowsPath
    )

    $resolved = [System.IO.Path]::GetFullPath($WindowsPath)
    $normalized = $resolved.Replace("\", "/")
    if ($normalized -match '^([A-Za-z]):/(.*)$') {
        $drive = $Matches[1].ToLowerInvariant()
        $tail = $Matches[2]
        return "/mnt/$drive/$tail"
    }

    throw "Unable to convert path to a WSL path: $WindowsPath"
}

function Escape-ForBashSingleQuote {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

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
    $available = if ($installedDistros.Count -gt 0) {
        $installedDistros -join ", "
    } else {
        "none"
    }
    throw "WSL distro '$Distro' was not found. Installed distros: ${available}. Install Ubuntu first, or pass -Distro with an existing distro."
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
    $ruleName = "ChatApp WSL Shell $Port"
    $rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if (-not $rule) {
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port | Out-Null
    }
} catch {
    Write-Warning "Failed to update Windows Firewall rule: $($_.Exception.Message)"
}

Write-Host "[shell-wsl] repo root: $repoRoot"
Write-Host "[shell-wsl] workspace root: $workspaceWindowsRoot"
Write-Host "[shell-wsl] distro: $Distro"
Write-Host "[shell-wsl] port: $Port"
Write-Host "[shell-wsl] wsl ip: $wslIp"

$tempScriptWindows = Join-Path $env:TEMP "chatapp-shell-execute-start.sh"
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
SHELL_EXEC_HOST='0.0.0.0' SHELL_EXEC_PORT='$Port' SHELL_EXEC_TOKEN='$escapedToken' SHELL_EXEC_ROOT='$escapedWorkspaceRootWsl' python3 'ios/Tools/shell_execute_server.py'
"@

[System.IO.File]::WriteAllText(
    $tempScriptWindows,
    $scriptContent,
    (New-Object System.Text.UTF8Encoding($false))
)
wsl.exe -d $Distro -- bash $tempScriptWsl
