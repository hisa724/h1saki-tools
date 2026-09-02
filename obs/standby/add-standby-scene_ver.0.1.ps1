#requires -Version 5.1

<#
.SYNOPSIS
OBS Studioに「待機画面」シーン（ループ動画＋BGM＋案内テキスト）を追加します。

.DESCRIPTION
配信開始前・休憩中に切り替えるためのシーンを、シーンコレクションのJSONへ直接書き込みます。

  - ループ動画（メディアソース / ループ再生・切替時に先頭から）
  - BGM（メディアソース / ループ再生・ゲイン → リミッター）
  - 案内テキスト（テキスト GDI+ / 画面下部・中央揃え）

既に同名のシーンがあれば中身を作り直します（2回実行しても増えません）。
現在のシーンは変更しません。適用前にシーンJSONを日付付きで退避します。OBS起動中は実行できません。

.PARAMETER VideoPath
ループ再生する動画（必須）。継ぎ目を消した版を使うこと（README の ffmpeg 手順参照）。

.PARAMETER BgmPath
BGMファイル。省略または空文字ならBGMソースを作らない。

.PARAMETER BgmGainDb
BGMのゲイン。既定 -8 dB（-11.7 LUFS の曲を配信向けに下げる想定）。

.PARAMETER Line1 / Line2
案内テキスト。Line2 が空なら1行だけ。

.EXAMPLE
.\add-standby-scene_ver.0.1.ps1 -VideoPath 'C:\obs\standby\standby_loop.mp4' -WhatIf

.EXAMPLE
.\add-standby-scene_ver.0.1.ps1 -VideoPath 'C:\obs\standby\standby_loop.mp4' -BgmPath 'C:\obs\standby\bgm.wav' -Line1 'まもなく配信を開始します' -Line2 '22:00〜'
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter()][string]$SceneName = '待機画面',
    [Parameter()][string]$VideoPath = '',
    [Parameter()][string]$BgmPath = '',
    [Parameter()][ValidateRange(-40, 20)][double]$BgmGainDb = -8,
    [Parameter()][string]$Line1 = 'まもなく配信を開始します',
    [Parameter()][string]$Line2 = '',
    [Parameter()][string]$FontName = 'LINE Seed JP ExtraBold',
    [Parameter()][ValidateRange(24, 300)][int]$FontSize = 88,
    [Parameter()][int]$CanvasWidth = 1920,
    [Parameter()][int]$CanvasHeight = 1080,
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
    @('standby', 'SceneName', 'SceneName'), @('standby', 'VideoPath', 'VideoPath'), @('standby', 'BgmPath', 'BgmPath'),
    @('standby', 'BgmGainDb', 'BgmGainDb'), @('standby', 'Line1', 'Line1'), @('standby', 'Line2', 'Line2'),
    @('standby', 'FontName', 'FontName'), @('standby', 'FontSize', 'FontSize'))) {
    $sec, $key, $var = $m
    if ($bound -contains $var) { continue }
    if (-not ($ini.ContainsKey($sec) -and $ini[$sec].ContainsKey($key))) { continue }
    $val = $ini[$sec][$key]
    if ($val -eq '' -and $key -ne 'Line2' -and $key -ne 'BgmPath') { continue }
    $cur = Get-Variable -Name $var -ValueOnly
    if ($cur -is [double]) { $val = [double]$val } elseif ($cur -is [int]) { $val = [int]$val }
    Set-Variable -Name $var -Value $val -Scope Script
}
if (Test-Path -LiteralPath $iniPath) { Write-Host "settings.ini を読み込みました: $iniPath" }

Write-Host "OBS待機画面シーン追加 ver.$ScriptVersion"
Write-Host ''

