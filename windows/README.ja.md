# HyperOS_SAUnlock for Windows

[English](README.md)

HyperOS 搭載端末向けの 5G SA 有効化・復元ツール（Windows / PowerShell 版）です。

## 動作要件

- Windows 10 / 11
- Windows PowerShell 5.1 または PowerShell 7
- Android platform-tools（`adb` コマンドが使用可能な環境）
- 端末側の USB デバッグ有効化（接続端末は 1 台のみ）
  *※端末が認識されない場合は、各社純正の ADB USB ドライバーを導入してください。*

## 使い方

ZIP を展開したフォルダーで PowerShell を開き、スクリプトを実行します。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\HyperOSSAUnlock.ps1

```

*※スクリプト実行が許可されている環境では `.\HyperOSSAUnlock.ps1` で直接実行可能です。*

### インタラクティブメニュー

```text
HyperOS_SAUnlock
Target: not selected

  1. Check Status
  2. Unlock (Backup)
  3. Restore
  4. Select SIM slot
  0. Exit

Select [0-4]:

```

1. **`4` で対象スロットを選択**: SIM 1（slot 0）または SIM 2（slot 1）を指定。
2. **`1` で接続確認**: Check Status で端末認識と現在値を確認。
3. **`2` で有効化**: バックアップを作成し、SA スイッチを有効化。
4. **`3` で復元**: 設定を初期バックアップの状態へロールバック。

### CLI オプション（非対話実行）

ADB のパスを個別に指定する場合:

```powershell
.\HyperOSSAUnlock.ps1 -AdbPath 'C:\Android\platform-tools\adb.exe'

```

メニューを介さずに直接実行する場合（例: SIM 2 / slot 1 の操作）:

```powershell
# 状態確認
.\HyperOSSAUnlock.ps1 -Action status -Slot 1

# 有効化（バックアップ含む）
.\HyperOSSAUnlock.ps1 -Action enable -Slot 1

# 復元
.\HyperOSSAUnlock.ps1 -Action restore -Slot 1

```

*※SIM 1 を操作する場合は `-Slot 0` を指定してください。*

## バックアップと復旧

既定の保存先: `%LocalAppData%\HyperOSSAUnlock`

* `backup.json`: 初回実行時の設定スナップショット。既存ファイルは上書きされず、端末シリアルやスロットが一致しない場合は復元をブロックします。
* `recovery.json`: 処理実行直前の状態を一時保存するセーフティネット。書き換え失敗時や処理中断時は、次回 `Restore` 実行時にこの直前状態への復旧が優先されます。
* `operation.lock`: 複数プロセスの同時実行を防止する排他制御ロック。

※別のスロットを操作する場合は、事前に元のスロットを `Restore` してからバックアップを別ディレクトリへ退避するか、`-BackupDirectory` で保存先を分けてください。

※`backup.json` には端末のシリアル番号が含まれるため、共有・公開しないよう注意してください。

## ビルドとテスト

ビルド要件: JDK、Android SDK Platform（API 23 以降）、Build-Tools（`d8` を含む環境）

リポジトリルートからビルドを実行します。

```powershell
.\windows\build.ps1 -SdkRoot 'C:\Android\Sdk'

```

*※`windows/build/HyperOSSAUnlock-windows-powershell.zip` が生成されます。*

*※特定バージョンを固定する場合は `-PlatformVersion` や `-BuildToolsVersion` を指定してください。*

モックテストの実行（接続端末の設定は変更されません）:

```powershell
.\windows\tests\Run-Tests.ps1

```

*※端末側の仕様詳細、動作確認済み機種、免責事項は [メイン README]を参照してください。*
