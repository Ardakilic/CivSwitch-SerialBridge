#!/bin/bash
#
# First-boot bootstrap for the CivSwitch Moonlight bridge (Raspberry Pi OS Bookworm).
#
# Runs ONCE on a fresh Pi, installs the whole bridge, then removes itself so it
# never runs again. This is the "flash, plug in, walk away" path — no SSH, no
# keyboard, no monitor.
#
# To use it:
#   1. Flash Raspberry Pi OS Lite (Bookworm) to the SD card.
#   2. Mount the small FAT "bootfs" partition and copy this file to its root.
#   3. Copy the whole `moonlight-bridge/` folder next to it, so you end up with
#        <bootfs>/firstrun.sh
#        <bootfs>/moonlight-bridge/setup.sh
#      (that's <bootfs>/firmware/... if you mount the whole-card image).
#   4. Append this to <bootfs>/cmdline.txt on a single line:
#        systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target
#   5. Unmount, eject, put the card in the Pi, plug in Ethernet + power.
#
# On first boot the script runs, sets up the bridge, and reboots. After the
# reboot the Pi comes up as the bridge (AP + firewall + spoof) on its own.
# Everything it does is logged to /var/log/civswitch-moonlight-firstrun.log.
#
# NOTE: this needs the Pi's Ethernet to reach the internet (to install packages)
# during first boot. The reliable "test it first" path is still Imager + SSH +
# setup.sh — see README, "Flashing a fresh Pi & testing".

set -ex
exec > /var/log/civswitch-moonlight-firstrun.log 2>&1

# The FAT boot partition is at /boot/firmware on Bookworm (/boot on older OSes).
BOOT=""
for d in /boot/firmware /boot; do
  if [ -f "$d/config.txt" ] || [ -f "$d/cmdline.txt" ]; then
    BOOT="$d"; break
  fi
done
[ -n "$BOOT" ] || { echo "ERROR: boot partition not found"; exit 1; }

SRC="$BOOT/moonlight-bridge"
[ -f "$SRC/setup.sh" ] || { echo "ERROR: $SRC/setup.sh not found"; exit 1; }

# Under systemd.run, NetworkManager hasn't started yet — bring eth0 up manually
# and wait for an internet path (apt needs it).
ip link set eth0 up
if command -v dhclient >/dev/null 2>&1; then
  dhclient -1 eth0 2>/dev/null || true
elif command -v dhcpcd >/dev/null 2>&1; then
  dhcpcd -q eth0 2>/dev/null || true
fi

for _ in $(seq 1 90); do
  if ip -4 addr show dev eth0 2>/dev/null | grep -q 'inet ' \
     && apt-get update -qq >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# Run the real setup from a stable copy.
DEST="/opt/civswitch-moonlight-src"
mkdir -p "$DEST"
cp -r "$SRC"/. "$DEST"/
chmod +x "$DEST/setup.sh"
"$DEST/setup.sh"

# Remove ourselves so this only runs once (and undo the cmdline hook).
rm -f "$BOOT/firstrun.sh"
if [ -f "$BOOT/cmdline.txt" ]; then
  sed -i 's| systemd\.run[^ ]*||g; s| systemd\.run_success_action[^ ]*||g; s| systemd\.unit=kernel-command-line\.target||g' "$BOOT/cmdline.txt"
fi

echo "CivSwitch Moonlight bridge first-boot setup complete."