if (@(Get-Process -Name 'obs64', 'obs32' -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'OBS Studioが起動中です。OBSを完全に終了してから、もう一度実行してください。'
}
if (-not $VideoPath) { throw "動画が指定されていません。settings.ini の [standby] VideoPath を設定するか、-VideoPath で指定してください。" }
if (-not (Test-Path -LiteralPath $VideoPath -PathType Leaf)) { throw "動画が見つかりません: $VideoPath" }
if ($BgmPath -and -not (Test-Path -LiteralPath $BgmPath -PathType Leaf)) { throw "BGMが見つかりません: $BgmPath" }

# ---- 対象ファイル ----
$userIniPath = Join-Path $ConfigRoot 'user.ini'
if (-not (Test-Path -LiteralPath $userIniPath -PathType Leaf)) { throw "OBSのユーザー設定が見つかりません: $userIniPath" }
$collectionFile = $null
foreach ($line in (Get-Content -LiteralPath $userIniPath -Encoding UTF8)) {
    if ($line -match '^SceneCollectionFile=(.+)$') { $collectionFile = $matches[1].Trim(); break }
}
if ([string]::IsNullOrWhiteSpace($collectionFile)) { throw 'OBSの現在のシーンコレクションを特定できません（SceneCollectionFile）。' }
if ($collectionFile -notmatch '\.json$') { $collectionFile = $collectionFile + '.json' }
$scenePath = Join-Path (Join-Path $ConfigRoot 'basic\scenes') $collectionFile
if (-not (Test-Path -LiteralPath $scenePath -PathType Leaf)) { throw "シーンコレクションが見つかりません: $scenePath" }
Write-Host "対象: $scenePath"

$text = if ($Line2) { $Line1 + "`n" + $Line2 } else { $Line1 }
Write-Host ''
Write-Host '--- 追加する内容 ---'
Write-Host ("  シーン「{0}」" -f $SceneName)
Write-Host ("    動画: {0}（ループ）" -f $VideoPath)
if ($BgmPath) { Write-Host ("    BGM : {0}（ループ / ゲイン {1} dB）" -f $BgmPath, $BgmGainDb) } else { Write-Host '    BGM : なし' }
Write-Host ("    文字: {0}  [{1} {2}px]" -f ($text -replace "`n", ' / '), $FontName, $FontSize)
Write-Host ''
if ($simulationOnly) { Write-Host '（-WhatIf のため、ここまでで終了します。ファイルは変更していません）'; return }
if (-not $PSCmdlet.ShouldProcess($scenePath, '待機画面シーンを追加')) { return }

# ---- 退避 ----
$backupDir = Join-Path $PSScriptRoot '..\backup'
if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupPath = Join-Path $backupDir ("scenes-before-standby-$stamp.json")
Copy-Item -LiteralPath $scenePath -Destination $backupPath -Force
Write-Host "退避しました: $backupPath"

$json = Get-Content -LiteralPath $scenePath -Raw -Encoding UTF8 | ConvertFrom-Json
$mixers = 255
if ($json.PSObject.Properties.Name.Contains('DesktopAudioDevice1')) { $mixers = $json.DesktopAudioDevice1.mixers }

# ---- 部品 ----
function New-Obj { param([hashtable]$Fields) $o = New-Object PSObject; foreach ($k in $Fields.Keys) { $o | Add-Member -NotePropertyName $k -NotePropertyValue $Fields[$k] }; return $o }
function New-Filter {
    param([string]$Name, [string]$Id, [hashtable]$Settings)
    return New-Obj @{ balance = 0.5; deinterlace_field_order = 0; deinterlace_mode = 0; enabled = $true
        hotkeys = (New-Object PSObject); id = $Id; mixers = 0; monitoring_type = 0; muted = $false; name = $Name
        prev_ver = 520093699; private_settings = (New-Object PSObject); 'push-to-mute' = $false; 'push-to-mute-delay' = 0
        'push-to-talk' = $false; 'push-to-talk-delay' = 0; settings = (New-Obj $Settings); sync = 0; versioned_id = $Id; volume = 1.0 }
}
function New-Source {
    param([string]$Name, [string]$Id, [string]$VersionedId, [PSObject]$Settings, [int]$Mixers, [object[]]$Filters)
    $s = New-Obj @{ balance = 0.5; deinterlace_field_order = 0; deinterlace_mode = 0; enabled = $true; flags = 0
        hotkeys = (New-Object PSObject); id = $Id; mixers = $Mixers; monitoring_type = 0; muted = $false; name = $Name
        prev_ver = 537001986; private_settings = (New-Object PSObject); 'push-to-mute' = $false; 'push-to-mute-delay' = 0
        'push-to-talk' = $false; 'push-to-talk-delay' = 0; settings = $Settings; sync = 0
        uuid = [guid]::NewGuid().ToString(); versioned_id = $VersionedId; volume = 1.0 }
    if ($Filters -and $Filters.Count -gt 0) { $s | Add-Member -NotePropertyName 'filters' -NotePropertyValue $Filters }
    return $s
}

$videoSrc = New-Source -Name ($SceneName + '_動画') -Id 'ffmpeg_source' -VersionedId 'ffmpeg_source' -Mixers $mixers -Settings (New-Obj @{
    local_file = $VideoPath; is_local_file = $true; looping = $true; restart_on_activate = $true
    # close_when_inactive を true にすると、スタジオモードのプレビューでは（非アクティブ扱いのため）黒いままになる。
    # 待機画面は短い動画なので開きっぱなしで構わない
    hw_decode = $true; close_when_inactive = $false; clear_on_media_end = $false; speed_percent = 100 })

$bgmSrc = $null
if ($BgmPath) {
    $bgmSrc = New-Source -Name ($SceneName + '_BGM') -Id 'ffmpeg_source' -VersionedId 'ffmpeg_source' -Mixers $mixers -Settings (New-Obj @{
        local_file = $BgmPath; is_local_file = $true; looping = $true; restart_on_activate = $true
        hw_decode = $false; close_when_inactive = $true; clear_on_media_end = $false; speed_percent = 100 }) -Filters @(
        (New-Filter 'ゲイン' 'gain_filter' @{ db = $BgmGainDb }),
        (New-Filter 'リミッター' 'limiter_filter' @{ threshold = -3; release_time = 60 }))
}

# 色は OBS の ABGR 整数。白=4294967295 / 黒=4278190080
$textSrc = New-Source -Name ($SceneName + '_文字') -Id 'text_gdiplus' -VersionedId 'text_gdiplus_v3' -Mixers 0 -Settings (New-Obj @{
    text = $text; font = (New-Obj @{ face = $FontName; size = $FontSize; flags = 0; style = 'Regular' })
    color = [uint32]4294967295; opacity = 100; outline = $true; outline_size = 8; outline_color = [uint32]4278190080; outline_opacity = 100
    align = 'center'; valign = 'center'; antialiasing = $true; read_from_file = $false })

# ---- シーン項目 ----
function New-Item2 {
    param([int]$Id, [PSObject]$Src, [double]$X, [double]$Y, [int]$BoundsType, [double]$BW, [double]$BH)
    # OBS 31 以降は scale_ref があると pos_rel / bounds_rel / scale_rel（相対値）から位置と大きさを復元する。
    # 相対値は「キャンバス中心を原点、キャンバス高さの半分を 1」とした座標。
    # 例: pos(0,0) → pos_rel(-1.777, -1.0) / bounds(1920,1080) → bounds_rel(3.556, 2.0)
    # ここを 0 のままにすると項目が大きさ 0 で描画され、何も映らない（2026-09-02 の不具合）。
    $half = [double]$CanvasHeight / 2.0
    $relX = ($X - [double]$CanvasWidth / 2.0) / $half
    $relY = ($Y - [double]$CanvasHeight / 2.0) / $half
    return New-Obj @{ name = $Src.name; source_uuid = $Src.uuid; visible = $true; locked = $false; rot = 0.0
        scale_ref = (New-Obj @{ x = [double]$CanvasWidth; y = [double]$CanvasHeight }); align = 5
        bounds_type = $BoundsType; bounds_align = 0; bounds_crop = $false
        crop_left = 0; crop_top = 0; crop_right = 0; crop_bottom = 0; id = $Id; group_item_backup = $false
        pos = (New-Obj @{ x = $X; y = $Y }); pos_rel = (New-Obj @{ x = $relX; y = $relY })
        scale = (New-Obj @{ x = 1.0; y = 1.0 }); scale_rel = (New-Obj @{ x = 1.0; y = 1.0 })
        bounds = (New-Obj @{ x = $BW; y = $BH }); bounds_rel = (New-Obj @{ x = ($BW / $half); y = ($BH / $half) })
        scale_filter = 'disable'; blend_method = 'default'; blend_type = 'normal'
        show_transition = (New-Obj @{ duration = 300 }); hide_transition = (New-Obj @{ duration = 300 })
        private_settings = (New-Object PSObject) }
}
$items = @()
$items += New-Item2 -Id 1 -Src $videoSrc -X 0 -Y 0 -BoundsType 2 -BW $CanvasWidth -BH $CanvasHeight            # 全画面（内側に収める）
if ($bgmSrc) { $items += New-Item2 -Id 2 -Src $bgmSrc -X 0 -Y 0 -BoundsType 0 -BW 0 -BH 0 }
$boxH = 240
$items += New-Item2 -Id 3 -Src $textSrc -X 0 -Y ($CanvasHeight - $boxH - 60) -BoundsType 6 -BW $CanvasWidth -BH $boxH   # 下部・中央揃え

# ---- 既存の同名シーンとそのソースを除去（作り直し）----
$oldScene = @($json.sources | Where-Object { $_.id -eq 'scene' -and $_.name -eq $SceneName })
# 注意: PowerShell は「,」が「+」より先に結合されるため、各要素を必ず括弧で囲む
$dropNames = @(($SceneName + '_動画'), ($SceneName + '_BGM'), ($SceneName + '_文字'))
if ($oldScene.Count -gt 0) {
    $json.sources = @($json.sources | Where-Object { -not ($_.id -eq 'scene' -and $_.name -eq $SceneName) -and ($dropNames -notcontains $_.name) })
    Write-Host "既存の「$SceneName」を作り直します"
}

# ---- シーン本体（既存シーンの雛形を複製して差し替え）----
$tmplScene = @($json.sources | Where-Object { $_.id -eq 'scene' })[0]
if ($null -eq $tmplScene) { throw '雛形にするシーンがありません。' }
$scene = $tmplScene | ConvertTo-Json -Depth 30 | ConvertFrom-Json
$scene.name = $SceneName
$scene.uuid = [guid]::NewGuid().ToString()
$scene.hotkeys = New-Object PSObject
$scene.settings.items = $items
$scene.settings.id_counter = 3
$scene.settings.custom_size = $false

$newSources = @($videoSrc); if ($bgmSrc) { $newSources += $bgmSrc }; $newSources += $textSrc; $newSources += $scene
$json.sources = @($json.sources) + $newSources

# scene_order に追加（無ければ）
$order = @($json.scene_order)
if (-not ($order | Where-Object { $_.name -eq $SceneName })) { $json.scene_order = $order + @((New-Obj @{ name = $SceneName })) }

# ---- 書き出し（BOM無しUTF-8）----
$out = $json | ConvertTo-Json -Depth 100 -Compress:$false
[System.IO.File]::WriteAllText($scenePath, $out, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host ("追加しました: シーン「{0}」（ソース {1} 個 / 項目 {2} 個）" -f $SceneName, ($newSources.Count - 1), $items.Count)
Write-Host ''
Write-Host '次にやること:'
Write-Host '  1. OBSを起動し、シーン一覧に「待機画面」が出ているか確認する'
Write-Host '  2. 待機画面に切り替えて、動画がループし、BGMが鳴り、文字が下部中央に出るか確認する'
Write-Host '  3. 文字を変えるときは、テキストソースをダブルクリックして直接編集してよい（次回この'
Write-Host '     スクリプトを実行すると -Line1/-Line2 の内容で作り直されるので注意）'
Write-Host '  4. BGMが大きい/小さいときは -BgmGainDb で調整して再実行'
Write-Host ''
Write-Host "戻すとき: $backupPath をシーンコレクションに上書きしてください（OBSは終了しておくこと）"
