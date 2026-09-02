#requires -Version 5.1

<#
.SYNOPSIS
OBS Studioの「マイク」と「デスクトップ音声」へ、ゲーム実況向けの音声設定を一括で適用します。

.DESCRIPTION
配信で「叫び声は聞こえるが、考えながらのボソボソ喋りが聞こえない」状態を解消します。

マイク側:
  ノイズ抑制 → ゲイン → エキスパンダー → 3バンドEQ → コンプレッサー → リミッター
  ゲインをエキスパンダーより前に置くのが要点です。後ろに置くと、エキスパンダーが
  増幅前の小さい信号を見てしまい、普通の喋りまで減衰対象になります。

デスクトップ音声側:
  ダッキング（サイドチェーン圧縮） → リミッター
  マイクに声が入っている間だけゲーム音を自動で下げます。これが最も効きます。

適用前にシーンJSONを日付付きで退避します。OBS起動中は実行できません。

.PARAMETER GainDb
マイクに追加するゲインです。標準は +18.5 dB（現行値の引き継ぎ）。

.PARAMETER ExpanderThreshold
エキスパンダーのしきい値です。標準は -45 dB。ここを上げると小声が削られます。

.PARAMETER CompressorThreshold
マイクのコンプレッサーのしきい値です。標準は -20 dB。

.PARAMETER DuckThreshold
ダッキングのしきい値です。標準は -35 dB。マイクがこれを超えるとゲーム音が下がります。

.PARAMETER DuckRatio
ダッキングの比率です。標準は 10。大きいほどゲーム音が深く下がります。

.PARAMETER MicName
マイク音源の名前です。標準は「マイク」。

.PARAMETER DesktopName
デスクトップ音声の名前です。標準は「デスクトップ音声」。

.EXAMPLE
.\configure-audio_ver.0.1.ps1 -WhatIf

.EXAMPLE
.\configure-audio_ver.0.1.ps1

.EXAMPLE
.\configure-audio_ver.0.1.ps1 -DuckRatio 6 -DuckThreshold -30
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter()][ValidateRange(-30, 40)][double]$GainDb = 18.5,
    [Parameter()][ValidateRange(-60, -10)][double]$ExpanderThreshold = -45,
    [Parameter()][ValidateRange(-60, -1)][double]$CompressorThreshold = -20,
    [Parameter()][ValidateRange(-60, -1)][double]$DuckThreshold = -35,
    [Parameter()][ValidateRange(1, 32)][double]$DuckRatio = 10,
    [Parameter()][string]$MicName = 'マイク',
    [Parameter()][string]$DesktopName = 'デスクトップ音声',
    [Parameter()][string]$ConfigRoot = (Join-Path $env:APPDATA 'obs-studio')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptVersion = '0.1'
$simulationOnly = [bool]$WhatIfPreference
$WhatIfPreference = $false

# ---- settings.ini（obs/settings.ini）の読み込み。引数で明示したものは引数が優先 ----
function Import-IniSettings {
    param([string]$Path)
    $result = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }
    $section = ''
    foreach ($raw in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith(';') -or $line.StartsWith('#')) { continue }
        if ($line -match '^\[(.+)\]$') { $section = $matches[1].Trim(); if (-not $result.ContainsKey($section)) { $result[$section] = @{} }; continue }
        $i = $line.IndexOf('=')
        if ($i -lt 1 -or -not $section) { continue }
        $result[$section][$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim()
    }
    return $result
}
$iniPath = Join-Path $PSScriptRoot '..\settings.ini'
$ini = Import-IniSettings $iniPath
$bound = @($PSBoundParameters.Keys)
foreach ($m in @(
    @('audio', 'GainDb', 'GainDb'), @('audio', 'ExpanderThreshold', 'ExpanderThreshold'),
    @('audio', 'CompressorThreshold', 'CompressorThreshold'), @('audio', 'DuckThreshold', 'DuckThreshold'),
    @('audio', 'DuckRatio', 'DuckRatio'), @('audio', 'MicName', 'MicName'), @('audio', 'DesktopName', 'DesktopName'))) {
    $sec, $key, $var = $m
    if ($bound -contains $var) { continue }
    if (-not ($ini.ContainsKey($sec) -and $ini[$sec].ContainsKey($key))) { continue }
    $val = $ini[$sec][$key]
    if ($val -eq '') { continue }
    $cur = Get-Variable -Name $var -ValueOnly
    if ($cur -is [double]) { $val = [double]$val } elseif ($cur -is [int]) { $val = [int]$val }
    Set-Variable -Name $var -Value $val -Scope Script
}
if (Test-Path -LiteralPath $iniPath) { Write-Host "settings.ini を読み込みました: $iniPath" }

