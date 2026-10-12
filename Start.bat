@echo off
:: Change to the directory where this batch file is located
cd /d "%~dp0"

:: Bypass execution policy and request Administrator privileges (UAC) to run the script
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0wsl-usb-autoreconnect.ps1\"' -Verb RunAs"