# CivSwitch Moonlight Bridge (Raspberry Pi)

Stream Moonlight from a Sunshine host on your home LAN to a Switch that is **still air-gapped from the internet**. The Pi sits between the two: the Switch joins the Pi's Wi-Fi, the Pi reaches the Sunshine PC over Ethernet, and a default-deny firewall guarantees the Switch can never reach the internet (so it never talks to Nintendo).

This is a fourth variant, alongside the [ESP32](../esp32-bridge), [Pi](../pi-bridge), and [Linux](../linux-bridge) builds. It reuses the Pi build's AP, catch-all DNS, and connectivity spoof, and adds IP forwarding + a locked-down firewall for the one thing the Switch is allowed to reach: the Sunshine PC.

## ⚠️ Untested

Same status as the [Pi build](../pi-bridge): written but **not yet tested on real hardware**. It targets Raspberry Pi OS **Bookworm** (which uses NetworkManager). If you try it and something breaks, open an issue — happy to fix it.

## Why

Two goals that normally conflict:

1. Moonlight needs the Switch and the Sunshine PC to be reachable from each other.
2. You don't want the Switch talking to Nintendo's servers — ever.

The Pi routes between the two networks but only in one narrow direction. The Switch reaches the Sunshine PC by IP and nothing else; there is no route to the internet.

## Wiring / diagram

```
Switch 2 (Moonlight)           Raspberry Pi                        Home LAN
┌───────────────────┐        ┌────────────────────────┐       ┌─────────────────┐
│ Wi-Fi client      │        │ wlan0 — AP (air-gapped)│       │ router (DHCP +  │
│ 192.168.4.2       │◄─WiFi──►│ 192.168.4.1/24         │       │  internet)      │
│ (DHCP from Pi)    │        │ dnsmasq + bridge.py    │       └────────┬────────┘
└───────────────────┘        │                        │                │
                             │ nftables FORWARD:      │       ┌────────▼────────┐
                             │   policy DROP          │       │ Sunshine PC     │
                             │   ✓ Switch → LAN       │       │ 192.168.1.50    │
                             │   ✓ established/related│       │ (Moonlight host)│
                             │ eth0 — uplink (DHCP) ──┼──────►│                 │
                             └────────────────────────┘       └─────────────────┘

  Switch ──► Sunshine PC : allowed   (masqueraded — appears to come from the Pi)
  Switch ──► internet    : DROPPED   (FORWARD default-deny)
```

## How it works

- NetworkManager puts `wlan0` into AP mode (configurable SSID/password).
- dnsmasq hands out IPs and resolves **every** DNS name to the Pi, so the Switch never resolves real internet hostnames.
- `bridge.py` mimics Nintendo's connectivity-check endpoints, so the Switch thinks it's online and skips the captive-portal popup.
- IP forwarding is **on** so the Pi can route, but `nftables` sets the FORWARD policy to **DROP** and only allows `Switch subnet → home-LAN subnet` (plus established/related return traffic). Everything else — i.e. the internet — is dropped.
- Masquerade (SNAT) rewrites the Switch's traffic as it leaves `eth0`, so the Sunshine PC replies to the Pi without any router or PC config.

## Safety (the hard guarantee)

The air-gap rests on one rule: **FORWARD default-deny**. The Switch is on the AP subnet and the only forwarded destination is `LAN_SUBNET`. Any packet the Switch sends to any other destination is dropped, so there is no path to the internet regardless of what the Switch tries. `setup.sh` refuses to finish unless it can confirm the drop policy, the allow rule, and the masquerade rule are actually loaded.

The firewall is a persistent systemd service, so it re-applies the same rules on every boot.

## Requirements

