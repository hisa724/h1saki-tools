# OBS設定バックアップ（Windows・試験版）

`backup-obs-settings.ps1` は、OBS Studioの設定フォルダを日時付きZIPに保存するPowerShellスクリプトです。

## バックアップ対象

標準では `%APPDATA%\obs-studio` の内容をまとめて保存します。プロファイル、シーンコレクション、プラグイン設定などが含まれます。

> [!WARNING]
> ZIPには配信キー、サービストークン、OBS WebSocketの認証情報などが含まれる可能性があります。GitHub、クラウドの共有フォルダ、チャットなどへアップロードしないでください。

## 対応環境

- Windows
- Windows PowerShell 5.1以降、またはPowerShell 7以降
- 通常インストール版のOBS Studio

ポータブル版は `-SourcePath` で設定フォルダを指定してください。

## 実行前の準備

1. OBS Studioを正常終了します。
2. [`backup-obs-settings.ps1`](../scripts/backup-obs-settings.ps1) と [`backup-obs-settings.cmd`](../scripts/backup-obs-settings.cmd) を同じフォルダへダウンロードします。

## もっとも簡単な実行方法

1. OBS Studioを終了します。
2. `backup-obs-settings.cmd` をダブルクリックします。
3. 成功・失敗にかかわらずウィンドウが停止するので、表示内容を確認します。
4. 何かキーを押すとウィンドウが閉じます。

OBSが起動中の場合はバックアップを作成せず、安全のため停止します。

## PowerShellから実行する方法

PowerShellを開き、スクリプトを保存したフォルダへ移動します。

## 変更内容を確認する

次のコマンドでは実際のバックアップを作成しません。

```powershell
.\backup-obs-settings.ps1 -WhatIf
```

## バックアップを作成する

```powershell
.\backup-obs-settings.ps1
```

既定の保存先は、Windowsの「ドキュメント」内にある `OBS-Backups` フォルダです。

保存先を指定する場合：

```powershell
.\backup-obs-settings.ps1 -DestinationPath "D:\Backups\OBS"
```

実行ポリシーにより起動できない場合は、その1回だけ次のコマンドで実行できます。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\backup-obs-settings.ps1
```

## 正常終了の確認

次の表示を確認してください。

- `OBS settings backup completed.` と表示される
- 保存先に `obs-settings-YYYYMMDD-HHMMSS.zip` がある
- ZIPのサイズが0バイトではない
- ZIPを開くとOBSの設定ファイルやフォルダが入っている

## 復元について

この試験版はバックアップ作成専用です。自動復元はまだ実装していません。ZIPを安全な場所へ保管し、復元が必要になった場合は上書きする前に現在の設定も別途バックアップしてください。

## 既知の制限

- OBS起動中は標準で処理を停止します。
- OBSプログラム本体、プラグイン本体、録画ファイル、画像・動画などの参照素材はバックアップしません。
- OBS外の場所に保存された素材やスクリプトはバックアップしません。
- ポータブル版は設定フォルダの手動指定が必要です。
