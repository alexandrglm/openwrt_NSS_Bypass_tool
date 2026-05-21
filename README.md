# NSS-Switch - NSS Bypass

> **⚠️ WORK IN PROGRESS**

A selective CPU bypass manager for Qualcomm NSS (Network Subsystem) on OpenWrt.  
This tool allows you to mark specific connections so they are processed by the **CPU** instead of the **NSS hardware accelerator**.

![](./DOCS/img/watch.png)

Useful (and **needed**) for:

- Traffic that needs deep inspection (e.g., `tcpdump`, `bandwidthd`, `snort`)
- Debugging or troubleshooting NSS offload issues
- Per-flow bypass rules without disabling NSS globally

**No service/network restart required to bypass (hot-swapping) any NSS connection.**

> 📌 See [`CHANGELOG.md`](./CHANGELOG.md) for detailed history and pending work.

---

## Usage

```bash
# Bypass all traffic from a specific device
nss-switch add --src-ip 192.168.1.50 --comment "PC off NSS"


# Bypass SSH traffic (temporary)
nss-switch add --proto tcp --dst-port 22 --temp

# Interactive: pick a connection and create a rule
nss-switch pick
```
![](./DOCS/img/pick.png)

```bash
# Live monitor with 5-second refresh
nss-switch watch 5
```
![](./DOCS/img/bypassed.png)


### 🚀 Commands

| Command | Description |
|---|---|
| `nss-switch watch [--once] [interval]` | Live TUI monitor – refreshes every interval seconds. Use PgUp/PgDown / mouse to scroll. |
| `nss-switch pick` | Browse all active connections interactively and create a bypass rule from the selected one. |
| `nss-switch add [options]` | Manually add a bypass rule. |
| `nss-switch list` | List all defined bypass rules. |
| `nss-switch remove <id>` | Remove a bypass rule by ID. |
| `nss-switch flush [--rules\|--all\|--temp]` | Remove rules from nftables. |
| `nss-switch apply` | Re-apply `rules.conf` to nftables. |
| `nss-switch status` | Show full status dashboard (ECM state, rules, conntrack). |
| `nss-switch config [KEY] [VALUE]` | View or set configuration (`PERSIST_DEFAULT`, `DEBUG_MODE`, `WATCH_INTERVAL`). |
| `nss-switch debug <subcmd>` | Debugging tools – see `nss-switch debug --help`. |

---

# ➕ `add` Options

| Option | Description |
|---|---|
| `--proto tcp\|udp\|icmp\|any` | Match protocol |
| `--src-ip <IP/CIDR>` | Match source IP or subnet |
| `--dst-ip <IP/CIDR>` | Match destination IP or subnet |
| `--src-port <port>` | Match source port (TCP/UDP) |
| `--dst-port <port>` | Match destination port (TCP/UDP) |
| `--iface <interface>` | Match input interface (`out:<iface>` for egress) |
| `--persist` | Rule survives reboot |
| `--temp` | Temporary rule (lost on reboot) |
| `--comment <text>` | Human-readable label |
| `--no-defunct` | Skip ECM defunct after adding |


---

# 📦 Installation on OpenWrt

## Pre-requisites
- [X] - OpenWRT +25.12 with NSS (QCA SSDK) enabled
- [X] - Full `conntrack` / `iptables-nft` support.

## APK file
```bash
apk add /path/to/nss-switch-1.0.0-r1_DEBUG.apk --allow-untrusted
```
>  RSA public key is included in the repository/releases so they can be added to `/etc/apk/keys/` directly, making the `--allow-untrusted` flag unnecessary


## Using `install.sh` script

```bash
# Put the install.sh into your /tmp/ and run the installer
chmod +x install.sh
./install.sh
```

The installer:

- Copies all scripts to `/usr/bin/NSS-Switch/`
- Creates the needed symlinks
- Sets up persistent firewall includes for `fw4`
- Installs default configuration

---

## Manual Installation

