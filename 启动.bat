@echo off
chcp 65001 >nul
rem ZUA campus network auto-login - launcher
rem UAC prompt will appear. GUI runs elevated to manage the SYSTEM scheduled task.
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0src\app\CampusNet-GUI.ps1"
exit
