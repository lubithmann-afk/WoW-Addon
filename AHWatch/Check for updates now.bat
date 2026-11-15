@echo off
rem Starts the updater in its own window and closes, so this folder can be replaced
cd /d "%TEMP%"
start "AHWatch - check for updates" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0updater.ps1"
