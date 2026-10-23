#!/bin/bash
# ============================================================
#  LineageOS 18.1 installer for the Microsoft Lumia 950 XL (cityman)
#  Linux version of installer.bat; same steps, same menu.
#  Needs: adb, fastboot, root (for mounting EFIESP and USB access).
# ============================================================

if [ "$EUID" -ne 0 ] && [ -z "$CITYMAN_NO_ELEVATE" ]; then
    echo "Requesting root..."
    exec sudo "$0" "$@"
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADB=${ADB:-adb}
FASTBOOT=${FASTBOOT:-fastboot}
PHONE_DIR=/tmp/cityman
STAMP=$(date +%Y%m%d-%H%M)
LOGFILE="$ROOT/install_log_$STAMP.txt"
echo "LineageOS 18.1 installer log, $STAMP" > "$LOGFILE"

log() { echo "[INFO] $*" >> "$LOGFILE"; }
err() { echo " [ERROR] $*"; echo "[ERROR] $*" >> "$LOGFILE"; }
confirm() { local a; read -r -p "  $1 (Y/N): " a; log "$1 answered [$a]"; [[ "$a" =~ ^[Yy]$ ]]; }
wait_enter() { read -r -p "  Press Enter to continue..." _; }
fail() {
    echo
    echo " Stopped. Nothing after the failed step was done."
    echo " Fix the problem above, then run installer.sh again and choose 2"
    echo " (or 4 if the phone no longer boots). Log: $LOGFILE"
    log "Stopped after an error"
    exit 1
}

# Runs cityman.sh on the phone. Success = it printed @@OK.
helper() {
    local out
    out=$("$ADB" shell "bash $PHONE_DIR/cityman.sh $*" < /dev/null 2>&1)
    echo "$out" >> "$LOGFILE"
    echo "$out" | grep -v '@@'
    echo "$out" | grep -q '@@OK\|@@STATE='
}

adb_state() { "$ADB" get-state 2>/dev/null; }

preflight() {
    local missing=0 f z
    for f in BCD bootshim.efi Stage2.efi developermenu.efi emmc_appsboot.mbn twrp.img modem.img PLAT.img; do
        [ -f "$ROOT/DATA/$f" ] || { err "Missing DATA/$f"; missing=1; }
    done
    [ -f "$ROOT/cityman.sh" ] || { err "Missing cityman.sh"; missing=1; }
    for f in "$ADB" "$FASTBOOT"; do
        command -v "$f" >/dev/null || { err "$f not found. Install it (e.g. sudo apt install adb fastboot)."; missing=1; }
    done
    for f in modem.img twrp.img; do
        if [ -f "$ROOT/DATA/$f" ] && [ "$(stat -c %s "$ROOT/DATA/$f")" -lt 1048576 ]; then
            err "DATA/$f is too small - the download is incomplete. Download the installer again."
            missing=1
        fi
    done
    use_sideload=0
    sideload_zip=""
    if [ ! -f "$ROOT/DATA/system.img" ]; then
        for z in "$ROOT"/lineage-18.1*.zip; do
            [ -s "$z" ] && { use_sideload=1; sideload_zip="$z"; }
        done
        [ "$use_sideload" = 1 ] || { err "No LineageOS zip found. Put lineage-18.1-...-cityman.zip next to installer.sh."; missing=1; }
    else
        for f in system.img vendor.img boot.img; do
            [ -f "$ROOT/DATA/$f" ] || { err "Missing DATA/$f"; missing=1; }
        done
    fi
    [ "$missing" = 0 ] || return 1
    if [ "$use_sideload" = 1 ]; then
        echo " [OK] Files present. LineageOS zip: $sideload_zip"
    else
        echo " [OK] Files present. LineageOS images in DATA/."
    fi
}

find_efiesp() {
    local dev
    EFIESP=${CITYMAN_EFIESP:-}
    while true; do
        if [ -z "$EFIESP" ]; then
            EFIESP=$(findmnt -n -o TARGET -S LABEL=EFIESP 2>/dev/null | head -n 1)
        fi
        if [ -z "$EFIESP" ] && dev=$(blkid -L EFIESP 2>/dev/null); then
            mkdir -p /tmp/cityman-efiesp
            mount "$dev" /tmp/cityman-efiesp && EFIESP=/tmp/cityman-efiesp
        fi
        if [ -n "$EFIESP" ] && [ -f "$EFIESP/EFI/Microsoft/BOOT/BCD" ]; then
            echo " [OK] Found the phone's EFIESP at $EFIESP"
            return 0
        fi
        echo
        echo " [!] Could not find the phone's EFIESP partition."
        echo "     - Is the phone in Mass Storage Mode? lsblk should then show a"
        echo "       partition labelled EFIESP."
        echo "     - Was the bootloader unlocked with WPinternals first?"
        read -r -p "  R = look again, or type the EFIESP mount path, Q = quit: " EFIESP
        case "$EFIESP" in
            [Qq]) return 1 ;;
            [Rr]) EFIESP="" ;;
        esac
    done
}

