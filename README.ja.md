# HyperOS_SAUnlock

[English](README.md) 

HyperOS を搭載した Xiaomi / Redmi 端末において、非表示・無効化されている 5G Standalone（SA）設定を ADB 経由で有効化・復元するデスクトップツールです。macOS（GUI アプリ）および Windows（PowerShell メニュー）の両環境に対応しています。

## 動作確認済み環境

* Redmi K60 Ultra (23078RKD5C) HyperOS 3.0.307.0 CNROM
* Redmi K80 (24122RKC7C) HyperOS 3.0.307.0 CNROM
* Redmi 15 5G SoftBank (A501XM) HyperOS 3.0.3.0 JP SOFTBANK ROM

※動作確認は povo でのみ行っています。他社回線でも同一のファームウェア制限が原因であれば有効化できる可能性がありますが、povo 以外は未検証です。

※本ツールは端末側の制限を解除するものであり、ハードウェア非対応バンドの解放やキャリア側の制約を解除するものではありません。実際の SA 接続可否は契約プランや電波環境に依存します。

## 対象 SIM スロット

操作前に、対象とするスロットを手動で選択してください。

* **SIM 1 (slot 0)**
* **SIM 2 (slot 1)**

※指定する番号は Android 内部の論理スロット番号（0 始まり）です。物理トレイの位置と異なる場合や eSIM を利用する場合は、端末側の SIM 設定を確認の上で該当スロットを選択してください。データ通信用 SIM の自動切り替えやキャリア判定は行いません。


## 使い方
[macOS](macos/README.md) | [Windows](windows/README.ja.md)

事前準備として、PC に Android platform-tools を導入し、端末の「開発者向けオプション」で USB デバッグを有効化して PC を許可してください（接続端末は 1 台のみ）。

### macOS

1. `HyperOS_SAUnlock.app` を起動し、対象の SIM スロットを選択する。
2. **Check Status** をクリックし、接続状態と現在の設定値を確認する。
3. **Unlock (Backup)** を実行する（設定がバックアップされ、指定スロットの SA が有効化される）。
4. 元に戻す場合は **Restore** を実行する。

### Windows

ZIP パッケージを展開し、PowerShell でスクリプトを実行します。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\HyperOSSAUnlock.ps1

```

* `[4]` SIM スロット選択（最初に設定）
* `[1]` 状態確認
* `[2]` バックアップ & 有効化
* `[3]` 復元（Restore）
* `[0]` 終了

※Windows PowerShell 5.1 または PowerShell 7 が必要です。詳細は [Windows ドキュメント](https://www.google.com/search?q=windows/README.ja.md&utm_source=gemini) を参照してください。

## バックアップ

バックアップファイルは各 OS の以下に保存されます。

* **macOS**: `~/Library/Application Support/HyperOSSAUnlock/backup.json`
* **Windows**: `%LocalAppData%\HyperOSSAUnlock\backup.json`

選択スロット、Android Settings の値（`dual_sa_enabled` を含む）、SA スイッチの状態、端末シリアル番号を保存します。既存の `backup.json` は上書きされず、シリアル番号やスロットが一致しない端末への復元は拒否されます（スロット情報のない旧バックアップは slot 0 として処理）。

有効化処理ごとに直前状態を `recovery.json` へ一時保存します。処理の中断や異常終了が発生した場合は、次回 **Restore** 実行時に直前状態への復旧が優先されます。

※別のスロットを操作する場合は、事前に現在のスロットを **Restore** で復元した上で、`backup.json` を別の場所へ退避してください。

## 仕組み

1. **システム設定（system）の書き換え**
`5g_network_mode_selection_visiable` を `1`（SA モード選択の表示）、`5g_sa_mode_disabled` を `0`（ファームウェア側の SA 無効化解除）に設定します。
2. **内部 API 呼び出し**
`sa-probe.jar` を端末の `/data/local/tmp` に転送し、`app_process` 経由で Xiaomi の `miui.radio.extphone` Binder サービスを呼び出し、指定スロットの `setUserFiveGSaEnabled(true, slot)` を実行します。
3. **反映確認**
`isUserFiveGSaEnabled(slot)` および設定値を再読み込みして成否を判定します。

## ソースからビルドする

要件: JDK、Android SDK Platform（API 23 以降）、Build-Tools（`d8` を含む環境）

### macOS

要 macOS 11 以降、Xcode Command Line Tools。

```sh
bash macos/build.sh
open "macos/build/HyperOS_SAUnlock.app"

```

### Windows

```powershell
.\windows\build.ps1 -SdkRoot 'C:\Android\Sdk'

```

※`windows/build/HyperOSSAUnlock-windows-powershell.zip` が出力されます。

### テスト実行

* **macOS**: `bash macos/test.sh`
* **Windows**: `.\windows\tests\Run-Tests.ps1`

※ADB モックを使用したテストのため、接続中端末の設定は変更されません。

## トラブルシューティング

* **端末が認識されない**: ターミナルで `adb devices` を実行して接続を確認し、端末の画面ロックを解除して USB デバッグを許可してください。
* **ADB が見つからない**: platform-tools のパスを `PATH` に通すか、`ANDROID_HOME` を設定してください。
* **Network mode が `Unknown` になる**: 一部ファームウェアで取得 API が省略されている仕様です。SA スイッチ自体の状態は「SA user switch」の値で確認してください。

## 免責事項

* 本ソフトウェアは非公式ツールであり、Xiaomi、KDDI、povo、その他通信事業者とは一切関係ありません。
* 本ツールの使用による端末の故障、ブートループ、データ消失、契約上のトラブル、その他いかなる損害についても、開発者は一切の責任を負いません。すべて自己責任で使用してください。

## ライセンス

[MIT License](https://www.google.com/search?q=LICENSE&utm_source=gemini)
