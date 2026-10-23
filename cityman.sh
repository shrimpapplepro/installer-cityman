#!/bin/bash
# Lumia 950 XL (cityman) install helper. Runs inside TWRP; pushed to /tmp by
# installer.bat / installer.sh.
#
#   bash cityman.sh state             print @@STATE=windows|partitioned|unknown
#   bash cityman.sh backup            dump phone-unique partitions to /tmp/cityman-backup
#   bash cityman.sh partition         delete Windows MainOS/Data/MMOS, create Android layout
#   bash cityman.sh verify-aboot      check LK2ND is readable on aboot
#   bash cityman.sh repair-aboot      reformat aboot and put LK2ND back on it
#   bash cityman.sh flash NAME FILE   write FILE to partition NAME and verify it
#   bash cityman.sh provision         copy modem calibration + MAC addresses from DPP
#   bash cityman.sh verify-system     check LineageOS is on the system partition
#
# Every command prints @@OK as its last line on success; the installers look
# for it. Partitions are found by their exact GPT name through parted, never
# through /dev/block/.../by-name: those links do not exist for partitions
# created in the current TWRP session.

DISK=${CITYMAN_DISK:-/dev/block/mmcblk0}
WORK=/tmp/cityman
BACKUP_DIR=/tmp/cityman-backup
LK2ND=emmc_appsboot.mbn

die() { echo "[ERROR] $*"; exit 1; }

partnum() {
    parted -s -m "$DISK" print 2>/dev/null | awk -F: -v n="$1" '$6==n{print $1; exit}'
}

partdev() {
    local n
    n=$(partnum "$1")
    [ -n "$n" ] && echo "${DISK}p${n}"
}

md5_of() { md5sum | awk '{print $1}'; }

# The kernel adds a new partition's device node a moment after parted
# returns; formatting before it exists fails.
wait_node() {
    local t
    for t in 1 2 3 4 5 6 7 8 9 10; do
        [ -b "$1" ] && return 0
        sleep 1
    done
    return 1
}

cmd_state() {
    if [ -n "$(partnum aboot)" ] && [ -n "$(partnum userdata)" ]; then
        echo "@@STATE=partitioned"
    elif [ -n "$(partnum MainOS)" ] && [ -n "$(partnum Data)" ]; then
        echo "@@STATE=windows"
    else
        echo "@@STATE=unknown"
    fi
}

# Partitions that hold this phone's IMEI, radio calibration and MAC
# addresses. They cannot be downloaded again; keep the copy safe.
BACKUP_PARTS="APDP DBI DDR DPO DPP LIMITS MODEM_FS1 MODEM_FS2 MODEM_FSC MODEM_FSG MSADP SEC SSD UEFI_BS_NV UEFI_RT_NV"
CRITICAL_PARTS="DPP MODEM_FS1 MODEM_FS2 MODEM_FSC MODEM_FSG SSD"

cmd_backup() {
    rm -rf "$BACKUP_DIR"
    mkdir -p "$BACKUP_DIR" || die "cannot create $BACKUP_DIR"
    parted -s -m "$DISK" print > "$BACKUP_DIR/partitions.txt" 2>&1
    local p dev
    for p in $BACKUP_PARTS; do
        dev=$(partdev "$p")
        if [ -z "$dev" ]; then
            echo "  $p: not found, skipped"
            continue
        fi
        dd if="$dev" of="$BACKUP_DIR/$p.bin" bs=65536 2>/dev/null || die "reading $p failed"
        echo "  $p: $(stat -c %s "$BACKUP_DIR/$p.bin") bytes"
    done
    for p in $CRITICAL_PARTS; do
        [ -s "$BACKUP_DIR/$p.bin" ] || die "$p is missing from the backup"
    done
    echo "@@OK"
}

