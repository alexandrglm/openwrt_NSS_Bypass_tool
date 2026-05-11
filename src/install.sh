#!/usr/bin/env ash
# install.sh — Deploy NSS-Switch to /usr/bin/NSS-Switch/
# Run this on the router after uploading the files via SCP
# ASH compatible — BusyBox v1.37+

set -e

INSTALL_DIR=/usr/bin/NSS-Switch
FIREWALL_LINK=/etc/firewall.d/nss-bypass
FW_CONF=/etc/config/firewall

# ─── Colors (minimal, no lib loaded yet) ─────────────────────────────────────
G='\033[0;32m' Y='\033[0;33m' R='\033[0;31m' B='\033[1m' E='\033[0m'
ok()   { printf "${G}[ OK ]${E} %s\n" "$*"; }
info() { printf "       %s\n" "$*"; }
warn() { printf "${Y}[WARN]${E} %s\n" "$*"; }
err()  { printf "${R}[ERR ]${E} %s\n" "$*" >&2; }
sep()  { printf "────────────────────────────────────────\n"; }

# ─── Root check ───────────────────────────────────────────────────────────────
[ "$(id -u)" = "0" ] || { err "Run as root"; exit 1; }

# ─── Detect source dir (where this script lives) ─────────────────────────────
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

printf "\n${B}NSS-Switch Installer${E}\n"
sep
info "Source : $SRC_DIR"
info "Target : $INSTALL_DIR"
sep

# ─── Create directory structure ───────────────────────────────────────────────
mkdir -p "$INSTALL_DIR/lib"
mkdir -p "$INSTALL_DIR/state"
mkdir -p "$INSTALL_DIR/firewall.d"
ok "Directories created"

# ─── Copy main files ──────────────────────────────────────────────────────────
cp "$SRC_DIR/nss-switch.sh" "$INSTALL_DIR/nss-switch.sh"
cp "$SRC_DIR/config"        "$INSTALL_DIR/config"
ok "Main files copied"

# ─── Copy libraries ───────────────────────────────────────────────────────────
for lib in ui.sh ecm.sh conntrack.sh nft.sh detect.sh rules.sh; do
    if [ -f "$SRC_DIR/lib/$lib" ]; then
        cp "$SRC_DIR/lib/$lib" "$INSTALL_DIR/lib/$lib"
        ok "lib/$lib"
    else
        err "Missing: $SRC_DIR/lib/$lib"
        exit 1
    fi
done

# ─── Copy firewall hook ───────────────────────────────────────────────────────
cp "$SRC_DIR/firewall.d/nss-bypass" "$INSTALL_DIR/firewall.d/nss-bypass"
ok "firewall.d/nss-bypass"

# ─── Copy state/rules.conf (only if not already present — preserve existing) ──
if [ ! -f "$INSTALL_DIR/state/rules.conf" ]; then
    cp "$SRC_DIR/state/rules.conf" "$INSTALL_DIR/state/rules.conf"
    ok "state/rules.conf (fresh)"
else
    warn "state/rules.conf already exists — preserved (not overwritten)"
fi

# ─── Set permissions ──────────────────────────────────────────────────────────
chmod 755 "$INSTALL_DIR/nss-switch.sh"
chmod 644 "$INSTALL_DIR/config"
chmod 755 "$INSTALL_DIR/lib/"*.sh
chmod 755 "$INSTALL_DIR/firewall.d/nss-bypass"
chmod 644 "$INSTALL_DIR/state/rules.conf"
ok "Permissions set"

# ─── Symlink /etc/firewall.d/nss-bypass → our script ─────────────────────────
if [ -L "$FIREWALL_LINK" ]; then
    warn "$FIREWALL_LINK already a symlink — updating"
    ln -sf "$INSTALL_DIR/firewall.d/nss-bypass" "$FIREWALL_LINK"
elif [ -f "$FIREWALL_LINK" ]; then
    warn "$FIREWALL_LINK exists as file — backing up and replacing"
    mv "$FIREWALL_LINK" "${FIREWALL_LINK}.bak"
    ln -s "$INSTALL_DIR/firewall.d/nss-bypass" "$FIREWALL_LINK"
else
    ln -s "$INSTALL_DIR/firewall.d/nss-bypass" "$FIREWALL_LINK"
    ok "Symlink: $FIREWALL_LINK -> $INSTALL_DIR/firewall.d/nss-bypass"
fi

# ─── Add UCI include to /etc/config/firewall (idempotent) ────────────────────
if grep -q "nss_bypass_include" "$FW_CONF" 2>/dev/null; then
    warn "UCI include already present in $FW_CONF — skipped"
else
    printf "\nconfig include 'nss_bypass_include'\n\toption type 'script'\n\toption path '/etc/firewall.d/nss-bypass'\n" \
        >> "$FW_CONF"
    ok "UCI include added to $FW_CONF"
fi

# ─── Create symlink in PATH ───────────────────────────────────────────────────
if [ ! -L /usr/bin/nss-switch ]; then
    ln -s "$INSTALL_DIR/nss-switch.sh" /usr/bin/nss-switch
    ok "nss-switch available in PATH (/usr/bin/nss-switch)"
else
    warn "/usr/bin/nss-switch already exists — skipped"
fi

# ─── Verify structure ─────────────────────────────────────────────────────────
sep
printf "${B}Installed structure:${E}\n"
find "$INSTALL_DIR" | sort | while IFS= read -r f; do
    printf "  %s\n" "$f"
done

# ─── Run environment check ────────────────────────────────────────────────────
sep
printf "${B}Running environment check...${E}\n"
sep
"$INSTALL_DIR/nss-switch.sh" debug env 2>/dev/null || warn "Environment check had warnings (see above)"

sep
ok "Installation complete"
info ""
info "Usage:  nss-switch help"
info "        nss-switch watch"
info "        nss-switch pick"
info "        nss-switch debug env"
info ""
warn "Firewall NOT reloaded automatically."
info "When ready: /etc/init.d/firewall restart"
info ""
