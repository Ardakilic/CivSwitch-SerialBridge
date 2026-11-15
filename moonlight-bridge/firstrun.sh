#!/bin/bash
#
# First-boot bootstrap for the CivSwitch Moonlight bridge (Raspberry Pi OS Bookworm).
#
# Runs ONCE on a fresh Pi, then hands off to a one-shot service that finishes the
# install on the next (normal) boot. This is the "flash, plug in, walk away" path
# — no SSH, no keyboard, no monitor.
#
# Why two stages: the systemd.run phase runs before NetworkManager, so there is
# no internet to `apt-get install` from. Stage 1 (this script) only does local
# work (create user, enable SSH, copy the bundled files, install a one-shot
# service) and then reboots; stage 2 runs on the next boot once the network is
# up and does the real install (apt + AP + firewall + spoof).
#
# To use it:
#   1. Flash Raspberry Pi OS Lite (Bookworm — the "Legacy" track) to the SD card.
#   2. Mount the small FAT "bootfs" partition and copy this file to its root.
#   3. Copy the whole `moonlight-bridge/` folder next to it, so you end up with
#        <bootfs>/firstrun.sh
#        <bootfs>/moonlight-bridge/setup.sh
#   4. Append this to <bootfs>/cmdline.txt on a single line:
#        systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target
#   5. Unmount, eject, put the card in the Pi, plug in Ethernet + power.
#
# Logs:  stage 1 -> /var/log/civswitch-moonlight-firstrun.log
#        stage 2 -> /var/log/civswitch-moonlight-firstboot.log
#
# NOTE: targets Bookworm's `systemd` first-boot. The current "Raspberry Pi OS"
# default is Trixie (cloud-init) — this script won't run there; flash the
# "Legacy" Bookworm image instead.

set -x
exec > /var/log/civswitch-moonlight-firstrun.log 2>&1

# ── Config (set these before flashing) ─────────────────────────────
FIRST_USER=""          # username to create on first boot (empty = leave as-is)
FIRST_PASSWORD=""      # its password (only used if FIRST_USER is set)
ENABLE_SSH=1           # 1 = enable SSH on first boot

# The FAT boot partition is at /boot/firmware on Bookworm (/boot on older OSes).
BOOT=""
for d in /boot/firmware /boot; do
  if [ -f "$d/config.txt" ] || [ -f "$d/cmdline.txt" ]; then
    BOOT="$d"; break
  fi
done

SRC="$BOOT/moonlight-bridge"
DEST="/opt/civswitch-moonlight-src"
SERVICE="civswitch-moonlight-firstboot.service"

# Enable SSH and create the first user (so you can log in afterwards). These
# run even if everything below fails, so the Pi is never bricked.
if [ "${ENABLE_SSH:-0}" = "1" ]; then
  systemctl enable ssh 2>/dev/null || true
fi
if [ -n "$FIRST_USER" ] && ! id -u "$FIRST_USER" >/dev/null 2>&1; then
  useradd -m -G sudo,adm,dialout,audio,video,plugdev,games,users,render,input,netdev,gpio,i2c,spi "$FIRST_USER" || true
  if [ -n "$FIRST_PASSWORD" ]; then
    echo "$FIRST_USER:$FIRST_PASSWORD" | chpasswd || true
  fi
fi

# Stage 1: copy the bundled files somewhere stable, and install a one-shot
# service that runs setup.sh on the next (normal, networked) boot.
rc=1
if [ -n "$BOOT" ] && [ -f "$SRC/setup.sh" ]; then
  mkdir -p "$DEST"
  cp -r "$SRC"/. "$DEST"/
  chmod +x "$DEST/setup.sh"

  # Wrapper that runs setup.sh then removes itself so it only runs once.
  cat > "$DEST/run-setup.sh" <<'EOF'
#!/bin/bash
set -x
exec > /var/log/civswitch-moonlight-firstboot.log 2>&1
/opt/civswitch-moonlight-src/setup.sh
rc=$?
if [ "$rc" -eq 0 ]; then
  systemctl disable civswitch-moonlight-firstboot.service || true
  rm -f /etc/systemd/system/civswitch-moonlight-firstboot.service || true
  systemctl daemon-reload || true
fi
echo "CivSwitch Moonlight bridge first-boot setup done (rc=$rc)."
exit 0
EOF
  chmod +x "$DEST/run-setup.sh"

  cat > "/etc/systemd/system/$SERVICE" <<EOF
[Unit]
Description=CivSwitch Moonlight bridge first-boot setup
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$DEST/run-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE"
  rc=0
else
  echo "ERROR: boot partition not found, or $SRC/setup.sh missing"
fi

# Remove ourselves so stage 1 only runs once (and undo the cmdline hook). Always
# do this so the Pi reboots into a normal boot even if something above failed.
if [ -n "$BOOT" ]; then
  rm -f "$BOOT/firstrun.sh"
  if [ -f "$BOOT/cmdline.txt" ]; then
    sed -i 's| systemd\.run[^ ]*||g; s| systemd\.run_success_action[^ ]*||g; s| systemd\.unit=kernel-command-line\.target||g' "$BOOT/cmdline.txt"
  fi
fi

echo "CivSwitch Moonlight bridge first-boot stage 1 complete (rc=$rc)."
exit 0
