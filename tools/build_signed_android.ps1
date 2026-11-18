param([string]$UpdateRepository = 'CrissMagic/mianban')

$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$flutter = Join-Path $project '.tools/flutter/bin/flutter.bat'
if (!(Test-Path -LiteralPath $flutter)) { $flutter = 'flutter' }
$signing = Join-Path $project '.signing'
$keystore = Join-Path $signing 'android-release.p12'
$password = Join-Path $signing 'android-release-password.dpapi'
$fingerprintFile = Join-Path $signing 'certificate-sha256.txt'

if ($UpdateRepository -notmatch '^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$') { throw '更新仓库格式应为 owner/repo。' }
if (!$env:ANDROID_HOME) { throw '请设置 ANDROID_HOME。' }
$buildTools = Join-Path $env:ANDROID_HOME 'build-tools/36.0.0'

Push-Location $project
try {
    $version = Select-String -Path pubspec.yaml -Pattern '^version: ([0-9]+\.[0-9]+\.[0-9]+)\+([1-9][0-9]*)$'
    if (!$version) { throw 'pubspec.yaml 缺少正式发行版本。' }
    $name = $version.Matches[0].Groups[1].Value
    $code = $version.Matches[0].Groups[2].Value
    $expectedFingerprint = (Get-Content -LiteralPath $fingerprintFile -Raw).Trim()
    $env:MIANBAN_SIGNED_RELEASE = 'true'
    $env:ANDROID_KEYSTORE_FILE = $keystore
    $env:ANDROID_KEYSTORE_PASSWORD = (Get-Content -LiteralPath $password -Raw).Trim() |
        ConvertTo-SecureString | ConvertFrom-SecureString -AsPlainText
    & $flutter build apk --release "--dart-define=MIANBAN_UPDATE_REPOSITORY=$UpdateRepository"
    if ($LASTEXITCODE -ne 0) { throw '正式签名 APK 构建失败。' }

    $apk = Join-Path $project 'build/app/outputs/flutter-apk/app-release.apk'
    $certificate = & (Join-Path $buildTools 'apksigner.bat') verify --print-certs $apk
    if ($LASTEXITCODE -ne 0) { throw 'APK 签名校验失败。' }
    $actual = ($certificate | Select-String '^Signer #1 certificate SHA-256 digest: ([0-9a-f]{64})$').Matches[0].Groups[1].Value
    if ($actual -ne $expectedFingerprint) { throw 'APK 签名证书不一致。' }
    $badging = & (Join-Path $buildTools 'aapt2.exe') dump badging $apk
    if ($LASTEXITCODE -ne 0) { throw 'APK 包信息读取失败。' }
    $expected = "package: name='com.mianban.sleep' versionCode='$code' versionName='$name'"
    if (!$badging[0].StartsWith($expected)) { throw 'APK 包名或版本不匹配。' }

    $asset = "mianban-android-$name-$code.apk"
    $destination = Join-Path $project "deliverables/$asset"
    Copy-Item -LiteralPath $apk -Destination $destination
    $hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$destination.sha256" -Value "$hash  $asset" -Encoding ascii
    Write-Output $destination
} finally {
    Remove-Item Env:MIANBAN_SIGNED_RELEASE,Env:ANDROID_KEYSTORE_FILE,Env:ANDROID_KEYSTORE_PASSWORD -ErrorAction SilentlyContinue
    Pop-Location
}
