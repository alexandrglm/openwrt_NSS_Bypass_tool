#!/usr/bin/env ash
# uninstall.sh — Complete removal of NSS-Switch
# Run this to remove all rules, connections, and files
# ASH compatible — BusyBox v1.37+

set -e

INSTALL_DIR=/usr/bin/NSS-Switch
FIREWALL_LINK=/etc/firewall.d/nss-bypass
FW_CONF=/etc/config/firewall
NSS_MARK=0x00010000

# ─── Colors ───────────────────────────────────────────────────────────────────
G='\033[0;32m' Y='\033[0;33m' R='\033[0;31m' B='\033[1m' E='\033[0m'
ok()   { printf "${G}[ OK ]${E} %s\n" "$*"; }
info() { printf "       %s\n" "$*"; }
warn() { printf "${Y}[WARN]${E} %s\n" "$*"; }
err()  { printf "${R}[ERR ]${E} %s\n" "$*" >&2; }
sep()  { printf "────────────────────────────────────────\n"; }

# ─── Root check ───────────────────────────────────────────────────────────────
[ "$(id -u)" = "0" ] || { err "Run as root"; exit 1; }

printf "\n${B}NSS-Switch Uninstaller${E}\n"
sep
warn "This will REMOVE all NSS-Switch components and rules"
warn "All bypass rules will be deleted"
warn "NSS acceleration will be restored to normal"
sep

# Confirm
printf "${B}Are you sure? Type 'yes' to continue: ${E}"
read -r confirm
if [ "$confirm" != "yes" ]; then
    info "Uninstall cancelled"
    exit 0
fi

# ─── 1. Remove nftables chains and rules ──────────────────────────────────────
info "Removing nftables rules..."

# Remove jumps from mangle chains
handles=$(nft -a list chain inet fw4 mangle_prerouting 2>/dev/null | grep "jump nss_bypass_pre" | grep -oE 'handle [0-9]+' | awk '{print $2}')
for h in $handles; do
    nft delete rule inet fw4 mangle_prerouting handle "$h" 2>/dev/null
done

handles=$(nft -a list chain inet fw4 mangle_postrouting 2>/dev/null | grep "jump nss_bypass_post" | grep -oE 'handle [0-9]+' | awk '{print $2}')
for h in $handles; do
    nft delete rule inet fw4 mangle_postrouting handle "$h" 2>/dev/null
done

# Delete our chains
nft delete chain inet fw4 nss_bypass_pre 2>/dev/null
nft delete chain inet fw4 nss_bypass_post 2>/dev/null

ok "nftables rules removed"

# ─── 2. Remove conntrack marks (clear bypass) ─────────────────────────────────
info "Clearing conntrack marks..."
if [ -f /proc/net/nf_conntrack ]; then
    # Get all connections with our mark and clear them
    conntrack -L 2>/dev/null | grep "mark=$NSS_MARK" | while read -r line; do
        proto=$(echo "$line" | awk '{print $1}')
        src=$(echo "$line" | grep -oE 'src=[^ ]+' | head -1 | cut -d= -f2)
        dst=$(echo "$line" | grep -oE 'dst=[^ ]+' | head -1 | cut -d= -f2)
        [ -n "$proto" ] && [ -n "$src" ] && [ -n "$dst" ] && \
            conntrack -D -p "$proto" -s "$src" -d "$dst" 2>/dev/null
    done
fi
ok "Conntrack marks cleared"

# ─── 3. Force ECM to defunct all and re-evaluate ──────────────────────────────
info "Restoring ECM/NSS acceleration..."
if [ -f /sys/kernel/debug/ecm/ecm_db/defunct_all ]; then
    echo 1 > /sys/kernel/debug/ecm/ecm_db/defunct_all 2>/dev/null
    ok "ECM defuncted (will re-accelerate normally)"
fi

# ─── 4. Remove UCI include from /etc/config/firewall ──────────────────────────
info "Removing UCI include from firewall config..."
if grep -q "nss_bypass_include" "$FW_CONF" 2>/dev/null; then
    sed -i "/config include 'nss_bypass_include'/,+2d" "$FW_CONF"
    ok "UCI include removed"
else
    info "UCI include not found"
fi

# ─── 5. Remove symlink from /etc/firewall.d ───────────────────────────────────
info "Removing firewall hook symlink..."
if [ -L "$FIREWALL_LINK" ]; then
    rm -f "$FIREWALL_LINK"
    ok "Symlink removed"
elif [ -f "$FIREWALL_LINK" ]; then
    warn "Found regular file, backing up to ${FIREWALL_LINK}.uninstall.bak"
    mv "$FIREWALL_LINK" "${FIREWALL_LINK}.uninstall.bak"
fi

# ─── 6. Remove symlink from /usr/bin ──────────────────────────────────────────
info "Removing nss-switch command..."
if [ -L /usr/bin/nss-switch ]; then
    rm -f /usr/bin/nss-switch
    ok "Symlink removed"
fi

# ─── 7. Remove entire installation directory ──────────────────────────────────
info "Removing $INSTALL_DIR..."
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    ok "Installation directory removed"
fi

# ─── 8. Clean temporary files ─────────────────────────────────────────────────
info "Cleaning temporary files..."
rm -f /tmp/nss-switch-pick.* 2>/dev/null
rm -f /tmp/nss-ifmap.* 2>/dev/null
rm -f /tmp/nss-debug-* 2>/dev/null
rm -f /tmp/nss-debug-prev-* 2>/dev/null
ok "Temporary files cleaned"

# ─── 9. Restart firewall to apply changes ─────────────────────────────────────
info "Restarting firewall..."
/etc/init.d/firewall restart 2>/dev/null
ok "Firewall restarted"

# ─── 10. Final summary ───────────────────────────────────────────────────────
sep
printf "${B}Uninstall Complete${E}\n"
sep
info "The following have been removed:"
info "  • All nftables bypass rules and chains"
info "  • All conntrack marks (bypass flags)"
info "  • ECM configuration restored to normal"
info "  • UCI include from /etc/config/firewall"
info "  • Symlinks from /etc/firewall.d/ and /usr/bin/"
info "  • $INSTALL_DIR"
info "  • Temporary files"
sep
ok "NSS acceleration is now fully restored to normal operation"
info ""
info "You may want to run: /etc/init.d/firewall restart"
info "If you had custom rules before NSS-Switch, they remain unchanged"
info ""
