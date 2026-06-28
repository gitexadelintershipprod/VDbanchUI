@echo off
setlocal
set "APP_ROOT=%~dp0"
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "%APP_ROOT%src\VdbenchUI.ps1"
endlocal
