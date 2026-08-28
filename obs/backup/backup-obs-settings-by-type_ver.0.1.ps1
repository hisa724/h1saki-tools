#requires -Version 5.1

<#
.SYNOPSIS
OBS Studioの設定を、音声・マイク・録画・配信に分けてバックアップします。

.DESCRIPTION
現在選択中のプロファイルとシーンコレクションから、指定した種類の設定だけを
抽出し、日時付きZIPへ保存します。OBS起動中は実行できません。

.PARAMETER Category
Audio、Microphone、Recording、Streaming、Allから選択します。

.PARAMETER DestinationPath
ZIPの保存先です。標準では、このスクリプトと同じフォルダへ保存します。
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter()]
    [ValidateSet('Audio', 'Microphone', 'Recording', 'Streaming', 'All')]
    [string]$Category,

    [Parameter()]
    [string]$DestinationPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptVersion = '0.1'
$simulationOnly = [bool]$WhatIfPreference
$WhatIfPreference = $false

Write-Host "OBS種類別設定バックアップ ver.$ScriptVersion"
Write-Host ''

if ([string]::IsNullOrWhiteSpace($Category)) {
    Write-Host '1. 音声設定'
    Write-Host '2. マイク設定'
    Write-Host '3. 録画設定'
    Write-Host '4. 配信設定'
    Write-Host '5. すべて個別にバックアップ'
    Write-Host ''
    $choice = Read-Host '番号を入力してください (1-5)'
    $Category = switch ($choice) {
        '1' { 'Audio' }
        '2' { 'Microphone' }
        '3' { 'Recording' }
        '4' { 'Streaming' }
        '5' { 'All' }
        default { throw '入力が正しくありません。1から5の番号を入力してください。' }
    }
    Write-Host ''
}

if (@(Get-Process -Name 'obs64', 'obs32' -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'OBS Studioが起動中です。OBSを完全に終了してから、もう一度実行してください。'
}

if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
    $DestinationPath = $PSScriptRoot
}
$DestinationPath = [System.IO.Path]::GetFullPath($DestinationPath)

$obsConfigRoot = Join-Path $env:APPDATA 'obs-studio'
$userIniPath = Join-Path $obsConfigRoot 'user.ini'
if (-not (Test-Path -LiteralPath $userIniPath -PathType Leaf)) {
    throw "OBSのユーザー設定が見つかりません: $userIniPath"
}

function Get-IniSelectionValue {
    param([Parameter(Mandatory = $true)][string]$Key)

    $line = Get-Content -LiteralPath $userIniPath -Encoding UTF8 |
        Where-Object { $_ -match ('^' + [regex]::Escape($Key) + '=(.+)$') } |
        Select-Object -First 1
    if ($null -eq $line -or $line -notmatch ('^' + [regex]::Escape($Key) + '=(.+)$')) {
        throw "OBSの現在値を特定できません: $Key"
    }
    return $matches[1]
}

function Read-IniSections {
    param([Parameter(Mandatory = $true)][string]$Path)

    $result = [ordered]@{}
    $currentSection = $null
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ($line -match '^\[(.+)\]$') {
            $currentSection = $matches[1]
            if (-not $result.Contains($currentSection)) {
                $result[$currentSection] = [ordered]@{}
            }
            continue
        }
        if ($null -ne $currentSection -and $line -match '^([^=]+)=(.*)$') {
            $result[$currentSection][$matches[1]] = $matches[2]
        }
    }
    return $result
}

function Select-Keys {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Values,
        [Parameter(Mandatory = $true)][string]$Pattern
    )

    $selected = [ordered]@{}
    foreach ($key in $Values.Keys) {
        if ([string]$key -match $Pattern) {
            $selected[$key] = $Values[$key]
        }
    }
    return $selected
}

