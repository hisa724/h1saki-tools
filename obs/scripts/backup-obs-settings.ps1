#requires -Version 5.1

<#
.SYNOPSIS
Backs up OBS Studio settings on Windows to a timestamped ZIP file.

.DESCRIPTION
Copies the OBS Studio configuration directory to a temporary staging directory,
then creates a ZIP archive. OBS must be closed by default so the backup is
internally consistent.

.PARAMETER DestinationPath
Directory in which the ZIP file is created. The default is
Documents\OBS-Backups.

.PARAMETER SourcePath
OBS Studio configuration directory. The default is %APPDATA%\obs-studio.
This parameter is mainly intended for portable OBS installations and testing.

.PARAMETER AllowWhileObsRunning
Allows a backup while OBS is running. This can produce an inconsistent backup
and is not recommended.

.EXAMPLE
.\backup-obs-settings.ps1

.EXAMPLE
.\backup-obs-settings.ps1 -DestinationPath "D:\Backups\OBS"

.EXAMPLE
.\backup-obs-settings.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationPath = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'OBS-Backups'),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SourcePath = (Join-Path $env:APPDATA 'obs-studio'),

    [Parameter()]
    [switch]$AllowWhileObsRunning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsPathInside {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CandidatePath,

        [Parameter(Mandatory = $true)]
        [string]$ParentPath
    )

    $candidateFullPath = [System.IO.Path]::GetFullPath($CandidatePath).TrimEnd('\')
    $parentFullPath = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd('\')
    return (
        $candidateFullPath.Equals($parentFullPath, [System.StringComparison]::OrdinalIgnoreCase) -or
        $candidateFullPath.StartsWith(
            $parentFullPath + '\',
            [System.StringComparison]::OrdinalIgnoreCase
        )
    )
}

if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
    throw "OBS settings were not found: $SourcePath"
}

$obsProcesses = @(Get-Process -Name 'obs64', 'obs32' -ErrorAction SilentlyContinue)
if ($obsProcesses.Count -gt 0 -and -not $AllowWhileObsRunning) {
    throw 'OBS Studio is running. Close OBS and run the backup again. Use -AllowWhileObsRunning only if you accept the risk of an inconsistent backup.'
}

if (Test-IsPathInside -CandidatePath $DestinationPath -ParentPath $SourcePath) {
    throw 'DestinationPath must not be inside the OBS settings directory.'
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$archiveName = "obs-settings-$timestamp.zip"
$archivePath = Join-Path $DestinationPath $archiveName
$suffix = 1

while (Test-Path -LiteralPath $archivePath) {
    $archiveName = "obs-settings-$timestamp-$suffix.zip"
    $archivePath = Join-Path $DestinationPath $archiveName
    $suffix++
}

if (-not $PSCmdlet.ShouldProcess($archivePath, "Back up OBS settings from '$SourcePath'")) {
    return
}

$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("h1saki-obs-backup-" + [guid]::NewGuid().ToString('N'))
$stagingContent = Join-Path $stagingRoot 'obs-studio'

try {
    New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

    Write-Host 'Copying OBS settings...'
    Copy-Item -LiteralPath $SourcePath -Destination $stagingContent -Recurse -Force

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Write-Host 'Creating ZIP archive...'
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $stagingContent,
        $archivePath,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )

    $archive = Get-Item -LiteralPath $archivePath
    if ($archive.Length -le 0) {
        throw 'The backup ZIP was created but is empty.'
    }

    Write-Host ''
    Write-Host 'OBS settings backup completed.' -ForegroundColor Green
    Write-Host "Backup: $($archive.FullName)"
    Write-Host ("Size: {0:N2} MB" -f ($archive.Length / 1MB))
    Write-Warning 'This ZIP may contain stream keys, service tokens, and OBS WebSocket credentials. Do not upload or share it.'
}
catch {
    if (Test-Path -LiteralPath $archivePath) {
        Remove-Item -LiteralPath $archivePath -Force
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}
