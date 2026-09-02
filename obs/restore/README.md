# OBS環境移行・復元支援（Windows・動作検証中）

`restore-obs-on-new-pc_ver.0.2.ps1` は、OBSの設定バックアップを**移行先PCで実行して復元する**ための安全確認付きツールです。

> [!CAUTION]
> `ver.0.2` は隔離環境で検証中です。実際の移行先PCでOBSを起動し、映像・音声・素材・プラグインを確認するまでは完成版として扱いません。

## このツールの考え方

これは「完全自動復元」ではありません。PCごとに異なるデバイス、GPU、プラグイン、認証情報を安全に確認しながら移行する**復元支援ツール**です。

- 移行先PCで実行します。
- OBS本体は移行先へあらかじめインストールします。
- OBS本体やプラグイン本体はバックアップから上書きしません。
- OBS設定は復元前に日付付きフォルダへ退避します。
- 既知の機密設定は標準で除外します。
- 素材の保存先が変わる場合はパス対応ファイルを使用します。

## 対応するバックアップ

- `backup-obs-settings_ver.0.1.ps1` が作る `obs-settings-日時.zip`
- `obs-complete-日時.zip` 形式バージョン1

Audio、Microphone、Recording、Streamingの**種類別バックアップZIPは対象外**です。

## 標準で復元するもの

- シーンコレクション
- プロファイル
- 映像・音声・録画設定
- ホットキーなどのOBS基本設定
- 機密情報を含まないプラグイン設定
- 完全バックアップ内の外部素材（パス対応を指定したものだけ）

## 標準で復元しないもの

- OBS Studioのプログラム本体
- プラグイン本体
- 配信サービスの `service.json`
- OBS WebSocketの設定
- OBSブラウザのCookie・ログイン状態
- ファイル名または内容から秘密値の可能性を検出した設定
- パス対応を指定していない外部素材

シーンJSON内のブラウザURLなどから秘密値らしき内容を検出した場合、そのシーンJSON自体を除外することがあります。表示された除外件数を確認し、必要な設定は移行後にOBS上で再設定してください。

## 安全対策

- OBS起動中は停止します。
- ZIP内の絶対パス、`..`、重複パス、異常な展開サイズを拒否します。
- 復元先は末尾が `obs-studio` のフォルダに限定します。
- 現在の設定を `.before-migration-日時` へ退避してから復元します。
- 外部素材はSHA-256で検証します。
- 外部素材は標準で上書きしません。
- `-OverwriteReferencedFiles` を使った場合も、上書き前のファイルを `.before-obs-migration-日時.bak` として残します。
- 途中で失敗した場合は、変更した範囲を復元前の状態へ戻します。
- `-WhatIf` でZIP、機密設定、素材対応、復元件数だけを先に検証できます。

## 移行先PCでの手順

1. 公式インストーラーでOBS Studioをインストールします。
2. 必要なプラグインを、移行先PCのOBSに対応する版でインストールします。
3. バックアップZIPとこの `restore/` フォルダを移行先PCへコピーします。
4. OBS Studioを完全に終了します。
5. PowerShellで `-WhatIf` を実行します。
6. 復元先、除外件数、未対応素材数を確認します。
7. 問題がなければ `-WhatIf` を外して実行します。
8. OBSを起動し、下記の確認項目を点検します。

## まずシミュレーションする

```powershell
.\restore-obs-on-new-pc_ver.0.2.ps1 `
  -BackupPath "D:\Backup\obs-settings-20260902-120000.zip" `
  -WhatIf
```

`復元計画の検証に合格しました` と表示されても、OBS上での動作を保証するものではありません。ファイル変更を行わず、復元前の機械検証に合格したという意味です。

## 復元を実行する

```powershell
.\restore-obs-on-new-pc_ver.0.2.ps1 `
  -BackupPath "D:\Backup\obs-settings-20260902-120000.zip"
```

標準以外の場所へOBSをインストールした場合：

```powershell
.\restore-obs-on-new-pc_ver.0.2.ps1 `
  -BackupPath "D:\Backup\obs-settings-20260902-120000.zip" `
  -ObsInstallPath "D:\Apps\obs-studio"
```

## 外部素材の場所を変更する

`path-map.example.json` をコピーし、移行元と移行先の素材フォルダを記入します。

```json
{
  "mappings": [
    {
      "source": "D:\\OBS-Assets",
      "destination": "E:\\OBS-Assets"
    }
  ]
}
```

実行時に指定します。

```powershell
.\restore-obs-on-new-pc_ver.0.2.ps1 `
  -BackupPath "D:\Backup\obs-complete-20260902-120000.zip" `
  -PathMapFile ".\path-map.json"
```

完全バックアップに収録された素材だけを対応先へ復元し、シーンJSON内の一致するパスも置換します。対応がない素材は変更せず、OBSでの再リンクが必要です。

> [!WARNING]
> 実際のパス対応ファイルにWindowsユーザー名などが含まれる場合は、GitHubへ公開しないでください。サンプル以外はリポジトリの外へ保存してください。

## 機密設定も復元する場合

```powershell
.\restore-obs-on-new-pc_ver.0.2.ps1 `
  -BackupPath "D:\Backup\obs-settings-20260902-120000.zip" `
  -RestoreSensitiveSettings
```

配信キー、WebSocketパスワード、ブラウザCookie、URL内のトークンなどがコピーされる可能性があります。信頼できる自分のPC間で、ZIPの保管状態を確認した場合だけ使用してください。

## 復元後の確認

1. シーンコレクションとプロファイルを開けるか
2. 画像、動画、音声、ブラウザソースが表示されるか
3. マイク、スピーカー、キャプチャーデバイスを選び直す必要がないか
4. 追加プラグインが読み込まれているか
5. GPU、エンコーダー、録画先、解像度、FPSが移行先PCに合っているか
6. 配信サービスとOBS WebSocketの認証を再設定したか
7. 1分程度のテスト録画で、映像・ゲーム音・マイク音・音ズレを確認したか

問題がある場合は、表示された `.before-migration-日時` フォルダを削除せず保管してください。

## 開発状況

- スクリプト構文検査: 実施
- 隔離した仮環境での通常設定ZIP復元: 合格
- 隔離した仮環境での完全ZIP、素材パス変換、SHA-256検証: 合格
- `-WhatIf` の無変更確認: 合格
- エラー時ロールバック: 合格
- 実際の移行先PCでのOBS起動確認: **未実施**
- 判定: **作成済み・動作検証中**