function Read-JsonIfPresent {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

$profileDirectoryName = Get-IniSelectionValue -Key 'ProfileDir'
$sceneCollectionFile = Get-IniSelectionValue -Key 'SceneCollectionFile'
$profilePath = Join-Path $obsConfigRoot ("basic\profiles\" + $profileDirectoryName)
$scenePath = Join-Path $obsConfigRoot ("basic\scenes\" + $sceneCollectionFile)
$basicIniPath = Join-Path $profilePath 'basic.ini'

foreach ($requiredPath in @($profilePath, $scenePath, $basicIniPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "必要なOBS設定が見つかりません: $requiredPath"
    }
}

$ini = Read-IniSections -Path $basicIniPath
$scene = Read-JsonIfPresent -Path $scenePath
$recordEncoder = Read-JsonIfPresent -Path (Join-Path $profilePath 'recordEncoder.json')
$streamEncoder = Read-JsonIfPresent -Path (Join-Path $profilePath 'streamEncoder.json')
$service = Read-JsonIfPresent -Path (Join-Path $profilePath 'service.json')

function Get-SettingsSnapshot {
    param([Parameter(Mandatory = $true)][string]$SnapshotCategory)

    switch ($SnapshotCategory) {
        'Audio' {
            return [ordered]@{
                Audio = $ini['Audio']
                TrackSettings = Select-Keys -Values $ini['AdvOut'] -Pattern '^(Track[1-6](Bitrate|Name)|AudioEncoder|RecAudioEncoder|FFABitrate|FFAudioMixes)$'
                DesktopAudioDevice = $scene.DesktopAudioDevice1
            }
        }
        'Microphone' {
            return [ordered]@{
                Microphone = $scene.AuxAudioDevice1
            }
        }
        'Recording' {
            return [ordered]@{
                Output = Select-Keys -Values $ini['Output'] -Pattern '^(Mode|FilenameFormatting)$'
                Recording = Select-Keys -Values $ini['AdvOut'] -Pattern '^(Rec|FF|Track[1-6](Bitrate|Name))'
                Video = $ini['Video']
                RecordEncoder = $recordEncoder
            }
        }
        'Streaming' {
            return [ordered]@{
                Output = Select-Keys -Values $ini['Output'] -Pattern '^(Mode|Delay|Reconnect|RetryDelay|MaxRetries|BindIP|IPFamily|NewSocketLoopEnable|LowLatencyEnable)'
                Streaming = Select-Keys -Values $ini['AdvOut'] -Pattern '^(ApplyServiceSettings|UseRescale|TrackIndex|VodTrackIndex|Encoder|StreamMultiTrackAudioMixes|AudioEncoder)$'
                StreamEncoder = $streamEncoder
                Service = $service
            }
        }
        default {
            throw "未対応の設定種類です: $SnapshotCategory"
        }
    }
}

function New-SettingsBackup {
    param([Parameter(Mandatory = $true)][string]$SnapshotCategory)

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $archivePath = Join-Path $DestinationPath "obs-settings-$($SnapshotCategory.ToLowerInvariant())-$timestamp.zip"
    $suffix = 1
    while (Test-Path -LiteralPath $archivePath) {
        $archivePath = Join-Path $DestinationPath "obs-settings-$($SnapshotCategory.ToLowerInvariant())-$timestamp-$suffix.zip"
        $suffix++
    }

    Write-Host "対象: $SnapshotCategory"
    Write-Host "保存先: $archivePath"

    if ($simulationOnly) {
        Write-Host 'シミュレーションのため、ZIPは作成しません。'
        Write-Host ''
        return
    }

    if (-not $PSCmdlet.ShouldProcess($archivePath, "$SnapshotCategory 設定をバックアップ")) {
        return
    }

    $stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("h1saki-obs-settings-type-" + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
        New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null

        $snapshot = [ordered]@{
            FormatVersion = '1'
            ToolVersion = $ScriptVersion
            Category = $SnapshotCategory
            CreatedAt = (Get-Date).ToString('o')
            Profile = $profileDirectoryName
            SceneCollection = $sceneCollectionFile
            Settings = Get-SettingsSnapshot -SnapshotCategory $SnapshotCategory
        }
        $snapshot | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $stageRoot 'settings.json') -Encoding UTF8

        $warningText = if ($SnapshotCategory -eq 'Streaming') {
            '配信設定バックアップには配信キーやサービストークンが含まれる可能性があります。公開・共有は禁止です。'
        }
        elseif ($SnapshotCategory -eq 'Microphone') {
            'マイク設定にはデバイスID、フィルター、音量、ミュート、モニタリング設定が含まれます。'
        }
        else {
            'このZIPはOBS設定の復元目的だけに使用し、公開・共有しないでください。'
        }
        [IO.File]::WriteAllText((Join-Path $stageRoot '注意事項.txt'), $warningText, [Text.UTF8Encoding]::new($true))

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($stageRoot, $archivePath, [IO.Compression.CompressionLevel]::Optimal, $false)
        $zip = Get-Item -LiteralPath $archivePath
        if ($zip.Length -le 0) {
            throw '作成されたZIPの容量が0バイトです。'
        }
        Write-Host "完了: $($zip.FullName)" -ForegroundColor Green
        Write-Host ''
    }
    catch {
        if (Test-Path -LiteralPath $archivePath) {
            Remove-Item -LiteralPath $archivePath -Force
        }
        throw
    }
    finally {
        if (Test-Path -LiteralPath $stageRoot) {
            $resolvedStage = (Resolve-Path -LiteralPath $stageRoot).Path
            $expectedPrefix = [IO.Path]::GetTempPath().TrimEnd('\') + '\h1saki-obs-settings-type-'
            if (-not $resolvedStage.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "一時フォルダの安全確認に失敗しました: $resolvedStage"
            }
            Remove-Item -LiteralPath $resolvedStage -Recurse -Force
        }
    }
}

$selectedCategories = if ($Category -eq 'All') { @('Audio', 'Microphone', 'Recording', 'Streaming') } else { @($Category) }
foreach ($selectedCategory in $selectedCategories) {
    New-SettingsBackup -SnapshotCategory $selectedCategory
}

if ($simulationOnly) {
    Write-Host 'シミュレーション結果: 種類別バックアップを作成できます。実際のZIPは作成していません。' -ForegroundColor Green
}
else {
    Write-Warning '作成したZIPにはデバイス情報や認証情報が含まれる可能性があります。公開・共有しないでください。'
}