Write-Host "OBS音声一括設定 ver.$ScriptVersion"
Write-Host ''

if (@(Get-Process -Name 'obs64', 'obs32' -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'OBS Studioが起動中です。OBSを完全に終了してから、もう一度実行してください。'
}

$obsConfigRoot = $ConfigRoot
$userIniPath = Join-Path $obsConfigRoot 'user.ini'
if (-not (Test-Path -LiteralPath $userIniPath -PathType Leaf)) {
    throw "OBSのユーザー設定が見つかりません: $userIniPath"
}

$collectionFile = $null
foreach ($line in (Get-Content -LiteralPath $userIniPath -Encoding UTF8)) {
    if ($line -match '^SceneCollectionFile=(.+)$') { $collectionFile = $matches[1].Trim(); break }
}
if ([string]::IsNullOrWhiteSpace($collectionFile)) {
    throw 'OBSの現在のシーンコレクションを特定できません（SceneCollectionFile）。'
}

if ($collectionFile -notmatch '\.json$') { $collectionFile = $collectionFile + '.json' }
$scenePath = Join-Path (Join-Path $obsConfigRoot 'basic\scenes') $collectionFile
if (-not (Test-Path -LiteralPath $scenePath -PathType Leaf)) {
    throw "シーンコレクションが見つかりません: $scenePath"
}
Write-Host "対象: $scenePath"

# ---- フィルター定義 ----
function New-Filter {
    param([string]$Name, [string]$Id, [hashtable]$Settings)
    $s = New-Object PSObject
    foreach ($k in $Settings.Keys) { $s | Add-Member -NotePropertyName $k -NotePropertyValue $Settings[$k] }
    $f = New-Object PSObject
    $f | Add-Member -NotePropertyName 'balance'  -NotePropertyValue 0.5
    $f | Add-Member -NotePropertyName 'deinterlace_field_order' -NotePropertyValue 0
    $f | Add-Member -NotePropertyName 'deinterlace_mode' -NotePropertyValue 0
    $f | Add-Member -NotePropertyName 'enabled'  -NotePropertyValue $true
    $f | Add-Member -NotePropertyName 'hotkeys'  -NotePropertyValue (New-Object PSObject)
    $f | Add-Member -NotePropertyName 'id'       -NotePropertyValue $Id
    $f | Add-Member -NotePropertyName 'mixers'   -NotePropertyValue 0
    $f | Add-Member -NotePropertyName 'monitoring_type' -NotePropertyValue 0
    $f | Add-Member -NotePropertyName 'muted'    -NotePropertyValue $false
    $f | Add-Member -NotePropertyName 'name'     -NotePropertyValue $Name
    $f | Add-Member -NotePropertyName 'prev_ver' -NotePropertyValue 520093699
    $f | Add-Member -NotePropertyName 'private_settings' -NotePropertyValue (New-Object PSObject)
    $f | Add-Member -NotePropertyName 'push-to-mute' -NotePropertyValue $false
    $f | Add-Member -NotePropertyName 'push-to-mute-delay' -NotePropertyValue 0
    $f | Add-Member -NotePropertyName 'push-to-talk' -NotePropertyValue $false
    $f | Add-Member -NotePropertyName 'push-to-talk-delay' -NotePropertyValue 0
    $f | Add-Member -NotePropertyName 'settings' -NotePropertyValue $s
    $f | Add-Member -NotePropertyName 'sync' -NotePropertyValue 0
    $f | Add-Member -NotePropertyName 'versioned_id' -NotePropertyValue $Id
    $f | Add-Member -NotePropertyName 'volume' -NotePropertyValue 1.0
    return $f
}

# マイク: ゲインをエキスパンダーより前に置く
$micFilters = @(
    (New-Filter 'ノイズ抑制' 'noise_suppress_filter' @{ method = 'rnnoise' }),
    (New-Filter 'ゲイン' 'gain_filter' @{ db = $GainDb }),
    (New-Filter 'エキスパンダー' 'expander_filter' @{
        ratio = 2; threshold = $ExpanderThreshold; attack_time = 10
        release_time = 100; output_gain = 0; detector = 'RMS' }),
    (New-Filter '3バンドイコライザー' 'basic_eq_filter' @{ low = -4; mid = 0; high = 0 }),
    (New-Filter 'コンプレッサー' 'compressor_filter' @{
        ratio = 3; threshold = $CompressorThreshold; attack_time = 6
        release_time = 60; output_gain = 3 }),
    (New-Filter 'リミッター' 'limiter_filter' @{ threshold = -3; release_time = 60 })
)

# デスクトップ音声: マイクをサイドチェーンにしたダッキング
$desktopFilters = @(
    (New-Filter 'ダッキング' 'compressor_filter' @{
        ratio = $DuckRatio; threshold = $DuckThreshold; attack_time = 5
        release_time = 200; output_gain = 0; sidechain_source = $MicName }),
    (New-Filter 'リミッター' 'limiter_filter' @{ threshold = -3; release_time = 60 })
)

Write-Host ''
Write-Host '--- 適用する設定 ---'
Write-Host ("  マイク         ゲイン {0} dB / エキスパンダー {1} dB / コンプ {2} dB" -f $GainDb, $ExpanderThreshold, $CompressorThreshold)
Write-Host ("  デスクトップ音声  ダッキング {0}:1 / しきい値 {1} dB / サイドチェーン: {2}" -f $DuckRatio, $DuckThreshold, $MicName)
Write-Host ''

if ($simulationOnly) {
    Write-Host '（-WhatIf のため、ここまでで終了します。ファイルは変更していません）'
    return
}
if (-not $PSCmdlet.ShouldProcess($scenePath, 'OBSの音声フィルターを一括設定')) { return }

# ---- 退避 ----
$backupDir = Join-Path $PSScriptRoot '..\backup'
if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupPath = Join-Path $backupDir ("scenes-before-audio-$stamp.json")
Copy-Item -LiteralPath $scenePath -Destination $backupPath -Force
Write-Host "退避しました: $backupPath"

# ---- 適用 ----
$json = Get-Content -LiteralPath $scenePath -Raw -Encoding UTF8 | ConvertFrom-Json

$applied = @()
foreach ($pair in @(
    @{ Key = 'AuxAudioDevice1';     Filters = $micFilters;     Label = $MicName },
    @{ Key = 'DesktopAudioDevice1'; Filters = $desktopFilters; Label = $DesktopName })) {

    $key = $pair.Key
    if (-not $json.PSObject.Properties.Name.Contains($key)) {
        Write-Warning "音源が見つかりません: $key（$($pair.Label)）。スキップします。"
        continue
    }
    $dev = $json.$key
    if ($dev.PSObject.Properties.Name.Contains('filters')) {
        $dev.filters = $pair.Filters
    } else {
        $dev | Add-Member -NotePropertyName 'filters' -NotePropertyValue $pair.Filters
    }
    $applied += "$($pair.Label)（$($pair.Filters.Count)個）"
}

if ($applied.Count -eq 0) { throw '適用できる音源がありませんでした。' }

$out = $json | ConvertTo-Json -Depth 100 -Compress:$false
# OBSはBOM無しUTF-8を期待するため、Set-Content(-Encoding UTF8はBOM付き)は使わない
[System.IO.File]::WriteAllText($scenePath, $out, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host ('適用しました: ' + ($applied -join ' / '))
Write-Host ''
Write-Host '次にやること:'
Write-Host '  1. OBSを起動する'
Write-Host '  2. ミキサーの歯車 → フィルタ で、マイクとデスクトップ音声に入っているか確認する'
Write-Host '  3. 少し喋って、ゲーム音が下がることを確認する'
Write-Host '  4. 喋っているときメーターが -12 dB 前後、ピークが -6 dB を超えないようにマイクの入力音量を調整する'
Write-Host ''
Write-Host "戻すとき: $backupPath を $scenePath に上書きしてください（OBSは終了しておくこと）"
