@echo off
rem Keep this file tiny. Each branch ends in "exit /b" on the same line, so an update that
rem replaces this file while it runs cannot break it.
rem When Windows Terminal is the default terminal it hosts this window too. Closing this
rem window at once can shut Terminal down before it opens the new one, so wait 3 seconds.
rem If Terminal will not start, carry on to the next line and run in this window.
title Scrap Mechanic Sync
where wt.exe >nul 2>&1 && (start "" wt.exe -w new --size 120,42 --title "Scrap Mechanic Sync" --suppressApplicationTitle --tabColor #FF8A00 powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0sm-sync.ps1" && (ping -n 4 127.0.0.1 >nul & exit /b))
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0sm-sync.ps1" & exit /b
