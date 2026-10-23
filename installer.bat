@echo off
:: ============================================================
::  LineageOS 18.1 installer for the Microsoft Lumia 950 XL (cityman)
:: ============================================================
::  Read README.md first. Short version:
::    1. Unlock the bootloader with WPinternals.
::    2. Put the phone in Mass Storage Mode and run this, option 1.
::    3. Follow the prompts. Everything after the first reboot runs
::       inside TWRP; fastboot is only used to start TWRP.
::  If anything fails, run it again and choose option 2: it checks
::  what is already done and continues from there.
:: ============================================================
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"

if not defined CITYMAN_NO_ELEVATE (
    net session >nul 2>&1
    if errorlevel 1 (
        echo Requesting administrator rights...
        PowerShell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
        exit /b
    )
)

set "ROOT=%~dp0"
set "ADB=%ROOT%bin\adb.exe"
set "FASTBOOT=%ROOT%bin\fastboot.exe"
set "OUT=%TEMP%\cityman_out.txt"
set "PHONE_DIR=/tmp/cityman"
set "HELPER=bash %PHONE_DIR%/cityman.sh"
for /f %%i in ('PowerShell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmm" ^<nul') do set "STAMP=%%i"
set "LOGFILE=%ROOT%install_log_%STAMP%.txt"
echo LineageOS 18.1 installer log, %STAMP% > "%LOGFILE%"
set "menu_tries=0"

:menu
set /a menu_tries+=1
if %menu_tries% GTR 5 exit /b 1
echo.
echo  ============================================================
echo   LineageOS 18.1 installer - Lumia 950 XL (cityman)
echo  ============================================================
echo.
echo   1. New install         phone runs Windows, is in Mass Storage Mode
echo   2. Continue install    phone shows LK2ND, TWRP or Android
echo                          (checks what is done and carries on)
echo   3. Repair              no sound / no mobile signal / no TWRP;
echo                          rewrites modem + recovery, keeps your data
echo   4. Rescue bootloop     phone in Mass Storage Mode; puts LK2ND
echo                          back on EFIESP
echo   5. Rescue boot image   phone in Mass Storage Mode; writes TWRP
echo                          to the boot partition
echo   Q. Quit
echo.
set "choice="
set /p "choice=  Choose 1-5: "
if /i "!choice!"=="Q" exit /b 0
if "!choice!"=="1" goto new_install
if "!choice!"=="2" goto continue_install
if "!choice!"=="3" goto repair
if "!choice!"=="4" goto rescue_bootloop
if "!choice!"=="5" goto rescue_boot_image
goto menu


REM ============================================================
REM  1. New install: patch EFIESP from Windows
REM ============================================================
:new_install
call :preflight || goto fail
call :log "New install"
echo.
echo  --- Step 1 of 5: Patch EFIESP ---
call :find_efiesp || goto fail

echo.
echo  This overwrites the Windows boot configuration on !EFIESP!
echo  so the phone boots LK2ND instead of Windows.
call :confirm "Continue?" || goto cancelled

set "BOOTDIR=!EFIESP!\Windows\System32\BOOT"
call :copy_file "%ROOT%DATA\BCD" "!EFIESP!\EFI\Microsoft\BOOT\BCD" || goto fail
call :copy_file "%ROOT%DATA\bootshim.efi" "!BOOTDIR!\bootshim.efi" || goto fail
call :copy_file "%ROOT%DATA\developermenu.efi" "!BOOTDIR!\developermenu.efi" || goto fail
call :copy_file "%ROOT%DATA\Stage2.efi" "!EFIESP!\Stage2.efi" || goto fail
call :copy_file "%ROOT%DATA\emmc_appsboot.mbn" "!EFIESP!\emmc_appsboot.mbn" || goto fail
if not exist "!BOOTDIR!\ui\" md "!BOOTDIR!\ui"
copy /y "%ROOT%ui\*" "!BOOTDIR!\ui\" >> "%LOGFILE%" 2>&1
if errorlevel 1 (
    call :err "Copying the ui folder to !BOOTDIR!\ui failed."
    goto fail
)
echo  [OK] EFIESP patched.
call :log "EFIESP patched at !EFIESP!"

echo.
echo  Now reboot the phone into LK2ND:
echo    - Hold the Power button about 10 seconds until it vibrates, then let go.
echo    - Keep the USB cable connected.
echo    - The phone should show a black screen with text: that is LK2ND.
echo  If it shows the Windows logo or the sad face, run option 4.
call :wait_enter
goto continue_install


