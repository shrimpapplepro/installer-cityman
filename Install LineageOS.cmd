@echo off
rem Opens the LineageOS installer window for the Lumia 950 XL.
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0app\LumiaInstaller.ps1"
