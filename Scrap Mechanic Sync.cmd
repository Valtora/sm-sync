@echo off
rem Keep this file tiny. Each branch ends in "exit /b" on the same line, so an update that
rem replaces this file while it runs cannot break it.
title Scrap Mechanic Sync
where wt.exe >nul 2>&1 && (start "" wt.exe -w new --size 110,42 --title "Scrap Mechanic Sync" --suppressApplicationTitle --tabColor #FF8A00 powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0sm-sync.ps1" & exit /b)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0sm-sync.ps1" & exit /b
