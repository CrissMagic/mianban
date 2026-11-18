param([string]$Device = 'emulator-5556', [string]$Target = 'integration_test/sleep_flow_test.dart')

$ErrorActionPreference = 'Stop'
$projectPath = Split-Path $PSScriptRoot -Parent
$flutterCommand = Join-Path $projectPath '.tools/flutter/bin/flutter.bat'
if (!(Test-Path -LiteralPath $flutterCommand)) { $flutterCommand = 'flutter' }
if (!$env:ANDROID_HOME) { throw '请设置 ANDROID_HOME。' }
$adbCommand = Join-Path $env:ANDROID_HOME 'platform-tools/adb.exe'
$previousFlag = $env:ORG_GRADLE_PROJECT_MIANBAN_INTEGRATION

Push-Location $projectPath
try {
    $env:ORG_GRADLE_PROJECT_MIANBAN_INTEGRATION = 'true'
    & $flutterCommand build apk --debug --target-platform android-x64 -t $Target
    if ($LASTEXITCODE -ne 0) { throw '测试包构建失败。' }
    $metadata = Get-Content build/app/outputs/apk/debug/output-metadata.json -Raw | ConvertFrom-Json
    if ($metadata.applicationId -ne 'com.mianban.sleep.integration') { throw '测试包隔离检查失败。' }

    & $adbCommand -s $Device install -r build/app/outputs/flutter-apk/app-debug.apk
    if ($LASTEXITCODE -ne 0) { throw '测试包安装失败。' }
    foreach ($permission in @('RECORD_AUDIO', 'POST_NOTIFICATIONS')) {
        & $adbCommand -s $Device shell pm grant com.mianban.sleep.integration "android.permission.$permission"
        if ($LASTEXITCODE -ne 0) { throw "模拟器权限设置失败 $permission" }
    }
    & $flutterCommand test $Target -d $Device --no-uninstall --timeout 4m
    if ($LASTEXITCODE -ne 0) { throw 'Flutter 设备测试失败。' }
} finally {
    $env:ORG_GRADLE_PROJECT_MIANBAN_INTEGRATION = $previousFlag
    Pop-Location
}
