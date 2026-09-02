#requires -Version 5.1

<#
.SYNOPSIS
OBS Studioのマイクへ、ゲーム実況向けの基準フィルター設定を適用します。

.DESCRIPTION
現在のシーンコレクションにある「マイク」へ、ノイズ抑制、エキスパンダー、
3バンドEQ、ゲイン、コンプレッサー、リミッターを設定します。適用前に
シーンJSONとプロファイル設定を日付付きで退避します。OBS起動中は実行できません。

.PARAMETER GainDb
OBSフィルターで追加するゲインです。標準は +3 dBです。

.PARAMETER ExpanderThreshold
エキスパンダーのしきい値です。標準は -40 dBです。

.PARAMETER CompressorThreshold
コンプレッサーのしきい値です。標準は -18 dBです。

.PARAMETER ConfigRoot
OBS Studioの設定フォルダです。標準は %APPDATA%\obs-studio です。
主にポータブル版OBSまたは隔離テストで指定します。

.PARAMETER TestMode
隔離テスト用です。ConfigRootがWindowsの一時フォルダ内にある場合だけ、
OBSプロセスの確認を省略します。実環境の設定には使用できません。

.EXAMPLE
.\configure-microphone_ver.0.1.ps1 -WhatIf

.EXAMPLE
.\configure-microphone_ver.0.1.ps1 -GainDb 3 -ExpanderThreshold -40 -CompressorThreshold -18
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter()][ValidateRange(-30, 30)][double]$GainDb = 3,
    [Parameter()][ValidateRange(-60, -10)][double]$ExpanderThreshold = -40,
    [Parameter()][ValidateRange(-60, -1)][double]$CompressorThreshold = -18,
    [Parameter()][ValidateNotNullOrEmpty()][string]$ConfigRoot = (Join-Path $env:APPDATA 'obs-studio'),
    [Parameter()][switch]$TestMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptVersion = '0.1'
$simulationOnly = [bool]$WhatIfPreference
$WhatIfPreference = $false

Write-Host "OBSマイク設定 ver.$ScriptVersion"
Write-Host ''

function Test-IsPathInside {
    param(
        [Parameter(Mandatory = $true)][string]$CandidatePath,
        [Parameter(Mandatory = $true)][string]$ParentPath
    )

    $candidateFull = [IO.Path]::GetFullPath($CandidatePath).TrimEnd('\')
    $parentFull = [IO.Path]::GetFullPath($ParentPath).TrimEnd('\')
    return (
        $candidateFull.Equals($parentFull, [StringComparison]::OrdinalIgnoreCase) -or
        $candidateFull.StartsWith($parentFull + '\', [StringComparison]::OrdinalIgnoreCase)
    )
}

$obsConfigRoot = [IO.Path]::GetFullPath($ConfigRoot)
if ($TestMode -and -not (Test-IsPathInside -CandidatePath $obsConfigRoot -ParentPath ([IO.Path]::GetTempPath()))) {
    throw 'TestModeの設定先はWindowsの一時フォルダ内に限定されます。'
}

if (-not $TestMode -and @(Get-Process -Name 'obs64', 'obs32' -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'OBS Studioが起動中です。OBSを完全に終了してから、もう一度実行してください。'
}

$userIniPath = Join-Path $obsConfigRoot 'user.ini'
if (-not (Test-Path -LiteralPath $userIniPath -PathType Leaf)) {
    throw "OBSのユーザー設定が見つかりません: $userIniPath"
}

function Get-SelectionValue {
    param([Parameter(Mandatory = $true)][string]$Key)

    $line = Get-Content -LiteralPath $userIniPath -Encoding UTF8 |
        Where-Object { $_ -match ('^' + [regex]::Escape($Key) + '=(.+)$') } |
        Select-Object -First 1
    if ($null -eq $line -or $line -notmatch ('^' + [regex]::Escape($Key) + '=(.+)$')) {
        throw "OBSの現在値を特定できません: $Key"
    }
    return $matches[1]
}

function Set-IniValue {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Lines,
        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $sectionStart = -1
    $sectionEnd = $Lines.Count
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match '^\[(.+)\]$') {
            if ($sectionStart -ge 0) {
                $sectionEnd = $index
                break
            }
            if ($matches[1].Equals($Section, [StringComparison]::OrdinalIgnoreCase)) {
                $sectionStart = $index
            }
        }
    }

    if ($sectionStart -lt 0) {
        if ($Lines.Count -gt 0 -and $Lines[$Lines.Count - 1] -ne '') { $Lines.Add('') }
        $Lines.Add("[$Section]")
        $Lines.Add("$Key=$Value")
        return
    }

    for ($index = $sectionStart + 1; $index -lt $sectionEnd; $index++) {
        if ($Lines[$index] -match ('^' + [regex]::Escape($Key) + '=')) {
            $Lines[$index] = "$Key=$Value"
            return
        }
    }
    $Lines.Insert($sectionEnd, "$Key=$Value")
}

function New-FilterObject {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$VersionedId,
        [Parameter(Mandatory = $true)][object]$Settings,
        [Parameter(Mandatory = $true)][int64]$PreviousVersion
    )

    return [PSCustomObject][ordered]@{
        prev_ver = $PreviousVersion
        name = $Name
        uuid = [guid]::NewGuid().ToString()
        id = $Id
        versioned_id = $VersionedId
        settings = $Settings
        mixers = 255
        sync = 0
        flags = 0
        volume = 1.0
        balance = 0.5
        enabled = $true
        muted = $false
        'push-to-mute' = $false
        'push-to-mute-delay' = 0
        'push-to-talk' = $false
        'push-to-talk-delay' = 0
        hotkeys = [PSCustomObject]@{}
        deinterlace_mode = 0
        deinterlace_field_order = 0
        monitoring_type = 0
        private_settings = [PSCustomObject]@{}
    }
}

function Get-OrCreateFilter {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$ExistingFilters,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$VersionedId,
        [Parameter(Mandatory = $true)][object]$Settings,
        [Parameter(Mandatory = $true)][int64]$PreviousVersion
    )

    $filter = $ExistingFilters | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if ($null -eq $filter) {
        return New-FilterObject -Name $Name -Id $Id -VersionedId $VersionedId -Settings $Settings -PreviousVersion $PreviousVersion
    }

    $filter.name = $Name
    $filter.versioned_id = $VersionedId
    $filter.settings = $Settings
    $filter.enabled = $true
    return $filter
}

