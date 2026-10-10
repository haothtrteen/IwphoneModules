@echo off
REM =====================================================
REM  Build release APK
REM
REM  Why you must run this YOURSELF (in a normal terminal):
REM  the assistant's shell runs inside a "LiteSandbox" that hooks child
REM  process creation. The Dart VM cannot create its stdio pipes there,
REM  so every flutter command dies with:
REM      CreateFile failed 231 (ERROR_PIPE_BUSY)
REM  Your own terminal is not sandboxed, so it works.
REM
REM  Usage: double-click this file, or run it from cmd/PowerShell.
REM =====================================================
setlocal
set "FLUTTER=F:\flutter\flutter_windows_3.32.8-stable\flutter\bin\flutter.bat"
cd /d "%~dp0.."

echo.
echo === Shell Manager : build release APK ===
echo working dir: %CD%
echo.

if not exist "%FLUTTER%" (
  echo [ERROR] flutter not found at:
  echo         %FLUTTER%
  echo         Edit FLUTTER= in this file if your path differs.
  exit /b 1
)

echo [1/2] flutter analyze ...
call "%FLUTTER%" --no-version-check analyze
if errorlevel 1 (
  echo.
  echo [WARN] analyze reported issues - continuing anyway
)

echo.
echo [2/2] flutter build apk --release ...
call "%FLUTTER%" --no-version-check build apk --release
if errorlevel 1 (
  echo.
  echo [FAILED] build failed - scroll up for the first error
  exit /b 1
)

echo.
echo [OK] build finished:
dir "build\app\outputs\flutter-apk\app-release.apk" | findstr /i "app-release.apk"
echo.
echo Tell the assistant it's done - it will install and verify on the device.
echo.
pause
