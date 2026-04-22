param(
    [string]$Branch = "",
    [string]$Workflow = "build-ios-ipa.yml",
    [switch]$Wait,
    [switch]$NoAutoSync
)

$ErrorActionPreference = "Stop"

function Resolve-PushRemote {
    $preferred = @("mirror", "origin")
    foreach ($remote in $preferred) {
        $remoteUrl = (git remote get-url $remote 2>$null)
        if ($LASTEXITCODE -eq 0 -and $remoteUrl -and $remoteUrl.Trim()) {
            return $remote
        }
    }

    $allRemotes = (& git remote 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $allRemotes) {
        throw "Cannot resolve git remote for push."
    }

    $fallback = ($allRemotes | Select-Object -First 1).Trim()
    if (-not $fallback) {
        throw "Cannot resolve git remote for push."
    }
    return $fallback
}

function Get-GitHubRepo {
    if ($env:GH_OWNER -and $env:GH_REPO) {
        return @{
            Owner = $env:GH_OWNER.Trim()
            Repo = $env:GH_REPO.Trim()
            Remote = Resolve-PushRemote
        }
    }

    $remoteNames = @("mirror", "origin")
    foreach ($remote in $remoteNames) {
        $remoteUrl = (git remote get-url $remote 2>$null)
        if (-not $remoteUrl) { continue }
        $remoteUrl = $remoteUrl.Trim()
        if (-not $remoteUrl) { continue }

        if ($remoteUrl -match "github\.com[:/](?<owner>[^/]+)/(?<repo>[^/.]+)(?:\.git)?$") {
            return @{
                Owner = $matches["owner"]
                Repo = $matches["repo"]
                Remote = $remote
            }
        }
    }

    throw "Cannot resolve GitHub owner/repo from git remotes. Set GH_OWNER and GH_REPO env vars."
}

function Get-GitHubToken {
    if ($env:GITHUB_TOKEN -and $env:GITHUB_TOKEN.Trim()) {
        return $env:GITHUB_TOKEN.Trim()
    }

    $credentialInput = @"
protocol=https
host=github.com

"@
    $raw = $credentialInput | git credential fill 2>$null
    if (-not $raw) {
        throw "Missing GitHub token. Set GITHUB_TOKEN or configure git credential for github.com."
    }

    $tokenLine = $raw -split "`n" | Where-Object { $_ -like "password=*" } | Select-Object -First 1
    if (-not $tokenLine) {
        throw "No password found in git credential store for github.com."
    }

    $token = $tokenLine.Substring(9).Trim()
    if (-not $token) {
        throw "Empty token from git credential store."
    }
    return $token
}

function Invoke-GH {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $false)]$Body
    )

    $headers = @{
        Authorization = "Bearer $script:GitHubToken"
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    if ($PSBoundParameters.ContainsKey("Body")) {
        $json = $Body | ConvertTo-Json -Depth 100
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -ContentType "application/json" -Body $json
    }
    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
}

function Resolve-Branch {
    param([string]$InputBranch)
    if ($InputBranch -and $InputBranch.Trim()) {
        return $InputBranch.Trim()
    }

    $current = (git rev-parse --abbrev-ref HEAD 2>$null)
    if ($current) {
        $current = $current.Trim()
        if ($current -and $current -ne "HEAD") {
            return $current
        }
    }
    return "main"
}

function Get-CurrentBranch {
    $current = (git rev-parse --abbrev-ref HEAD 2>$null)
    if (-not $current) {
        throw "Cannot resolve current git branch."
    }
    $current = $current.Trim()
    if (-not $current -or $current -eq "HEAD") {
        throw "Detached HEAD is not supported for auto sync."
    }
    return $current
}

function Invoke-GitChecked {
    param(
        [Parameter(Mandatory = $true)][string[]]$Args,
        [string]$ErrorMessage = "git command failed"
    )

    & git @Args
    if ($LASTEXITCODE -ne 0) {
        throw $ErrorMessage
    }
}

function Has-WorkingTreeChanges {
    $statusLines = & git status --porcelain --untracked-files=all
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to inspect git working tree."
    }
    return -not [string]::IsNullOrWhiteSpace(($statusLines -join "`n"))
}

function Ensure-RemoteBranchPushed {
    param(
        [Parameter(Mandatory = $true)][string]$Remote,
        [Parameter(Mandatory = $true)][string]$Branch
    )

    $remoteBranchSha = (& git ls-remote --heads $Remote $Branch 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to query remote branch '$Remote/$Branch'."
    }

    if ([string]::IsNullOrWhiteSpace(($remoteBranchSha -join "`n"))) {
        Invoke-GitChecked -Args @("push", "-u", $Remote, $Branch) -ErrorMessage "Failed to push new branch '$Branch' to remote '$Remote'."
    } else {
        Invoke-GitChecked -Args @("push", $Remote, $Branch) -ErrorMessage "Failed to push branch '$Branch' to remote '$Remote'."
    }
}

