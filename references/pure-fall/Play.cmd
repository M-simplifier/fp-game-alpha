@echo off
setlocal
set "GAME=%~dp0release\PURE-FALL-win64-1.0.0\PURE-FALL.exe"
if not exist "%GAME%" (
  echo PURE / FALL package is missing. Run tools/package.ps1 from the source folder.
  pause
  exit /b 1
)
start "" "%GAME%"
