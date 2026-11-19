@echo off
cd /d "%~dp0"
echo ==========================================================
echo   Delta Force PC Optimizer - FPS Sampler
echo   1. Launch the game and get into a match
echo   2. Run this, then play for 10 minutes
echo   3. Send logs\perf_*.csv to your AI assistant
echo ==========================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\02_fps-sampler.ps1" -Minutes 10
echo.
echo Done. Check the logs folder.
pause
