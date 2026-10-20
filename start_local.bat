@echo off
cd /d "%~dp0"
py -3 start_local.py
if errorlevel 1 python start_local.py
pause
