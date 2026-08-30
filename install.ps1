#
# Switchrail installer for PowerShell
# https://github.com/nekstep/switchrail-releases
#
# Env: SWITCHRAIL_VERSION, SWITCHRAIL_BIN_DIR
#
# Usage:
#   irm https://raw.githubusercontent.com/nekstep/switchrail-releases/main/install.ps1 | iex
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/nekstep/switchrail-releases/main/install.ps1))) -Version 0.1.42
#   $env:SWITCHRAIL_VERSION="0.1.42"; irm https://raw.githubusercontent.com/nekstep/switchrail-releases/main/install.ps1 | iex
#   $env:SWITCHRAIL_BIN_DIR="$HOME\bin"; irm https://raw.githubusercontent.com/nekstep/switchrail-releases/main/install.ps1 | iex
#

param(
    [Parameter(Position = 0)]
    [string]$Version
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 can otherwise negotiate older TLS versions.
[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Invoke-WebRequest's built-in progress UI is very slow on Windows PowerShell 5.1.
$ProgressPreference = 'SilentlyContinue'

# Useful with `irm ... | iex`, where passing script parameters is awkward.
if (-not $Version -and $env:SWITCHRAIL_VERSION) {
    $Version = $env:SWITCHRAIL_VERSION
}

# This installer intentionally installs the native Windows binary only.
# Windows PowerShell 5.1 does not expose $PSVersionTable.Platform.
if ($PSVersionTable.Platform -and $PSVersionTable.Platform -ne 'Win32NT') {
    Write-Error 'This installer is for Windows. On macOS/Linux, use install.sh.'
    exit 1
}

if (-not $env:USERPROFILE) {
    Write-Error 'USERPROFILE is not set.'
    exit 1
}

$Repo = 'nekstep/switchrail-releases'
$SwitchrailDir = Join-Path $env:USERPROFILE '.switchrail'
$BinDir = if ($env:SWITCHRAIL_BIN_DIR) {
    [Environment]::ExpandEnvironmentVariables($env:SWITCHRAIL_BIN_DIR)
} else {
    Join-Path $SwitchrailDir 'bin'
}

# --- Helpers ---

function Download-File([string]$Url, [string]$OutFile) {
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = 'GET'
    $request.Timeout = 300000
    $request.ReadWriteTimeout = 300000
    $request.AllowAutoRedirect = $true
    $request.UserAgent = 'switchrail-installer'
    $request.AutomaticDecompression =
        [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate

    $response = $null
    $stream = $null
    $fileStream = $null

    try {
        $response = $request.GetResponse()
        $totalBytes = $response.ContentLength
        $stream = $response.GetResponseStream()
        $fileStream = [System.IO.File]::Create($OutFile)

        $buffer = New-Object byte[] 65536
        $totalRead = [int64]0
        $lastPercent = -1
        $lastMb = -1

        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fileStream.Write($buffer, 0, $read)
            $totalRead += $read
            $mb = [math]::Round($totalRead / 1MB, 1)

            if ($totalBytes -gt 0) {
                $percent = [math]::Min(100, [math]::Floor(($totalRead / $totalBytes) * 100))
                if ($percent -ne $lastPercent) {
                    $totalMb = [math]::Round($totalBytes / 1MB, 1)
                    Write-Host "`r  Downloading... ${mb} MB / ${totalMb} MB (${percent}%)" -NoNewline
                    $lastPercent = $percent
                }
            } elseif ($mb -ne $lastMb) {
                Write-Host "`r  Downloading... ${mb} MB" -NoNewline
                $lastMb = $mb
            }
        }

        Write-Host ''
    } finally {
        if ($fileStream) { $fileStream.Dispose() }
        if ($stream) { $stream.Dispose() }
        if ($response) { $response.Dispose() }
    }
}

function Try-DownloadFile([string]$Url, [string]$OutFile) {
    try {
        Download-File $Url $OutFile
        return $true
    } catch {
        if (Test-Path $OutFile) {
            Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
}

function Get-LatestReleaseTag([string]$Repository) {
    $url = "https://api.github.com/repos/$Repository/releases/latest"
    $request = [System.Net.HttpWebRequest]::Create($url)
    $request.Method = 'GET'
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 30000
    $request.AllowAutoRedirect = $true
    $request.UserAgent = 'switchrail-installer'
    $request.Accept = 'application/vnd.github+json'
    $request.AutomaticDecompression =
        [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate

    $response = $null
    $stream = $null
    $reader = $null

    try {
        $response = $request.GetResponse()
        $stream = $response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $release = ($reader.ReadToEnd() | ConvertFrom-Json)
        $tag = [string]$release.tag_name
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($stream) { $stream.Dispose() }
        if ($response) { $response.Dispose() }
    }

    if (-not $tag -or $tag -notmatch '^v?\d+\.\d+\.\d+(-[A-Za-z0-9._-]+)?$') {
        throw "GitHub returned an invalid latest release tag: $tag"
    }

    return $tag
}

function Get-InstalledVersion([string]$PreferredPath, [string]$CommandName) {
    $candidates = @()
    if (Test-Path -LiteralPath $PreferredPath -PathType Leaf) {
        $candidates += $PreferredPath
    }

    $command = Get-Command $CommandName -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command -and $command.Source -and $command.Source -ne $PreferredPath) {
        $candidates += $command.Source
    }

    foreach ($candidate in $candidates) {
        try {
            $output = @(& $candidate --version 2>$null)
            if ($LASTEXITCODE -eq 0) {
                $text = ($output -join ' ').Trim()
                if ($text) {
                    return [pscustomobject]@{ Path = $candidate; Version = $text }
                }
            }
        } catch {
            # Keep looking: an older or damaged binary may not support --version.
        }
    }

    if ($candidates.Count -gt 0) {
        return [pscustomobject]@{ Path = $candidates[0]; Version = 'version unavailable' }
    }

    return $null
}

function Add-ToUserPath([string]$Directory) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $pathEntries = if ($userPath) {
        @($userPath -split ';' | Where-Object { $_ -and $_.Trim() -ne '' })
    } else {
        @()
    }

    $normalizedDirectory = $Directory.TrimEnd('\')
    $alreadyPresent = $false

    foreach ($entry in $pathEntries) {
        $expanded = [Environment]::ExpandEnvironmentVariables($entry).TrimEnd('\')
        if ($expanded -ieq $normalizedDirectory) {
            $alreadyPresent = $true
            break
        }
    }

    if (-not $alreadyPresent) {
        $newPath = (@($Directory) + $pathEntries) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        Write-Host "  Added $Directory to your User PATH." -ForegroundColor DarkGray
    }

    # Make it available in this PowerShell session immediately as well.
    $sessionEntries = @($env:Path -split ';')
    $sessionPresent = $false
    foreach ($entry in $sessionEntries) {
        if ($entry.TrimEnd('\') -ieq $normalizedDirectory) {
            $sessionPresent = $true
            break
        }
    }
    if (-not $sessionPresent) {
        $env:Path = "$Directory;$env:Path"
    }
}

# --- Validate version ---

if ($Version -and $Version -notmatch '^v?\d+\.\d+\.\d+(-[A-Za-z0-9._-]+)?$') {
    Write-Error "Invalid version format: $Version (expected X.Y.Z, vX.Y.Z, or prerelease suffix)"
    exit 1
}

# --- Detect native Windows architecture ---

# PROCESSOR_ARCHITEW6432 contains the native architecture when a 32-bit process
# runs under 64-bit Windows. Prefer it when available.
$nativeArch = if ($env:PROCESSOR_ARCHITEW6432) {
    $env:PROCESSOR_ARCHITEW6432
} else {
    $env:PROCESSOR_ARCHITECTURE
}

$arch = switch ($nativeArch.ToUpperInvariant()) {
    'AMD64' { 'amd64' }
    'ARM64' { 'arm64' }
    'X86'   { $null }
    default { $null }
}

if (-not $arch) {
    Write-Error "Unsupported Windows architecture: $nativeArch. Switchrail requires 64-bit Windows."
    exit 1
}

$binaryName = 'switchrail.exe'
$dest = Join-Path $BinDir $binaryName
$aliasName = 'swr.exe'
$aliasDest = Join-Path $BinDir $aliasName

# A previous installer-created alias is byte-identical to switchrail.exe. Do
# not overwrite an unrelated swr.exe when a custom bin directory is used.
if (Test-Path -LiteralPath $aliasDest) {
    if (-not (Test-Path -LiteralPath $aliasDest -PathType Leaf)) {
        Write-Error "Refusing to replace existing $aliasDest because it is not a file."
        exit 1
    }
    if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) {
        Write-Error "Refusing to replace existing $aliasDest because switchrail.exe is not installed beside it."
        exit 1
    }

    $primaryHash = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
    $aliasHash = (Get-FileHash -LiteralPath $aliasDest -Algorithm SHA256).Hash
    if ($primaryHash -ne $aliasHash) {
        Write-Error "Refusing to replace existing $aliasDest because it is not the installed Switchrail binary."
        exit 1
    }
}

# --- Report currently installed version ---

$installedVersion = Get-InstalledVersion $dest $binaryName
if ($installedVersion) {
    Write-Host "Installed: $($installedVersion.Version)" -ForegroundColor DarkGray
    Write-Host "  $($installedVersion.Path)" -ForegroundColor DarkGray
} else {
    Write-Host 'Installed: not found' -ForegroundColor DarkGray
}

# --- Resolve release URL ---

if ($Version) {
    $normalizedVersion = $Version -replace '^v', ''
    $tag = "v$normalizedVersion"
    $releaseBase = "https://github.com/$Repo/releases/download/$tag"
    $displayVersion = $tag
} else {
    try {
        $tag = Get-LatestReleaseTag $Repo
    } catch {
        Write-Error "Cannot resolve the latest Switchrail release: $($_.Exception.Message)"
        exit 1
    }
    $releaseBase = "https://github.com/$Repo/releases/download/$tag"
    $displayVersion = $tag
}

$archive_version = $displayVersion -replace '^v', ''
$archive = "switchrail_{$archive_version}_windows_${arch}.zip"

# --- Prepare temporary files ---

New-Item -ItemType Directory -Path $SwitchrailDir -Force | Out-Null
New-Item -ItemType Directory -Path $BinDir -Force | Out-Null

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("switchrail-install-" + [Guid]::NewGuid().ToString('N'))
$extractDir = Join-Path $tempRoot 'extract'
$archivePath = Join-Path $tempRoot $archive
$checksumsPath = Join-Path $tempRoot 'checksums.txt'

New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

try {
    # --- Download release asset ---

    Write-Host "Downloading: Switchrail $displayVersion (windows/$arch)" -ForegroundColor Cyan
    Write-Host "  Downloading $archive..." -ForegroundColor DarkGray

    $archiveUrl = "$releaseBase/$archive"
    if (-not (Try-DownloadFile $archiveUrl $archivePath)) {
        Write-Error "Release asset not found or download failed: $archiveUrl"
        exit 1
    }

    # --- Verify GoReleaser checksum when available ---

    $checksumsUrl = "$releaseBase/checksums.txt"
    if (Try-DownloadFile $checksumsUrl $checksumsPath) {
        $expected = $null

        foreach ($line in Get-Content $checksumsPath) {
            # GoReleaser normally writes: <sha256><whitespace><filename>
            if ($line -match '^([0-9A-Fa-f]{64})\s+\*?(.+?)\s*$') {
                $checksumFile = $Matches[2]
                if ($checksumFile -eq $archive) {
                    $expected = $Matches[1].ToLowerInvariant()
                    break
                }
            }
        }

        if (-not $expected) {
            Write-Error "$archive is missing from checksums.txt"
            exit 1
        }

        $actual = (Get-FileHash -Path $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            Write-Error "Checksum mismatch for $archive"
            exit 1
        }

        Write-Host '  Checksum verified.' -ForegroundColor DarkGray
    } else {
        Write-Host '  Warning: checksums.txt not found; continuing without checksum verification.' -ForegroundColor Yellow
    }

    # --- Extract archive ---

    Expand-Archive -Path $archivePath -DestinationPath $extractDir -Force

    $binary = Get-ChildItem -Path $extractDir -Filter $binaryName -File -Recurse |
        Select-Object -First 1

    if (-not $binary) {
        Write-Error "$binaryName not found inside $archive"
        exit 1
    }

    # --- Install binary (locked-file safe) ---

    $new = "$dest.new.$PID"
    $old = "$dest.old"
    $aliasNew = "$aliasDest.new.$PID"
    $aliasOld = "$aliasDest.old"

    Remove-Item -LiteralPath $new -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $aliasNew -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $aliasOld -Force -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath $binary.FullName -Destination $new -Force
    Copy-Item -LiteralPath $binary.FullName -Destination $aliasNew -Force

    $movedOld = $false
    $movedAliasOld = $false
    $installedNew = $false
    $installedAliasNew = $false
    try {
        if (Test-Path -LiteralPath $aliasDest) {
            Move-Item -LiteralPath $aliasDest -Destination $aliasOld -Force
            $movedAliasOld = $true
        }
        if (Test-Path -LiteralPath $dest) {
            Move-Item -LiteralPath $dest -Destination $old -Force
            $movedOld = $true
        }

        Move-Item -LiteralPath $new -Destination $dest -Force
        $installedNew = $true
        Move-Item -LiteralPath $aliasNew -Destination $aliasDest -Force
        $installedAliasNew = $true
    } catch {
        $installError = $_.Exception.Message
        if ($installedAliasNew) {
            Remove-Item -LiteralPath $aliasDest -Force -ErrorAction SilentlyContinue
        }
        if ($installedNew) {
            Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
        }
        if ($movedOld -and (Test-Path -LiteralPath $old) -and -not (Test-Path -LiteralPath $dest)) {
            Move-Item -LiteralPath $old -Destination $dest -Force -ErrorAction SilentlyContinue
        }
        if ($movedAliasOld -and (Test-Path -LiteralPath $aliasOld) -and -not (Test-Path -LiteralPath $aliasDest)) {
            Move-Item -LiteralPath $aliasOld -Destination $aliasDest -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $new -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $aliasNew -Force -ErrorAction SilentlyContinue
        Write-Error "Cannot update switchrail.exe and swr.exe. Stop Switchrail and retry. $installError"
        exit 1
    }

    Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $aliasOld -Force -ErrorAction SilentlyContinue

    Write-Host "Switchrail installed to $dest" -ForegroundColor Green
    Write-Host "Short command installed to $aliasDest" -ForegroundColor Green

    # --- Ensure switchrail is on PATH ---

    Add-ToUserPath $BinDir

    Write-Host ''
    Write-Host "Run 'switchrail' or 'swr' to get started!" -ForegroundColor Cyan
} finally {
    if (Test-Path $tempRoot) {
        Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
