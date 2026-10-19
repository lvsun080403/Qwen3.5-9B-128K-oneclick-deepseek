@echo off
chcp 65001 >nul
cd /d "%~dp0"
title Qwen3.5-9B Local API

if not exist "%~dp0qwen-deploy.ps1" (
    echo [x] qwen-deploy.ps1 was not found in this folder.
    echo     Both files must sit side by side: qwen-deploy.ps1 + start-qwen.bat
    echo.
    pause >nul
    exit /b 1
)

if "%~1"=="" (
    echo [*] First run takes 10-20 min: downloads runtime ^(1.5 GB^) + model ^(6 GB^).
    echo [*] Everything is installed under: %~dp0llama.cpp
    echo.
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0qwen-deploy.ps1" -Background -ApiTest
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0qwen-deploy.ps1" %*
)

echo.
echo [i] Window stays open on purpose. Press any key to close it.
echo [i] Closing this window does NOT stop the server - it keeps running in background.
pause >nul
