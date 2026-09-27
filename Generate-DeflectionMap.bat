@echo off
setlocal
cd /d "%~dp0"
echo =================================================================
echo  Alpine intelliVIEW - Job Deflection Layout Mapper
echo =================================================================
echo.

if "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Generate-DeflectionMap.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Generate-DeflectionMap.ps1" -JobNumber "%~1"
)

echo.
pause
