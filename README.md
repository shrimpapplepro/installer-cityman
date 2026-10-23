# LineageOS 18.1 installer for the Lumia 950 XL (cityman)

Turns a Lumia 950 XL running Windows 10 Mobile into a LineageOS 18.1 phone.
Windows on the phone is erased. Everything that is unique to your phone (IMEI,
radio calibration, Wi-Fi/Bluetooth addresses) is backed up to your PC first.

## You need

- A Windows 10/11 PC (Linux works too, use `installer.sh`) and a USB cable.
- This installer: **Code → Download ZIP**, then unzip it.
- The LineageOS zip from the
  [Releases page](https://github.com/shrimpapplepro/android_device_msft_cityman/releases),
  for example `lineage-18.1-20261022-UNOFFICIAL-cityman.zip`. Put it **next to
  `installer.bat`**, not inside a folder. Keep only one LineageOS zip there.
- [WPinternals](https://github.com/ReneLergner/WPinternals) to unlock the bootloader.

## Install with the app (recommended)

Double-click **`Install LineageOS.cmd`**. A window opens that shows what mode the
phone is in, finds the LineageOS zip next to it (or choose it, or drag it onto
the window), and does the whole install when you press **Install**. It waits for
the phone by itself and only stops for things it cannot do for you:

- unlocking the bootloader and switching to Mass Storage Mode in WPinternals
  (the window tells you when; see step 1 and 2 below),
- holding the Power button to restart the phone,
- two Yes/No questions before it changes the phone's boot files and before it
  erases Windows.

If the phone later has no sound or no mobile signal, press **Repair sound /
signal**. If it no longer starts, press **Phone won't start** and follow the
window. Your backup and a log of every run are next to the app
(**Open backup folder**, **Open log**).

## Install with the script

1. **Unlock the bootloader** with WPinternals.
   WPinternals needs the phone's FFU firmware and the emergency loaders
   registered first (Download tab). If they are missing, the unlock can quietly
   roll back while still looking successful: check that WPinternals reports the
   bootloader as **unlocked** before you go on.
2. **Mass Storage Mode**: in WPinternals, choose *Switch to Mass Storage mode*.
   The phone's partitions show up in Explorer as several drives.
3. **Run `installer.bat`** (double-click; allow the admin prompt) and choose **1**.
   It finds the phone's EFIESP drive on its own and asks before changing it.
4. **Reboot into LK2ND** when the installer says so: hold Power about
   10 seconds until the phone vibrates. Keep the cable in. The phone shows a
   black screen with text.
5. **Answer the prompts.** The installer then:
   - starts TWRP over USB,
   - backs up the phone's unique partitions to `backup-<date>` next to
     `installer.bat`. **Keep this folder**; it cannot be downloaded again,
   - asks before repartitioning, then replaces Windows with the Android layout,
   - writes the recovery (TWRP) and the modem/audio firmware,
   - copies your phone's modem calibration and MAC addresses,
   - installs LineageOS and reboots.

   Every step is checked; if one fails the installer stops and says why.
   The first boot of LineageOS takes a few minutes.

## If something goes wrong

Press Install again in the app, or run `installer.bat` again. Neither repeats a finished step that would destroy
data, so it is always safe to rerun.

| What you see | Choose | What it does |
|---|---|---|
| The install stopped partway, or the PC lost the phone | **2** | Works out what is already done and continues |
| Phone restarts in a loop, Windows logo or sad face | **4** | Phone in Mass Storage Mode (hold Power + Vol Down ~10 s, then hold Camera, pick *Mass Storage Mode*); puts the bootloader back |
| No sound at all, no mobile signal, or no TWRP | **3** | Rewrites the modem firmware and recovery and redoes provisioning. Apps and files are kept |
| "Could not find the phone's EFIESP drive" | | Phone not in Mass Storage Mode, or not unlocked yet (step 1) |
| Stuck at "Waiting for the phone" while it shows LK2ND | | Windows has no driver for it. In Device Manager it should appear as *Android Bootloader Interface*; if it has a warning sign, install the [Google USB driver](https://developer.android.com/studio/run/win-usb) for it |
| "LineageOS is not on the system partition" | **2** | Read the error on the phone's TWRP screen; usually a wrong or damaged zip |

The log of every run is saved as `install_log_<date>.txt` next to the installer.
Include it when you ask for help.

## How it works

| Step | Where | What |
|---|---|---|
| 1 | Windows, Mass Storage Mode | Copies `BCD`, `bootshim.efi`, `Stage2.efi`, the developer menu and LK2ND (`emmc_appsboot.mbn`) to EFIESP, so the phone boots LK2ND instead of Windows |
| 2 | LK2ND | `fastboot boot twrp.img`. This is the only fastboot step |
| 3 | TWRP | `cityman.sh backup`, then `cityman.sh partition`: deletes MainOS/Data/MMOS and creates the Android partitions |
| 4 | TWRP | `cityman.sh flash recovery` and `flash modem`, `cityman.sh provision` |
| 5 | TWRP | `adb sideload` of the LineageOS zip, checked with `cityman.sh verify-system` |

`cityman.sh` runs on the phone and finds partitions by their exact GPT name.
LK2ND is kept on both the `aboot` partition and EFIESP: `Stage2.efi` loads it
from whichever FAT volume has it, so a damaged `aboot` no longer bricks the boot.

Instead of the zip you can put `system.img`, `vendor.img` and `boot.img` in
`DATA\`; they are then flashed with fastboot.

## Other scripts

- `rescue.ps1` / `rescue.sh`: write an image straight to a partition in Mass
  Storage Mode (menu option 5).
- `unpack_ffu_to_folder.py`: unpack a Lumia FFU firmware file.
- `decompress_br.py`, `sdat2img.py`: turn `.new.dat.br` system images into raw images.
- `create_modem_img_70mb.bat` / `create_modem_img.sh`: build `modem.img` from `modem_firmware\`.

Based on [shadowofleaf96/installer-cityman](https://github.com/shadowofleaf96/installer-cityman).
