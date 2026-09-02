#requires -Version 5.1

<#
.SYNOPSIS
OBSの設定バックアップを、移行先のWindows PCへ安全確認付きで復元します。

.DESCRIPTION
このスクリプトは移行先PCで実行します。現在のOBS設定を日付付きフォルダへ
退避してから、通常の設定バックアップまたは完全バックアップ内の設定を復元します。
OBS本体とプラグイン本体はコピーせず、移行先にインストール済みのOBSを使用します。

標準では、配信キー、OBS WebSocket認証、ブラウザCookieなどの既知の機密設定を
復元しません。外部素材はPathMapFileで移行元と移行先の対応を指定した場合だけ
復元し、シーンJSON内のパスも同じ対応で置換します。

.PARAMETER BackupPath
復元に使用するZIPです。省略時はobs/backupまたはこのスクリプトと同じフォルダから、
最新のobs-settings-日時.zipまたはobs-complete-日時.zipを選びます。

.PARAMETER ObsConfigPath
移行先PCのOBS設定フォルダです。標準は %APPDATA%\obs-studio です。

.PARAMETER ObsInstallPath
移行先PCにインストール済みのOBSフォルダです。省略時は標準のProgram Files配下を
確認します。OBS本体のファイルは変更しません。

.PARAMETER PathMapFile
移行元と移行先の素材フォルダを対応付けるJSONファイルです。省略時は外部素材を
復元せず、シーンJSON内の素材パスも変更しません。

.PARAMETER OverwriteReferencedFiles
移行先に同名の外部素材がある場合も上書きします。上書き前のファイルは
.before-obs-migration-日時.bak として残します。

.PARAMETER RestoreSensitiveSettings
既知の機密設定も含めて復元します。配信キー、WebSocketパスワード、Cookieなどが
移行先へコピーされる可能性があるため、内容を理解した場合だけ指定してください。

.PARAMETER SkipObsInstallCheck
OBS本体の存在確認を省略します。隔離テストまたは特殊なポータブル環境専用です。

.PARAMETER TestMode
隔離テスト用です。復元先がWindowsの一時フォルダ内にある場合だけ、OBSプロセスと
OBS本体の確認を省略します。実環境の復元には使用できません。

.EXAMPLE
.\restore-obs-on-new-pc_ver.0.2.ps1 -BackupPath "D:\Backup\obs-settings-20260902-120000.zip" -WhatIf

.EXAMPLE
.\restore-obs-on-new-pc_ver.0.2.ps1 -BackupPath "D:\Backup\obs-settings-20260902-120000.zip"

.EXAMPLE
.\restore-obs-on-new-pc_ver.0.2.ps1 -BackupPath "D:\Backup\obs-complete-20260902-120000.zip" -PathMapFile ".\path-map.example.json"
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [string]$BackupPath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ObsConfigPath = (Join-Path $env:APPDATA 'obs-studio'),

    [Parameter()]
    [string]$ObsInstallPath,

    [Parameter()]
    [string]$PathMapFile,

    [Parameter()]
    [switch]$OverwriteReferencedFiles,

    [Parameter()]
    [switch]$RestoreSensitiveSettings,

    [Parameter()]
    [switch]$SkipObsInstallCheck,

    [Parameter()]
    [switch]$TestMode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptVersion = '0.2'
$simulationOnly = [bool]$WhatIfPreference
$WhatIfPreference = $false
$restoreStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$extractRoot = Join-Path ([IO.Path]::GetTempPath()) ('h1saki-obs-new-pc-' + [guid]::NewGuid().ToString('N'))
$configRollbackPath = $null
$configTargetCreated = $false
$referenceChanges = [Collections.Generic.List[object]]::new()

Write-Host "OBS環境移行・復元支援 ver.$ScriptVersion"
Write-Host 'このスクリプトは移行先PCで実行します。'
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