REM ============================================================
REM  2. Continue install (inside TWRP)
REM ============================================================
:continue_install
call :preflight || goto fail
call :log "Continue install"
echo.
echo  --- Step 2 of 5: Start TWRP ---
call :ensure_twrp || goto fail

echo.
echo  --- Step 3 of 5: Back up and repartition ---
call :backup || goto fail
call :phone_state || goto fail
if "!PHONE_STATE!"=="partitioned" (
    echo  [OK] Already partitioned for Android, skipping repartition.
    call :check_aboot || goto fail
) else if "!PHONE_STATE!"=="windows" (
    call :repartition || goto fail
) else (
    call :err "The phone has neither the Windows nor the Android partition layout."
    echo         Stop here and ask for help; do not repartition by hand.
    goto fail
)

echo.
echo  --- Step 4 of 5: Recovery, modem firmware, provisioning ---
call :flash_firmware || goto fail
call :provision || goto fail

echo.
echo  --- Step 5 of 5: Install LineageOS ---
call :install_os || goto fail

echo.
echo  ============================================================
echo   Done. The phone is rebooting into LineageOS.
echo   The first boot takes a few minutes.
echo   Keep the backup folder: !BACKUP_SAVED!
echo  ============================================================
call :log "Install finished"
call :wait_enter
exit /b 0


REM ============================================================
REM  3. Repair: modem firmware + recovery + provisioning
REM ============================================================
:repair
call :preflight || goto fail
call :log "Repair"
echo.
echo  Repair rewrites the recovery and modem partitions and redoes
echo  provisioning. Apps and files are kept.
call :ensure_twrp || goto fail
call :phone_state || goto fail
if not "!PHONE_STATE!"=="partitioned" (
    call :err "The phone is not partitioned for Android yet. Use option 2."
    goto fail
)
call :check_aboot || goto fail
call :flash_firmware || goto fail
call :provision || goto fail
echo.
echo  [OK] Repair done, rebooting.
"%ADB%" reboot >nul 2>&1
call :log "Repair finished"
call :wait_enter
exit /b 0


REM ============================================================
REM  4. Rescue bootloop: LK2ND back onto EFIESP
REM ============================================================
:rescue_bootloop
call :log "Rescue bootloop"
echo.
echo  Put the phone in Mass Storage Mode first:
echo    - Hold Power + Volume Down about 10 seconds until it vibrates,
echo      then hold the Camera button to open the Developer Menu
echo      and choose Mass Storage Mode.
echo    - Or use WPinternals: Switch to Mass Storage mode.
call :wait_enter
call :find_efiesp || goto fail
call :copy_file "%ROOT%DATA\emmc_appsboot.mbn" "!EFIESP!\emmc_appsboot.mbn" || goto fail
if not exist "!EFIESP!\Stage2.efi" call :copy_file "%ROOT%DATA\Stage2.efi" "!EFIESP!\Stage2.efi" || goto fail
echo.
echo  [OK] LK2ND copied to !EFIESP!
echo  Hold Power about 10 seconds to reboot. The phone should reach
echo  LK2ND or Android. Then run option 2 to finish the install.
call :log "LK2ND copied to !EFIESP!"
call :wait_enter
exit /b 0


REM ============================================================
REM  5. Rescue boot image (raw write via Mass Storage Mode)
REM ============================================================
:rescue_boot_image
call :log "Rescue boot image"
echo.
echo  Put the phone in Mass Storage Mode (see option 4), then continue.
call :wait_enter
PowerShell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%rescue.ps1" -ImageName "twrp.img" -PartitionName "boot"
call :wait_enter
exit /b 0


REM ============================================================
REM  Steps
REM ============================================================

