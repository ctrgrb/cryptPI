# Encrypted Raspberry Pi root with a USB key

Prepares a Raspberry Pi 5 (also works on Pi 4) so that the SD card holds a
fully encrypted root filesystem, while the boot partition and the LUKS key live
on an external USB stick.

- USB present in the Pi: it boots and unlocks the SD automatically, no password.
- USB absent: nothing boots, and the SD is encrypted at rest.

The single script `prepare-rpi-encrypted.sh` does everything and asks for all
settings interactively. You do not edit any file.

## How it works

```
USB stick (the key)                 SD card (the data)
  p1 FAT32 "BOOTFS":                  p1 LUKS2 container:
    Pi firmware + kernel                ext4 root "/" (encrypted)
    initramfs
    config.txt / cmdline.txt          No FAT partition, so the Pi
    cryptkey  (random keyfile)        cannot boot from the SD alone.
```

Boot sequence: the Pi 5 EEPROM finds firmware on the USB (the SD has no FAT
partition, so it is skipped), loads the kernel and initramfs, the initramfs
reads `cryptkey` off the USB via the standard Debian `passdev` keyscript,
unlocks the SD's LUKS volume, and pivots to the encrypted root. No prompt.

## Security model

- The encryption key is 4096 random bytes from `/dev/urandom`. It is the only
  LUKS key. There is no backup passphrase.
- The keyfile sits in plaintext on the USB. The USB is the key. Whoever holds
  the USB can decrypt the SD. This protects against SD-only theft, not against
  theft of both together. That is inherent to password-free auto-unlock.
- Lose or destroy the USB and the SD data is unrecoverable, by design.
  Recommended: image the USB to a spare stick and store it safely. That is a
  copy of the key, not a weaker password, so it does not reduce security.

## Prerequisites

Run on a NATIVE Linux machine (or a Linux live USB), not inside WSL. The script
needs raw block-device access to the SD card and the USB stick, plus aarch64
emulation to rebuild the Pi's ARM initramfs in a chroot. WSL does not expose the
SD reader or USB as real block devices.

Install the required tools (Debian/Ubuntu):

```
sudo apt update
sudo apt install -y cryptsetup cryptsetup-bin parted gdisk dosfstools rsync \
    qemu-user-static binfmt-support curl xz-utils openssl util-linux
```

## Usage

Plug in both the SD card and the USB stick, then:

```
sudo bash prepare-rpi-encrypted.sh
```

WARNING: this erases both the SD card and the USB stick completely.

The script prompts for, in order:

1. SD card  - chosen from a list of detected disks (becomes encrypted root)
2. USB stick - chosen from the list (becomes boot + key)
3. `ERASE`  - typed confirmation, after showing both disks
4. Username to create on the Pi
5. Password (hidden, asked twice)
6. Image source - Enter to download the latest trixie Lite, or a path to a local
   `.img` / `.img.xz`
7. USB boot+key partition size in MiB (default 1024)
8. Scratch/work directory (default `/tmp/rpi-enc`)

It then runs unattended: download, partition, LUKS format with the random
keyfile, copy the root filesystem to the SD, copy boot + key to the USB, and
rebuild the initramfs in a chroot.

Any prompt can be skipped by presetting an environment variable, for example:

```
SD_DEV=/dev/mmcblk0 USB_DEV=/dev/sda BOOT_SIZE_MIB=2048 sudo -E bash prepare-rpi-encrypted.sh
```

## First boot

Move both the USB and the SD into the Pi 5 and power on. The user you chose is
created automatically (no setup wizard), and the SD unlocks without a password.
First boot regenerates SSH host keys and similar, so give it a minute.

## Notes and likely tweak points

- Targets Pi 5 and Pi 4 (arm64). Pi 3 and older read `bootcode.bin` from the
  SD's first FAT partition and cannot cleanly boot firmware from USB, so this
  layout does not apply to them.
- initramfs naming: Pi 5 uses `kernel_2712.img` / `initramfs_2712`; the script
  relies on `auto_initramfs=1` and also copies the initramfs under both the Pi 5
  and Pi 4 names. If it does not boot, check this first.
- `passdev` timeout is 30s in `/etc/crypttab`. If the USB enumerates slowly and
  unlock fails intermittently, raise it and rerun `update-initramfs -u` on the Pi.
- The chroot step installs `cryptsetup` packages, so the machine needs internet
  access during preparation.

## Files

- `prepare-rpi-encrypted.sh` - the preparation script
- `README.md` - this file
