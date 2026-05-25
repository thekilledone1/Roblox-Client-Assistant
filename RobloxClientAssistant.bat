@echo off
:: Unblocks both files to prevent Windows security warnings on future runs.
powershell.exe -NoProfile -Command "Unblock-File -Path '%~dp0RobloxClientAssistant.bat'; Unblock-File -Path '%~dp0RobloxClientAssistant.ps1'"
:: Launches RobloxClientAssistant.ps1 with no console window.
:: Keep this .bat in the same folder as the .ps1 file.
powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0RobloxClientAssistant.ps1"