:preflight
set "missing=0"
for %%F in (BCD bootshim.efi Stage2.efi developermenu.efi emmc_appsboot.mbn twrp.img modem.img PLAT.img) do (
    if not exist "%ROOT%DATA\%%F" (
        call :err "Missing DATA\%%F"
        set "missing=1"
    )
)
for %%F in (cityman.sh bin\adb.exe bin\fastboot.exe ui) do (
    if not exist "%ROOT%%%F" (
        call :err "Missing %%F"
        set "missing=1"
    )
)
for %%F in ("%ROOT%DATA\modem.img" "%ROOT%DATA\twrp.img") do (
    if exist %%F if %%~zF LSS 1048576 (
        call :err "DATA\%%~nxF is only %%~zF bytes - the download is incomplete. Download the installer again."
        set "missing=1"
    )
)
set "use_sideload=0"
set "sideload_zip="
if not exist "%ROOT%DATA\system.img" (
    for %%Z in ("%ROOT%lineage-18.1*.zip") do (
        if %%~zZ GTR 0 (
            set "use_sideload=1"
            set "sideload_zip=%%~fZ"
        )
    )
    if "!use_sideload!"=="0" (
        call :err "No LineageOS zip found. Put lineage-18.1-...-cityman.zip next to installer.bat."
        set "missing=1"
    )
) else (
    for %%F in (system.img vendor.img boot.img) do (
        if not exist "%ROOT%DATA\%%F" (
            call :err "Missing DATA\%%F"
            set "missing=1"
        )
    )
)
if "!missing!"=="1" exit /b 1
if "!use_sideload!"=="1" (
    echo  [OK] Files present. LineageOS zip: !sideload_zip!
    call :log "Sideload zip: !sideload_zip!"
) else (
    echo  [OK] Files present. LineageOS images in DATA\.
)
exit /b 0


:find_efiesp
set "EFIESP="
if defined CITYMAN_EFIESP set "EFIESP=%CITYMAN_EFIESP%"
if not defined EFIESP (
    for /f "usebackq delims=" %%p in (`PowerShell -NoProfile -Command "Get-Volume -FileSystemLabel EFIESP -ErrorAction SilentlyContinue | Get-Partition | ForEach-Object AccessPaths | Where-Object { $_ -notlike '\\?\*' } | Select-Object -First 1" ^<nul`) do set "EFIESP=%%p"
)
if defined EFIESP if "!EFIESP:~-1!"=="\" set "EFIESP=!EFIESP:~0,-1!"
if defined EFIESP if exist "!EFIESP!\EFI\Microsoft\BOOT\BCD" (
    echo  [OK] Found the phone's EFIESP at !EFIESP!
    exit /b 0
)
echo.
echo  [!] Could not find the phone's EFIESP drive.
echo      - Is the phone in Mass Storage Mode? It then shows up in Explorer
echo        as several drives, one of them called EFIESP.
echo      - Was the bootloader unlocked with WPinternals first?
echo.
echo   R = look again    B = pick the EFIESP drive by hand    Q = quit
set "ans="
set /p "ans=  Choose R, B or Q: "
if /i "!ans!"=="R" goto find_efiesp
if /i not "!ans!"=="B" exit /b 1
set "EFIESP="
for /f "usebackq delims=" %%I in (`PowerShell -NoProfile -Command "(New-Object -COM 'Shell.Application').BrowseForFolder(0,'Select the phone''s EFIESP drive (it contains an EFI folder)',0,0).Self.Path" ^<nul`) do set "EFIESP=%%I"
if not defined EFIESP exit /b 1
if "!EFIESP:~-1!"=="\" set "EFIESP=!EFIESP:~0,-1!"
if exist "!EFIESP!\EFI\Microsoft\BOOT\BCD" (
    echo  [OK] Using !EFIESP!
    exit /b 0
)
call :err "!EFIESP! has no EFI\Microsoft\BOOT\BCD - that is not the phone's EFIESP."
echo         Pick the drive itself (for example F:\), not a folder on your PC.
goto find_efiesp


