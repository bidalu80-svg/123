@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "PS1_SCRIPT=%SCRIPT_DIR%trigger_ipa_build.ps1"

if not exist "%PS1_SCRIPT%" (
  echo [ERROR] Missing script: %PS1_SCRIPT%
  pause
  exit /b 1
)

powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1_SCRIPT%" %*
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
  echo.
  echo Trigger failed. Press any key to close.
  pause >nul
)

exit /b %EXIT_CODE%
