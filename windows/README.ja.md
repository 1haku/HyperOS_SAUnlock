# HyperOS_SAUnlock for Windows

[English](README.md)

Windows 10/11、Windows PowerShell 5.1 または PowerShell 7、Android platform-tools が必要です。`adb devices` で端末が認識され、デバッグ接続が許可されていることを確認してください。認識されない場合は、端末に対応した ADB USB ドライバーをインストールしてください。

Windows 用 ZIP をすべて同じフォルダーへ展開し、そのフォルダーで PowerShell を開いて実行します。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\HyperOSSAUnlock.ps1
```

この実行ポリシーは起動した PowerShell プロセスだけに適用されます。PC 全体の設定は変更しません。スクリプトの実行が許可されている環境では、`.\HyperOSSAUnlock.ps1` でも起動できます。

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

番号を入力して Enter を押します。結果が表示されたあと、メニューに戻ります。操作する端末だけを接続してください。最初に **4** で SIM 1（slot 0）または SIM 2（slot 1）を選択してください。通信事業者の判定は行いません。

`adb.exe` は `ANDROID_SDK_ROOT`、`ANDROID_HOME`、`%LocalAppData%\Android\Sdk`、`PATH` から探します。場所を指定することもできます。

```powershell
.\HyperOSSAUnlock.ps1 -AdbPath 'C:\Android\platform-tools\adb.exe'
```

メニューを使わずに SIM 2 を操作する例（SIM 1 は `-Slot 0`）:

```powershell
.\HyperOSSAUnlock.ps1 -Action status -Slot 1
.\HyperOSSAUnlock.ps1 -Action enable -Slot 1
.\HyperOSSAUnlock.ps1 -Action restore -Slot 1
```

## バックアップと復旧

既定の保存先は `%LocalAppData%\HyperOSSAUnlock` です。`-BackupDirectory` で変更した場合、復元時も同じ保存先を指定してください。

- `backup.json` は最初の設定を保存します。上書きしません。
- `recovery.json` は有効化する直前の状態を保存します。自動復元に失敗した場合や処理を中断した場合、**Restore** でまずその操作の直前に戻します。その後、もう一度 Restore を実行すると最初のバックアップに戻ります。
- `operation.lock` は同じ保存先を使う複数プロセスの同時操作を防ぎます。終了後もファイルが残る場合がありますが、ロックはプロセス終了時に解除されます。

復元前に端末のシリアル番号とスロットを確認します。旧バックアップは slot 0 として読み込みます。別のスロットを操作する場合は、元のスロットを復元してからバックアップを別の場所へ保管するか、別の `-BackupDirectory` を指定してください。Settings 値は端末全体に関わるため、操作を重ねた場合は逆順で復元し、SIM の構成とデータ通信用 SIM は変更しないでください。各設定の復元と読み戻しを個別に行い、失敗した項目を表示します。元々存在しなかった設定キーは削除します。バックアップ形式は macOS 版と共通ですが、PC 間で自動同期はしません。端末のシリアル番号を含むため、バックアップファイルは公開しないでください。

## ビルドとテスト

JDK を `PATH` に追加し、API 23 以降の Android SDK Platform と `d8` を含む Build-Tools をインストールしたうえで、リポジトリのルートから実行します。

```powershell
.\windows\build.ps1 -SdkRoot 'C:\Android\Sdk'
```

インストール済みの安定版から自動選択します。固定する場合は `-PlatformVersion` と `-BuildToolsVersion` を指定できます。

出力先は `windows/build/HyperOSSAUnlock-windows-powershell.zip` です。`android/SaProbe.java` をコンパイルし、スクリプト、プロセス実行用コード、DEX JAR をまとめます。配布 ZIP を使う場合、JDK や Android SDK のビルドツールは不要です。

テストでは ADB を模した処理と一時バックアップを使用します。

```powershell
.\windows\tests\Run-Tests.ps1
```

端末側の仕組み、確認済み機種、免責事項はリポジトリの README を参照してください。Windows での USB 接続は実機確認が必要です。模擬テストの成功は実機での動作確認を意味しません。
