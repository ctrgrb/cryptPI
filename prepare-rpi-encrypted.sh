#!/usr/bin/env bash
#
# prepare-rpi-encrypted.sh
#
# Prepare a Raspberry Pi 5 (also works on Pi 4) for FULL-DISK ENCRYPTED root on
# the SD card, with the boot partition + LUKS keyfile living on an external USB.
#
#   - USB present in the Pi  -> boots and auto-unlocks the SD, no password.
#   - USB absent             -> nothing boots, SD data is encrypted at rest.
#
# RUN THIS ON A REAL LINUX MACHINE (native, or a Linux live USB). It needs raw
# block-device access to the SD card and the USB stick, plus aarch64 emulation
# (qemu-user-static) to regenerate the Pi's ARM initramfs in a chroot.
#
# WARNING: this ERASES both the SD card and the USB stick completely.
#
# Tested-conceptually against Raspberry Pi OS (trixie / Debian 13) Lite arm64.
# Review every step. Keep backups. You are wiping disks.
#
set -euo pipefail

############################################################################
# 0. DEFAULTS — you do NOT need to edit anything here.
#    The script asks for all of these interactively at runtime; the values
#    below are just the defaults offered at each prompt (press Enter to accept).
#    You may still preset any of them via env vars to skip its prompt.
############################################################################

SD_DEV="${SD_DEV:-}"     # SD card  -> encrypted root  (chosen from a list)
USB_DEV="${USB_DEV:-}"   # USB stick -> boot + key      (chosen from a list)

IMG_FILE="${IMG_FILE:-}" # local .img/.img.xz; blank = download latest trixie Lite
IMG_URL="${IMG_URL:-https://downloads.raspberrypi.com/raspios_lite_arm64_latest}"

BOOT_SIZE_MIB="${BOOT_SIZE_MIB:-1024}"  # FAT boot+key partition size on the USB

PI_USER="${PI_USER:-}"   # first-boot login user  (prompted)
PI_PASS="${PI_PASS:-}"   # first-boot password    (prompted, hidden)

WORK="${WORK:-/tmp/rpi-enc}"  # scratch dir for temp mounts / downloads

############################################################################
# Internals — you normally don't edit below here
############################################################################