ensure_twrp() {
    local polls=0 boots=0 state
    while true; do
        state=$(adb_state)
        case "$state" in
            recovery) break ;;
            sideload) echo "  Phone is in ADB sideload mode: tap Cancel on the phone."; sleep 5; continue ;;
            device) echo "  Android is running: rebooting to LK2ND..."; "$ADB" reboot bootloader >/dev/null 2>&1; sleep 15; continue ;;
        esac
        if "$FASTBOOT" devices 2>/dev/null | grep -q fastboot; then
            boots=$((boots + 1))
            if [ "$boots" -gt 3 ]; then
                err "fastboot boot twrp.img failed 3 times. Check that 'fastboot devices' lists the phone and that you run as root (USB permissions)."
                return 1
            fi
            echo "  LK2ND found: starting TWRP..."
            "$FASTBOOT" boot "$ROOT/DATA/twrp.img"
            sleep 20
            continue
        fi
        polls=$((polls + 1))
        if [ $((polls % 6)) = 1 ]; then
            echo "  Waiting for the phone (LK2ND, TWRP or Android over USB)..."
            echo "    - Android: enable USB debugging and accept the prompt on the phone."
        fi
        sleep 5
    done
    echo " [OK] TWRP is running."
    "$ADB" shell "mkdir -p $PHONE_DIR" < /dev/null >/dev/null 2>&1
    "$ADB" push "$ROOT/cityman.sh" "$PHONE_DIR/cityman.sh" >/dev/null 2>&1 || { err "Could not copy cityman.sh to the phone."; return 1; }
    "$ADB" push "$ROOT/DATA/emmc_appsboot.mbn" "$PHONE_DIR/emmc_appsboot.mbn" >/dev/null 2>&1 || { err "Could not copy emmc_appsboot.mbn to the phone."; return 1; }
}

backup() {
    echo " Backing up the phone's unique partitions (IMEI, radio calibration, MACs)..."
    helper backup || return 1
    rm -rf "$ROOT/cityman-backup"
    "$ADB" pull /tmp/cityman-backup "$ROOT/cityman-backup" >> "$LOGFILE" 2>&1
    if [ ! -s "$ROOT/cityman-backup/DPP.bin" ]; then
        err "Could not copy the backup to this PC. Nothing was changed on the phone."
        return 1
    fi
    BACKUP_SAVED="$ROOT/backup-$STAMP"
    rm -rf "$BACKUP_SAVED"
    mv "$ROOT/cityman-backup" "$BACKUP_SAVED"
    [ -n "$SUDO_USER" ] && chown -R "$SUDO_USER" "$BACKUP_SAVED"
    echo " [OK] Backup saved to $BACKUP_SAVED"
    log "Backup saved to $BACKUP_SAVED"
}

phone_state() {
    PHONE_STATE=$("$ADB" shell "bash $PHONE_DIR/cityman.sh state" < /dev/null 2>/dev/null | tr -d '\r' | sed -n 's/^@@STATE=//p')
    [ -n "$PHONE_STATE" ] || { err "Could not read the phone's partition table."; return 1; }
    log "Partition layout: $PHONE_STATE"
}

repartition() {
    echo
    echo " [WARNING] Next: delete Windows (MainOS, Data) and create the Android"
    echo "           partitions. Windows and everything stored in it is erased."
    echo "           Your backup is in $BACKUP_SAVED"
    confirm "Repartition now?" || return 1
    if [ -f "$ROOT/DATA/PLAT.img" ]; then
        "$ADB" push "$ROOT/DATA/PLAT.img" "$PHONE_DIR/PLAT.img" >/dev/null 2>&1
        helper flash PLAT "$PHONE_DIR/PLAT.img"
    fi
    echo " Repartitioning, about a minute..."
    helper partition || return 1
    echo " [OK] Repartitioned."
}