:ensure_twrp
REM Gets the phone into TWRP from LK2ND, Android or TWRP and pushes the helper.
set "polls=0"
set "boots=0"
:ensure_twrp_poll
call :adb_state
if "!ADB_STATE!"=="recovery" goto ensure_twrp_ready
if "!ADB_STATE!"=="sideload" (
    echo   Phone is in ADB sideload mode: tap Cancel on the phone.
    call :sleep 5
    goto ensure_twrp_poll
)
if "!ADB_STATE!"=="device" (
    echo   Android is running: rebooting to LK2ND...
    "%ADB%" reboot bootloader >nul 2>&1
    call :sleep 15
    goto ensure_twrp_poll
)
"%FASTBOOT%" devices 2>nul | findstr /c:"fastboot" >nul
if not errorlevel 1 (
    set /a boots+=1
    if !boots! GTR 3 (
        call :err "fastboot boot twrp.img failed 3 times."
        echo         Check Device Manager: the phone needs the Google USB driver,
        echo         shown as Android Bootloader Interface. See README, Troubleshooting.
        exit /b 1
    )
    echo   LK2ND found: starting TWRP...
    "%FASTBOOT%" boot "%ROOT%DATA\twrp.img"
    call :sleep 20
    goto ensure_twrp_poll
)
set /a polls+=1
set /a hint=polls %% 6
if !hint!==1 (
    echo   Waiting for the phone ^(LK2ND, TWRP or Android over USB^)...
    echo     - LK2ND: black screen with text. Not in Device Manager as
    echo       "Android Bootloader Interface"? Install the Google USB driver.
    echo     - Android: enable USB debugging and accept the prompt on the phone.
)
call :sleep 5
goto ensure_twrp_poll
:ensure_twrp_ready
echo  [OK] TWRP is running.
"%ADB%" shell "mkdir -p %PHONE_DIR%" <nul >nul 2>&1
"%ADB%" push "%ROOT%cityman.sh" %PHONE_DIR%/cityman.sh >nul 2>&1 || (call :err "Could not copy cityman.sh to the phone." & exit /b 1)
"%ADB%" push "%ROOT%DATA\emmc_appsboot.mbn" %PHONE_DIR%/emmc_appsboot.mbn >nul 2>&1 || (call :err "Could not copy emmc_appsboot.mbn to the phone." & exit /b 1)
exit /b 0


:backup
echo  Backing up the phone's unique partitions ^(IMEI, radio calibration, MACs^)...
call :helper backup || exit /b 1
if exist "%ROOT%cityman-backup\" rd /s /q "%ROOT%cityman-backup"
"%ADB%" pull /tmp/cityman-backup "%ROOT%cityman-backup" >> "%LOGFILE%" 2>&1
if not exist "%ROOT%cityman-backup\DPP.bin" (
    call :err "Could not copy the backup to this PC. Nothing was changed on the phone."
    exit /b 1
)
set "BACKUP_SAVED=%ROOT%backup-%STAMP%"
if exist "!BACKUP_SAVED!\" rd /s /q "!BACKUP_SAVED!"
move "%ROOT%cityman-backup" "!BACKUP_SAVED!" >nul
echo  [OK] Backup saved to !BACKUP_SAVED!
call :log "Backup saved to !BACKUP_SAVED!"
exit /b 0


:phone_state
set "PHONE_STATE="
call :helper state
for /f "tokens=2 delims==" %%s in ('findstr /c:"@@STATE=" "%OUT%"') do set "PHONE_STATE=%%s"
if not defined PHONE_STATE (
    call :err "Could not read the phone's partition table."
    exit /b 1
)
call :log "Partition layout: !PHONE_STATE!"
exit /b 0


:repartition
echo.
echo  [WARNING] Next: delete Windows ^(MainOS, Data^) and create the Android
echo            partitions. Windows and everything stored in it is erased.
echo            Your backup is in !BACKUP_SAVED!
call :confirm "Repartition now?" || exit /b 1
if exist "%ROOT%DATA\PLAT.img" (
    "%ADB%" push "%ROOT%DATA\PLAT.img" %PHONE_DIR%/PLAT.img >nul 2>&1
    call :helper flash PLAT %PHONE_DIR%/PLAT.img
)
echo  Repartitioning, about a minute...
call :helper partition || exit /b 1
echo  [OK] Repartitioned.
exit /b 0


:check_aboot
call :helper verify-aboot && exit /b 0
echo  LK2ND on the aboot partition is damaged, rewriting it...
call :helper repair-aboot || exit /b 1
exit /b 0


:flash_firmware
"%ADB%" push "%ROOT%DATA\twrp.img" %PHONE_DIR%/twrp.img >nul 2>&1 || (call :err "Could not copy twrp.img to the phone." & exit /b 1)
call :helper flash recovery %PHONE_DIR%/twrp.img || exit /b 1
"%ADB%" push "%ROOT%DATA\modem.img" %PHONE_DIR%/modem.img >nul 2>&1 || (call :err "Could not copy modem.img to the phone." & exit /b 1)
call :helper flash modem %PHONE_DIR%/modem.img || exit /b 1
"%ADB%" shell "rm -f %PHONE_DIR%/twrp.img %PHONE_DIR%/modem.img" <nul >nul 2>&1
exit /b 0