function Test-SafeConfigTarget {
    param([Parameter(Mandatory = $true)][string]$TargetPath)

    $fullPath = [IO.Path]::GetFullPath($TargetPath).TrimEnd('\')
    $rootPath = [IO.Path]::GetPathRoot($fullPath).TrimEnd('\')
    $leafName = Split-Path -Leaf $fullPath
    return (
        -not $fullPath.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase) -and
        $leafName.Equals('obs-studio', [StringComparison]::OrdinalIgnoreCase)
    )
}

function Get-RelativePathFromRoot {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$ChildPath
    )

    $rootFull = [IO.Path]::GetFullPath($RootPath).TrimEnd('\') + '\'
    $childFull = [IO.Path]::GetFullPath($ChildPath)
    if (-not $childFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "指定したパスが基準フォルダの外にあります: $ChildPath"
    }
    return $childFull.Substring($rootFull.Length)
}

function Get-AvailablePath {
    param([Parameter(Mandatory = $true)][string]$BasePath)

    $candidate = $BasePath
    $suffix = 1
    while (Test-Path -LiteralPath $candidate) {
        $candidate = "$BasePath-$suffix"
        $suffix++
    }
    return $candidate
}

function Get-AvailableFileBackupPath {
    param([Parameter(Mandatory = $true)][string]$OriginalPath)

    $basePath = "$OriginalPath.before-obs-migration-$restoreStamp.bak"
    $candidate = $basePath
    $suffix = 1
    while (Test-Path -LiteralPath $candidate) {
        $candidate = "$basePath-$suffix"
        $suffix++
    }
    return $candidate
}

function Test-IsObsInstallation {
    param([Parameter(Mandatory = $true)][string]$CandidatePath)

    if (-not (Test-Path -LiteralPath $CandidatePath -PathType Container)) {
        return $false
    }
    return (
        (Test-Path -LiteralPath (Join-Path $CandidatePath 'bin\64bit\obs64.exe') -PathType Leaf) -or
        (Test-Path -LiteralPath (Join-Path $CandidatePath 'bin\32bit\obs32.exe') -PathType Leaf)
    )
}

function Find-ObsInstallation {
    param([string]$ExplicitPath)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        if (-not (Test-IsObsInstallation -CandidatePath $ExplicitPath)) {
            throw "指定した場所にOBS本体が見つかりません: $ExplicitPath"
        }
        return [IO.Path]::GetFullPath($ExplicitPath)
    }

    $candidates = [Collections.Generic.List[string]]::new()
    foreach ($programRoot in @(
        [Environment]::GetFolderPath('ProgramFiles'),
        $env:ProgramW6432,
        ${env:ProgramFiles(x86)}
    )) {
        if (-not [string]::IsNullOrWhiteSpace($programRoot)) {
            $candidate = Join-Path $programRoot 'obs-studio'
            if (-not $candidates.Contains($candidate)) {
                $candidates.Add($candidate)
            }
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-IsObsInstallation -CandidatePath $candidate) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    return $null
}

function Test-SafeArchiveEntryName {
    param([Parameter(Mandatory = $true)][string]$EntryName)

    $normalized = $EntryName.Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $false }
    if ($normalized.StartsWith('/') -or $normalized -match '^[A-Za-z]:') { return $false }
    foreach ($part in $normalized.Split('/')) {
        if ($part -eq '..') { return $false }
    }
    return $true
}

