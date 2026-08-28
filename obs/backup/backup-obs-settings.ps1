#requires -Version 5.1

<#
.SYNOPSIS
Windows版OBS Studioの設定を、日時付きZIPファイルへバックアップします。

.DESCRIPTION
OBS Studioの設定フォルダを一時作業フォルダへコピーし、復元に不要な
キャッシュやログを除外してからZIPを作成します。設定の整合性を守るため、
標準ではOBSを終了していないと実行できません。

.PARAMETER DestinationPath
ZIPファイルの保存先です。標準では、このスクリプトが置かれている
フォルダへ保存します。

.PARAMETER SourcePath
OBS Studioの設定フォルダです。標準は %APPDATA%\obs-studio です。
主にポータブル版OBSや動作試験で使用します。

.PARAMETER AllowWhileObsRunning
OBS起動中のバックアップを許可します。不完全なバックアップになる可能性が
あるため、通常は指定しないでください。

.PARAMETER IncludeTransientData
ブラウザキャッシュ、ログ、クラッシュ記録、プロファイラーデータ、更新用
ファイルも含めます。これらは設定の復元に不要で容量を大きくするため、
標準では除外します。

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
    [string]$DestinationPath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SourcePath = (Join-Path $env:APPDATA 'obs-studio'),

    [Parameter()]
    [switch]$AllowWhileObsRunning,

    [Parameter()]
    [switch]$IncludeTransientData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
    $DestinationPath = $PSScriptRoot
}

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
    throw "OBSの設定フォルダが見つかりません: $SourcePath"
}

$obsProcesses = @(Get-Process -Name 'obs64', 'obs32' -ErrorAction SilentlyContinue)
if ($obsProcesses.Count -gt 0 -and -not $AllowWhileObsRunning) {
    throw 'OBS Studioが起動中です。OBSを完全に終了してから、もう一度実行してください。-AllowWhileObsRunning は不完全なバックアップになる危険を承知した場合だけ使用してください。'
}

if (Test-IsPathInside -CandidatePath $DestinationPath -ParentPath $SourcePath) {
    throw '保存先はOBSの設定フォルダと同じ場所、またはその配下に指定できません。'
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

if (-not $PSCmdlet.ShouldProcess($archivePath, "'$SourcePath' のOBS設定をバックアップ")) {
    return
}

$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("h1saki-obs-backup-" + [guid]::NewGuid().ToString('N'))
$stagingContent = Join-Path $stagingRoot 'obs-studio'

try {
    New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

    Write-Host 'OBS設定をコピーしています...'
    Copy-Item -LiteralPath $SourcePath -Destination $stagingContent -Recurse -Force

    if (-not $IncludeTransientData) {
        Write-Host 'バックアップから不要な一時データを除外しています...'

        $rootTransientDirectories = @(
            'crashes',
            'logs',
            'profiler_data',
            'updates'
        )

        foreach ($directoryName in $rootTransientDirectories) {
            $transientPath = Join-Path $stagingContent $directoryName
            if (Test-Path -LiteralPath $transientPath -PathType Container) {
                Remove-Item -LiteralPath $transientPath -Recurse -Force
            }
        }

        $cacheDirectoryNames = @(
            'Cache',
            'Code Cache',
            'GPUCache',
            'DawnCache',
            'CacheStorage'
        )

        $cacheDirectories = @(
            Get-ChildItem -LiteralPath $stagingContent -Directory -Recurse -Force |
                Where-Object { $cacheDirectoryNames -contains $_.Name } |
                Sort-Object { $_.FullName.Length } -Descending
        )

        foreach ($cacheDirectory in $cacheDirectories) {
            if (Test-Path -LiteralPath $cacheDirectory.FullName -PathType Container) {
                Remove-Item -LiteralPath $cacheDirectory.FullName -Recurse -Force
            }
        }
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Write-Host 'ZIPファイルを作成しています...'
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $stagingContent,
        $archivePath,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )

    $archive = Get-Item -LiteralPath $archivePath
    if ($archive.Length -le 0) {
        throw 'バックアップZIPは作成されましたが、容量が0バイトです。'
    }

    Write-Host ''
    Write-Host 'OBS設定のバックアップが完了しました。' -ForegroundColor Green
    Write-Host "保存先: $($archive.FullName)"
    Write-Host ("容量: {0:N2} MB" -f ($archive.Length / 1MB))
    Write-Warning 'このZIPには配信キー、サービストークン、OBS WebSocketの認証情報などが含まれる可能性があります。アップロードや共有はしないでください。'
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
