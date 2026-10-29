@echo off
rem Starts the dashboard. Edit the next line if your ledger_app password is different.
rem set DB_PASSWORD=LedgerApp#2026
cd /d "%~dp0"
python app.py
pause
