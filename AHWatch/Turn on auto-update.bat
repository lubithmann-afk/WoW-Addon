@echo off
title AHWatch auto-update
cd /d "%TEMP%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0updater.ps1" -On