cmd_partition() {
    case "$(cmd_state)" in
        "@@STATE=windows") ;;
        "@@STATE=partitioned") die "the phone is already partitioned for Android - nothing to do. Continue with the install step instead." ;;
        *) die "unexpected partition layout (no MainOS/Data and no Android partitions). Stop here and ask for help." ;;
    esac
    [ -s "$WORK/$LK2ND" ] || die "$WORK/$LK2ND missing (the installer pushes it)"

    local n
    for p in Data MainOS MMOS; do
        n=$(partnum "$p")
        if [ -z "$n" ]; then
            echo "$p not found, skipped"
            continue
        fi
        echo "Deleting $p (GPT nr. $n)"
        parted -s "$DISK" rm "$n" || die "deleting $p failed"
    done

    echo "Creating Android partitions"
    local androidPartitions=("aboot"      "1MiB"     "fat16"
                             "boot"       "34MiB"    "ext4"
                             "recovery"   "34MiB"    "ext4"
                             "misc"       "16MiB"    "ext4"
                             "modem"      "70MiB"    "fat16"
                             "cache"      "150MiB"   "ext4"
                             "persist"    "68MiB"    "ext4"
                             "persistent" "68MiB"    "ext4"
                             "fsc"        "1MiB"     "ext4"
                             "fsg"        "2MiB"     "ext4"
                             "metadata"   "2MiB"     "ext4"
                             "ssd"        "2MiB"     "ext4"
                             "modemst1"   "2MiB"     "ext4"
                             "modemst2"   "2MiB"     "ext4"
                             "vendor"     "384MiB"   "ext4"
                             "system"     "3072MiB"  "ext4"
                             "userdata"   "100%"     "ext4")
    local i last_line end_size total_size newpart
    for ((i=0; i<${#androidPartitions[@]}; i+=3)); do
        last_line=$(parted -s "$DISK" unit MiB print | grep -E '^\s*[0-9]' | tail -n 1)
        end_size=$(echo "$last_line" | awk '{print $3}')
        if [ "${androidPartitions[i+1]}" != "100%" ]; then
            total_size=$(( ${androidPartitions[i+1]//[^0-9]/} + ${end_size//[^0-9]/} ))
        else
            total_size="100%"
        fi
        echo "${androidPartitions[i]}: ${end_size} -> ${total_size}"
        parted -s "$DISK" unit MiB mkpart "${androidPartitions[i]}" "$end_size" "$total_size" \
            || die "creating ${androidPartitions[i]} failed"
        sleep 1
        sync

        newpart=$(partnum "${androidPartitions[i]}")
        [ -n "$newpart" ] || die "${androidPartitions[i]} not found after creating it"
        wait_node "${DISK}p${newpart}" || die "${DISK}p${newpart} did not appear"
        if [ "${androidPartitions[i+2]}" = "fat16" ]; then
            mkfs.fat "${DISK}p${newpart}" >/dev/null || die "formatting ${androidPartitions[i]} failed"
        else
            mke2fs -q -t ext4 "${DISK}p${newpart}" 2>&1 | grep -v 'too small for a journal'
            [ "${PIPESTATUS[0]}" = 0 ] || die "formatting ${androidPartitions[i]} failed"
        fi
    done

    install_lk2nd
    cmd_verify_aboot
}

# LK2ND goes on aboot, and a copy stays on EFIESP: Stage2.efi loads
# emmc_appsboot.mbn from whichever FAT volume has it, so the EFIESP copy
# keeps the phone bootable if aboot is ever damaged.
install_lk2nd() {
    local aboot efiesp
    aboot=$(partdev aboot) || die "aboot not found"
    efiesp=$(partdev EFIESP) || die "EFIESP not found"
    mkdir -p "$WORK/aboot" "$WORK/efiesp"
    mount -t vfat "$aboot" "$WORK/aboot" || die "cannot mount aboot"
    cp "$WORK/$LK2ND" "$WORK/aboot/$LK2ND" || die "copying LK2ND to aboot failed"
    umount "$WORK/aboot"
    if mount -t vfat "$efiesp" "$WORK/efiesp"; then
        [ -s "$WORK/efiesp/$LK2ND" ] || cp "$WORK/$LK2ND" "$WORK/efiesp/$LK2ND"
        umount "$WORK/efiesp"
    fi
    sync
}

cmd_verify_aboot() {
    local aboot want got
    aboot=$(partdev aboot) || die "aboot not found"
    mkdir -p "$WORK/aboot"
    mount -t vfat -o ro "$aboot" "$WORK/aboot" 2>/dev/null || die "aboot is not a FAT volume - LK2ND cannot load from it"
    if [ ! -s "$WORK/aboot/$LK2ND" ]; then
        umount "$WORK/aboot"
        die "aboot has no $LK2ND"
    fi
    got=$(md5_of < "$WORK/aboot/$LK2ND")
    umount "$WORK/aboot"
    if [ -s "$WORK/$LK2ND" ]; then
        want=$(md5_of < "$WORK/$LK2ND")
        [ "$got" = "$want" ] || die "$LK2ND on aboot does not match the installer's copy"
    fi
    echo "aboot: LK2ND present ($got)"
    echo "@@OK"
}

cmd_repair_aboot() {
    local aboot
    aboot=$(partdev aboot) || die "aboot not found"
    [ -s "$WORK/$LK2ND" ] || die "$WORK/$LK2ND missing (the installer pushes it)"
    umount "$aboot" 2>/dev/null
    mkfs.fat "$aboot" >/dev/null || die "formatting aboot failed"
    install_lk2nd
    cmd_verify_aboot
}

cmd_verify_system() {
    local system prop version
    system=$(partdev system) || die "system not found"
    mkdir -p "$WORK/system"
    mount -t ext4 -o ro "$system" "$WORK/system" || die "cannot mount system"
    for prop in "$WORK/system/build.prop" "$WORK/system/system/build.prop"; do
        [ -f "$prop" ] && version=$(grep '^ro.lineage.version=' "$prop" | cut -d= -f2) && break
    done
    umount "$WORK/system"
    [ -n "$version" ] || die "no LineageOS build on the system partition"
    echo "LineageOS $version installed"
    echo "@@OK"
}

cmd_flash() {
    local name=$1 file=$2 dev size psize want got
    [ -s "$file" ] || die "$file missing or empty"
    dev=$(partdev "$name") || die "partition $name not found"
    [ -b "$dev" ] || die "$dev is not a block device"
    size=$(stat -c %s "$file")
    psize=$(blockdev --getsize64 "$dev") && [ "$psize" -gt 0 ] || die "cannot read the size of $name"
    [ "$size" -le "$psize" ] || die "$file ($size bytes) does not fit $name ($psize bytes)"
    echo "Writing $(basename "$file") to $name ($dev)"
    dd if="$file" of="$dev" bs=1048576 2>/dev/null || die "writing $name failed"
    sync
    want=$(md5_of < "$file")
    got=$(head -c "$size" "$dev" | md5_of)
    [ "$got" = "$want" ] || die "$name verify failed (wrote $want, read back $got)"
    echo "$name: verified"
    echo "@@OK"
}

# Copies the Windows modem calibration (MODEM_FS*, SSD) to the Android
# partitions and turns DPP's WLAN/BT provisioning into the MAC files the
# Android drivers read from /persist.
cmd_provision() {
    local dpp persist src dst size
    dpp=$(partdev DPP) || die "DPP not found"
    persist=$(partdev persist) || die "persist not found"
    mkdir -p "$WORK/dpp" "$WORK/persist"
    mount -o ro "$dpp" "$WORK/dpp" || die "cannot mount DPP"
    mount "$persist" "$WORK/persist" || { umount "$WORK/dpp"; die "cannot mount persist"; }

    local wlan="$WORK/dpp/QCOM/WLAN.PROVISION" bt="$WORK/dpp/QCOM/BT.PROVISION"
    [ -s "$wlan" ] && [ -s "$bt" ] || { umount "$WORK/dpp" "$WORK/persist"; die "DPP has no WLAN/BT provisioning"; }
    mac() { hexdump -v -e '6/1 "%02X"' -s "$1" -n 6 "$wlan"; }
    {
        echo "Intf0MacAddress=$(mac 3)"
        echo "Intf1MacAddress=$(mac 9)"
        echo "Intf2MacAddress=$(mac 15)"
        echo "Intf3MacAddress=$(mac 21)"
    } > "$WORK/persist/wlan_mac.bin"
    hexdump -v -e '6/1 "%02X"' -s 2 -n 6 "$bt" | sed 's/\(..\)/\1:/g; s/:$//' > "$WORK/persist/bdaddr.txt"
    echo "Wi-Fi MAC: $(head -n 1 "$WORK/persist/wlan_mac.bin")"
    echo "BT address: $(cat "$WORK/persist/bdaddr.txt")"
    sync
    umount "$WORK/persist"
    umount "$WORK/dpp"

    for pair in MODEM_FS1:modemst1 MODEM_FS2:modemst2 MODEM_FSC:fsc MODEM_FSG:fsg SSD:ssd; do
        src=$(partdev "${pair%%:*}") || die "${pair%%:*} not found"
        dst=$(partdev "${pair##*:}") || die "${pair##*:} not found"
        [ -b "$src" ] && [ -b "$dst" ] || die "$src or $dst is not a block device"
        size=$(blockdev --getsize64 "$src") && [ "$size" -gt 0 ] || die "cannot read the size of ${pair%%:*}"
        dd if="$src" of="$dst" bs=65536 2>/dev/null || die "copying ${pair%%:*} failed"
        [ "$(head -c "$size" "$src" | md5_of)" = "$(head -c "$size" "$dst" | md5_of)" ] \
            || die "${pair##*:} verify failed"
        echo "${pair%%:*} -> ${pair##*:}: verified"
    done
    sync
    echo "@@OK"
}

mkdir -p "$WORK"
case "$1" in
    state) cmd_state ;;
    backup) cmd_backup ;;
    partition) cmd_partition ;;
    verify-aboot) cmd_verify_aboot ;;
    repair-aboot) cmd_repair_aboot ;;
    verify-system) cmd_verify_system ;;
    flash) cmd_flash "$2" "$3" ;;
    provision) cmd_provision ;;
    *) die "usage: $0 state|backup|partition|verify-aboot|repair-aboot|flash NAME FILE|provision|verify-system" ;;
esac