- Raspberry Pi 3 B+ / 4 / 5 / Zero 2 W (onboard Wi-Fi) running Raspberry Pi OS **Bookworm**. For streaming, use a **5 GHz model (Pi 4/5)** — the 2.4 GHz-only boards (3 B+, Zero 2 W) work but are bandwidth-limited. See "Which Raspberry Pi?" below.
- The Pi's Ethernet plugged into your home router (the uplink).
- A Sunshine host (PC) on the same home LAN.
- Moonlight (homebrew) on the Switch.
- A way to control the Pi: Ethernet/SSH, or keyboard + monitor. Once the Pi is the AP, its Wi-Fi belongs to the Switch, not your LAN.

## Which Raspberry Pi? (2.4 vs 5 GHz)

The bridge is the same scripts on every Pi — the only thing that changes is the Wi-Fi band, which decides how well Moonlight streams.

| Pi model | Wi-Fi | Verdict |
|---|---|---|
| Pi 5 | 2.4 + 5 GHz | ✅ Best |
| Pi 4 / Pi 400 | 2.4 + 5 GHz | ✅ Recommended |
| Pi 3 B+ | 2.4 GHz only | ⚠️ Works, but 2.4 GHz caps streaming (fine for testing the bridge) |
| Zero 2 W | 2.4 GHz only | ⚠️ Works, 2.4 GHz only |

Moonlight needs real bandwidth, and 2.4 GHz tops out around ~20–40 Mbps (roughly 720p). 5 GHz (Pi 4/5) is what you want for smooth 1080p.

Set the band at the top of `setup.sh`:

- **5 GHz models (Pi 4 / 5 / 400):** `AP_BAND="a"` and `AP_CHANNEL=36`
- **2.4 GHz models (Pi 3 B+ / Zero 2 W):** keep `AP_BAND="bg"` and `AP_CHANNEL=6`

> There are no separate releases per Pi model — the scripts are universal and one Raspberry Pi OS image boots them all. You only change the one `AP_BAND` line for your board.

## Flashing a fresh Pi & testing

Two ways to get this onto a blank microSD card. Use the first for your first test — it's the reliable one. The second is fully automatic once you trust the build.

### Option 1 — Imager + one command (recommended)

