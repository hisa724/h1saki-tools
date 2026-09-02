# OBS 待機画面シーンの追加

配信開始前・休憩中に切り替える「待機画面」シーンを、スクリプト1本でOBSに追加します。

## 何ができるか

| ソース | 内容 |
|---|---|
| `待機画面_動画` | ループ動画。切り替えるたびに先頭から再生。全画面（内側に収める） |
| `待機画面_BGM` | BGM。ループ。ゲイン → リミッター |
| `待機画面_文字` | 案内テキスト。画面下部・中央揃え。縁取りつき |

既に同名のシーンがあれば**中身を作り直します**（2回実行しても増えません）。
現在選択中のシーンは変更しません。適用前にシーンJSONを `../backup/` へ日付付きで退避します。

## 使い方

### 1. `obs/settings.ini` に動画とBGMのパスを書く（推奨）

`obs/settings.example.ini` を同じフォルダに **`settings.ini`** という名前でコピーして、`[standby]` を書き換えます。

```ini
[standby]
SceneName=待機画面
VideoPath=C:\obs\standby\standby_loop.mp4     ; 必須。継ぎ目を消したループ動画
BgmPath=C:\obs\standby\bgm.wav                ; 空にするとBGMなし
BgmGainDb=-8
Line1=まもなく配信を開始します
Line2=22:00〜
FontName=LINE Seed JP ExtraBold
FontSize=88
```

### 2. OBS を**完全に終了**して `add-standby-scene_ver.0.1.cmd` をダブルクリック

引数で上書きもできます（引数 > settings.ini > 既定値）。

```powershell
.\add-standby-scene_ver.0.1.ps1 -WhatIf                 # 確認だけ
.\add-standby-scene_ver.0.1.ps1 -Line2 '21:00〜'         # 今日だけ時刻を変える
.\add-standby-scene_ver.0.1.ps1 -BgmGainDb -12          # BGMを下げる
```

| パラメーター / ini キー | 既定 | 説明 |
|---|---|---|
| `SceneName` | 待機画面 | シーン名 |
| `VideoPath` | **必須** | ループ動画。**継ぎ目を消した版**を使う |
| `BgmPath` | （なし） | 指定するとBGMソースを作る。**空ならBGMなし** |
| `Line1` / `Line2` | まもなく配信を開始します / （空） | 案内テキスト。**両方空なら文字ソースを作らない** |

### 要らないものを外す

| 外したいもの | やること |
|---|---|
| BGM | `BgmPath=` を空にする |
| 文字 | `Line1=` と `Line2=` を両方空にする |
| 動画の位置・大きさ・文字の見た目を変える | スクリプト内の `New-Item2 ... -BoundsType` の行（動画・文字の配置）と `$textSrc` のブロック（フォント・色・縁取り）を編集する。編集後は `-WhatIf` で確認 |

シーンは**毎回作り直し**なので、OBS 上で手で足したものは次の実行で消えます。残したいものは別シーンに置いてください。
| `-BgmGainDb` | -8 | BGMのゲイン |
| `-Line1` / `-Line2` | まもなく配信を開始します / （空） | 案内テキスト。2行目が空なら1行 |
| `-FontName` / `-FontSize` | LINE Seed JP ExtraBold / 88 | フォント |

## 動画をループ用に整える

10秒程度の短い動画は、そのままループすると継ぎ目で絵が飛びます。
末尾1秒と先頭1秒をクロスフェードで重ねると、継ぎ目が消えます（尺は1秒短くなる）。

```bash
ffmpeg -i standby.mp4 -filter_complex \
 "[0:v]trim=1:9.04,setpts=PTS-STARTPTS[body];[0:v]trim=9.04:10.04,setpts=PTS-STARTPTS[tail];[0:v]trim=0:1,setpts=PTS-STARTPTS[head];[tail][head]xfade=transition=fade:duration=1:offset=0[seam];[body][seam]concat=n=2:v=1:a=0,format=yuv420p[v]" \
 -map "[v]" -r 24 -c:v libx264 -crf 18 -preset slow -movflags +faststart standby_loop.mp4
```

（`9.04` = 元の尺 − 1 秒。尺に合わせて置き換える）
5分の動画に伸ばす必要はありません。OBS のメディアソースがループします。

## 注意

- **BGMがAI生成（Suno等）の場合、YouTubeアーカイブでAI開示が必要**になります
- 文字はOBS上でテキストソースを直接編集して構いません。ただし次にこのスクリプトを実行すると `-Line1/-Line2` の内容で作り直されます
- 動画が 1280×720 でもキャンバス 1920×1080 に拡大して収めます。背景用途なら問題ない範囲です

## 元に戻す

`../backup/scenes-before-standby-<日時>.json` をシーンコレクションに上書き（OBS は終了しておく）。