$profileDirectoryName = Get-SelectionValue -Key 'ProfileDir'
$sceneCollectionFile = Get-SelectionValue -Key 'SceneCollectionFile'
$profilePath = Join-Path $obsConfigRoot ("basic\profiles\" + $profileDirectoryName)
$basicIniPath = Join-Path $profilePath 'basic.ini'
$scenePath = Join-Path $obsConfigRoot ("basic\scenes\" + $sceneCollectionFile)

foreach ($requiredPath in @($basicIniPath, $scenePath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "必要なOBS設定が見つかりません: $requiredPath"
    }
}

$scene = Get-Content -LiteralPath $scenePath -Raw -Encoding UTF8 | ConvertFrom-Json
$microphone = $scene.AuxAudioDevice1
if ($null -eq $microphone -or $microphone.id -ne 'wasapi_input_capture') {
    throw '現在のシーンコレクションにWindowsのマイク入力が見つかりません。OBSでマイクを追加してから実行してください。'
}

$deviceId = [string]$microphone.settings.device_id
$existingFilters = @($microphone.filters)
$previousVersion = [int64]$microphone.prev_ver

$noiseSettings = [PSCustomObject][ordered]@{ method = 'rnnoise' }
$expanderSettings = [PSCustomObject][ordered]@{ ratio = 2.0; threshold = $ExpanderThreshold; attack_time = 10; release_time = 100; output_gain = 0.0; detector = 'RMS' }
$equalizerSettings = [PSCustomObject][ordered]@{ low = -4.0; mid = 0.0; high = 0.0 }
$gainSettings = [PSCustomObject][ordered]@{ db = $GainDb }
$compressorSettings = [PSCustomObject][ordered]@{ ratio = 3.0; threshold = $CompressorThreshold; attack_time = 6; release_time = 60; output_gain = 3.0 }
$limiterSettings = [PSCustomObject][ordered]@{ threshold = -4.0; release_time = 60 }

$newFilters = @(
    Get-OrCreateFilter -ExistingFilters $existingFilters -Name 'ノイズ抑制' -Id 'noise_suppress_filter' -VersionedId 'noise_suppress_filter_v2' -Settings $noiseSettings -PreviousVersion $previousVersion
    Get-OrCreateFilter -ExistingFilters $existingFilters -Name 'エキスパンダー' -Id 'expander_filter' -VersionedId 'expander_filter' -Settings $expanderSettings -PreviousVersion $previousVersion
    Get-OrCreateFilter -ExistingFilters $existingFilters -Name '3バンドイコライザー' -Id 'basic_eq_filter' -VersionedId 'basic_eq_filter' -Settings $equalizerSettings -PreviousVersion $previousVersion
    Get-OrCreateFilter -ExistingFilters $existingFilters -Name 'ゲイン' -Id 'gain_filter' -VersionedId 'gain_filter' -Settings $gainSettings -PreviousVersion $previousVersion
    Get-OrCreateFilter -ExistingFilters $existingFilters -Name 'コンプレッサー' -Id 'compressor_filter' -VersionedId 'compressor_filter' -Settings $compressorSettings -PreviousVersion $previousVersion
    Get-OrCreateFilter -ExistingFilters $existingFilters -Name 'リミッター' -Id 'limiter_filter' -VersionedId 'limiter_filter' -Settings $limiterSettings -PreviousVersion $previousVersion
)

Write-Host "対象マイク: $($microphone.name)"
Write-Host "デバイス設定: $(if ([string]::IsNullOrWhiteSpace($deviceId)) { '未指定' } else { $deviceId })"
Write-Host 'ノイズ抑制: RNNoise'
Write-Host "エキスパンダー: 2:1 / $ExpanderThreshold dB"
Write-Host "EQ: 低域 -4 dB / 中域 0 dB / 高域 0 dB"
Write-Host "ゲイン: $GainDb dB"
Write-Host "コンプレッサー: 3:1 / $CompressorThreshold dB / 出力 +3 dB"
Write-Host 'リミッター: -4 dB'
Write-Host '音声: 48kHz / ステレオ'

if ($simulationOnly) {
    Write-Host ''
    Write-Host 'シミュレーション結果: 適用可能です。設定ファイルは変更していません。' -ForegroundColor Green
    return
}

if (-not $PSCmdlet.ShouldProcess($microphone.name, '現在のマイク設定を退避して基準フィルターを適用')) {
    return
}

$backupStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$sceneBackupPath = "$scenePath.before-microphone-settings-$backupStamp.bak"
$basicIniBackupPath = "$basicIniPath.before-microphone-settings-$backupStamp.bak"
Copy-Item -LiteralPath $scenePath -Destination $sceneBackupPath -Force
Copy-Item -LiteralPath $basicIniPath -Destination $basicIniBackupPath -Force

try {
    $microphone.filters = $newFilters

    $basicLines = [Collections.Generic.List[string]]::new()
    foreach ($line in Get-Content -LiteralPath $basicIniPath -Encoding UTF8) { $basicLines.Add($line) }
    Set-IniValue -Lines $basicLines -Section 'Audio' -Key 'SampleRate' -Value '48000'
    Set-IniValue -Lines $basicLines -Section 'Audio' -Key 'ChannelSetup' -Value 'Stereo'

    $sceneJson = $scene | ConvertTo-Json -Depth 100 -Compress
    [IO.File]::WriteAllText($scenePath, $sceneJson, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllLines($basicIniPath, $basicLines, [Text.UTF8Encoding]::new($true))

    $verifyScene = Get-Content -LiteralPath $scenePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (@($verifyScene.AuxAudioDevice1.filters).Count -ne 6) {
        throw '適用後のマイクフィルター数が6件ではありません。'
    }

    Write-Host ''
    Write-Host 'OBSマイク設定を適用しました。' -ForegroundColor Green
    Write-Host "変更前のシーン設定: $sceneBackupPath"
    Write-Host "変更前の音声設定: $basicIniBackupPath"
    Write-Warning 'OBSでテスト録音し、普通の声が -18～-12 dB、大きな声が -10～-6 dB、最大値が -3 dB以下に入るか確認してください。'
}
catch {
    Copy-Item -LiteralPath $sceneBackupPath -Destination $scenePath -Force
    Copy-Item -LiteralPath $basicIniBackupPath -Destination $basicIniPath -Force
    throw
}