1. Flash **Raspberry Pi OS Lite — Bookworm** with the [Raspberry Pi Imager](https://www.raspberrypi.com/software/). In the Imager this is the *Legacy* track (currently "Raspberry Pi OS (Legacy, 64-bit) Lite"). The default "Raspberry Pi OS" image is now Debian Trixie; the automatic `firstrun.sh` path (Option 2) targets Bookworm's `systemd` first-boot, not Trixie's cloud-init.
2. In the Imager's OS Customization screen (Ctrl/Cmd+Shift+X): set a hostname, set a username + password, and turn on **SSH**. Leave Wi-Fi empty — the Pi's Wi-Fi becomes the Switch's AP.
3. Boot the Pi with Ethernet plugged into your home router, wait a minute, then connect:

```sh
ssh <user>@<hostname>.local
```

4. Get the code onto the Pi and run it. Until the repo is pushed, copy the folder over with `scp`; once it's pushed, clone instead:

```sh
# before the code is pushed:
scp -r moonlight-bridge/ <user>@<hostname>.local:~/

# on the Pi:
sudo ~/moonlight-bridge/setup.sh
```

`setup.sh` sets the Wi-Fi country automatically, so the AP comes up with no extra steps.

### Option 2 — fully automatic first boot (no SSH)

Drop [`firstrun.sh`](firstrun.sh) plus the `moonlight-bridge/` folder onto the boot partition and add the `systemd.run=` line to `cmdline.txt` — full steps are in the header of `firstrun.sh`. The Pi installs the bridge on its first boot, then reboots into it. Needs the Pi's Ethernet to reach the internet during that first boot, and a Bookworm (Legacy) image — Trixie uses cloud-init, which this script doesn't target.

### How to test

1. The AP (`Switch2Moonlight`) should appear.
2. Join from the Switch — it should connect with **no captive-portal popup**.
3. In Moonlight, add your Sunshine PC **by IP** and confirm it pairs (see above) and streams.
4. Confirm the air-gap: the Switch can reach the Sunshine PC but nothing else — the eShop / browser should not load.

> Pi 3 B+ is 2.4 GHz only — fine for proving the bridge works, but expect limited streaming bandwidth vs a Pi 4/5 at 5 GHz.

## Install

```sh
git clone https://github.com/jackspence7/CivSwitch-SerialBridge.git
cd CivSwitch-SerialBridge/moonlight-bridge
sudo ./setup.sh
```

`setup.sh` installs `dnsmasq` + `python3` + `nftables`, creates the AP, sets up the `eth0` uplink, writes the DNS config, installs the firewall + spoof server as systemd services, and brings the AP up. It's safe to re-run.

> If your Wi-Fi country isn't set, set it first: `sudo raspi-config nonint do_wlan_country US` (or your country). Channel 6 is the default.

## Connect the Switch and add the Sunshine host by IP

1. On the Switch, join the AP (`AP_SSID`, from Config below). The spoof makes it look online, so there's no captive-portal popup.
2. On the Sunshine PC, note its LAN IP (e.g. `192.168.1.50`). Make sure Sunshine is running and allowed through the OS firewall (Moonlight uses UDP `47998–48010` and TCP `47984`/`47989`/`48010`).
3. In Moonlight on the Switch, tap **Add Host** and choose to **enter the IP manually**. Do **not** use auto-discovery/scan — the bridge's default-deny FORWARD drops the multicast/mDNS that discovery relies on, so you must add by IP.
4. Enter the Sunshine PC's IP and connect.
5. Moonlight shows a 4-digit PIN. On the Sunshine PC, open the Sunshine web UI (`http://localhost:47990`), go to the **PIN** tab, enter the code, and submit. The Switch is now paired.
6. Add a game/app and stream.

## Config

Edit the block at the top of `setup.sh` and re-run it to change network settings:

| Setting | Default | Notes |
|---|---|---|
| `AP_SSID` | `Switch2Moonlight` | |
| `AP_PASSWORD` | *(empty)* | empty = open; set a WPA2 passphrase (8+ chars) to secure the AP |
| `AP_BAND` / `AP_CHANNEL` | `bg` / `6` | set `AP_BAND=a` + channel `36` for 5 GHz (Pi 4/5 — strongly recommended for streaming) |
| `AP_IP` / `AP_PREFIX` | `192.168.4.1` / `24` | the Pi's address on the Switch network |
| `DHCP_START` / `DHCP_END` | `192.168.4.2` – `192.168.4.50` | |
| `LAN_SUBNET` | `192.168.1.0/24` | home-LAN subnet to allow — or a single Sunshine IP, e.g. `192.168.1.50` |
| `ETH_IF` | `eth0` | uplink interface (home LAN) |

## Undo / revert

```sh
sudo systemctl disable --now civswitch-moonlight civswitch-moonlight-firewall dnsmasq
sudo rm -f /etc/systemd/system/civswitch-moonlight.service \
           /etc/systemd/system/civswitch-moonlight-firewall.service
sudo rm -f /etc/civswitch-moonlight.nft /etc/dnsmasq.conf \
           /etc/sysctl.d/99-civswitch-moonlight.conf
sudo mv /etc/dnsmasq.conf.civswitch-moonlight.bak /etc/dnsmasq.conf   # if a backup was made
sudo nft delete table ip moonlight_bridge 2>/dev/null || true
sudo sysctl -w net.ipv4.ip_forward=0
sudo nmcli con del Switch2Moonlight Switch2Moonlight-uplink
sudo rm -rf /opt/civswitch-moonlight
sudo systemctl daemon-reload
```

## License

MIT. The Nintendo connectivity-check responses are adapted from [90DNS](https://github.com/Thesola10/90dns) (GPL-2.0-or-later) via [fernando-granco/switch2-homebrew](https://github.com/fernando-granco/switch2-homebrew) (MIT), same as the ESP32, Pi, and Linux builds.