function Auto-SyncLocalChanges {
    param(
        [Parameter(Mandatory = $true)][string]$Remote,
        [Parameter(Mandatory = $true)][string]$ResolvedBranch
    )

    $currentBranch = Get-CurrentBranch
    if ($currentBranch -ne $ResolvedBranch) {
        throw "Current branch '$currentBranch' differs from target branch '$ResolvedBranch'. Switch to '$ResolvedBranch' or omit branch arg."
    }

    $hasChanges = Has-WorkingTreeChanges
    if ($hasChanges) {
        Write-Host "[INFO] Local changes detected. Auto committing..."
        Invoke-GitChecked -Args @("add", "-A") -ErrorMessage "Failed to stage local changes."
        $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $commitMessage = "chore: auto-sync before IPA build ($timestamp)"
        Invoke-GitChecked -Args @("commit", "-m", $commitMessage) -ErrorMessage "Failed to create auto-sync commit."
        Write-Host "[OK] Auto commit created."
    } else {
        Write-Host "[INFO] No uncommitted local changes."
    }

    Write-Host "[INFO] Pushing branch '$ResolvedBranch' to '$Remote'..."
    Ensure-RemoteBranchPushed -Remote $Remote -Branch $ResolvedBranch
    Write-Host "[OK] Branch pushed."
}

$repoInfo = Get-GitHubRepo
$script:GitHubToken = Get-GitHubToken
$resolvedBranch = Resolve-Branch -InputBranch $Branch
$escapedBranch = [System.Uri]::EscapeDataString($resolvedBranch)
$escapedWorkflow = [System.Uri]::EscapeDataString($Workflow)
$owner = $repoInfo.Owner
$repo = $repoInfo.Repo
$remote = $repoInfo.Remote

Write-Host "[INFO] Repo: $owner/$repo"
Write-Host "[INFO] Remote: $remote"
Write-Host "[INFO] Workflow: $Workflow"
Write-Host "[INFO] Branch: $resolvedBranch"

if (-not $NoAutoSync) {
    Auto-SyncLocalChanges -Remote $remote -ResolvedBranch $resolvedBranch
} else {
    Write-Host "[INFO] Auto sync disabled."
}

$dispatchedAt = Get-Date
Invoke-GH -Method POST -Uri "https://api.github.com/repos/$owner/$repo/actions/workflows/$escapedWorkflow/dispatches" -Body @{
    ref = $resolvedBranch
} | Out-Null

Write-Host "[OK] Workflow dispatch submitted."

$run = $null
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 2
    $runs = Invoke-GH -Method GET -Uri "https://api.github.com/repos/$owner/$repo/actions/workflows/$escapedWorkflow/runs?branch=$escapedBranch&event=workflow_dispatch&per_page=10"
    $run = $runs.workflow_runs |
        Sort-Object created_at -Descending |
        Where-Object { [datetime]$_.created_at -ge $dispatchedAt.AddMinutes(-1) } |
        Select-Object -First 1
    if ($run) { break }
}

if (-not $run) {
    Write-Warning "Dispatch succeeded but run not found yet."
    Write-Host "Open manually: https://github.com/$owner/$repo/actions/workflows/$Workflow"
    exit 0
}

$runUrl = $run.html_url
Write-Host "[OK] Run created: $runUrl"

try {
    Start-Process $runUrl | Out-Null
    Write-Host "[INFO] Opened run page in browser."
} catch {
    Write-Warning "Could not open browser automatically."
}

if (-not $Wait) {
    Write-Host "[DONE] Trigger complete. Use --wait to monitor until finish."
    exit 0
}

Write-Host "[INFO] Waiting for workflow completion..."

$runId = $run.id
for ($i = 0; $i -lt 180; $i++) {
    Start-Sleep -Seconds 10
    $state = Invoke-GH -Method GET -Uri "https://api.github.com/repos/$owner/$repo/actions/runs/$runId"
    $status = $state.status
    $conclusion = $state.conclusion
    $safeConclusion = if ($null -eq $conclusion) { "" } else { [string]$conclusion }
    Write-Host ("  status={0} conclusion={1}" -f $status, $safeConclusion)

    if ($status -eq "completed") {
        if ($conclusion -eq "success") {
            Write-Host "[OK] Workflow completed successfully."
            $arts = Invoke-GH -Method GET -Uri "https://api.github.com/repos/$owner/$repo/actions/runs/$runId/artifacts"
            $ipaArtifact = $arts.artifacts | Where-Object { $_.name -eq "chatapp-ipa" } | Select-Object -First 1
            if ($ipaArtifact) {
                Write-Host ("[OK] Artifact: {0} (ID: {1})" -f $ipaArtifact.name, $ipaArtifact.id)
            } else {
                Write-Warning "No chatapp-ipa artifact found."
            }
            exit 0
        }
        Write-Error "Workflow completed with conclusion: $conclusion"
    }
}

Write-Error "Timeout while waiting for workflow completion."