MAP_NAME="cryptroot"
KEYFILE="$WORK/cryptkey"
SD_MNT="$WORK/sdroot"
USB_MNT="$WORK/usbboot"
IMG_MNT="$WORK/img"
LOOP=""        # set later
LOOP_USED=0

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ask "Question" "default"  -> prints the answer on stdout (prompt goes to stderr,
# so it is safe inside $(...) ). Press Enter to take the default.
ask() {
  local prompt="$1" def="${2:-}" reply
  if [[ -n "$def" ]]; then read -rp "$prompt [$def]: " reply; echo "${reply:-$def}"
  else                    read -rp "$prompt: " reply;        echo "$reply"; fi
}

# Build a partition node name: /dev/sda + 1 -> /dev/sda1 ; /dev/mmcblk0 + 1 -> /dev/mmcblk0p1
partdev() {
  local dev="$1" num="$2"
  if [[ "$dev" =~ [0-9]$ ]]; then echo "${dev}p${num}"; else echo "${dev}${num}"; fi
}

# Show all whole disks and let the user pick one. Prints the chosen /dev path on
# stdout; all UI goes to stderr so it can be used in $(...) capture.
choose_disk() {
  local prompt="$1" exclude="${2:-}"
  local -a devs=() lines=()
  while IFS= read -r line; do
    local name type
    name=$(awk '{print $1}' <<<"$line")
    type=$(awk '{print $3}' <<<"$line")
    [[ "$type" == disk ]] || continue
    [[ -n "$exclude" && "$name" == "$exclude" ]] && continue
    devs+=("$name"); lines+=("$line")
  done < <(lsblk -dpn -o NAME,SIZE,TYPE,TRAN,VENDOR,MODEL)

  [[ ${#devs[@]} -gt 0 ]] || die "No selectable disks found."

  printf '\n%s\n' "$prompt" >&2
  printf '      %-14s %-8s %-6s %-8s %s\n' NAME SIZE TYPE TRAN MODEL >&2
  local i
  for i in "${!devs[@]}"; do printf '  [%d] %s\n' "$i" "${lines[$i]}" >&2; done

  local sel
  while :; do
    read -rp "Enter number: " sel
    [[ "$sel" =~ ^[0-9]+$ && -n "${devs[$sel]:-}" ]] && break
    echo "Invalid selection." >&2
  done
  echo "${devs[$sel]}"
}

cleanup() {
  set +e
  log "Cleaning up mounts / loop devices"
  for m in "$SD_MNT/boot/firmware" "$SD_MNT/dev/pts" "$SD_MNT/dev" \
           "$SD_MNT/proc" "$SD_MNT/sys" "$SD_MNT" "$USB_MNT" \
           "$IMG_MNT/boot/firmware" "$IMG_MNT"; do
    mountpoint -q "$m" && umount -R "$m" 2>/dev/null
  done
  cryptsetup status "$MAP_NAME" >/dev/null 2>&1 && cryptsetup close "$MAP_NAME"
  [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

############################################################################
# 1. Sanity checks
############################################################################

[[ $EUID -eq 0 ]] || die "Run as root (sudo)."

for t in cryptsetup parted blkid rsync sgdisk mkfs.vfat mkfs.ext4 losetup \
         qemu-aarch64-static; do
  command -v "$t" >/dev/null 2>&1 || die "Missing tool: $t  (see prerequisites in the README)"
done

# Confirm aarch64 emulation is registered so the chroot can run ARM binaries.
# Accept either the Debian/binfmt-support registration or a systemd-binfmt one.
aarch64_binfmt_ok() {
  update-binfmts --display qemu-aarch64 2>/dev/null | grep -q enabled && return 0
  local f
  for f in /proc/sys/fs/binfmt_misc/*aarch64* /proc/sys/fs/binfmt_misc/qemu-aarch64; do
    [[ -f "$f" ]] && grep -q '^enabled' "$f" && return 0
  done
  return 1
}
if ! aarch64_binfmt_ok; then
  die "aarch64 emulation is not registered. On Debian/Ubuntu run:
    sudo apt install -y qemu-user-static binfmt-support
    sudo systemctl restart systemd-binfmt 2>/dev/null || true
    sudo update-binfmts --enable qemu-aarch64 2>/dev/null || true
  If /proc/sys/fs/binfmt_misc is not mounted:
    sudo mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc"
fi

# Interactive disk selection (skipped for any device preset via env var).
log "Detected disks on this machine:"
lsblk -dpo NAME,SIZE,TYPE,TRAN,VENDOR,MODEL | grep -E 'disk|NAME' >&2 || true
[[ -n "$SD_DEV"  ]] || SD_DEV=$(choose_disk  "Select the SD card (becomes the ENCRYPTED ROOT):")
[[ -n "$USB_DEV" ]] || USB_DEV=$(choose_disk "Select the USB stick (becomes BOOT + KEY):" "$SD_DEV")

[[ -b "$SD_DEV"  ]] || die "SD device $SD_DEV not found."
[[ -b "$USB_DEV" ]] || die "USB device $USB_DEV not found."
[[ "$SD_DEV" != "$USB_DEV" ]] || die "SD and USB are the same device!"

log "About to COMPLETELY ERASE these devices:"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL "$SD_DEV" "$USB_DEV"
echo
read -rp "Type ERASE to continue: " ans
[[ "$ans" == "ERASE" ]] || die "Aborted."

# Ask for the first-boot login user now, so nothing is needed after first boot.
if [[ -z "$PI_USER" ]]; then
  read -rp "Username to create on the Pi: " PI_USER
  [[ -n "$PI_USER" ]] || die "Username cannot be empty."
fi
if [[ -z "$PI_PASS" ]]; then
  while :; do
    read -rsp "Password for '$PI_USER': " PI_PASS; echo
    read -rsp "Confirm password: " p2; echo
    [[ "$PI_PASS" == "$p2" && -n "$PI_PASS" ]] && break
    echo "Passwords empty or do not match — try again."
  done
fi

# Image source: a local file, or download the latest trixie Lite.
if [[ -z "$IMG_FILE" ]]; then
  IMG_FILE=$(ask "Path to a local .img/.img.xz (blank = download latest trixie Lite)")
fi

# USB boot+key partition size.
BOOT_SIZE_MIB=$(ask "USB boot+key partition size in MiB" "$BOOT_SIZE_MIB")
[[ "$BOOT_SIZE_MIB" =~ ^[0-9]+$ ]] || die "Partition size must be a number."

# Scratch directory (derived mount paths are recomputed from it below).
WORK=$(ask "Scratch/work directory" "$WORK")
KEYFILE="$WORK/cryptkey"
SD_MNT="$WORK/sdroot"
USB_MNT="$WORK/usbboot"
IMG_MNT="$WORK/img"

mkdir -p "$WORK" "$SD_MNT" "$USB_MNT" "$IMG_MNT"

############################################################################
# 2. Obtain + loop-mount the Raspberry Pi OS image
############################################################################

if [[ -z "$IMG_FILE" ]]; then
  log "Downloading Raspberry Pi OS image"
  curl -fL "$IMG_URL" -o "$WORK/raspios.img.xz"
  IMG_FILE="$WORK/raspios.img.xz"
fi

if [[ "$IMG_FILE" == *.xz ]]; then
  log "Decompressing image"
  xz -dkf "$IMG_FILE"
  IMG_FILE="${IMG_FILE%.xz}"
fi

log "Attaching image to a loop device"
LOOP=$(losetup -fP --show "$IMG_FILE")
IMG_BOOT="${LOOP}p1"
IMG_ROOT="${LOOP}p2"
[[ -b "$IMG_BOOT" && -b "$IMG_ROOT" ]] || die "Image doesn't have the expected p1/p2 layout."

############################################################################
# 3. Partition the USB  (FAT boot+key)  and the SD  (LUKS)
############################################################################

log "Partitioning USB $USB_DEV -> single FAT32 boot/key partition"
wipefs -a "$USB_DEV"
parted -s "$USB_DEV" mklabel msdos
parted -s "$USB_DEV" mkpart primary fat32 1MiB "$((BOOT_SIZE_MIB + 1))MiB"
parted -s "$USB_DEV" set 1 lba on
partprobe "$USB_DEV"; sleep 2
USB_BOOT=$(partdev "$USB_DEV" 1)
mkfs.vfat -F 32 -n BOOTFS "$USB_BOOT"

log "Partitioning SD $SD_DEV -> single LUKS partition"
wipefs -a "$SD_DEV"
parted -s "$SD_DEV" mklabel msdos
parted -s "$SD_DEV" mkpart primary 1MiB 100%
partprobe "$SD_DEV"; sleep 2
SD_PART=$(partdev "$SD_DEV" 1)

############################################################################
# 4. Create LUKS, add keyfile, make the filesystem
############################################################################

log "Generating random 4096-bit keyfile from /dev/urandom (the ONLY key)"
dd if=/dev/urandom of="$KEYFILE" bs=512 count=8 status=none   # 4096 random bytes
chmod 400 "$KEYFILE"

log "LUKS-formatting the SD with the random keyfile as the only key"
# No passphrase slot at all: the USB keyfile is the sole way to unlock.
# Lose/destroy the USB -> the data is unrecoverable, by design.
# --pbkdf-memory is capped so a Pi with limited RAM can still unlock.
cryptsetup luksFormat --type luks2 \
  --pbkdf argon2id --pbkdf-memory 524288 --pbkdf-parallel 4 \
  --key-file "$KEYFILE" --batch-mode \
  "$SD_PART"

log "Opening LUKS and making ext4 root"
cryptsetup open --key-file "$KEYFILE" "$SD_PART" "$MAP_NAME"
mkfs.ext4 -L rootfs "/dev/mapper/$MAP_NAME"

############################################################################
# 5. Copy the OS:  image root -> encrypted SD ;  image boot -> USB
############################################################################

log "Mounting source image"
mount "$IMG_ROOT" "$IMG_MNT"
mount "$IMG_BOOT" "$IMG_MNT/boot/firmware"

log "Mounting targets"
mount "/dev/mapper/$MAP_NAME" "$SD_MNT"
mount "$USB_BOOT" "$USB_MNT"

log "Copying root filesystem onto the encrypted SD (this takes a while)"
rsync -aHAXx --info=progress2 \
  --exclude='/boot/firmware/*' \
  "$IMG_MNT"/ "$SD_MNT"/

log "Copying boot/firmware onto the USB"
rsync -aHAX "$IMG_MNT/boot/firmware"/ "$USB_MNT"/

log "Placing keyfile on the USB"
cp "$KEYFILE" "$USB_MNT/cryptkey"
chmod 400 "$USB_MNT/cryptkey"

############################################################################
# 6. Collect UUIDs and rewrite crypttab / fstab / cmdline / config
############################################################################

LUKS_UUID=$(cryptsetup luksUUID "$SD_PART")
USB_UUID=$(blkid -s UUID -o value "$USB_BOOT")
log "LUKS UUID = $LUKS_UUID    USB(FAT) UUID = $USB_UUID"

log "Writing /etc/crypttab (passdev keyscript reads the key off the USB)"
cat > "$SD_MNT/etc/crypttab" <<EOF
# <target>   <source>            <key=device:path:timeout>                              <options>
$MAP_NAME UUID=$LUKS_UUID /dev/disk/by-uuid/$USB_UUID:/cryptkey:30 luks,keyscript=/lib/cryptsetup/scripts/passdev,initramfs
EOF

log "Writing /etc/fstab"
cat > "$SD_MNT/etc/fstab" <<EOF
proc                       /proc          proc    defaults          0 0
/dev/mapper/$MAP_NAME      /              ext4    defaults,noatime  0 1
UUID=$USB_UUID             /boot/firmware vfat    defaults          0 2
EOF

log "Rewriting cmdline.txt (point root at the mapper, drop first-boot resize)"
# Keep it minimal. Debian's initramfs does the unlocking from crypttab, so we do
# NOT need cryptdevice= (that's an Arch-ism). We just point root at the mapper.
cat > "$USB_MNT/cmdline.txt" <<EOF
console=tty1 root=/dev/mapper/$MAP_NAME rootfstype=ext4 fsck.repair=yes rootwait
EOF

log "Ensuring config.txt loads an initramfs"
if ! grep -q '^auto_initramfs=1' "$USB_MNT/config.txt" 2>/dev/null; then
  printf '\n# Encrypted-root setup\nauto_initramfs=1\n' >> "$USB_MNT/config.txt"
fi

# Pre-seed the login user so first boot is fully unattended (no setup wizard).
log "Seeding first-boot user '$PI_USER' (userconf.txt)"
HASH=$(echo "$PI_PASS" | openssl passwd -6 -stdin)
echo "${PI_USER}:${HASH}" > "$USB_MNT/userconf.txt"

############################################################################
# 7. chroot (via qemu) into the encrypted root to install cryptsetup
#    and regenerate the ARM initramfs
############################################################################

log "Preparing chroot"
mount --bind "$USB_MNT" "$SD_MNT/boot/firmware"
mount --bind /dev      "$SD_MNT/dev"
mount --bind /dev/pts  "$SD_MNT/dev/pts"
mount -t proc  proc    "$SD_MNT/proc"
mount -t sysfs sysfs   "$SD_MNT/sys"
cp /usr/bin/qemu-aarch64-static "$SD_MNT/usr/bin/"
cp /etc/resolv.conf "$SD_MNT/etc/resolv.conf"

log "Installing cryptsetup + regenerating initramfs inside the Pi root"
chroot "$SD_MNT" /bin/bash <<'CHROOT'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y cryptsetup cryptsetup-initramfs
# Force cryptsetup into the initramfs.
mkdir -p /etc/cryptsetup-initramfs
echo 'CRYPTSETUP=y' > /etc/cryptsetup-initramfs/conf-hook
# Regenerate initramfs for every installed kernel.
update-initramfs -u -k all || update-initramfs -c -k all
CHROOT

# Make sure the firmware can find the initramfs under both Pi 4 and Pi 5 names.
log "Publishing initramfs under firmware-expected names"
INITRD=$(ls -1 "$SD_MNT"/boot/initrd.img-* 2>/dev/null | sort | tail -n1 || true)
if [[ -n "$INITRD" ]]; then
  cp "$INITRD" "$USB_MNT/initramfs_2712"   # Pi 5
  cp "$INITRD" "$USB_MNT/initramfs8"       # Pi 4 (harmless to have both)
fi

log "DONE.  Insert BOTH the USB and the SD into the Pi 5 and power on."
echo "  - Log in as '$PI_USER' with the password you set; no setup wizard runs."
echo "  - First boot regenerates SSH keys etc.; give it a minute."
echo "  - The USB keyfile is the ONLY key. No backup passphrase exists."
echo "    Lose or destroy the USB and the SD data is unrecoverable, by design."
echo "    -> Consider imaging the USB to a spare stick and storing it safely."
