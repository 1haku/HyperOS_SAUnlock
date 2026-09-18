# HyperOS_SAUnlock

[English](README.md)

HyperOS を搭載した Xiaomi・Redmi 端末で、非表示または無効になっている 5G Standalone（SA）の設定を有効にするデスクトップツールです。ADB 経由で接続し、変更前の設定をバックアップして、あとから復元できます。macOS アプリと Windows 用 PowerShell メニューを用意しています。

対象の SIM スロットは手動で選択し、通信事業者の判定は行いません。Xiaomi 独自の電話サービスを利用するため、対応状況は端末のファームウェアに依存します。

[macOS](macos/README.md) | [Windows](windows/README.ja.md)

## 動作確認済み環境

- Redmi K60 Ultra (23078RKD5C) HyperOS 3.0.307.0 CNROM
- Redmi K80 (24122RKC7C) HyperOS 3.0.307.0 CNROM
- Redmi 15 5G SoftBank (A501XM) HyperOS 3.0.3.0 JP SOFTBANK ROM

これまでの回線検証は povo で行っています。他社回線でも同じファームウェア設定が制限の原因であれば利用できる可能性がありますが、未検証です。スイッチを有効にしても、端末にない機能の追加や、通信事業者側の制限の解除はできません。実際の SA 接続は、端末、SIM、契約、ネットワークの対応状況によって決まります。

## 対象 SIM スロット

操作前に **SIM 1（slot 0）** または **SIM 2（slot 1）** を選択してください。通信事業者の判定や、データ通信用 SIM の切り替えは行いません。

番号は Android の論理スロットを示し、物理トレイの位置とは限りません。eSIM を使用する場合は、端末の SIM 設定を確認してください。

## 使い方

### macOS

1. 端末の開発者向けオプションで「USB デバッグ」を有効にし、Mac に接続してデバッグ接続を許可する（接続端末は 1 台のみ）。
2. `HyperOS_SAUnlock.app` を起動し、対象の SIM スロットを選択する。
3. Check Status で接続と現在の設定値を確認する。
4. Unlock (Backup) を実行する（現在の設定が保存され、選択したスロットの SA が有効化される）。
5. 元に戻す場合は Restore を実行する。

### Windows

Windows 用パッケージを展開し、そのフォルダーで PowerShell を開いて実行します。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\HyperOSSAUnlock.ps1
```

最初に **4** で SIM スロットを選択します。**1** で状態確認、**2** でバックアップと有効化、**3** で復元、**0** で終了します。Windows PowerShell 5.1 または PowerShell 7 と Android platform-tools が必要です。ADB の設定やオプションは [Windows 用の説明](windows/README.ja.md) を参照してください。

## バックアップ

macOS: `~/Library/Application Support/HyperOSSAUnlock/backup.json`

Windows: `%LocalAppData%\HyperOSSAUnlock\backup.json`

選択したスロット、Android Settings の値（`dual_sa_enabled` を含む）、SA スイッチの状態、端末のシリアル番号を保存します。既存のバックアップは上書きしません。端末と選択スロットがバックアップに一致しない場合、操作を中止します。スロット情報のない旧バックアップは slot 0 として読み込みます。

別のスロットを操作する前に、元のスロットを復元し、バックアップを別の場所へ保管してください。保存する Settings 値は端末全体に関わるため、復元時は SIM の構成とデータ通信用 SIM を変更しないでください。個々の SIM カードの識別は行いません。

有効化するたびに、操作直前の状態を同じフォルダーの `recovery.json` に保存します。失敗時はこの状態への復元を試みます。復旧が未完了の場合、**Restore** はまずその復旧を再試行します。その後、もう一度 Restore を実行すると最初のバックアップに戻ります。両 OS で [バックアップ形式と補助プログラムのコマンド](docs/protocol.md) は共通です。

## 仕組み

`system/5g_network_mode_selection_visiable` を `1`、`system/5g_sa_mode_disabled` を `0` に設定し、SA の設定項目を表示・有効化します。

次に `sa-probe.jar` を端末の `/data/local/tmp` に転送し、`app_process` で実行します。この補助プログラムが Xiaomi の `miui.radio.extphone` Binder サービスを通じて、選択したスロットに対する `setUserFiveGSaEnabled(true, slot)` を呼び出します。

最後に `isUserFiveGSaEnabled(slot)` と Settings 値を読み戻します。成功と表示されるのは端末側のスイッチを確認できた場合であり、SA 接続中であることを示すものではありません。

## ソースからビルドする

要件: macOS 11 以降、Xcode Command Line Tools、JDK、API 23 以降の Android SDK Platform、`d8` を含む Build-Tools。

インストール済みの安定版から、それぞれ最も新しいバージョンを選びます。固定する場合は `ANDROID_PLATFORM` と `ANDROID_BUILD_TOOLS`、または PowerShell の `-PlatformVersion` と `-BuildToolsVersion` を指定してください。[Android のビルド手順](android/README.md)も参照できます。配布パッケージの利用にはビルド環境は不要で、ADB のみ必要です。

```sh
bash macos/build.sh
open "macos/build/HyperOS_SAUnlock.app"
```

Windows 用パッケージは、JDK を `PATH` に追加した Windows 環境で次のように作成できます。

```powershell
.\windows\build.ps1 -SdkRoot 'C:\Android\Sdk'
```

出力先は `windows/build/HyperOSSAUnlock-windows-powershell.zip` です。両方のビルドで共通の `android/SaProbe.java` をコンパイルします。OS ごとのコードは `macos/` と `windows/` にあり、生成物と端末のバックアップは `.gitignore` で除外しています。

テストは `bash macos/test.sh` または `.\windows\tests\Run-Tests.ps1` で実行できます。ADB の応答を模したテストなので、接続中の端末の設定は変更しません。Windows 用のワークフローは Windows PowerShell 5.1 と PowerShell 7 の両方で実行する構成です。

## トラブルシューティング

- 端末が認識されない: ターミナルで `adb devices` を実行して接続を確認し、端末のロックを解除して USB デバッグ接続を許可してください。
- ADB が見つからない: platform-tools を `PATH` に追加するか、`ANDROID_HOME` を設定してください。
- Network mode が `Unknown` になる: 一部のファームウェアではクエリ API が省略されているため正常な動作です。代わりに「SA user switch」の値を確認してください。

## 免責事項

- 本ソフトウェアは非公式ツールであり、Xiaomi、KDDI、povo、その他の通信事業者とは関係ありません。
- 本ツールの使用による端末の文鎮化、ブートループ、データ消失、契約上の問題、その他の損害について、開発者は一切責任を負いません。すべて自己責任で使用してください。

## ライセンス

MIT License