```bash
# 1. Define installation paths
INSTALL_DIR="/usr/bin/NSS-Switch"
FIREWALL_LINK="/etc/firewall.d/nss-bypass"
FW_CONF="/etc/config/firewall"
RULES_FILE="$INSTALL_DIR/state/rules.conf"

# 2. Create required directories
mkdir -p "$INSTALL_DIR/lib"
mkdir -p "$INSTALL_DIR/state"
mkdir -p "$INSTALL_DIR/firewall.d"

# 3. Copy all files to their destinations
cp nss-switch.sh "$INSTALL_DIR/"
cp config "$INSTALL_DIR/"
cp lib/ui.sh "$INSTALL_DIR/lib/"
cp lib/ecm.sh "$INSTALL_DIR/lib/"
cp lib/conntrack.sh "$INSTALL_DIR/lib/"
cp lib/nft.sh "$INSTALL_DIR/lib/"
cp lib/detect.sh "$INSTALL_DIR/lib/"
cp lib/rules.sh "$INSTALL_DIR/lib/"
cp lib/debug.sh "$INSTALL_DIR/lib/"
cp firewall.d/nss-bypass "$INSTALL_DIR/firewall.d/"

# 4. Set permissions
chmod 755 "$INSTALL_DIR/nss-switch.sh"
chmod 644 "$INSTALL_DIR/config"
chmod 755 "$INSTALL_DIR/lib/"*.sh
chmod 755 "$INSTALL_DIR/firewall.d/nss-bypass"
touch "$RULES_FILE"
chmod 644 "$RULES_FILE"

# 5. Create symlink in PATH
ln -s "$INSTALL_DIR/nss-switch.sh" /usr/bin/nss-switch
chmod 755 /usr/bin/nss-switch

# 6. Create firewall symlink
ln -s "$INSTALL_DIR/firewall.d/nss-bypass" "$FIREWALL_LINK"

# 7. Add UCI include to firewall config (idempotent)
if ! grep -q "nss_bypass_include" "$FW_CONF" 2>/dev/null; then
    printf '\nconfig include 'nss_bypass_include'\n\toption type 'script'\n\toption path '/etc/firewall.d/nss-bypass'\n' >> "$FW_CONF"
fi

# 8. Once installed, apply any pre-existant rule (if you are updating)
nss-switch apply
```
---



## How it works

```
Mark 0x00010000 to desired packet -> Makes an ECM defunct -> So, CPU handles this traffic -> NSS bypass achieved
```

> NSS-Switch injects `nftables` rules into the kernel's `mangle` `pre` & `post` tables to set a specific packet mark (`0x00010000`) on matching connections. This mark is designed to not interfere with other marking schemes.

1. **Marking**: When a packet matches a user-defined rule (by IP, port, interface, etc.), nftables applies the `0x00010000` mark to the packet.

2. **Saving to conntrack**: A postrouting rule saves this mark to the connection tracking entry (`ct mark`), ensuring both directions of the flow carry the same mark.


> When ECM (Enhanced Connection Manager) detects this mark in a packet, it **defuncts** the connection (to shut it down for an established NSS path), forcing an immediate re‑evaluation. The mark persists as long as the rule persist, so ECM hands the flow to the **CPU** instead of the NSS hardware accelerator as needed.



3. **ECM defunct**: The Enhanced Connection Manager (ECM), which normally accelerates connections via NSS hardware, detects this mark and immediately **defuncts** the connection, forcing a full re‑evaluation.

> Now, the connection is processed by the CPU, bypassing NSS acceleration entirely. 

> No service restart is required, and only the marked connections are affected , and NSS continues to accelerate all other traffic normally.

4. **CPU takeover**:  Because the mark persists, ECM hands the flow to the standard Linux network stack (CPU) instead of offloading it to NSS hardware.

5. **Restore on reply**: A prerouting rule restores the mark from conntrack for reply packets, maintaining bypass status in both directions.



---

# 🧪 Status

| Component | Status |
|---|---|
| `ipq807x` (e.g., Xiaomi AX3600) | ✅ Fully tested and functional |
| Other NSS SoCs (`ipq607x`, `ipq501x`) | ❌ Not tested , no hardware available for development |
| ECM frontend detection | ✅ Works with Hardware Offloading (NSS), also Software Offloading (SFE) |
| `nftables` + `conntrack` integration | ✅ Fully working |
| Interactive shell UI (`watch`, `pick`) | ✅ Working with native terminal components |
| Persistent rules | ✅ Survive reboots via `rules.conf` and `fw4` includes |

> 📌 See [`CHANGELOG.md`](./CHANGELOG.md) for detailed history and pending work.


---


# 🤝 Contributing & PR to OpenWrt

This tool is not yet ready for an official OpenWrt package.

## Reason

NSS-Switch is only useful for users running a non-official OpenWrt fork with NSS support (typically developed maintained by @AgustinLorenzo, [here](https://github.com/AgustinLorenzo/openwrt)). Mainline OpenWrt does not include NSS drivers.

## If you want to help

- Test on other SoC's which includes any NSS solution (`ipq60xx`, `ipq50xx`)
- Report bugs with `nss-switch debug env` output
- Submit fixes or improvements

---

# 📄 License

GPL-2.0

---

# 👏 Thanks

- @AgustinLorenzo / @qosmio: OpenWrt NSS forks, `nss_packages`, `qca-ssdk`, and inspiration
- Any community testers on `ipq807x` hardware