check_aboot() {
    helper verify-aboot && return 0
    echo " LK2ND on the aboot partition is damaged, rewriting it..."
    helper repair-aboot
}

flash_firmware() {
    "$ADB" push "$ROOT/DATA/twrp.img" "$PHONE_DIR/twrp.img" >/dev/null 2>&1 || { err "Could not copy twrp.img to the phone."; return 1; }
    helper flash recovery "$PHONE_DIR/twrp.img" || return 1
    "$ADB" push "$ROOT/DATA/modem.img" "$PHONE_DIR/modem.img" >/dev/null 2>&1 || { err "Could not copy modem.img to the phone."; return 1; }
    helper flash modem "$PHONE_DIR/modem.img" || return 1
    "$ADB" shell "rm -f $PHONE_DIR/twrp.img $PHONE_DIR/modem.img" < /dev/null >/dev/null 2>&1
}

install_os() {
    local polls p
    if [ "$use_sideload" = 1 ]; then
        confirm "Install LineageOS from $sideload_zip?" || return 1
        "$ADB" shell twrp sideload < /dev/null >/dev/null 2>&1
        polls=0
        until [ "$(adb_state)" = sideload ]; do
            polls=$((polls + 1))
            [ "$polls" = 4 ] && echo "  Waiting for sideload mode. If nothing happens: on the phone tap Advanced, ADB Sideload, swipe."
            sleep 3
        done
        echo " Sending LineageOS, a few minutes..."
        # adb sideload often exits non-zero ("failed to read command") even on
        # success, so check the result on the phone instead of the exit code.
        "$ADB" sideload "$sideload_zip"
        polls=0
        until [ "$(adb_state)" = recovery ]; do
            polls=$((polls + 1))
            [ "$polls" -gt 24 ] && { err "TWRP did not come back after the install. Look at the phone screen."; return 1; }
            sleep 5
        done
        helper verify-system || { err "LineageOS is not on the system partition. The TWRP screen shows why."; return 1; }
        "$ADB" reboot >/dev/null 2>&1
    else
        confirm "Flash system, vendor and boot from DATA/ with fastboot?" || return 1
        "$ADB" reboot bootloader >/dev/null 2>&1
        until "$FASTBOOT" devices 2>/dev/null | grep -q fastboot; do sleep 5; done
        for p in system vendor boot; do
            echo " Flashing $p..."
            "$FASTBOOT" flash "$p" "$ROOT/DATA/$p.img" || { err "fastboot flash $p failed. Use the LineageOS zip instead."; return 1; }
        done
        "$FASTBOOT" reboot >/dev/null 2>&1
    fi
}

copy_file() {
    cp -f "$1" "$2" && cmp -s "$1" "$2" || { err "Copying $(basename "$1") to $2 failed."; return 1; }
    echo "  copied $(basename "$1")"
}

