@echo off
setlocal
title Accio Optimizer
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0AccioOptimizer.ps1"
if errorlevel 1 (
    echo.
    echo [Accio Optimizer] O PowerShell retornou um erro.
    echo Consulte os logs em %%ProgramData%%\AccioOptimizer\Logs
    pause
)
endlocal
