<#
.SYNOPSIS
    Installs the working copy of the mod into the local Factorio mods folder.

.DESCRIPTION
    Packs the repository the same way build.ps1 does, but prefixes the mod
    *title* in info.json with "LOCAL" so a dev build is easy to recognise in
    the in-game mod list. The mod *name* is left untouched: it must match the
    zip name and every __ShoterRailSignalPlanner__ asset path, and saves refer
    to it.

    The result is written to <ModsDir>\ShoterRailSignalPlanner_<version>.zip,
    replacing an existing zip or folder of the same version. Other installed
    versions are reported; pass -RemoveOtherVersions to delete them.

.EXAMPLE
    .\deploy-local.ps1
    .\deploy-local.ps1 -RemoveOtherVersions
    .\deploy-local.ps1 -ModsDir 'D:\Factorio\mods' -Verbose
#>
[CmdletBinding()]
param(
    # Factorio mods folder. Defaults to the standard per-user install location.
    [string]$ModsDir = (Join-Path $env:APPDATA 'Factorio\mods'),

    # Delete other installed versions of this mod (zips and folders).
    [switch]$RemoveOtherVersions,

    # Text placed in front of the title.
    [string]$TitlePrefix = 'LOCAL'
)

$ErrorActionPreference = 'Stop'

# Keep in sync with build.ps1.
$IgnoreDirectories = @(
    'dist'
    '.git'
    '.github'
    '.vscode'
    '.idea'
    'node_modules'
)

$IgnoreFiles = @(
    '*.ps1'
    '.gitignore'
    '.gitattributes'
    '*.zip'
    '*.ps1xml'
    'Thumbs.db'
    '.DS_Store'
)

$RootDir  = $PSScriptRoot
$InfoPath = Join-Path $RootDir 'info.json'

if (-not (Test-Path -LiteralPath $InfoPath)) {
    throw "info.json not found at $InfoPath"
}
if (-not (Test-Path -LiteralPath $ModsDir)) {
    throw "Mods folder not found: $ModsDir (use -ModsDir to point at it)"
}

$info    = Get-Content -LiteralPath $InfoPath -Raw | ConvertFrom-Json
$ModName = "$($info.name)".Trim()
$version = "$($info.version)".Trim()
if (-not $ModName) { throw "No 'name' field found in $InfoPath" }
if (-not $version) { throw "No 'version' field found in $InfoPath" }

function Test-Ignored {
    param([Parameter(Mandatory)][System.IO.FileSystemInfo]$Item)

    $relative = $Item.FullName.Substring($RootDir.Length).TrimStart('\', '/').Replace('\', '/')
    $patterns = if ($Item.PSIsContainer) { $IgnoreDirectories } else { $IgnoreFiles }

    foreach ($pattern in $patterns) {
        if ($Item.Name -like $pattern -or $relative -like $pattern) { return $true }
    }
    return $false
}

function Copy-Tree {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        if (Test-Ignored -Item $item) {
            Write-Verbose "skip   $($item.FullName)"
            continue
        }
        $target = Join-Path $Destination $item.Name
        if ($item.PSIsContainer) {
            Copy-Tree -Source $item.FullName -Destination $target
        }
        else {
            Write-Verbose "add    $($item.FullName)"
            Copy-Item -LiteralPath $item.FullName -Destination $target -Force
        }
    }
}

$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
$stagingMod  = Join-Path $stagingRoot $ModName
$zipName     = "${ModName}_${version}.zip"
$zipPath     = Join-Path $ModsDir $zipName

try {
    Write-Host "Packing $ModName $version for local use ..."
    Copy-Tree -Source $RootDir -Destination $stagingMod

    # Edit the title as text so the rest of info.json keeps its exact formatting.
    $stagedInfo = Join-Path $stagingMod 'info.json'
    $json = [System.IO.File]::ReadAllText($stagedInfo)
    $titlePattern = '("title"\s*:\s*")(?!' + [regex]::Escape($TitlePrefix) + ' )'
    if ($json -notmatch '"title"\s*:') { throw "info.json has no 'title' field to prefix." }
    $json = [regex]::Replace($json, $titlePattern, ('${1}' + $TitlePrefix + ' '), 1)
    [System.IO.File]::WriteAllText($stagedInfo, $json, (New-Object System.Text.UTF8Encoding $false))
    Write-Host "Title  : $(($json | ConvertFrom-Json).title)"

    # Anything with this exact version would clash with the new zip.
    foreach ($same in @($zipPath, (Join-Path $ModsDir "${ModName}_${version}"), (Join-Path $ModsDir $ModName))) {
        if (Test-Path -LiteralPath $same) {
            Write-Host "Replace: $same"
            Remove-Item -LiteralPath $same -Recurse -Force
        }
    }

    Compress-Archive -Path $stagingMod -DestinationPath $zipPath -CompressionLevel Optimal

    $sizeKb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1KB, 1)
    Write-Host "Created $zipPath ($sizeKb KB)" -ForegroundColor Green

    $escaped = [regex]::Escape($ModName)
    $others = Get-ChildItem -LiteralPath $ModsDir -Force | Where-Object {
        $_.FullName -ne $zipPath -and $_.Name -match "^${escaped}_\d+\.\d+\.\d+(\.zip)?$"
    }
    foreach ($other in $others) {
        if ($RemoveOtherVersions) {
            Write-Host "Removed other version: $($other.Name)"
            Remove-Item -LiteralPath $other.FullName -Recurse -Force
        }
        else {
            Write-Warning "Other version still installed: $($other.Name) (Factorio loads the highest version; use -RemoveOtherVersions to delete)"
        }
    }
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}