new_install() {
    preflight || fail
    log "New install"
    echo
    echo " --- Step 1 of 5: Patch EFIESP ---"
    find_efiesp || fail
    echo
    echo " This overwrites the Windows boot configuration on $EFIESP"
    echo " so the phone boots LK2ND instead of Windows."
    confirm "Continue?" || { echo " Cancelled."; exit 1; }
    local bootdir="$EFIESP/Windows/System32/BOOT"
    copy_file "$ROOT/DATA/BCD" "$EFIESP/EFI/Microsoft/BOOT/BCD" || fail
    copy_file "$ROOT/DATA/bootshim.efi" "$bootdir/bootshim.efi" || fail
    copy_file "$ROOT/DATA/developermenu.efi" "$bootdir/developermenu.efi" || fail
    copy_file "$ROOT/DATA/Stage2.efi" "$EFIESP/Stage2.efi" || fail
    copy_file "$ROOT/DATA/emmc_appsboot.mbn" "$EFIESP/emmc_appsboot.mbn" || fail
    mkdir -p "$bootdir/ui" && cp -f "$ROOT"/ui/* "$bootdir/ui/" || { err "Copying the ui folder failed."; fail; }
    sync
    [ "$EFIESP" = /tmp/cityman-efiesp ] && umount /tmp/cityman-efiesp
    echo " [OK] EFIESP patched."
    log "EFIESP patched at $EFIESP"
    echo
    echo " Now reboot the phone into LK2ND:"
    echo "   - Hold the Power button about 10 seconds until it vibrates, then let go."
    echo "   - Keep the USB cable connected."
    echo "   - The phone should show a black screen with text: that is LK2ND."
    echo " If it shows the Windows logo or the sad face, run option 4."
    wait_enter
    continue_install
}

continue_install() {
    preflight || fail
    log "Continue install"
    echo
    echo " --- Step 2 of 5: Start TWRP ---"
    ensure_twrp || fail
    echo
    echo " --- Step 3 of 5: Back up and repartition ---"
    backup || fail
    phone_state || fail
    case "$PHONE_STATE" in
        partitioned) echo " [OK] Already partitioned for Android, skipping repartition."; check_aboot || fail ;;
        windows) repartition || fail ;;
        *) err "The phone has neither the Windows nor the Android partition layout."
           echo "        Stop here and ask for help; do not repartition by hand."; fail ;;
    esac
    echo
    echo " --- Step 4 of 5: Recovery, modem firmware, provisioning ---"
    flash_firmware || fail
    helper provision || fail
    echo
    echo " --- Step 5 of 5: Install LineageOS ---"
    install_os || fail
    echo
    echo " ============================================================"
    echo "  Done. The phone is rebooting into LineageOS."
    echo "  The first boot takes a few minutes."
    echo "  Keep the backup folder: $BACKUP_SAVED"
    echo " ============================================================"
    log "Install finished"
}

repair() {
    preflight || fail
    log "Repair"
    echo
    echo " Repair rewrites the recovery and modem partitions and redoes"
    echo " provisioning. Apps and files are kept."
    ensure_twrp || fail
    phone_state || fail
    [ "$PHONE_STATE" = partitioned ] || { err "The phone is not partitioned for Android yet. Use option 2."; fail; }
    check_aboot || fail
    flash_firmware || fail
    helper provision || fail
    echo
    echo " [OK] Repair done, rebooting."
    "$ADB" reboot >/dev/null 2>&1
    log "Repair finished"
}

rescue_bootloop() {
    log "Rescue bootloop"
    echo
    echo " Put the phone in Mass Storage Mode first:"
    echo "   - Hold Power + Volume Down about 10 seconds until it vibrates,"
    echo "     then hold the Camera button to open the Developer Menu"
    echo "     and choose Mass Storage Mode."
    wait_enter
    find_efiesp || fail
    copy_file "$ROOT/DATA/emmc_appsboot.mbn" "$EFIESP/emmc_appsboot.mbn" || fail
    [ -f "$EFIESP/Stage2.efi" ] || copy_file "$ROOT/DATA/Stage2.efi" "$EFIESP/Stage2.efi" || fail
    sync
    [ "$EFIESP" = /tmp/cityman-efiesp ] && umount /tmp/cityman-efiesp
    echo
    echo " [OK] LK2ND copied to $EFIESP"
    echo " Hold Power about 10 seconds to reboot. The phone should reach"
    echo " LK2ND or Android. Then run option 2 to finish the install."
    log "LK2ND copied to $EFIESP"
}

rescue_boot_image() {
    log "Rescue boot image"
    echo
    echo " Put the phone in Mass Storage Mode (see option 4), then continue."
    wait_enter
    bash "$ROOT/rescue.sh" twrp.img boot
}

for tries in 1 2 3 4 5; do
    echo
    echo " ============================================================"
    echo "  LineageOS 18.1 installer - Lumia 950 XL (cityman)"
    echo " ============================================================"
    echo
    echo "  1. New install         phone runs Windows, is in Mass Storage Mode"
    echo "  2. Continue install    phone shows LK2ND, TWRP or Android"
    echo "                         (checks what is done and carries on)"
    echo "  3. Repair              no sound / no mobile signal / no TWRP;"
    echo "                         rewrites modem + recovery, keeps your data"
    echo "  4. Rescue bootloop     phone in Mass Storage Mode; puts LK2ND"
    echo "                         back on EFIESP"
    echo "  5. Rescue boot image   phone in Mass Storage Mode; writes TWRP"
    echo "                         to the boot partition"
    echo "  Q. Quit"
    echo
    read -r -p "  Choose 1-5: " choice || exit 1
    case "$choice" in
        1) new_install; exit 0 ;;
        2) continue_install; exit 0 ;;
        3) repair; exit 0 ;;
        4) rescue_bootloop; exit 0 ;;
        5) rescue_boot_image; exit 0 ;;
        [Qq]) exit 0 ;;
    esac
done
exit 1
