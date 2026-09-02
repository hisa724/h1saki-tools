# OBS設定バックアップ（Windows・試験版）

`backup-obs-settings_ver.0.1.ps1` は、OBS Studioの設定フォルダを日時付きZIPに保存するPowerShellスクリプトです。

## 現在のバージョン

- バージョン: `ver.0.1`
- 位置づけ: 初回試験版
- PowerShell本体: `backup-obs-settings_ver.0.1.ps1`
- ダブルクリック用: `backup-obs-settings_ver.0.1.cmd`

## 種類別設定バックアップ（作成済み・動作検証中）

`backup-obs-settings-by-type_ver.0.1.ps1` では、OBS画面上の用途に合わせて設定を分けて保存できます。

| 種類 | 内容 | ZIP名 |
|---|---|---|
| Audio | サンプルレート、チャンネル、デスクトップ音声、トラック設定 | `obs-settings-audio-日時.zip` |
| Microphone | マイクデバイス、音量、ミュート、モニタリング、フィルター | `obs-settings-microphone-日時.zip` |
| Recording | 録画形式、保存先、解像度、FPS、エンコーダー | `obs-settings-recording-日時.zip` |
| Streaming | 配信サービス、配信キー、映像・音声エンコーダー | `obs-settings-streaming-日時.zip` |

`backup-obs-settings-by-type_ver.0.1.cmd` をダブルクリックすると、番号で対象を選択できます。「すべて」は4種類を別々のZIPとして作成します。

> [!WARNING]
> 個別バックアップにも配信キー、トークン、Cookieなどが含まれる可能性があります。公開・共有しないでください。

> [!CAUTION]
> **実行前にOBS Studioを完全に終了してください。OBS起動中はバックアップできません。**
> 起動中の設定変更やファイル書き込みによって不完全なZIPが作られるのを防ぐため、スクリプトがOBSを検出するとバックアップを作成せず停止します。

## バックアップ対象

標準では `%APPDATA%\obs-studio` から、OBSの設定データを保存します。

### バックアップされるもの

- シーンコレクション
- プロファイル
- 配信・録画・映像・音声設定
- ソース、フィルター、画面配置の構成
- ホットキー設定
- プラグインの設定ファイル
- OBS WebSocketの設定
- OBS全体の基本設定
- ブラウザソースのCookieやログイン状態に関係するデータ

> [!WARNING]
> 配信キー、サービストークン、OBS WebSocketの認証情報、ブラウザCookieなどが含まれる可能性があります。作成したZIPをGitHub、チャット、公開クラウドなどへアップロードしないでください。

### バックアップされないもの

- OBS Studioのプログラム本体
- プラグイン本体
- 録画した動画
- シーンで参照している画像、動画、音声、フォント
- `%APPDATA%\obs-studio` の外に置いたスクリプトや設定
- OBSブラウザの一時キャッシュ
- OBSのログ、クラッシュ記録、プロファイラーデータ、更新用データ

このバックアップだけで、OBS環境のすべてを別PCへ完全移行できるわけではありません。復元先にもOBS本体、使用しているプラグイン、画像・動画・音声などの参照素材が必要です。

容量を抑えるため、次の一時データは標準でZIPから除外します。

- OBSのログ
- クラッシュ記録
- プロファイラーデータ
- 更新用データ
- OBSブラウザのキャッシュ、コードキャッシュ、GPUキャッシュ

ブラウザのCookieなど、ログイン状態の復元に関係するデータは除外対象にしていません。

## 対応環境

- Windows
- Windows PowerShell 5.1以降、またはPowerShell 7以降
- 通常インストール版のOBS Studio

ポータブル版は `-SourcePath` で設定フォルダを指定してください。

## 実行前の準備

1. OBS Studioを正常終了します。
2. [`backup-obs-settings_ver.0.1.ps1`](backup-obs-settings_ver.0.1.ps1) と [`backup-obs-settings_ver.0.1.cmd`](backup-obs-settings_ver.0.1.cmd) を同じフォルダへダウンロードします。

## もっとも簡単な実行方法

1. OBS Studioを終了します。
2. `backup-obs-settings_ver.0.1.cmd` をダブルクリックします。
3. 成功・失敗にかかわらずウィンドウが停止するので、表示内容を確認します。
4. 何かキーを押すとウィンドウが閉じます。

OBSが起動中の場合はバックアップを作成せず、安全のため停止します。

## PowerShellから実行する方法

PowerShellを開き、スクリプトを保存したフォルダへ移動します。

## 変更内容を確認する

次のコマンドでは実際のバックアップを作成しません。

```powershell
.\backup-obs-settings_ver.0.1.ps1 -WhatIf
```

## バックアップを作成する

```powershell
.\backup-obs-settings_ver.0.1.ps1
```

既定では、`backup-obs-settings_ver.0.1.ps1` と `backup-obs-settings_ver.0.1.cmd` を置いたフォルダへZIPを作成します。

```text
backup/
  backup-obs-settings_ver.0.1.cmd
  backup-obs-settings_ver.0.1.ps1
  obs-settings-YYYYMMDD-HHMMSS.zip  ← 作成されるバックアップ
```

> [!WARNING]
> バックアップZIPは `.gitignore` の対象です。配信キーなどを含む可能性があるため、Gitへ追加したり公開したりしないでください。

保存先を指定する場合：

```powershell
.\backup-obs-settings_ver.0.1.ps1 -DestinationPath "D:\Backups\OBS"
```

調査目的などで一時データも含めた完全コピーが必要な場合：

```powershell
.\backup-obs-settings_ver.0.1.ps1 -IncludeTransientData
```

通常は指定する必要はありません。

実行ポリシーにより起動できない場合は、その1回だけ次のコマンドで実行できます。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\backup-obs-settings_ver.0.1.ps1
```

## 正常終了の確認

次の表示を確認してください。

- `OBS settings backup completed.` と表示される
- 保存先に `obs-settings-YYYYMMDD-HHMMSS.zip` がある
- ZIPのサイズが0バイトではない
- ZIPを開くとOBSの設定ファイルやフォルダが入っている

## 復元について

移行先PCへの設定復元には、[`restore/` のOBS環境移行・復元支援ツール](../restore/README.md)を使用できます。完全自動ではなく、既存設定の退避、機密設定の除外、素材パスの対応確認を行いながら復元する試験版です。

ZIPは安全な場所へ保管し、最初に必ず `-WhatIf` で復元計画を確認してください。実際のOBS環境での動作確認が終わるまでは、移行元PCと復元前の設定を残してください。

## 既知の制限

- OBS起動中は標準で処理を停止します。
- OBSプログラム本体、プラグイン本体、録画ファイル、画像・動画などの参照素材はバックアップしません。
- OBS外の場所に保存された素材やスクリプトはバックアップしません。
- ポータブル版は設定フォルダの手動指定が必要です。
