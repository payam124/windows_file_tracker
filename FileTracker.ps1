# CONFIGURATION
$WatchedPathsDefault = @("Z:\DefaultPath1", "Z:\DefaultPath2")

$IntervalSeconds = 10                    # 5 minutes
$StateFile = "$PSScriptRoot\last_snapshot.json"
$LogDir = "$PSScriptRoot\logs"

# Check environment variable
$envWatched = $env:FMON_WATCHED_PATHS
if (![string]::IsNullOrWhiteSpace($envWatched)) {
    $WatchedPaths = $envWatched -split ';'
    Write-Host "Using WatchedPaths from environment: $WatchedPaths"
} else {
    $WatchedPaths = $WatchedPathsDefault
    Write-Host "Using WatchedPaths from settings.ps1 or fallback: $WatchedPaths"
}

# Ensure log directory exists
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}

# Get file owner
function Get-FileOwner($path) {
    try {
        return (Get-Acl -Path $path).Owner
    } catch {
        return "N/A"
    }
}

# Build snapshot with metadata
function Get-FullSnapshot {
    $snapshot = @()
    foreach ($root in $WatchedPaths) {
        if (-not (Test-Path $root)) {
            Write-Warning "Path not found: $root"
            continue
        }

        Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            try {
                $hash = Get-FileHash -Path $_.FullName -Algorithm MD5
                $owner = Get-FileOwner $_.FullName
                $snapshot += [PSCustomObject]@{
                    Path         = $_.FullName
                    Owner        = $owner
                    Created      = $_.CreationTimeUtc
                    LastModified = $_.LastWriteTimeUtc
                    Hash         = $hash.Hash
                }
            } catch {
                Write-Warning "Could not process: $_.FullName"
            }
        }
    }
    return $snapshot
}

# Log changes and snapshot
function Log-Changes {
    param (
        [array]$previousSnapshot,
        [array]$currentSnapshot
    )

    $prevByPath = @{}
    $prevByHash = @{}
    foreach ($f in $previousSnapshot) {
        $prevByPath[$f.Path] = $f
        if (-not $prevByHash.ContainsKey($f.Hash)) {
            $prevByHash[$f.Hash] = @()
        }
        $prevByHash[$f.Hash] += $f.Path
    }

    $currByPath = @{}
    $currByHash = @{}
    foreach ($f in $currentSnapshot) {
        $currByPath[$f.Path] = $f
        if (-not $currByHash.ContainsKey($f.Hash)) {
            $currByHash[$f.Hash] = @()
        }
        $currByHash[$f.Hash] += $f.Path
    }

    $logTime = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logFile = Join-Path $LogDir "$logTime.log"
    $logContent = @()

    # Track moved files by hash to avoid duplication
    $movedHashes = @{}

    # Detect added files (and maybe moved)
    foreach ($addedPath in $currByPath.Keys | Where-Object { -not $prevByPath.ContainsKey($_) }) {
        $entry = $currByPath[$addedPath]
        $hash = $entry.Hash
        if ($prevByHash.ContainsKey($hash) -and -not $movedHashes.ContainsKey($hash)) {
            $from = $prevByHash[$hash][0]
            $fromEntry = $prevByPath[$from]
            $logContent += "[Moved] FROM: '$from' | Owner: $($fromEntry.Owner) | Created: $($fromEntry.Created) | Modified: $($fromEntry.LastModified)"
            $logContent += "[Moved]   TO: '$($entry.Path)' | Owner: $($entry.Owner) | Created: $($entry.Created) | Modified: $($entry.LastModified)"
            $movedHashes[$hash] = $true
        } else {
            $logContent += "[Added] '$($entry.Path)' | Owner: $($entry.Owner) | Created: $($entry.Created) | Modified: $($entry.LastModified)"
        }
    }

    # Detect removed files (and maybe moved — skip already handled)
    foreach ($removedPath in $prevByPath.Keys | Where-Object { -not $currByPath.ContainsKey($_) }) {
        $entry = $prevByPath[$removedPath]
        $hash = $entry.Hash
        if ($currByHash.ContainsKey($hash) -and -not $movedHashes.ContainsKey($hash)) {
            $to = $currByHash[$hash][0]
            $toEntry = $currByPath[$to]
            $logContent += "[Moved] FROM: '$($entry.Path)' | Owner: $($entry.Owner) | Created: $($entry.Created) | Modified: $($entry.LastModified)"
            $logContent += "[Moved]   TO: '$to' | Owner: $($toEntry.Owner) | Created: $($toEntry.Created) | Modified: $($toEntry.LastModified)"
            $movedHashes[$hash] = $true
        } elseif (-not $movedHashes.ContainsKey($hash)) {
            $logContent += "[Removed] '$($entry.Path)' | Owner: $($entry.Owner) | Created: $($entry.Created) | Modified: $($entry.LastModified)"
        }
    }

    if ($logContent.Count -gt 0) {
        Write-Host "Changes detected! Logging to $logFile`n"
        $logContent | ForEach-Object { Write-Host $_ }
        $logContent | Set-Content -Path $logFile -Encoding UTF8
        "`nSnapshot Details:" | Add-Content $logFile
        $currentSnapshot | ConvertTo-Json -Depth 5 | Add-Content $logFile
    } else {
        Write-Host "No changes detected."
    }
}

# Load or build initial snapshot
if (Test-Path $StateFile) {
    Write-Host "Loading previous snapshot..."
    try {
        $previousSnapshot = Get-Content $StateFile | ConvertFrom-Json -ErrorAction Stop
        $currentSnapshot = Get-FullSnapshot

        Log-Changes -previousSnapshot $previousSnapshot -currentSnapshot $currentSnapshot

        # Save new snapshot
        $currentSnapshot | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8
        $previousSnapshot = $currentSnapshot
    } catch {
        Write-Warning "Failed to load previous snapshot. Starting fresh..."
        $previousSnapshot = Get-FullSnapshot
        $previousSnapshot | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8
    }
} else {
    Write-Host "No previous snapshot found. Creating new one..."
    $previousSnapshot = Get-FullSnapshot
    $previousSnapshot | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8
}

# Main monitoring loop
while ($true) {
    Start-Sleep -Seconds $IntervalSeconds
    Write-Host "`n[$(Get-Date -Format u)] Checking for changes..."

    $currentSnapshot = Get-FullSnapshot
    Log-Changes -previousSnapshot $previousSnapshot -currentSnapshot $currentSnapshot

    # Save new snapshot
    $currentSnapshot | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8
    $previousSnapshot = $currentSnapshot
}