:provision
call :helper provision || exit /b 1
exit /b 0


:install_os
if "!use_sideload!"=="0" goto install_images
call :confirm "Install LineageOS from !sideload_zip!?" || exit /b 1
"%ADB%" shell twrp sideload <nul >nul 2>&1
set "polls=0"
:install_os_wait
call :adb_state
if "!ADB_STATE!"=="sideload" goto install_os_send
set /a polls+=1
if !polls!==4 echo   Waiting for sideload mode. If nothing happens: on the phone tap Advanced, ADB Sideload, swipe.
call :sleep 3
goto install_os_wait
:install_os_send
echo  Sending LineageOS, a few minutes...
"%ADB%" sideload "!sideload_zip!"
REM adb sideload often exits with "failed to read command" even on success,
REM so check the result on the phone instead of the exit code.
set "polls=0"
:install_os_back
call :sleep 5
call :adb_state
if "!ADB_STATE!"=="recovery" goto install_os_verify
set /a polls+=1
if !polls! GTR 24 (
    call :err "TWRP did not come back after the install. Look at the phone screen."
    exit /b 1
)
goto install_os_back
:install_os_verify
call :helper verify-system || (
    call :err "LineageOS is not on the system partition. The TWRP screen shows why."
    exit /b 1
)
"%ADB%" reboot >nul 2>&1
exit /b 0

:install_images
call :confirm "Flash system, vendor and boot from DATA\ with fastboot?" || exit /b 1
"%ADB%" reboot bootloader >nul 2>&1
:install_images_wait
"%FASTBOOT%" devices 2>nul | findstr /c:"fastboot" >nul
if errorlevel 1 (
    call :sleep 5
    goto install_images_wait
)
for %%P in (system vendor boot) do (
    echo  Flashing %%P...
    "%FASTBOOT%" flash %%P "%ROOT%DATA\%%P.img"
    if errorlevel 1 (
        call :err "fastboot flash %%P failed. Use the LineageOS zip instead: delete DATA\system.img and put the zip next to installer.bat."
        exit /b 1
    )
)
"%FASTBOOT%" reboot >nul 2>&1
exit /b 0


REM ============================================================
REM  Helpers
REM ============================================================

:helper
REM Runs cityman.sh on the phone. Success = it printed @@OK.
"%ADB%" shell "%HELPER% %*" <nul >"%OUT%" 2>&1
type "%OUT%" >> "%LOGFILE%"
findstr /v /c:"@@" "%OUT%"
findstr /c:"@@OK" "%OUT%" >nul && exit /b 0
findstr /c:"@@STATE=" "%OUT%" >nul && exit /b 0
exit /b 1

:adb_state
set "ADB_STATE="
for /f "delims=" %%s in ('""%ADB%" get-state 2>nul"') do set "ADB_STATE=%%s"
exit /b 0

:copy_file
copy /y %1 %2 >> "%LOGFILE%" 2>&1
if errorlevel 1 (
    call :err "Copying %~nx1 to %~2 failed."
    exit /b 1
)
fc /b %1 %2 <nul >nul 2>&1
if errorlevel 1 (
    call :err "%~2 does not match %~nx1 after copying."
    exit /b 1
)
echo   copied %~nx1
exit /b 0

:confirm
set "ans="
set /p "ans=  %~1 (Y/N): "
call :log "%~1 answered [!ans!]"
if /i "!ans!"=="Y" exit /b 0
exit /b 1

:wait_enter
set "ans="
set /p "ans=  Press Enter to continue..."
call :log "Enter pressed [!ans!]"
exit /b 0

:sleep
ping -n %~1 127.0.0.1 >nul
exit /b 0

:err
echo  [ERROR] %~1
echo [ERROR] %~1 >> "%LOGFILE%"
exit /b 0

:log
echo [INFO] %~1 >> "%LOGFILE%"
exit /b 0

:cancelled
echo  Cancelled. Nothing more was changed.
call :wait_enter
exit /b 1

:fail
echo.
echo  Stopped. Nothing after the failed step was done.
echo  Fix the problem above, then run installer.bat again and choose 2
echo  ^(or 4 if the phone no longer boots^). Log: %LOGFILE%
call :log "Stopped after an error"
call :wait_enter
exit /b 1
