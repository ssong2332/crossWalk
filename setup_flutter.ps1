# Flutter 설치 및 프로젝트 초기화 스크립트
# 관리자 권한 없이 실행 가능

$ErrorActionPreference = "Stop"

Write-Host "=== 횡단보도 앱 Flutter 설정 스크립트 ===" -ForegroundColor Cyan

# 1. Flutter SDK 다운로드 경로 확인
$flutterDir = "C:\flutter"
if (Test-Path "$flutterDir\bin\flutter.bat") {
    Write-Host "[OK] Flutter 이미 설치됨: $flutterDir" -ForegroundColor Green
} else {
    Write-Host "[INFO] Flutter SDK 다운로드 중 (stable 최신)..." -ForegroundColor Yellow
    $zipPath = "$env:TEMP\flutter_sdk.zip"
    Invoke-WebRequest -Uri "https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.32.2-stable.zip" -OutFile $zipPath
    Write-Host "[INFO] 압축 해제 중 (C:\flutter)..."
    Expand-Archive -Path $zipPath -DestinationPath "C:\" -Force
    Remove-Item $zipPath
    Write-Host "[OK] Flutter SDK 설치 완료" -ForegroundColor Green
}

# 2. PATH에 추가
$currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if ($currentPath -notlike "*C:\flutter\bin*") {
    [Environment]::SetEnvironmentVariable("PATH", "$currentPath;C:\flutter\bin", "User")
    $env:PATH = "$env:PATH;C:\flutter\bin"
    Write-Host "[OK] Flutter PATH 등록 완료" -ForegroundColor Green
}

# 3. flutter doctor 실행
Write-Host "`n[INFO] flutter doctor 실행..." -ForegroundColor Yellow
& "C:\flutter\bin\flutter.bat" doctor

# 4. crosswalk_app 스캐폴드 생성 (temp 폴더)
$tempApp = "$env:TEMP\crosswalk_app_scaffold"
if (Test-Path $tempApp) { Remove-Item $tempApp -Recurse -Force }

Write-Host "`n[INFO] Flutter 프로젝트 스캐폴드 생성 중..." -ForegroundColor Yellow
& "C:\flutter\bin\flutter.bat" create --org com.example --project-name crosswalk_app $tempApp

# 5. 스캐폴드의 android/ 폴더를 우리 프로젝트로 복사 (우리 파일 보존)
$targetApp = "C:\crossWalk\crosswalk_app"
$scaffoldAndroid = "$tempApp\android"
$targetAndroid = "$targetApp\android"

Write-Host "[INFO] Android 플랫폼 파일 복사 중..." -ForegroundColor Yellow
if (Test-Path $targetAndroid) {
    # 우리가 커스터마이즈한 파일들은 보존
    Copy-Item "$scaffoldAndroid\gradlew" "$targetAndroid\gradlew" -Force
    Copy-Item "$scaffoldAndroid\gradlew.bat" "$targetAndroid\gradlew.bat" -Force
    Copy-Item "$scaffoldAndroid\gradle\wrapper\gradle-wrapper.jar" "$targetAndroid\gradle\wrapper\gradle-wrapper.jar" -Force
    # res 폴더 복사 (아이콘 등)
    Copy-Item "$scaffoldAndroid\app\src\main\res" "$targetAndroid\app\src\main\res" -Recurse -Force
} else {
    Copy-Item $scaffoldAndroid $targetAndroid -Recurse
}

# local.properties 생성
"sdk.dir=C:\\Users\\$env:USERNAME\\AppData\\Local\\Android\\Sdk`nflutter.sdk=C:\\flutter" | Out-File "$targetAndroid\local.properties" -Encoding utf8

Remove-Item $tempApp -Recurse -Force

# 6. pub get
Write-Host "`n[INFO] flutter pub get 실행 중..." -ForegroundColor Yellow
Push-Location $targetApp
& "C:\flutter\bin\flutter.bat" pub get
Pop-Location

Write-Host "`n=== 설정 완료! ===" -ForegroundColor Green
Write-Host "다음 단계:" -ForegroundColor Cyan
Write-Host "  1. Python 학습 완료 후 TFLite 모델을 생성하세요"
Write-Host "  2. 생성된 .tflite 파일을 C:\crossWalk\crosswalk_app\assets\model\ 에 복사"
Write-Host "  3. Android 기기 연결 후: cd C:\crossWalk\crosswalk_app && flutter run"