function Expand-ArchiveEntrySafely {
    param(
        [Parameter(Mandatory = $true)][IO.Compression.ZipArchiveEntry]$Entry,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [Parameter(Mandatory = $true)][string]$RelativeName
    )

    $normalized = $RelativeName.Replace('/', '\').TrimStart('\')
    if ([string]::IsNullOrWhiteSpace($normalized)) { return }
    $destination = Join-Path $DestinationRoot $normalized
    if (-not (Test-IsPathInside -CandidatePath $destination -ParentPath $DestinationRoot)) {
        throw "ZIP内のパスが展開先の外を指しています: $RelativeName"
    }
    if ($Entry.FullName.EndsWith('/') -or $Entry.FullName.EndsWith('\')) {
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        return
    }
    $parent = Split-Path -Parent $destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    [IO.Compression.ZipFileExtensions]::ExtractToFile($Entry, $destination, $true)
}

function Test-SensitiveConfigFile {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$FullPath
    )

    $normalized = $RelativePath.Replace('\', '/').ToLowerInvariant()
    if ($normalized -match '(^|/)service\.json$') { return $true }
    if ($normalized.StartsWith('plugin_config/obs-websocket/')) { return $true }
    if ($normalized.StartsWith('plugin_config/obs-browser/')) { return $true }
    if ($normalized -match '(^|/)(cookies?|login data)(-journal)?$') { return $true }
    if ($normalized -match '(^|/).*(credential|password|passwd|token|secret).*$') { return $true }

    $extension = [IO.Path]::GetExtension($FullPath).ToLowerInvariant()
    if ((@('.json', '.ini', '.conf', '.cfg', '.txt') -notcontains $extension) -or
        (Get-Item -LiteralPath $FullPath).Length -gt 5MB) {
        return $false
    }

    $content = Get-Content -LiteralPath $FullPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($null -eq $content) { return $false }
    $namedSecret = '(?i)["'']?(stream[_-]?key|api[_-]?key|access[_-]?token|refresh[_-]?token|auth[_-]?token|password|passwd|client[_-]?secret)["'']?\s*[:=]\s*["'']?[^"''\s,}]{4,}'
    $urlSecret = '(?i)[?&](token|key|auth|password|sig|signature)=[^&"''\s]{4,}'
    return ($content -match $namedSecret -or $content -match $urlSecret)
}

function Remove-SensitiveIniValues {
    param([Parameter(Mandatory = $true)][string]$FilePath)

    $sensitiveKeys = '^(Token|RefreshToken|StreamKey|Key|Password|Passwd|ApiKey|AccessToken|AuthToken|ClientSecret|CookieId)='
    $lines = @(Get-Content -LiteralPath $FilePath -Encoding UTF8)
    $safeLines = @($lines | Where-Object { $_ -notmatch $sensitiveKeys })
    $removedCount = $lines.Count - $safeLines.Count
    if ($removedCount -gt 0) {
        [IO.File]::WriteAllLines($FilePath, [string[]]$safeLines, [Text.UTF8Encoding]::new($false))
    }
    return $removedCount
}

function Read-PathMappings {
    param([string]$MapFile)

    if ([string]::IsNullOrWhiteSpace($MapFile)) { return @() }
    if (-not (Test-Path -LiteralPath $MapFile -PathType Leaf)) {
        throw "パス対応ファイルが見つかりません: $MapFile"
    }

    $mapObject = Get-Content -LiteralPath $MapFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $rows = if ($null -ne $mapObject.mappings) { @($mapObject.mappings) } else { @($mapObject) }
    $result = [Collections.Generic.List[object]]::new()
    foreach ($row in $rows) {
        $source = [string]$row.source
        $destination = [string]$row.destination
        if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($destination)) {
            throw 'パス対応にはsourceとdestinationの両方が必要です。'
        }
        if (-not [IO.Path]::IsPathRooted($source) -or -not [IO.Path]::IsPathRooted($destination)) {
            throw 'パス対応のsourceとdestinationは絶対パスで指定してください。'
        }
        $sourceFull = [IO.Path]::GetFullPath($source).TrimEnd('\')
        $destinationFull = [IO.Path]::GetFullPath($destination).TrimEnd('\')
        if ($destinationFull.Equals([IO.Path]::GetPathRoot($destinationFull).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
            throw "移行先にはドライブ直下を指定できません: $destination"
        }
        $result.Add([PSCustomObject]@{ Source = $sourceFull; Destination = $destinationFull })
    }
    return @($result | Sort-Object { $_.Source.Length } -Descending)
}

function Resolve-MappedPath {
    param(
        [Parameter(Mandatory = $true)][string]$OriginalPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Mappings
    )

    $originalFull = [IO.Path]::GetFullPath($OriginalPath)
    foreach ($mapping in $Mappings) {
        $source = [string]$mapping.Source
        if ($originalFull.Equals($source, [StringComparison]::OrdinalIgnoreCase)) {
            return [string]$mapping.Destination
        }
        if ($originalFull.StartsWith($source + '\', [StringComparison]::OrdinalIgnoreCase)) {
            $relative = $originalFull.Substring($source.Length).TrimStart('\')
            $mapped = Join-Path ([string]$mapping.Destination) $relative
            if (-not (Test-IsPathInside -CandidatePath $mapped -ParentPath ([string]$mapping.Destination))) {
                throw "対応後の素材パスが移行先フォルダの外を指しています: $OriginalPath"
            }
            return [IO.Path]::GetFullPath($mapped)
        }
    }
    return $null
}

function Get-RemappedText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Mappings
    )

    $updated = $Text
    $replacementCount = 0
    foreach ($mapping in $Mappings) {
        $source = [string]$mapping.Source
        $destination = [string]$mapping.Destination
        foreach ($pair in @(
            @($source.Replace('\', '\\'), $destination.Replace('\', '\\')),
            @($source, $destination),
            @($source.Replace('\', '/'), $destination.Replace('\', '/'))
        )) {
            $before = $updated
            $updated = $updated.Replace([string]$pair[0], [string]$pair[1])
            if (-not $updated.Equals($before, [StringComparison]::Ordinal)) {
                $replacementCount++
            }
        }
    }
    return [PSCustomObject]@{ Text = $updated; ReplacementCount = $replacementCount }
}

if (-not $TestMode -and @(Get-Process -Name 'obs64', 'obs32' -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'OBS Studioが起動中です。OBSを完全に終了してから、もう一度実行してください。'
}

$ObsConfigPath = [IO.Path]::GetFullPath($ObsConfigPath)
if (-not (Test-SafeConfigTarget -TargetPath $ObsConfigPath)) {
    throw "OBS設定の復元先が安全条件を満たしません。末尾がobs-studioのフォルダを指定してください: $ObsConfigPath"
}
if ($TestMode -and -not (Test-IsPathInside -CandidatePath $ObsConfigPath -ParentPath ([IO.Path]::GetTempPath()))) {
    throw 'TestModeの復元先はWindowsの一時フォルダ内に限定されます。'
}

$detectedObsPath = $null
if (-not $SkipObsInstallCheck -and -not $TestMode) {
    $detectedObsPath = Find-ObsInstallation -ExplicitPath $ObsInstallPath
    if ($null -eq $detectedObsPath) {
        throw '移行先PCにOBS Studioが見つかりません。先にOBSを公式インストーラーで導入するか、-ObsInstallPathで場所を指定してください。'
    }
}

if ([string]::IsNullOrWhiteSpace($BackupPath)) {
    $obsDirectory = Split-Path -Parent $PSScriptRoot
    $backupDirectory = Join-Path $obsDirectory 'backup'
    $backupCandidates = [Collections.Generic.List[IO.FileInfo]]::new()
    foreach ($searchDirectory in @($backupDirectory, $PSScriptRoot)) {
        if (Test-Path -LiteralPath $searchDirectory -PathType Container) {
            foreach ($file in Get-ChildItem -LiteralPath $searchDirectory -Filter '*.zip' -File) {
                if ($file.Name -match '^obs-(settings|complete)-\d{8}-\d{6}(?:-\d+)?\.zip$') {
                    $backupCandidates.Add($file)
                }
            }
        }
    }
    $latestBackup = $backupCandidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -eq $latestBackup) {
        throw '対応するOBSバックアップZIPが見つかりません。-BackupPathで指定してください。'
    }
    $BackupPath = $latestBackup.FullName
}

if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
    throw "バックアップZIPが見つかりません: $BackupPath"
}
$BackupPath = (Resolve-Path -LiteralPath $BackupPath).Path
if ([IO.Path]::GetExtension($BackupPath) -ne '.zip') {
    throw "ZIPファイルを指定してください: $BackupPath"
}

$pathMappings = @(Read-PathMappings -MapFile $PathMapFile)
$configurationSource = Join-Path $extractRoot 'configuration'
$referencesCsv = Join-Path $extractRoot 'referenced-files.csv'
$backupFormat = $null
$referenceRows = @()
$configFiles = @()
$safeConfigFiles = @()
$sensitiveConfigFiles = @()
$referencePlan = [Collections.Generic.List[object]]::new()
$sanitizedIniValueCount = 0

try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $configurationSource -Force | Out-Null

    $archive = [IO.Compression.ZipFile]::OpenRead($BackupPath)
    try {
        if ($archive.Entries.Count -gt 100000) {
            throw 'ZIP内のファイル数が安全上限を超えています。'
        }
        $totalLength = [int64]0
        $seenNames = @{}
        foreach ($entry in $archive.Entries) {
            if (-not (Test-SafeArchiveEntryName -EntryName $entry.FullName)) {
                throw "ZIP内に安全でないパスがあります: $($entry.FullName)"
            }
            $key = $entry.FullName.Replace('\', '/').ToLowerInvariant()
            if ($seenNames.ContainsKey($key)) {
                throw "ZIP内に重複するパスがあります: $($entry.FullName)"
            }
            $seenNames[$key] = $true
            $totalLength += [int64]$entry.Length
            if ($totalLength -gt 50GB) {
                throw 'ZIPの展開後サイズが安全上限を超えています。'
            }
        }

        $entryNames = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
        $isComplete = (
            $entryNames -contains 'backup-manifest.json' -and
            @($entryNames | Where-Object { $_.StartsWith('configuration/', [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        )
        $isSettings = (
            -not $isComplete -and
            (
                $entryNames -contains 'global.ini' -or
                $entryNames -contains 'user.ini' -or
                @($entryNames | Where-Object { $_.StartsWith('basic/', [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
            )
        )
        if (-not $isComplete -and -not $isSettings) {
            throw '未対応のバックアップ形式です。通常のOBS設定バックアップまたは完全バックアップを指定してください。'
        }

        if ($isComplete) {
            $backupFormat = '完全バックアップ'
            $manifestEntry = $archive.GetEntry('backup-manifest.json')
            $manifestReader = [IO.StreamReader]::new($manifestEntry.Open(), [Text.Encoding]::UTF8, $true)
            try { $manifest = $manifestReader.ReadToEnd() | ConvertFrom-Json } finally { $manifestReader.Dispose() }
            if ([string]$manifest.FormatVersion -ne '1') {
                throw "未対応の完全バックアップ形式です: $($manifest.FormatVersion)"
            }
            if ($entryNames -notcontains 'referenced-files.csv') {
                throw '完全バックアップにreferenced-files.csvがありません。'
            }
            foreach ($entry in $archive.Entries) {
                $name = $entry.FullName.Replace('\', '/')
                if ($name.StartsWith('configuration/', [StringComparison]::OrdinalIgnoreCase)) {
                    Expand-ArchiveEntrySafely -Entry $entry -DestinationRoot $configurationSource -RelativeName $name.Substring('configuration/'.Length)
                }
                elseif ($name.StartsWith('referenced-files/', [StringComparison]::OrdinalIgnoreCase)) {
                    Expand-ArchiveEntrySafely -Entry $entry -DestinationRoot $extractRoot -RelativeName $name
                }
                elseif ($name -eq 'referenced-files.csv') {
                    Expand-ArchiveEntrySafely -Entry $entry -DestinationRoot $extractRoot -RelativeName $name
                }
            }
        }
        else {
            $backupFormat = 'OBS設定バックアップ'
            foreach ($entry in $archive.Entries) {
                Expand-ArchiveEntrySafely -Entry $entry -DestinationRoot $configurationSource -RelativeName $entry.FullName
            }
        }
    }
    finally {
        $archive.Dispose()
    }

    $configFiles = @(Get-ChildItem -LiteralPath $configurationSource -File -Recurse -Force)
    if ($configFiles.Count -eq 0) {
        throw 'バックアップ内に復元できるOBS設定ファイルがありません。'
    }

    if (-not $RestoreSensitiveSettings) {
        foreach ($iniFile in $configFiles | Where-Object { $_.Extension -eq '.ini' }) {
            $sanitizedIniValueCount += Remove-SensitiveIniValues -FilePath $iniFile.FullName
        }
    }

    foreach ($file in $configFiles) {
        $relative = Get-RelativePathFromRoot -RootPath $configurationSource -ChildPath $file.FullName
        if (-not $RestoreSensitiveSettings -and (Test-SensitiveConfigFile -RelativePath $relative -FullPath $file.FullName)) {
            $sensitiveConfigFiles += $file
            Write-Verbose "機密設定の可能性があるため除外: $relative"
        }
        else {
            $safeConfigFiles += $file
        }
    }

    if (Test-Path -LiteralPath $referencesCsv -PathType Leaf) {
        $referenceRows = @(Import-Csv -LiteralPath $referencesCsv -Encoding UTF8)
    }
    foreach ($reference in $referenceRows) {
        $originalPath = [string]$reference.OriginalPath
        $archiveRelative = ([string]$reference.ArchivePath).Replace('/', '\')
        if ([string]::IsNullOrWhiteSpace($originalPath) -or
            -not $archiveRelative.StartsWith('referenced-files\', [StringComparison]::OrdinalIgnoreCase)) {
            throw '完全バックアップの外部素材一覧に不正な行があります。'
        }
        $source = Join-Path $extractRoot $archiveRelative
        if (-not (Test-IsPathInside -CandidatePath $source -ParentPath (Join-Path $extractRoot 'referenced-files')) -or
            -not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "外部素材がバックアップ内にありません: $archiveRelative"
        }
        $actualSourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        if (-not $actualSourceHash.Equals([string]$reference.SHA256, [StringComparison]::OrdinalIgnoreCase)) {
            throw "バックアップ内の外部素材が破損しています: $archiveRelative"
        }
        $target = Resolve-MappedPath -OriginalPath $originalPath -Mappings $pathMappings
        $referencePlan.Add([PSCustomObject]@{ Source = $source; Target = $target; Original = $originalPath; Hash = [string]$reference.SHA256 })
    }

    $mappedReferences = @($referencePlan | Where-Object { $null -ne $_.Target })
    $unmappedReferences = @($referencePlan | Where-Object { $null -eq $_.Target })
    $existingReferences = @($mappedReferences | Where-Object { Test-Path -LiteralPath $_.Target -PathType Leaf })

    $sceneReplacementFiles = 0
    if ($pathMappings.Count -gt 0) {
        foreach ($sceneFile in $safeConfigFiles | Where-Object { $_.FullName -match '[\\/]basic[\\/]scenes[\\/].+\.json$' }) {
            $originalText = Get-Content -LiteralPath $sceneFile.FullName -Raw -Encoding UTF8
            $remapped = Get-RemappedText -Text $originalText -Mappings $pathMappings
            if ($remapped.ReplacementCount -gt 0) { $sceneReplacementFiles++ }
        }
    }

    Write-Host "使用するZIP: $BackupPath"
    Write-Host "形式: $backupFormat"
    if ($null -ne $detectedObsPath) { Write-Host "移行先のOBS本体: $detectedObsPath（変更しません）" }
    Write-Host "設定の復元先: $ObsConfigPath"
    Write-Host "復元する設定ファイル: $($safeConfigFiles.Count) 件"
    Write-Host "機密情報の可能性があるため除外する設定: $($sensitiveConfigFiles.Count) 件"
    Write-Host "INIから除外する機密設定値: $sanitizedIniValueCount 件"
    Write-Host "外部素材: 対応済み $($mappedReferences.Count) 件 / 未対応 $($unmappedReferences.Count) 件"
    Write-Host "シーン内の素材パスを書き換えるファイル: $sceneReplacementFiles 件"
    if ($existingReferences.Count -gt 0 -and -not $OverwriteReferencedFiles) {
        Write-Host "既存のため上書きしない外部素材: $($existingReferences.Count) 件"
    }
    if ($sensitiveConfigFiles.Count -gt 0) {
        Write-Warning '配信サービス、OBS WebSocket、ブラウザCookie、または秘密値らしき設定を除外します。必要な認証は移行後にOBS上で再設定してください。'
    }
    if ($unmappedReferences.Count -gt 0) {
        Write-Warning 'PathMapFileで対応していない外部素材は復元されません。移行後にOBSで再リンクしてください。'
    }

    if ($simulationOnly) {
        Write-Host ''
        Write-Host 'シミュレーション結果: 復元計画の検証に合格しました。実際のファイルは変更していません。' -ForegroundColor Green
        return
    }

    if (-not $PSCmdlet.ShouldProcess($ObsConfigPath, '現在のOBS設定を退避し、移行先PCへバックアップを復元')) {
        return
    }

    if (Test-Path -LiteralPath $ObsConfigPath) {
        $configRollbackPath = Get-AvailablePath -BasePath "$ObsConfigPath.before-migration-$restoreStamp"
        Write-Host "現在のOBS設定を退避しています: $configRollbackPath"
        Move-Item -LiteralPath $ObsConfigPath -Destination $configRollbackPath
    }

    Write-Host 'OBS設定を復元しています...'
    New-Item -ItemType Directory -Path $ObsConfigPath -Force | Out-Null
    $configTargetCreated = $true
    foreach ($file in $safeConfigFiles) {
        $relative = Get-RelativePathFromRoot -RootPath $configurationSource -ChildPath $file.FullName
        $destination = Join-Path $ObsConfigPath $relative
        if (-not (Test-IsPathInside -CandidatePath $destination -ParentPath $ObsConfigPath)) {
            throw "設定ファイルの復元先が安全条件を満たしません: $relative"
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
    }

    if ($pathMappings.Count -gt 0) {
        foreach ($sceneFile in Get-ChildItem -LiteralPath (Join-Path $ObsConfigPath 'basic\scenes') -Filter '*.json' -File -ErrorAction SilentlyContinue) {
            $originalText = Get-Content -LiteralPath $sceneFile.FullName -Raw -Encoding UTF8
            $remapped = Get-RemappedText -Text $originalText -Mappings $pathMappings
            if ($remapped.ReplacementCount -gt 0) {
                [IO.File]::WriteAllText($sceneFile.FullName, [string]$remapped.Text, [Text.UTF8Encoding]::new($false))
            }
        }
    }

    $restoredReferences = 0
    $skippedReferences = 0
    foreach ($item in $mappedReferences) {
        $targetExists = Test-Path -LiteralPath $item.Target -PathType Leaf
        if ($targetExists -and -not $OverwriteReferencedFiles) {
            $skippedReferences++
            continue
        }
        $change = [PSCustomObject]@{ Target = [string]$item.Target; Created = -not $targetExists; Backup = $null }
        if ($targetExists) {
            $change.Backup = Get-AvailableFileBackupPath -OriginalPath $item.Target
            Copy-Item -LiteralPath $item.Target -Destination $change.Backup -Force
        }
        $referenceChanges.Add($change)
        New-Item -ItemType Directory -Path (Split-Path -Parent $item.Target) -Force | Out-Null
        Copy-Item -LiteralPath $item.Source -Destination $item.Target -Force
        $actualTargetHash = (Get-FileHash -LiteralPath $item.Target -Algorithm SHA256).Hash
        if (-not $actualTargetHash.Equals([string]$item.Hash, [StringComparison]::OrdinalIgnoreCase)) {
            throw "復元した外部素材の検証に失敗しました: $($item.Target)"
        }
        $restoredReferences++
    }

    Write-Host ''
    Write-Host '移行先PCへのOBS設定の復元が完了しました。' -ForegroundColor Green
    Write-Host "復元した外部素材: $restoredReferences 件"
    Write-Host "既存のため変更しなかった外部素材: $skippedReferences 件"
    if ($null -ne $configRollbackPath) { Write-Host "復元前のOBS設定: $configRollbackPath" }
    if (@($referenceChanges | Where-Object { $null -ne $_.Backup }).Count -gt 0) {
        Write-Host '上書き前の外部素材は、元ファイルの隣に .before-obs-migration-*.bak として残しました。'
    }
    Write-Warning 'OBSを起動し、シーン、素材、音声・映像デバイス、プラグイン、配信・録画設定を確認してください。認証情報は必要に応じて再設定してください。'
}
catch {
    Write-Warning '復元処理に失敗しました。変更した範囲を復元前の状態へ戻します。'

    for ($index = $referenceChanges.Count - 1; $index -ge 0; $index--) {
        $change = $referenceChanges[$index]
        if (Test-Path -LiteralPath $change.Target -PathType Leaf) {
            Remove-Item -LiteralPath $change.Target -Force
        }
        if ($null -ne $change.Backup -and (Test-Path -LiteralPath $change.Backup -PathType Leaf)) {
            Move-Item -LiteralPath $change.Backup -Destination $change.Target
        }
    }

    if ($configTargetCreated -and (Test-Path -LiteralPath $ObsConfigPath -PathType Container)) {
        Remove-Item -LiteralPath $ObsConfigPath -Recurse -Force
    }
    if ($null -ne $configRollbackPath -and (Test-Path -LiteralPath $configRollbackPath -PathType Container)) {
        Move-Item -LiteralPath $configRollbackPath -Destination $ObsConfigPath
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $extractRoot -PathType Container) {
        $resolvedExtractRoot = (Resolve-Path -LiteralPath $extractRoot).Path
        $expectedPrefix = [IO.Path]::GetTempPath().TrimEnd('\') + '\h1saki-obs-new-pc-'
        if (-not $resolvedExtractRoot.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "一時フォルダの安全確認に失敗しました: $resolvedExtractRoot"
        }
        Remove-Item -LiteralPath $resolvedExtractRoot -Recurse -Force
    }
}
