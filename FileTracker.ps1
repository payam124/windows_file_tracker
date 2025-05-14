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

    # Track confirmed moved hashes to avoid double-reporting
    $movedPairs = @{}

    # Identify true moves: file hash existed in previous snapshot but changed path
    foreach ($hash in $prevByHash.Keys) {
        if ($currByHash.ContainsKey($hash)) {
            $oldPaths = $prevByHash[$hash]
            $newPaths = $currByHash[$hash]

            foreach ($oldPath in $oldPaths) {
                if (-not ($newPaths -contains $oldPath)) {
                    # If a file with same hash exists at a new path AND wasn't already in the previous snapshot
                    foreach ($newPath in $newPaths) {
                        if (-not ($prevByPath.ContainsKey($newPath))) {
                            $from = $prevByPath[$oldPath]
                            $to = $currByPath[$newPath]
                            $logContent += "[Moved] FROM: '$($from.Path)' | Owner: $($from.Owner) | Created: $($from.Created) | Modified: $($from.LastModified)"
                            $logContent += "[Moved]   TO: '$($to.Path)' | Owner: $($to.Owner) | Created: $($to.Created) | Modified: $($to.LastModified)"
                            $movedPairs[$oldPath] = $true
                            $movedPairs[$newPath] = $true
                            break
                        }
                    }
                }
            }
        }
    }

    # Added
    foreach ($addedPath in $currByPath.Keys | Where-Object { -not $prevByPath.ContainsKey($_) -and -not $movedPairs.ContainsKey($_) }) {
        $f = $currByPath[$addedPath]
        $logContent += "[Added] '$($f.Path)' | Owner: $($f.Owner) | Created: $($f.Created) | Modified: $($f.LastModified)"
    }

    # Removed
    foreach ($removedPath in $prevByPath.Keys | Where-Object { -not $currByPath.ContainsKey($_) -and -not $movedPairs.ContainsKey($_) }) {
        $f = $prevByPath[$removedPath]
        $logContent += "[Removed] '$($f.Path)' | Owner: $($f.Owner) | Created: $($f.Created) | Modified: $($f.LastModified)"
    }
    
    # === Detect file content or metadata changes ===
    foreach ($path in $prevByPath.Keys | Where-Object { $currByPath.ContainsKey($_) -and -not $movedPairs.ContainsKey($_) }) {
        $old = $prevByPath[$path]
        $new = $currByPath[$path]

        $changes = @()

        if ($old.Owner -ne $new.Owner) {
            $changes += "Owner: $($old.Owner) → $($new.Owner)"
        }
        if ($old.Created -ne $new.Created) {
            $changes += "Created: $($old.Created) → $($new.Created)"
        }
        if ($old.LastModified -ne $new.LastModified) {
            $changes += "Modified: $($old.LastModified) → $($new.LastModified)"
        }

        if ($changes.Count -gt 0) {
            try {
                $actualHash = (Get-FileHash -Path $new.Path -Algorithm MD5).Hash
                if ($actualHash -ne $old.Hash) {
                    $logContent += "[Changed] '$($new.Path)'"
                    foreach ($c in $changes) {
                        $logContent += "          $c"
                    }
                    $logContent += "          Hash: $($old.Hash) → $actualHash"
                }
            } catch {
                $logContent += "[Changed] '$($new.Path)' - Metadata changed but unable to retrieve hash"
                foreach ($c in $changes) {
                    $logContent += "          $c"
                }
            }
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

    # === Detect and log duplicate files by hash ===
    $hashGroups = $currentSnapshot | Group-Object -Property Hash | Where-Object { $_.Count -gt 1 }

    if ($hashGroups.Count -gt 0) {
        "`n[Duplicate Files by Hash Detected]" | Add-Content $logFile
        Write-Host "`n[Duplicate Files by Hash Detected]"

        foreach ($group in $hashGroups) {
            "`nDuplicate Hash: $($group.Name)" | Add-Content $logFile
            Write-Host "`nDuplicate Hash: $($group.Name)"
            foreach ($file in $group.Group) {
                $line = " - $($file.Path) | Owner: $($file.Owner) | Created: $($file.Created) | Modified: $($file.LastModified)"
                $line | Add-Content $logFile
                Write-Host $line
            }
        }
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
