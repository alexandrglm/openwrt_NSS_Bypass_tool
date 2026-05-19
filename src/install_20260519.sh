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

printf "\n${B}NSS-Switch Installer${E}\n"
sep
info "Target : $INSTALL_DIR"
sep

# ─── Create directory structure ───────────────────────────────────────────────
mkdir -p "$INSTALL_DIR/lib"
mkdir -p "$INSTALL_DIR/state"
mkdir -p "$INSTALL_DIR/firewall.d"
ok "Directories created"

# ──────────────────────────────────────────────────────────────────────────────
# CREATE nss-switch.sh
# ──────────────────────────────────────────────────────────────────────────────
cat > "$INSTALL_DIR/nss-switch.sh" << 'EOF'
#!/usr/bin/env ash
# nss-switch.sh — Qualcomm NSS selective bypass manager
# /usr/bin/NSS-Switch/nss-switch.sh
# ASH compatible — BusyBox v1.37+
# Usage: nss-switch <command> [options]

# set -e

# ─── Resolve our own directory ────────────────────────────────────────────────
SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# ─── Load config ──────────────────────────────────────────────────────────────
CONFIG_FILE="$SELF_DIR/config"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERR ] Config file not found: $CONFIG_FILE" >&2
    exit 1
fi
. "$CONFIG_FILE"

# ─── Debug logging helper (available before libs load) ────────────────────────
dbg() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "${DEBUG:-0}" = "1" ] || [ "$DEBUG_MODE" = "yes" ]; then
        printf "[DBG ] %s\n" "$*" >&2
        printf "%s [DBG] %s\n" "$ts" "$*" >> "$DEBUG_LOG" 2>/dev/null || true
    else
        printf "%s [DBG] %s\n" "$ts" "$*" >> "$DEBUG_LOG" 2>/dev/null || true
    fi
}

# ─── Load libraries ───────────────────────────────────────────────────────────
for lib in ui ecm conntrack nft detect rules; do
    lib_file="$SELF_DIR/lib/${lib}.sh"
    if [ ! -f "$lib_file" ]; then
        echo "[ERR ] Missing library: $lib_file" >&2
        exit 1
    fi
    . "$lib_file"
done
# ─── Load debug monitor  ────────────────────────
DEBUG_LIB="$SELF_DIR/lib/debug.sh"
if [ -f "$DEBUG_LIB" ]; then
    . "$DEBUG_LIB"
else
    cmd_debug_monitor() {
        ui_error "debug.sh should not be visible in PRODUCTION, monitor NOT available, sorry!"
        return 1
    }
fi

# ─── Root check ───────────────────────────────────────────────────────────────
check_root() {
    [ "$(id -u)" = "0" ] || { ui_error "Must be run as root"; exit 1; }
}

# ─── Log every invocation ────────────────────────────────────────────────────
dbg "Invoked: $0 $*"

# ─── Clean tmp files in each exec ────────────────────────────────────────────
_clean_tmp() {
    rm -f /tmp/nss-switch-pick.* 2>/dev/null
    rm -f /tmp/nss-ifmap.* 2>/dev/null
}
trap _clean_tmp INT TERM EXIT

# ─── COMMAND: watch ───────────────────────────────────────────────────────────
cmd_watch() {
    check_root
    local interval="${1:-$WATCH_INTERVAL}"
    local once=0
    [ "$1" = "--once" ] && { once=1; interval=0; }

    while true; do
        clear
        ui_banner
        printf "${C_DIM}Refresh: ${interval}s  |  Press Ctrl+C to exit  |  %s${C_RESET}\n" "$(date)"
        ui_sep

        local total bypassed
        total=$(ct_count)
        bypassed=$(ct_count_bypassed)
        ui_kv "Total connections" "$total"
        ui_kv "NSS-bypassed (CPU)" "$bypassed"
        ui_kv "NSS frontend" "$(ecm_frontend)  engine=$(ecm_engine)"
        ui_sep

        ui_conn_header
        ct_dump_all_full | while IFS='|' read -r n proto src dst iface nss bypass mark state; do
            local src_ip src_port dst_ip dst_port src_short dst_short
            src_ip=$(echo "$src" | cut -d'#' -f1)
            src_port=$(echo "$src" | cut -d'#' -f2)
            dst_ip=$(echo "$dst" | cut -d'#' -f1)
            dst_port=$(echo "$dst" | cut -d'#' -f2)
            if echo "$src_ip" | grep -q ":"; then
                src_short="[${src_ip}]:${src_port}"
            else
                src_short="${src_ip}:${src_port}"
            fi
            if echo "$dst_ip" | grep -q ":"; then
                dst_short="[${dst_ip}]:${dst_port}"
            else
                dst_short="${dst_ip}:${dst_port}"
            fi
            ui_conn_row "$n" "$proto" "$src_short" "$dst_short" "$iface" "$nss" "$bypass"
        done

        [ "$once" = "1" ] && break
        sleep "$interval"
    done
}

# ─── COMMAND: pick ────────────────────────────────────────────────────────────
cmd_pick() {
    check_root
    ui_banner
    ui_section "Connection Picker | Loading ..."

    local tmpfile
    tmpfile=$(mktemp /tmp/nss-switch-pick.XXXXXX)

    # DEBUG trap particular
    # trap "rm -f '$tmpfile'; trap - INT TERM EXIT; exit" INT TERM EXIT

    ct_dump_all_full > "$tmpfile"

    local total
    total=$(wc -l < "$tmpfile")
    if [ "$total" -eq 0 ]; then
        ui_warn "No connections found in conntrack"
        rm -f "$tmpfile"
        return 0
    fi

# DEBUG:    Pendiente reparar awk con la sintax de ash busybox
#     ui_conn_header
#     while IFS='|' read -r num proto src dst iface nss bypass mark state; do
#         src_ip=$(echo "$src" | cut -d'#' -f1)
#         src_port=$(echo "$src" | cut -d'#' -f2)
#         dst_ip=$(echo "$dst" | cut -d'#' -f1)
#         dst_port=$(echo "$dst" | cut -d'#' -f2)
#
#         if echo "$src_ip" | grep -q ":"; then
#             src_display="[${src_ip}]:${src_port}"
#         else
#             src_display="${src_ip}:${src_port}"
#         fi
#         if echo "$dst_ip" | grep -q ":"; then
#             dst_display="[${dst_ip}]:${dst_port}"
#         else
#             dst_display="${dst_ip}:${dst_port}"
#         fi
#
#         printf "%-4s %-6s %-40s %-40s %-17s %-5s %-8s\n" \
#             "$num" "$proto" "$src_display" "$dst_display" "$iface" "$nss" "$bypass"
#     done < "$tmpfile"
#     ui_sep
    ui_conn_header
    while IFS='|' read -r n proto src dst iface nss bypass mark state; do
        local src_ip src_port dst_ip dst_port src_short dst_short
        src_ip=$(echo "$src" | cut -d'#' -f1)
        src_port=$(echo "$src" | cut -d'#' -f2)
        dst_ip=$(echo "$dst" | cut -d'#' -f1)
        dst_port=$(echo "$dst" | cut -d'#' -f2)

        if echo "$src_ip" | grep -q ":"; then
            src_short="[${src_ip}]:${src_port}"
        else
            src_short="${src_ip}:${src_port}"
        fi
        if echo "$dst_ip" | grep -q ":"; then
            dst_short="[${dst_ip}]:${dst_port}"
        else
            dst_short="${dst_ip}:${dst_port}"
        fi

        ui_conn_row "$n" "$proto" "$src_short" "$dst_short" "$iface" "$nss" "$bypass"
    done < "$tmpfile"
    ui_sep
#     ui_conn_header
#     awk -F'|' '{
#         split($3, s, "#"); split($4, d, "#")
#         src_ip=substr(s[1],1,32)
#         dst_ip=substr(d[1],1,32)
#         src=(src_ip ~ /:/) ? "["src_ip"]:"s[2] : src_ip":"s[2]
#         dst=(dst_ip ~ /:/) ? "["dst_ip"]:"d[2] : dst_ip":"d[2]
#         printf "%-4s %-6s %-40s %-40s %-17s %-5s %-8s\n", $1,$2,src,dst,$5,$6,$7
#     }' "$tmpfile"
#     ui_sep

    ui_ask_num "Select connection number to configure" 1 "$total" || {
        rm -f "$tmpfile"
        return 1
    }
    local sel="$UI_NUM"

    local conn_line
    conn_line=$(awk -F'|' -v n="$sel" '$1==n {print; exit}' "$tmpfile")
    rm -f "$tmpfile"

    if [ -z "$conn_line" ]; then
        ui_error "Connection $sel not found"
        return 1
    fi

    local num proto src dst iface nss bypass mark state
    num=$(echo "$conn_line"   | cut -d'|' -f1)
    proto=$(echo "$conn_line" | cut -d'|' -f2)
    src=$(echo "$conn_line"   | cut -d'|' -f3)
    dst=$(echo "$conn_line"   | cut -d'|' -f4)
    iface=$(echo "$conn_line" | cut -d'|' -f5)
    nss=$(echo "$conn_line"   | cut -d'|' -f6)
    bypass=$(echo "$conn_line"| cut -d'|' -f7)
    mark=$(echo "$conn_line"  | cut -d'|' -f8)
    state=$(echo "$conn_line" | cut -d'|' -f9)

    local src_ip src_port dst_ip dst_port
    src_ip=$(echo "$src" | cut -d'#' -f1)
    src_port=$(echo "$src" | cut -d'#' -f2)
    dst_ip=$(echo "$dst" | cut -d'#' -f1)
    dst_port=$(echo "$dst" | cut -d'#' -f2)

    ui_section "Selected Connection"
    ui_kv "Protocol"  "$proto"
    ui_kv "Source"    "$src_ip : $src_port"
    ui_kv "Dest"      "$dst_ip : $dst_port"
    ui_kv "Interface" "$iface"
    ui_kv "NSS state" "$nss"
    ui_kv "Bypassed"  "$bypass"
    ui_sep

    ui_section "What should the bypass rule match on?"
    ui_bold "You can combine multiple criteria. Answer each:"
    printf "\n"

    local r_proto="any" r_src_ip="any" r_dst_ip="any"
    local r_sport="any" r_dport="any" r_iface="any"

    if ui_ask_yn "Match on protocol ($proto)?" y; then
        r_proto="$proto"
    fi
    if ui_ask_yn "Match on source IP ($src_ip)?" n; then
        ui_ask_input "Enter source IP/CIDR (or press Enter to keep '$src_ip')" "$src_ip"
        r_src_ip="$UI_INPUT"
    fi
    if ui_ask_yn "Match on destination IP ($dst_ip)?" n; then
        ui_ask_input "Enter destination IP/CIDR (or press Enter to keep '$dst_ip')" "$dst_ip"
        r_dst_ip="$UI_INPUT"
    fi
    if [ "$proto" = "tcp" ] || [ "$proto" = "udp" ]; then
        if ui_ask_yn "Match on source port ($src_port)?" n; then
            ui_ask_input "Source port" "$src_port"
            r_sport="$UI_INPUT"
        fi
        if ui_ask_yn "Match on destination port ($dst_port)?" n; then
            ui_ask_input "Destination port" "$dst_port"
            r_dport="$UI_INPUT"
        fi
    fi
    if [ "$iface" != "?" ] && [ -n "$iface" ]; then
        case "$iface" in
            local:*)
                local real_iface="${iface#local:}"
                ui_warn "Router-generated traffic (not a LAN device)"
                if ui_ask_yn "Match by output interface ($real_iface)?" y; then
                    r_iface="out:$real_iface"
                fi
                ;;
            *)
                if ui_ask_yn "Match on interface ($iface)?" n; then
                    r_iface="$iface"
                fi
                ;;
        esac
    fi

    local persist="$PERSIST_DEFAULT"
    if ui_ask_yn "Make this rule persistent (survive reboot)?" "$([ "$PERSIST_DEFAULT" = "yes" ] && echo y || echo n)"; then
        persist="yes"
    else
        persist="no"
    fi

    ui_ask_input "Comment for this rule" "bypass from pick: $src_ip -> $dst_ip"
    local comment="$UI_INPUT"

    ui_section "Rule Preview"
    ui_kv "Protocol"   "$r_proto"
    ui_kv "Src IP"     "$r_src_ip"
    ui_kv "Dst IP"     "$r_dst_ip"
    ui_kv "Src Port"   "$r_sport"
    ui_kv "Dst Port"   "$r_dport"
    ui_kv "Interface"  "$r_iface"
    ui_kv "Persistent" "$persist"
    ui_kv "Comment"    "$comment"
    ui_sep

    if ! rules_validate "$r_proto" "$r_src_ip" "$r_dst_ip" "$r_sport" "$r_dport" "$r_iface"; then
        ui_error "Validation failed — rule not added"
        return 1
    fi

    ui_confirm "Apply this bypass rule?" || { ui_warn "Aborted"; return 0; }

    local new_id
    new_id=$(rules_add "$r_proto" "$r_src_ip" "$r_dst_ip" \
        "$r_sport" "$r_dport" "$r_iface" "$persist" "$comment")
    ui_ok "Rule $new_id saved"

    nft_apply

    ui_info "Flushing matched connections..."
    ct_clear_rule_marks "$r_proto" "$r_src_ip" "$r_dst_ip" \
        "$r_sport" "$r_dport" "$r_iface"

    # DEBUG trap particular
    # rm -f "$tmpfile"
    # trap - INT TERM EXIT
    ui_ok "Done. Connection will be handled by CPU (not NSS) going forward."
}

# ─── COMMAND: add ─────────────────────────────────────────────────────────────
cmd_add() {
    check_root
    local proto="any" src_ip="any" dst_ip="any"
    local sport="any" dport="any" iface="any"
    local persist="$PERSIST_DEFAULT" comment="manual rule"
    local defunct_after=1

    while [ $# -gt 0 ]; do
        case "$1" in
            --proto)      proto="$2";    shift 2 ;;
            --src-ip)     src_ip="$2";   shift 2 ;;
            --dst-ip)     dst_ip="$2";   shift 2 ;;
            --src-port)   sport="$2";    shift 2 ;;
            --dst-port)   dport="$2";    shift 2 ;;
            --iface)      iface="$2";    shift 2 ;;
            --persist)    persist="yes"; shift   ;;
            --temp)       persist="no";  shift   ;;
            --comment)    comment="$2";  shift 2 ;;
            --no-defunct) defunct_after=0; shift ;;
            *)
                ui_error "Unknown option: $1"
                cmd_help
                return 1
                ;;
        esac
    done

    ui_banner
    ui_section "Add Manual Bypass Rule"
    ui_kv "Protocol"   "$proto"
    ui_kv "Src IP"     "$src_ip"
    ui_kv "Dst IP"     "$dst_ip"
    ui_kv "Src Port"   "$sport"
    ui_kv "Dst Port"   "$dport"
    ui_kv "Interface"  "$iface"
    ui_kv "Persistent" "$persist"
    ui_kv "Comment"    "$comment"
    [ "$defunct_after" = "0" ] && ui_kv "Defunct" "SKIP"

    rules_validate "$proto" "$src_ip" "$dst_ip" "$sport" "$dport" "$iface" || return 1

    local new_id
    new_id=$(rules_add "$proto" "$src_ip" "$dst_ip" "$sport" "$dport" "$iface" "$persist" "$comment")
    ui_ok "Rule $new_id added to $RULES_FILE"

    nft_apply

    if [ "$defunct_after" = "1" ]; then
        ui_info "Flushing matched connections..."
        ct_clear_rule_marks "$proto" "$src_ip" "$dst_ip" "$sport" "$dport" "$iface"
    else
        ui_info "Skipped connection flush (--no-defunct)"
        ui_info "New connections will be affected, existing ones will keep their state"
    fi

    ui_ok "Bypass rule $new_id is active"
}

# ─── COMMAND: list ────────────────────────────────────────────────────────────
cmd_list() {
    ui_banner
    ui_section "Active NSS Bypass Rules"
    rules_list
    echo ""
    ui_kv "Rules file" "$RULES_FILE"
    ui_kv "Firewall script" "$FW_SCRIPT"
    if nft_chains_exist 2>/dev/null; then
        ui_ok "NSS-Switch chains are live in nftables"
    else
        ui_warn "NSS-Switch chains NOT in live ruleset — run: nss-switch apply"
    fi
}

# ─── COMMAND: remove ──────────────────────────────────────────────────────────
cmd_remove() {
    check_root
    local id="$1"
    if [ -z "$id" ]; then
        ui_error "Usage: nss-switch remove <rule-id>"
        return 1
    fi
    ui_banner
    ui_section "Remove Rule $id"

    local line
    line=$(rules_get "$id") || { ui_error "Rule $id not found"; return 1; }
    rules_parse "$line"
    ui_kv "ID"      "$RULE_ID"
    ui_kv "Proto"   "$RULE_PROTO"
    ui_kv "Src IP"  "$RULE_SRC_IP"
    ui_kv "Dst IP"  "$RULE_DST_IP"
    ui_kv "Sport"   "$RULE_SPORT"
    ui_kv "Dport"   "$RULE_DPORT"
    ui_kv "Iface"   "$RULE_IFACE"
    ui_kv "Comment" "$RULE_COMMENT"

    ui_confirm "Remove this rule?" || { ui_warn "Aborted"; return 0; }

    rules_remove "$id"
    nft_apply

    ui_info "Clearing conntrack entries for this rule..."
    ct_clear_rule_marks "$RULE_PROTO" "$RULE_SRC_IP" "$RULE_DST_IP" \
        "$RULE_SPORT" "$RULE_DPORT" "$RULE_IFACE"

    ui_info "Defuncting ECM so NSS can re-accelerate..."
    ecm_defunct_all

    ui_ok "Rule $id removed. ECM will re-evaluate and re-accelerate those flows."
}

# ─── COMMAND: flush ───────────────────────────────────────────────────────────
cmd_flush() {
    check_root
    local mode="${1:---rules}"
    ui_banner
    ui_section "Flush NSS-Switch Rules"

    case "$mode" in
        --rules)
            ui_info "Removing all bypass rules from nftables (keeping rules.conf)"
            ui_confirm "Continue?" || return 0
            # Clear rules.conf, regenerate (empty) script, reload
            rules_clear
            nft_apply
            ecm_defunct_all
            ui_ok "All rules flushed from nftables. ECM will re-accelerate all flows."
            ;;
        --all)
            ui_warn "This removes ALL NSS-Switch configuration including persistent rules"
            ui_confirm "Are you sure?" || return 0
            rules_clear
            nft_apply
            ecm_defunct_all
            # Remove fw4 include
            _nft_remove_uci_include
            # Remove symlink
            rm -f /etc/firewall.d/nss-bypass 2>/dev/null || true
            ui_ok "NSS-Switch fully removed. Reload firewall to clean live rules."
            ;;
        --temp)
            ui_info "Removing only non-persistent (temporary) rules"
            ui_confirm "Continue?" || return 0
            rules_clear_temp
            nft_apply
            ecm_defunct_all
            ui_ok "Temporary rules flushed"
            ;;
        *)
            ui_error "Usage: nss-switch flush [--rules|--all|--temp]"
            return 1
            ;;
    esac
}

# ─── COMMAND: apply ───────────────────────────────────────────────────────────
# Re-generate script and reload firewall (useful after manual edits)
cmd_apply() {
    check_root
    ui_banner
    ui_info "Regenerating firewall script from rules.conf and reloading..."
    nft_apply
    ui_ok "Applied. Current rules:"
    rules_list
}

# ─── COMMAND: debug ───────────────────────────────────────────────────────────
cmd_debug() {
    local subcmd="${1:-env}"
    shift 2>/dev/null || true

    ui_banner
    case "$subcmd" in
        env)
            detect_check_all
            ;;
        ecm)
            ecm_debug_dump
            ;;
        nft)
            nft_show_our_rules
            ;;
        conntrack)
            ct_debug_raw
            ;;
        mark)
            ct_debug_mark
            ;;
        defunct-all)
            check_root
            ui_warn "This will defunct ALL connections in ECM — they will be re-evaluated"
            ui_confirm "Proceed?" || return 0
            ecm_defunct_all
            ;;
        frontend-stop)
            check_root
            local fam="${1:-both}"
            case "$fam" in
                ipv4) ecm_stop_ipv4 ;;
                ipv6) ecm_stop_ipv6 ;;
                both) ecm_stop_ipv4; ecm_stop_ipv6 ;;
                *)    ui_error "Usage: debug frontend-stop [ipv4|ipv6|both]"; return 1 ;;
            esac
            ;;
        frontend-restart)
            check_root
            ecm_restart
            ui_ok "ECM service restarted"
            ;;
        log)
            ui_section "NSS-Switch Debug Log (last 50 lines)"
            if [ -f "$DEBUG_LOG" ]; then
                tail -50 "$DEBUG_LOG"
            else
                ui_warn "No log file yet: $DEBUG_LOG"
            fi
            ;;
        log-clear)
            check_root
            > "$DEBUG_LOG"
            ui_ok "Log cleared"
            ;;
        rules-raw)
            ui_section "Raw rules.conf"
            cat "$RULES_FILE" 2>/dev/null || ui_warn "No rules file"
            ;;
        script-raw)
            ui_section "Raw generated firewall script"
            cat "$FW_SCRIPT" 2>/dev/null || ui_warn "No script generated yet"
            ;;
        monitor)
            cmd_debug_monitor "$@"
            ;;
        *)
            ui_error "Unknown debug subcommand: $subcmd"
            cmd_debug_help
            return 1
            ;;
    esac
}

cmd_debug_help() {
    printf "\n${C_BOLD}debug subcommands:${C_RESET}\n"
    printf "  %-25s %s\n" "env"              "Full environment check"
    printf "  %-25s %s\n" "ecm"              "ECM/NSS state dump"
    printf "  %-25s %s\n" "nft"              "Show our live nftables chains"
    printf "  %-25s %s\n" "conntrack"        "Dump raw /proc/net/nf_conntrack"
    printf "  %-25s %s\n" "mark"             "Show conntrack entries with our bypass mark"
    printf "  %-25s %s\n" "defunct-all"      "Force defunct ALL connections in ECM"
    printf "  %-25s %s\n" "frontend-stop [ipv4|ipv6|both]" "Stop NSS frontend(s)"
    printf "  %-25s %s\n" "frontend-restart" "Restart ECM service"
    printf "  %-25s %s\n" "log"              "Show last 50 lines of debug log"
    printf "  %-25s %s\n" "log-clear"        "Clear debug log"
    printf "  %-25s %s\n" "rules-raw"        "Show raw rules.conf content"
    printf "  %-25s %s\n" "script-raw"       "Show raw generated firewall script"
}

# ─── COMMAND: config ──────────────────────────────────────────────────────────
cmd_config() {
    local key="$1" val="$2"
    ui_banner
    ui_section "NSS-Switch Configuration"

    if [ -z "$key" ]; then
        # Show current config
        cat "$CONFIG_FILE" | grep -v '^#' | grep -v '^$' | while IFS='=' read -r k v; do
            ui_kv "$k" "$v"
        done
        return 0
    fi

    # Set a config value
    case "$key" in
        PERSIST_DEFAULT|DEBUG_MODE|WATCH_INTERVAL)
            if grep -q "^$key=" "$CONFIG_FILE"; then
                sed -i "s|^$key=.*|$key=$val|" "$CONFIG_FILE"
                ui_ok "Set $key=$val"
            else
                printf "%s=%s\n" "$key" "$val" >> "$CONFIG_FILE"
                ui_ok "Added $key=$val"
            fi
            ;;
        *)
            ui_error "Unknown config key: $key"
            ui_info "Valid keys: PERSIST_DEFAULT, DEBUG_MODE, WATCH_INTERVAL"
            return 1
            ;;
    esac
}

# ─── COMMAND: status ──────────────────────────────────────────────────────────
cmd_status() {
    ui_banner
    ui_section "NSS-Switch Status"

    ui_kv "Rules defined"  "$(rules_count)"
    ui_kv "Temp rules"     "$(grep -c '|no|'  "$RULES_FILE" 2>/dev/null; true)"
    ui_kv "Persist rules"  "$(grep -c '|yes|' "$RULES_FILE" 2>/dev/null; true)"
    echo ""
    ui_kv "ECM frontend" "$(ecm_frontend)"
    ui_kv "ECM engine" "$(ecm_engine)"
    ui_kv "Mark classifier" "$(ecm_mark_classifier_available && echo 'AVAILABLE' || echo 'MISSING')"
    echo ""
    ui_kv "Total conntrack" "$(ct_count)"
    ui_kv "Bypassed (CPU)" "$(ct_count_bypassed)"
    echo ""
    if nft_chains_exist 2>/dev/null; then
        ui_ok "NSS-Switch nft chains: LIVE"
    else
        ui_warn "NSS-Switch nft chains: NOT ACTIVE"
    fi
    ui_kv "Our mark" "$NSS_MARK"
    echo ""
    ui_section "Active Rules"
    rules_list
}

# ─── HELP ─────────────────────────────────────────────────────────────────────
cmd_help() {
    ui_banner
    printf "\n${C_BOLD}Usage:${C_RESET}  nss-switch <command> [options]\n\n"
    printf "${C_BOLD}Commands:${C_RESET}\n"
    printf "  ${C_CYAN}%-35s${C_RESET} %s\n" "watch [--once] [interval]"       "Live connection viewer (NSS vs CPU)"
    printf "  ${C_CYAN}%-35s${C_RESET} %s\n" "pick"                             "Interactive: pick a connection and bypass it"
    printf "  ${C_CYAN}%-35s${C_RESET} %s\n" "add [options]"                    "Manually add a bypass rule"
    printf "  ${C_CYAN}%-35s${C_RESET} %s\n" "list"                             "List all defined bypass rules"
    printf "  ${C_CYAN}%-35s${C_RESET} %s\n" "remove <id>"                      "Remove a bypass rule by ID"
    printf "  ${C_CYAN}%-35s${C_RESET} %s\n" "flush [--rules|--all|--temp]"     "Remove rules (--all removes everything)"
    printf "  ${C_CYAN}%-35s${C_RESET} %s\n" "apply"                            "Re-apply rules.conf to nftables"
    printf "  ${C_CYAN}%-35s${C_RESET} %s\n" "status"                           "Show full status"
    printf "  ${C_CYAN}%-35s${C_RESET} %s\n" "config [KEY] [VALUE]"             "View/set configuration"
    printf "  ${C_CYAN}%-35s${C_RESET} %s\n" "debug <subcommand>"               "Debug tools"
    printf "  ${C_CYAN}%-35s${C_RESET} %s\n" "help"                             "This help"
    printf "\n"
    printf "${C_BOLD}add options:${C_RESET}\n"
    printf "  %-30s %s\n" "--proto tcp|udp|icmp|any"  "Match protocol"
    printf "  %-30s %s\n" "--src-ip <IP/CIDR>"        "Match source IP or subnet"
    printf "  %-30s %s\n" "--dst-ip <IP/CIDR>"        "Match destination IP or subnet"
    printf "  %-30s %s\n" "--src-port <port>"         "Match source port (tcp/udp)"
    printf "  %-30s %s\n" "--dst-port <port>"         "Match destination port"
    printf "  %-30s %s\n" "--iface <interface>"       "Match input interface"
    printf "  %-30s %s\n" "--persist"                 "Survive reboot"
    printf "  %-30s %s\n" "--temp"                    "Temporary (default)"
    printf "  %-30s %s\n" "--comment <text>"          "Human label"
    printf "  %-30s %s\n" "--no-defunct"              "Skip ECM defunct after adding"
    printf "\n"
    printf "${C_BOLD}Examples:${C_RESET}\n"
    printf "  nss-switch add --iface lan2 --persist --comment 'Deco off NSS'\n"
    printf "  nss-switch add --src-ip 192.168.1.50 --comment 'PC off NSS'\n"
    printf "  nss-switch add --proto tcp --dst-port 22 --temp\n"
    printf "  nss-switch watch\n"
    printf "  nss-switch pick\n"
    printf "  nss-switch debug env\n"
    printf "\n"
    cmd_debug_help
    printf "\n"
}

# ─── MAIN DISPATCHER ──────────────────────────────────────────────────────────
COMMAND="${1:-help}"
shift 2>/dev/null || true

case "$COMMAND" in
    watch)           cmd_watch "$@"   ;;
    pick)            cmd_pick  "$@"   ;;
    add)             cmd_add   "$@"   ;;
    list)            cmd_list  "$@"   ;;
    remove|rm)       cmd_remove "$@"  ;;
    flush)           cmd_flush "$@"   ;;
    apply)           cmd_apply "$@"   ;;
    status)          cmd_status "$@"  ;;
    config)          cmd_config "$@"  ;;
    debug)           cmd_debug "$@"   ;;
    help|-h|--help)  cmd_help         ;;
    *)
        ui_error "Unknown command: $COMMAND"
        cmd_help
        exit 1
        ;;
esac

EOF
ok "nss-switch.sh created"

# ──────────────────────────────────────────────────────────────────────────────
# CREATE config
# ──────────────────────────────────────────────────────────────────────────────
cat > "$INSTALL_DIR/config" << 'EOF'
# NSS-Switch global configuration
# /usr/bin/NSS-Switch/config

# Default persistence mode for new rules: yes | no
PERSIST_DEFAULT=no

# Our reserved ct mark bit (bit 16, outside QoS 0x000000ff range)
NSS_MARK=0x00010000
NSS_MARK_MASK=0x00010000

# ECM debugfs base path
ECM_DEBUGFS=/sys/kernel/debug/ecm

# Our nftables table and chain names
NFT_TABLE="inet fw4"
NFT_CHAIN_PRE="nss_bypass_pre"
NFT_CHAIN_POST="nss_bypass_post"

# State and rules file
RULES_FILE=/usr/bin/NSS-Switch/state/rules.conf
DEBUG_LOG=/usr/bin/NSS-Switch/state/debug.log

# Firewall hook script (auto-generated, loaded by fw4)
FW_SCRIPT=/usr/bin/NSS-Switch/firewall.d/nss-bypass

# Watch refresh interval in seconds
WATCH_INTERVAL=3

# Debug mode: yes | no (can also be set via DEBUG=1 env var)
DEBUG_MODE=no

EOF
ok "config created"

# ──────────────────────────────────────────────────────────────────────────────
# CREATE lib/ui.sh
# ──────────────────────────────────────────────────────────────────────────────
cat > "$INSTALL_DIR/lib/ui.sh" << 'EOF'
#!/usr/bin/env ash
# lib/ui.sh — UI helpers: colors, tables, interactive prompts
# NSS-Switch — ASH compatible, BusyBox v1.37+

# ─── Colors ───────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'
    C_CYAN='\033[0;36m'
    C_BOLD='\033[1m'
    C_DIM='\033[2m'
    C_RESET='\033[0m'
else
    C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
    C_BOLD='' C_DIM='' C_RESET=''
fi

# ─── Print helpers ────────────────────────────────────────────────────────────
ui_info()    { printf "${C_CYAN}[INFO]${C_RESET}  %s\n" "$*"; }
ui_ok()      { printf "${C_GREEN}[ OK ]${C_RESET}  %s\n" "$*"; }
ui_warn()    { printf "${C_YELLOW}[WARN]${C_RESET}  %s\n" "$*"; }
ui_error()   { printf "${C_RED}[ERR ]${C_RESET}  %s\n" "$*" >&2; }
ui_debug()   { printf "${C_DIM}[DBG ]  %s${C_RESET}\n" "$*"; }
ui_section() { printf "\n${C_BOLD}${C_BLUE}══ %s ══${C_RESET}\n" "$*"; }
ui_bold()    { printf "${C_BOLD}%s${C_RESET}\n" "$*"; }

# ─── Banner ───────────────────────────────────────────────────────────────────
ui_banner() {
    printf "${C_BOLD}${C_CYAN}"
    printf "╔═══════════════════════════════════════╗\n"
    printf "║         NSS-Switch  v1.0              ║\n"
    printf "║   Qualcomm NSS selective bypass       ║\n"
    printf "╚═══════════════════════════════════════╝\n"
    printf "${C_RESET}"
}

# ─── Separator ────────────────────────────────────────────────────────────────
ui_sep() {
    printf "${C_DIM}─────────────────────────────────────────────────────────────────────────────────────────${C_RESET}\n"
}

# ─── Table header for connection watch ───────────────────────────────────────
ui_conn_header() {
    printf "${C_BOLD}"
    printf "%-4s %-6s %-40s %-40s %-17s %-5s %-8s\n" \
        "NUM" "PROTO" "SRC" "DST" "IFACE_IN" "NSS" "BYPASS"
    printf "${C_RESET}"
    ui_sep
}

# ─── Print one connection row ─────────────────────────────────────────────────
# $1=num $2=proto $3=src $4=dst $5=iface $6=nss_status $7=bypass
ui_conn_row() {
    local num="$1" proto="$2" src="$3" dst="$4"
    local iface="$5" nss="$6" bypass="$7"
    local nss_color="$C_GREEN"
    local byp_color="$C_RESET"

    case "$nss" in
        HW)  nss_color="$C_GREEN"  ;;
        SFE) nss_color="$C_YELLOW" ;;
        CPU) nss_color="$C_RED"    ;;
    esac
    [ "$bypass" = "YES" ] && byp_color="$C_YELLOW"

    printf "%-4s %-6s %-40s %-40s %-17s ${nss_color}%-5s${C_RESET} ${byp_color}%-8s${C_RESET}\n" \
        "$num" "$proto" "$src" "$dst" "$iface" "$nss" "$bypass"
}

# ─── Ask yes/no ───────────────────────────────────────────────────────────────
# Returns 0 for yes, 1 for no
ui_ask_yn() {
    local question="$1" default="${2:-n}"
    local hint ans
    case "$default" in
        y|Y) hint="[Y/n]" ;;
        *)   hint="[y/N]" ;;
    esac
    printf "${C_BOLD}%s %s: ${C_RESET}" "$question" "$hint"
    read -r ans
    [ -z "$ans" ] && ans="$default"
    case "$ans" in
        y|Y|yes|YES) return 0 ;;
        *)           return 1 ;;
    esac
}

# ─── Ask with options list ────────────────────────────────────────────────────
# Usage: ui_ask_choice "Question" opt1 opt2 opt3 ...
# Returns chosen value in UI_CHOICE
ui_ask_choice() {
    local question="$1"; shift
    local opts="$*"
    local i=1 opt ans
    printf "${C_BOLD}%s${C_RESET}\n" "$question"
    for opt in $opts; do
        printf "  ${C_CYAN}%d)${C_RESET} %s\n" "$i" "$opt"
        i=$((i+1))
    done
    printf "${C_BOLD}Choice [1-%d]: ${C_RESET}" "$((i-1))"
    read -r ans
    if ! echo "$ans" | grep -qE '^[0-9]+$'; then
        ui_error "Invalid choice"
        UI_CHOICE=""
        return 1
    fi
    i=1
    for opt in $opts; do
        if [ "$i" = "$ans" ]; then
            UI_CHOICE="$opt"
            return 0
        fi
        i=$((i+1))
    done
    ui_error "Choice out of range"
    UI_CHOICE=""
    return 1
}

# ─── Ask free text ────────────────────────────────────────────────────────────
# Returns value in UI_INPUT
ui_ask_input() {
    local question="$1" default="$2"
    if [ -n "$default" ]; then
        printf "${C_BOLD}%s [%s]: ${C_RESET}" "$question" "$default"
    else
        printf "${C_BOLD}%s: ${C_RESET}" "$question"
    fi
    read -r UI_INPUT
    [ -z "$UI_INPUT" ] && UI_INPUT="$default"
}

# ─── Ask numeric from a range ─────────────────────────────────────────────────
# Returns 0 and sets UI_NUM, or 1 on invalid
ui_ask_num() {
    local question="$1" min="$2" max="$3"
    printf "${C_BOLD}%s [%d-%d]: ${C_RESET}" "$question" "$min" "$max"
    read -r UI_NUM
    if ! echo "$UI_NUM" | grep -qE '^[0-9]+$'; then
        ui_error "Not a number"
        return 1
    fi
    if [ "$UI_NUM" -lt "$min" ] || [ "$UI_NUM" -gt "$max" ]; then
        ui_error "Out of range [$min-$max]"
        return 1
    fi
    return 0
}

# ─── Confirm action ───────────────────────────────────────────────────────────
ui_confirm() {
    ui_ask_yn "$1" "n"
}

# ─── Spinner for long ops ─────────────────────────────────────────────────────
ui_spinner_start() {
    export _SPINNER_MSG="$1"
    export _SPINNER_PID=""
    (
        i=0
        chars='|/-\'
        while true; do
            c=$(echo "$chars" | cut -c$((i%4+1)))
            printf "\r${C_CYAN}[%s]${C_RESET} %s   " "$c" "$_SPINNER_MSG"
            i=$((i+1))
            sleep 0.1
        done
    ) &
    _SPINNER_PID=$!
}

ui_spinner_stop() {
    if [ -n "$_SPINNER_PID" ]; then
        kill "$_SPINNER_PID" 2>/dev/null
        wait "$_SPINNER_PID" 2>/dev/null
        printf "\r                                        \r"
        _SPINNER_PID=""
    fi
}

# ─── Print a key=value pair ───────────────────────────────────────────────────
ui_kv() {
    printf "  ${C_DIM}%-22s${C_RESET} %s\n" "$1:" "$2"
}

# ─── Print rule row for list command ─────────────────────────────────────────
# $1=id $2=proto $3=src_ip $4=dst_ip $5=src_port $6=dst_port $7=iface $8=persist $9=comment
ui_rule_row() {
    local persist_col="$C_DIM"
    [ "$8" = "yes" ] && persist_col="$C_GREEN"
    printf "${C_BOLD}%-4s${C_RESET} %-5s %-18s %-18s %-6s %-6s %-10s ${persist_col}%-8s${C_RESET} %s\n" \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
}

ui_rule_header() {
    printf "${C_BOLD}"
    printf "%-4s %-5s %-18s %-18s %-6s %-6s %-10s %-8s %s\n" \
        "ID" "PROTO" "SRC_IP" "DST_IP" "SPORT" "DPORT" "IFACE" "PERSIST" "COMMENT"
    printf "${C_RESET}"
    ui_sep
}


EOF
ok "lib/ui.sh created"

# ──────────────────────────────────────────────────────────────────────────────
# CREATE lib/ecm.sh
# ──────────────────────────────────────────────────────────────────────────────
cat > "$INSTALL_DIR/lib/ecm.sh" << 'EOF'
#!/usr/bin/env ash
# lib/ecm.sh — ECM / NSS interaction via debugfs
# NSS-Switch — ASH compatible, BusyBox v1.37+

# ─── Check ECM is loaded and debugfs available ────────────────────────────────
ecm_check() {
    if [ ! -d "$ECM_DEBUGFS" ]; then
        ui_error "ECM debugfs not found at $ECM_DEBUGFS"
        ui_error "Is kmod-qca-nss-ecm loaded?"
        return 1
    fi
    # Ensure debugfs is mounted
    if ! mount | grep -q debugfs; then
        dbg "debugfs not mounted, attempting mount"
        mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
    fi
    return 0
}

# ─── Check Mark Classifier is available ───────────────────────────────────────
ecm_mark_classifier_available() {
    [ -d "$ECM_DEBUGFS/ecm_classifier_mark" ]
}

# ─── Get current frontend mode ────────────────────────────────────────────────
ecm_frontend() {
    local fe_file="$ECM_DEBUGFS/ecm_nss_ipv4"
    if [ -d "$fe_file" ]; then
        echo "NSS"
    elif [ -d "$ECM_DEBUGFS/ecm_sfe_ipv4" ]; then
        echo "SFE"
    else
        echo "UNKNOWN"
    fi
}

# ─── Get acceleration engine from UCI ─────────────────────────────────────────
ecm_engine() {
    local engine
    engine=$(grep -A2 "config ecm 'global'" /etc/config/ecm 2>/dev/null | \
             grep "acceleration_engine" | \
             awk '{print $3}' | tr -d "'")
    echo "${engine:-auto}"
}

# ─── Stop IPv4 frontend ───────────────────────────────────────────────────────
ecm_stop_ipv4() {
    local f="$ECM_DEBUGFS/front_end_ipv4_stop"
    if [ ! -f "$f" ]; then
        ui_error "front_end_ipv4_stop not found"
        return 1
    fi
    dbg "Writing 1 to $f"
    echo 1 > "$f"
    ui_ok "NSS IPv4 frontend stopped"
}

# ─── Stop IPv6 frontend ───────────────────────────────────────────────────────
ecm_stop_ipv6() {
    local f="$ECM_DEBUGFS/front_end_ipv6_stop"
    if [ ! -f "$f" ]; then
        ui_error "front_end_ipv6_stop not found"
        return 1
    fi
    dbg "Writing 1 to $f"
    echo 1 > "$f"
    ui_ok "NSS IPv6 frontend stopped"
}

# ─── Restart ECM service to restore frontends ─────────────────────────────────
ecm_restart() {
    dbg "Restarting qca-nss-ecm service"
    /etc/init.d/qca-nss-ecm restart 2>/dev/null
}

# ─── Defunct ALL connections in ECM DB ───────────────────────────────────────
ecm_defunct_all() {
    local f="$ECM_DEBUGFS/ecm_db/defunct_all"
    if [ ! -f "$f" ]; then
        ui_error "defunct_all not found at $f"
        return 1
    fi
    dbg "Writing 1 to defunct_all"
    echo 1 > "$f"
    ui_ok "All ECM connections defuncted (will be re-evaluated)"
}

# ─── Defunct connections by port ──────────────────────────────────────────────
ecm_defunct_by_port() {
    local port="$1"
    local f="$ECM_DEBUGFS/ecm_db/defunct_by_port"
    if [ ! -f "$f" ]; then
        dbg "defunct_by_port not available, falling back to defunct_all"
        ecm_defunct_all
        return
    fi
    dbg "defunct_by_port: $port"
    echo "$port" > "$f"
    ui_ok "ECM connections on port $port defuncted"
}

# ─── Get ECM connection list from ecm_dump.sh ─────────────────────────────────
# Outputs: proto|src_ip|src_port|dst_ip|dst_port|accel_state
ecm_connections() {
    local dump_bin
    dump_bin=$(command -v ecm_dump.sh 2>/dev/null)
    if [ -z "$dump_bin" ]; then
        dbg "ecm_dump.sh not found"
        return 1
    fi
    # ecm_dump.sh outputs XML — parse key fields
    ecm_dump.sh 2>/dev/null | awk '
        /<connection>/ { in_conn=1; proto="?"; src="?"; sport="?"; dst="?"; dport="?"; accel="CPU" }
        /<\/connection>/ {
            if (in_conn) print proto"|"src"|"sport"|"dst"|"dport"|"accel
            in_conn=0
        }
        in_conn && /<protocol>/ { match($0,/<protocol>([^<]+)/,a); proto=a[1] }
        in_conn && /<src_address>/ { match($0,/<src_address>([^<]+)/,a); src=a[1] }
        in_conn && /<src_port>/ { match($0,/<src_port>([^<]+)/,a); sport=a[1] }
        in_conn && /<dest_address>/ { match($0,/<dest_address>([^<]+)/,a); dst=a[1] }
        in_conn && /<dest_port>/ { match($0,/<dest_port>([^<]+)/,a); dport=a[1] }
        in_conn && /<accel>/ { match($0,/<accel>([^<]+)/,a); accel=a[1] }
    '
}

# ─── Get NSS stats summary ────────────────────────────────────────────────────
ecm_stats() {
    local stats_file="$ECM_DEBUGFS/stats"
    if [ -f "$stats_file" ]; then
        cat "$stats_file"
    else
        ui_warn "No stats file found in ECM debugfs"
    fi
}

# ─── Check if a connection (by mark) is being bypassed ────────────────────────
ecm_is_bypassed_by_mark() {
    local src_ip="$1"
    # Check conntrack for this IP having our mark
    cat /proc/net/nf_conntrack 2>/dev/null | \
        grep "src=$src_ip " | \
        grep -c "mark=$NSS_MARK" 2>/dev/null; true
}

# ─── Get accel_delay_pkts ─────────────────────────────────────────────────────
ecm_accel_delay_pkts() {
    local f="$ECM_DEBUGFS/ecm_classifier_default/accel_delay_pkts"
    [ -f "$f" ] && cat "$f" || echo "N/A"
}

# ─── Full ECM environment dump for debug ──────────────────────────────────────
ecm_debug_dump() {
    ui_section "ECM Environment"
    ui_kv "ECM debugfs" "$ECM_DEBUGFS"
    ui_kv "ECM loaded" "$([ -d "$ECM_DEBUGFS" ] && echo YES || echo NO)"
    ui_kv "Frontend dirs" "$(ls "$ECM_DEBUGFS" 2>/dev/null | tr '\n' ' ')"
    ui_kv "Active frontend" "$(ecm_frontend)"
    ui_kv "Engine (UCI)" "$(ecm_engine)"
    ui_kv "Mark classifier" "$(ecm_mark_classifier_available && echo AVAILABLE || echo MISSING)"
    ui_kv "accel_delay_pkts" "$(ecm_accel_delay_pkts)"

    ui_section "ECM DebugFS Files"
    if [ -d "$ECM_DEBUGFS/ecm_db" ]; then
        ls -la "$ECM_DEBUGFS/ecm_db/" 2>/dev/null
    fi

    ui_section "NSS Stats (summary)"
    ecm_stats 2>/dev/null | head -40

    ui_section "Mark Classifier State"
    if ecm_mark_classifier_available; then
        ls -la "$ECM_DEBUGFS/ecm_classifier_mark/" 2>/dev/null
        for f in "$ECM_DEBUGFS/ecm_classifier_mark/"*; do
            [ -f "$f" ] && printf "  %s = %s\n" "$(basename "$f")" "$(cat "$f" 2>/dev/null)"
        done
    else
        ui_warn "ecm_classifier_mark not present in debugfs"
    fi
}

EOF
ok "lib/ecm.sh created"

# ──────────────────────────────────────────────────────────────────────────────
# CREATE lib/conntrack.sh
# ──────────────────────────────────────────────────────────────────────────────
cat > "$INSTALL_DIR/lib/conntrack.sh" << 'EOF'
#!/usr/bin/env ash
# lib/conntrack.sh — Parse /proc/net/nf_conntrack, correlate with NSS state
# NSS-Switch — ASH compatible, BusyBox v1.37+

CONNTRACK_FILE=/proc/net/nf_conntrack

# ─── Check conntrack available ────────────────────────────────────────────────
ct_check() {
    [ -f "$CONNTRACK_FILE" ] || { ui_error "conntrack not available"; return 1; }
}

# ─── IP to decimal ────────────────────────────────────────────────────────────
_ip_to_dec() {
    local ip="$1"
    local a b c d
    a=$(echo "$ip" | cut -d'.' -f1)
    b=$(echo "$ip" | cut -d'.' -f2)
    c=$(echo "$ip" | cut -d'.' -f3)
    d=$(echo "$ip" | cut -d'.' -f4)
    echo $(( (a<<24) + (b<<16) + (c<<8) + d ))
}

# ─── Check if IP is in CIDR ───────────────────────────────────────────────────
_ct_ip_in_cidr() {
    local ip="$1" cidr="$2"
    local net prefix
    net=$(echo "$cidr" | cut -d'/' -f1)
    prefix=$(echo "$cidr" | cut -d'/' -f2)
    local ip_dec net_dec mask_dec
    ip_dec=$(_ip_to_dec "$ip")
    net_dec=$(_ip_to_dec "$net")
    if [ "$prefix" -eq 0 ]; then
        mask_dec=0
    else
        mask_dec=$(( ( (1<<31) | ( (1<<31)-1 ) ) ^ ( (1<<(32-prefix))-1 ) ))
    fi
    [ $(( ip_dec & mask_dec )) -eq $(( net_dec & mask_dec )) ]
}

# ─── Build interface map from ip addr show ────────────────────────────────────
# Writes to a tmpfile: "ip cidr iface" per line
_ct_build_iface_map() {
    local tmpfile="$1"
    ip addr show 2>/dev/null | awk '
        /^[0-9]+: / { iface=$2; gsub(/:$/,"",iface) }
        /inet / {
            if ($0 ~ /peer/) {
                print $2, $2"/32", iface
            } else {
                split($2, a, "/")
                print a[1], $2, iface
            }
        }
    ' > "$tmpfile"
}

# ─── Compress IPv6 address RFC 5952 ──────────────────────────────────────────
_ipv6_compress() {
    echo "$1" | awk '{
        split($0, a, ":")
        for(i=1;i<=8;i++) {
            gsub(/^0+/,"",a[i])
            if(a[i]=="") a[i]="0"
        }
        max_len=0; max_start=0; cur_len=0; cur_start=0
        for(i=1;i<=8;i++) {
            if(a[i]=="0") {
                if(cur_len==0) cur_start=i
                cur_len++
                if(cur_len>max_len) { max_len=cur_len; max_start=cur_start }
            } else { cur_len=0 }
        }
        result=""
        i=1
        while(i<=8) {
            if(max_len>1 && i==max_start) {
                if(i==1) result="::"
                else result=result"::"
                i+=max_len
            } else {
                if(result!="" && substr(result,length(result),1)!=":") result=result":"
                result=result a[i]
                i++
            }
        }
        print result
    }'
}

# ─── Get interface for a src IP ───────────────────────────────────────────────
# Returns: iface name, "local:iface" for router-own IPs, or "?"
ct_iface_for_src() {
    local src="$1"
    local found=""

    # Detect IPv6
    if echo "$src" | grep -q ":"; then
        # IPv6 path — use ip -6 route get
        local dev
        dev=$(ip -6 route get "$src" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
        if [ -z "$dev" ] || [ "$dev" = "lo" ]; then
            # Local router IP or loopback — find which iface owns it
            local own_iface
            own_iface=$(ip -6 addr show 2>/dev/null | awk -v src="$src" '
                /^[0-9]+: / { iface=$2; gsub(/:$/,"",iface) }
                /inet6 / {
                    split($2, a, "/")
                    if(a[1]==src) print iface
                }
            ')
            [ -n "$own_iface" ] && echo "local:$own_iface" || echo "local:pppoe-wan"
        else
            echo "$dev"
        fi
        return
    fi

    # IPv4 path — existing logic
    local tmp
    tmp=$(mktemp /tmp/nss-iface.XXXXXX)
    _ct_build_iface_map "$tmp"
    while IFS=' ' read -r ip cidr iface; do
        if [ "$src" = "$ip" ]; then
            rm -f "$tmp"
            echo "local:$iface"
            return
        fi
        if _ct_ip_in_cidr "$src" "$cidr" 2>/dev/null; then
            found="$iface"
        fi
    done < "$tmp"
    rm -f "$tmp"
    [ -n "$found" ] && echo "$found" && return
    echo "?"
}

# ─── Parse one conntrack line into variables ──────────────────────────────────
# Sets: CT_PROTO CT_SRC CT_SPORT CT_DST CT_DPORT CT_MARK CT_STATE CT_STATUS
ct_parse_line() {
    local line="$1"
    CT_PROTO=""
    CT_SRC="" CT_SPORT="" CT_DST="" CT_DPORT=""
    CT_MARK=0 CT_STATE="" CT_STATUS=""

    CT_PROTO=$(echo "$line" | awk '{print $3}')

    case "$CT_PROTO" in
        tcp|6)   CT_STATE=$(echo "$line" | awk '{print $4}') ;;
        udp|17)  CT_STATE="stateless" ;;
        *)       CT_STATE="?" ;;
    esac

    CT_SRC=$(echo "$line"   | grep -oE 'src=[^ ]+' | head -1 | cut -d= -f2)
    CT_DST=$(echo "$line"   | grep -oE 'dst=[^ ]+' | head -1 | cut -d= -f2)
    CT_SPORT=$(echo "$line" | grep -oE 'sport=[^ ]+' | head -1 | cut -d= -f2)
    CT_DPORT=$(echo "$line" | grep -oE 'dport=[^ ]+' | head -1 | cut -d= -f2)
    CT_MARK=$(echo "$line"  | grep -oE 'mark=[^ ]+' | head -1 | cut -d= -f2)
    CT_STATUS=$(echo "$line"| grep -oE 'status=[^ ]+' | head -1 | cut -d= -f2)

    CT_SPORT="${CT_SPORT:-?}"
    CT_DPORT="${CT_DPORT:-?}"
    CT_MARK="${CT_MARK:-0}"
}

# ─── Check if mark has our NSS bypass bit set ─────────────────────────────────
ct_is_bypassed() {
    local mark="$1"
    local mark_dec nss_dec
    mark_dec=$(printf '%d' "$mark" 2>/dev/null) || mark_dec=0
    nss_dec=$(printf '%d' "$NSS_MARK" 2>/dev/null) || nss_dec=65536
    [ $(( mark_dec & nss_dec )) -ne 0 ]
}

# ─── Determine NSS status for a connection ────────────────────────────────────
ct_nss_status() {
    local mark="$1"
    if ct_is_bypassed "$mark"; then
        echo "CPU"
        return
    fi
    if [ -d "$ECM_DEBUGFS/ecm_nss_ipv4" ]; then
        echo "HW"
    elif [ -d "$ECM_DEBUGFS/ecm_sfe_ipv4" ]; then
        echo "SFE"
    else
        echo "CPU"
    fi
}

# ─── Dump all connections as structured records ───────────────────────────────
# Output format: NUM|PROTO|SRC:SPORT|DST:DPORT|IFACE|NSS|BYPASS|MARK|STATE
# Filters out router-local connections (local:*) — use ct_dump_all_full for those
# DEBUG Deprecated, replaced by ct_dump_all_full
# ct_dump_all() {
#     ct_check || return 1
#     local ifmap
#     ifmap=$(mktemp /tmp/nss-ifmap.XXXXXX)
#     _ct_build_iface_map "$ifmap"
#     local num=0
#     while IFS= read -r line; do
#         ct_parse_line "$line"
#         [ -z "$CT_SRC" ] && continue
#         local iface found=""
#         while IFS=' ' read -r ip cidr if2; do
#             if [ "$CT_SRC" = "$ip" ]; then
#                 found="local:$if2"
#                 break
#             fi
#             if _ct_ip_in_cidr "$CT_SRC" "$cidr" 2>/dev/null; then
#                 found="$if2"
#             fi
#         done < "$ifmap"
#         [ -z "$found" ] && found="?"
#         iface="$found"
#         case "$iface" in local:*) continue ;; esac
#         [ "$iface" = "?" ] && continue
#         num=$((num+1))
#         local nss_status bypassed
#         nss_status=$(ct_nss_status "$CT_MARK")
#         bypassed="NO"
#         ct_is_bypassed "$CT_MARK" && bypassed="YES"
#         # Comprimir IPv6 si aplica
#         local display_src display_dst
#         if echo "$CT_SRC" | grep -q ":"; then
#             display_src=$(_ipv6_compress "$CT_SRC")
#         else
#             display_src="$CT_SRC"
#         fi
#         if echo "$CT_DST" | grep -q ":"; then
#             display_dst=$(_ipv6_compress "$CT_DST")
#         else
#             display_dst="$CT_DST"
#         fi
#         printf "%d|%s|%s#%s|%s#%s|%s|%s|%s|%s|%s\n" \
#             "$num" "$CT_PROTO" \
#             "$display_src" "$CT_SPORT" \
#             "$display_dst" "$CT_DPORT" \
#             "$iface" "$nss_status" "$bypassed" \
#             "$CT_MARK" "$CT_STATE"
#     done < "$CONNTRACK_FILE"
#     rm -f "$ifmap"
# }

# ─── Dump ALL connections including router-local ──────────────────────────────
# Output format: NUM|PROTO|SRC:SPORT|DST:DPORT|IFACE|NSS|BYPASS|MARK|STATE
# IFACE will show "local:pppoe-wan", "local:br-lan" etc for router traffic
ct_dump_all_full() {
    ct_check || return 1
# DEBUG Cambio para extraer la iface, nada de iterar y crear mapa, directamente de ip route y a correr
#     local ifmap
#     ifmap=$(mktemp /tmp/nss-ifmap.XXXXXX)

    # DEBUG trap particular, pasado a trap global en 3 condiciones, este block NO interfiere con cambio iface map
    # trap "rm -f '$ifmap'; trap - INT TERM EXIT; exit" INT TERM EXIT


#     _ct_build_iface_map "$ifmap"
    local num=0
    while IFS= read -r line; do
        ct_parse_line "$line"
        [ -z "$CT_SRC" ] && continue
# DEBUG Cambio para extraer la iface, nada de iterar y crear mapa, directamente de ip route y a correr
        local iface
        iface=$(ct_iface_for_src "$CT_SRC")
        [ -z "$iface" ] && iface="?"
#         local iface found=""
#         while IFS=' ' read -r ip cidr if2; do
#             if [ "$CT_SRC" = "$ip" ]; then
#                 found="local:$if2"
#                 break
#             fi
#             if _ct_ip_in_cidr "$CT_SRC" "$cidr" 2>/dev/null; then
#                 found="$if2"
#             fi
#         done < "$ifmap"
#         [ -z "$found" ] && found="?"
#         iface="$found"
        num=$((num+1))
        local nss_status bypassed
        nss_status=$(ct_nss_status "$CT_MARK")
        bypassed="NO"
        ct_is_bypassed "$CT_MARK" && bypassed="YES"

        # Comprimir IPv6 si aplica
        local display_src display_dst
        if echo "$CT_SRC" | grep -q ":"; then
            display_src=$(_ipv6_compress "$CT_SRC")
        else
            display_src="$CT_SRC"
        fi
        if echo "$CT_DST" | grep -q ":"; then
            display_dst=$(_ipv6_compress "$CT_DST")
        else
            display_dst="$CT_DST"
        fi
        printf "%d|%s|%s#%s|%s#%s|%s|%s|%s|%s|%s\n" \
            "$num" "$CT_PROTO" \
            "$display_src" "$CT_SPORT" \
            "$display_dst" "$CT_DPORT" \
            "$iface" "$nss_status" "$bypassed" \
            "$CT_MARK" "$CT_STATE"
    done < "$CONNTRACK_FILE"

# DEBUG Cambio para extraer la iface, nada de iterar y crear mapa, directamente de ip route y a correr
#     rm -f "$ifmap"


    # DEBUG trap particular
    # trap - INT TERM EXIT
}

# ─── Get single connection by NUM ─────────────────────────────────────────────
ct_get_by_num() {
    local target="$1"
    ct_dump_all_full | awk -F'|' -v n="$target" '$1==n {print; exit}'
}

# ─── Count total connections ──────────────────────────────────────────────────
ct_count() {
    wc -l < "$CONNTRACK_FILE" 2>/dev/null || echo 0
}

# ─── Count bypassed connections ───────────────────────────────────────────────
ct_count_bypassed() {
    local nss_dec
    nss_dec=$(printf '%d' "$NSS_MARK" 2>/dev/null) || nss_dec=65536
    local count=0
    while IFS= read -r line; do
        local mark mark_dec
        mark=$(echo "$line" | grep -oE 'mark=[^ ]+' | head -1 | cut -d= -f2)
        mark_dec=$(printf '%d' "${mark:-0}" 2>/dev/null) || mark_dec=0
        [ $(( mark_dec & nss_dec )) -ne 0 ] && count=$((count+1))
    done < "$CONNTRACK_FILE"
    echo "$count"
}

# ─── Clear conntrack entries matching rule criteria ───────────────────────────
ct_clear_rule_marks() {
    local proto="$1" src_ip="$2" dst_ip="$3"
    local sport="$4" dport="$5" iface="$6"

    dbg "Flushing connections for rule: proto=$proto src=$src_ip dst=$dst_ip sport=$sport dport=$dport iface=$iface"

    # Construir filtro de conntrack
    local filter=""
    [ "$proto"  != "any" ] && filter="$filter -p $proto"

    # IPs
    if [ "$src_ip" != "any" ] && [ "$dst_ip" != "any" ]; then
        filter="$filter -s $src_ip -d $dst_ip"
    elif [ "$src_ip" != "any" ]; then
        filter="$filter -s $src_ip"
    elif [ "$dst_ip" != "any" ]; then
        filter="$filter -d $dst_ip"
    fi

    # Puertos
    if [ "$sport" != "any" ] && [ "$dport" != "any" ]; then
        filter="$filter --sport $sport --dport $dport"
    elif [ "$sport" != "any" ]; then
        filter="$filter --sport $sport"
    elif [ "$dport" != "any" ]; then
        filter="$filter --dport $dport"
    fi

    # Interfaz - resolver a IP/subred
    local src_net=""
    if [ "$iface" != "any" ]; then
        case "$iface" in
            out:*)
                local out_iface="${iface#out:}"
                src_net=$(ip addr show "$out_iface" 2>/dev/null | \
                         grep -E 'inet |inet6 ' | head -1 | awk '{print $2}')
                ;;
            *)
                src_net=$(ip route show dev "$iface" 2>/dev/null | \
                         grep -v default | head -1 | awk '{print $1}')
                ;;
        esac
        [ -n "$src_net" ] && filter="$filter -s $src_net"
    fi

    # Ejecutar borrado en caliente
    if [ -n "$filter" ]; then
        dbg "conntrack -D $filter"
        conntrack -D $filter 2>/dev/null
        ui_ok "Matching conntrack entries flushed"
    else
        # Regla any - flushear todo conntrack
        ui_warn "Rule matches ALL connections - flushing entire conntrack"
        conntrack -F 2>/dev/null
        ui_ok "All conntrack entries flushed"
    fi

    # Forzar re-evaluación en ECM
    ecm_defunct_all
}

# ─── Debug: show conntrack entries with our mark ─────────────────────────────
ct_debug_mark() {
    ui_section "Conntrack entries with NSS-Switch mark ($NSS_MARK)"
    local found=0
    while IFS= read -r line; do
        local mark mark_dec nss_dec
        mark=$(echo "$line" | grep -oE 'mark=[^ ]+' | head -1 | cut -d= -f2)
        mark_dec=$(printf '%d' "${mark:-0}" 2>/dev/null) || mark_dec=0
        nss_dec=$(printf '%d' "$NSS_MARK" 2>/dev/null) || nss_dec=65536
        if [ $(( mark_dec & nss_dec )) -ne 0 ]; then
            echo "  $line"
            found=$((found+1))
        fi
    done < "$CONNTRACK_FILE"
    [ "$found" -eq 0 ] && ui_warn "No entries with our mark found"
    ui_kv "Total bypassed" "$found"
}

# ─── Debug: dump raw conntrack ────────────────────────────────────────────────
ct_debug_raw() {
    ui_section "Raw /proc/net/nf_conntrack"
    cat "$CONNTRACK_FILE" 2>/dev/null || ui_error "Cannot read conntrack"
}


EOF
ok "lib/conntrack.sh created"

# ──────────────────────────────────────────────────────────────────────────────
# CREATE lib/nft.sh
# ──────────────────────────────────────────────────────────────────────────────
cat > "$INSTALL_DIR/lib/nft.sh" << 'EOF'
#!/usr/bin/env ash
# lib/nft.sh — nftables chain/rule management for NSS-Switch
# Works by editing /usr/bin/NSS-Switch/firewall.d/nss-bypass (nft file)
# and reloading via /etc/init.d/firewall restart
# ASH compatible, BusyBox v1.37+

# ─── Paths ────────────────────────────────────────────────────────────────────
NFT_INCLUDE_LINK=/etc/firewall.d/nss-bypass
NFT_RULES_HEADER="# NSS-Switch managed rules — do not edit manually"

# ─── Check nft binary ─────────────────────────────────────────────────────────
nft_check() {
    command -v nft >/dev/null 2>&1 || { ui_error "nft not found"; return 1; }
}

# ─── Check our chains exist in live ruleset ───────────────────────────────────
nft_chains_exist() {
    nft list chain inet fw4 "$NFT_CHAIN_PRE"  >/dev/null 2>&1 && \
    nft list chain inet fw4 "$NFT_CHAIN_POST" >/dev/null 2>&1
}

# ─── Generate the full nss-bypass nft script from rules.conf ──────────────────
nft_generate_script() {
    dbg "Generating $FW_SCRIPT from $RULES_FILE"

    local c1 c2
    c1='"NSS-Switch: save bypass mark to conntrack"'
    c2='"NSS-Switch: restore bypass mark from conntrack"'

    echo '#!/bin/sh'                                                                   > "$FW_SCRIPT"
    echo '# NSS-Switch firewall.d hook — auto-generated, do not edit manually'       >> "$FW_SCRIPT"
    echo "# Generated: $(date)"                                                       >> "$FW_SCRIPT"
    echo ''                                                                            >> "$FW_SCRIPT"
    echo "NSS_MARK=${NSS_MARK}"                                                       >> "$FW_SCRIPT"
    echo "NFT_CHAIN_PRE=${NFT_CHAIN_PRE}"                                             >> "$FW_SCRIPT"
    echo "NFT_CHAIN_POST=${NFT_CHAIN_POST}"                                           >> "$FW_SCRIPT"
    echo ''                                                                            >> "$FW_SCRIPT"
    echo 'nft_add_chains() {'                                                         >> "$FW_SCRIPT"
    echo '    nft add chain inet fw4 ${NFT_CHAIN_PRE}  2>/dev/null || true'          >> "$FW_SCRIPT"
    echo '    nft flush chain inet fw4 ${NFT_CHAIN_PRE} 2>/dev/null || true'         >> "$FW_SCRIPT"
    echo '    nft add chain inet fw4 ${NFT_CHAIN_POST} 2>/dev/null || true'          >> "$FW_SCRIPT"
    echo '    nft flush chain inet fw4 ${NFT_CHAIN_POST} 2>/dev/null || true'        >> "$FW_SCRIPT"
    echo ''                                                                            >> "$FW_SCRIPT"
    echo '    handles=$(nft -a list chain inet fw4 mangle_prerouting 2>/dev/null | grep "jump ${NFT_CHAIN_PRE}" | grep -oE '"'"'handle [0-9]+'"'"' | awk '"'"'{print $2}'"'"')' >> "$FW_SCRIPT"
    echo '    for h in $handles; do nft delete rule inet fw4 mangle_prerouting handle "$h" 2>/dev/null; done' >> "$FW_SCRIPT"
    echo ''                                                                            >> "$FW_SCRIPT"
    echo '    handles=$(nft -a list chain inet fw4 mangle_postrouting 2>/dev/null | grep "jump ${NFT_CHAIN_POST}" | grep -oE '"'"'handle [0-9]+'"'"' | awk '"'"'{print $2}'"'"')' >> "$FW_SCRIPT"
    echo '    for h in $handles; do nft delete rule inet fw4 mangle_postrouting handle "$h" 2>/dev/null; done' >> "$FW_SCRIPT"
    echo ''                                                                            >> "$FW_SCRIPT"
    echo '    nft add rule inet fw4 mangle_prerouting  jump ${NFT_CHAIN_PRE}  comment "\"NSS-Switch prerouting\""'  >> "$FW_SCRIPT"
    echo '    nft add rule inet fw4 mangle_postrouting jump ${NFT_CHAIN_POST} comment "\"NSS-Switch postrouting\""' >> "$FW_SCRIPT"
    echo ''                                                                            >> "$FW_SCRIPT"
    echo '    nft add rule inet fw4 ${NFT_CHAIN_POST} meta mark and ${NSS_MARK} != 0 ct mark set meta mark and ${NSS_MARK} comment \"NSS-Switch: save bypass mark to conntrack\"' >> "$FW_SCRIPT"
    echo '    nft add rule inet fw4 ${NFT_CHAIN_PRE}  ct mark and ${NSS_MARK} != 0 meta mark set ct mark comment \"NSS-Switch: restore bypass mark from conntrack\"' >> "$FW_SCRIPT"
    echo '}'                                                                           >> "$FW_SCRIPT"
    echo ''                                                                            >> "$FW_SCRIPT"
    echo 'nft_add_rules() {'                                                          >> "$FW_SCRIPT"

    if [ -f "$RULES_FILE" ]; then
        while IFS='|' read -r id proto src_ip dst_ip src_port dst_port iface persist comment; do
            case "$id" in '#'*|'') continue ;; esac
            dbg "Generating nft rule for id=$id"
            _nft_emit_rule "$id" "$proto" "$src_ip" "$dst_ip" \
                "$src_port" "$dst_port" "$iface" "$comment"
        done < "$RULES_FILE"
    fi

    echo '    true'                                                                    >> "$FW_SCRIPT"
    echo '}'                                                                           >> "$FW_SCRIPT"
    echo ''                                                                            >> "$FW_SCRIPT"
    echo 'nft_add_chains'                                                             >> "$FW_SCRIPT"
    echo 'nft_add_rules'                                                              >> "$FW_SCRIPT"

    chmod +x "$FW_SCRIPT"
    dbg "Script generated at $FW_SCRIPT"
}

# ─── Emit a single nft rule (used by nft_generate_script) ────────────────────
_nft_emit_rule() {
    local id="$1" proto="$2" src_ip="$3" dst_ip="$4"
    local src_port="$5" dst_port="$6" iface="$7" comment="$8"
    local match=""


    if [ "$iface" != "any" ]; then
        case "$iface" in
            out:*)
                local out_iface="${iface#out:}"
                match="${match} oifname \"${out_iface}\""
                ;;
            *)
                match="${match} iifname \"${iface}\""
                ;;
        esac
    fi
    [ "$proto"    != "any" ] && match="${match} meta l4proto ${proto}"
    [ "$src_ip"   != "any" ] && match="${match} ip saddr ${src_ip}"
    [ "$dst_ip"   != "any" ] && match="${match} ip daddr ${dst_ip}"
    [ "$src_port" != "any" ] && match="${match} ${proto} sport ${src_port}"
    [ "$dst_port" != "any" ] && match="${match} ${proto} dport ${dst_port}"

    if [ -z "$(echo "$match" | tr -d ' ')" ]; then
        printf "    # SKIPPED rule id=%s — no match criteria\n" "$id" >> "$FW_SCRIPT"
        return
    fi

    printf "    # Rule id=%s: %s\n" "$id" "$comment"                                 >> "$FW_SCRIPT"
    printf "    nft add rule inet fw4 %s %s ct mark set ct mark or %s comment '\"NSS-Switch id=%s: %s\"'\n" \
        "$NFT_CHAIN_PRE" "$match" "$NSS_MARK" "$id" "$comment"                       >> "$FW_SCRIPT"
}

# ─── Apply: generate script and reload firewall ───────────────────────────────
nft_apply() {
    nft_generate_script || return 1
    _nft_ensure_fw4_include
    dbg "Reloading firewall"
    /etc/init.d/firewall restart >> "$DEBUG_LOG" 2>&1
    ui_ok "Firewall reloaded, NSS-Switch rules applied"
}

# ─── Ensure /etc/firewall.d/nss-bypass exists and points to our script ────────
_nft_ensure_fw4_include() {
    local target="/etc/firewall.d/nss-bypass"
    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
        dbg "Creating symlink $target -> $FW_SCRIPT"
        ln -s "$FW_SCRIPT" "$target"
    elif [ -L "$target" ]; then
        local current
        current=$(readlink -f "$target" 2>/dev/null)
        if [ "$current" != "$FW_SCRIPT" ]; then
            dbg "Updating symlink $target -> $FW_SCRIPT"
            ln -sf "$FW_SCRIPT" "$target"
        fi
    fi
    _nft_ensure_uci_include
}

# ─── Ensure UCI include block exists in /etc/config/firewall ──────────────────
_nft_ensure_uci_include() {
    local fw_conf=/etc/config/firewall
    if ! grep -q "nss_bypass_include" "$fw_conf" 2>/dev/null; then
        dbg "Adding UCI include to $fw_conf"
        printf "\nconfig include 'nss_bypass_include'\n\toption type 'script'\n\toption path '/etc/firewall.d/nss-bypass'\n" \
            >> "$fw_conf"
        ui_ok "UCI include added to /etc/config/firewall"
    fi
}

# ─── Remove UCI include from /etc/config/firewall ────────────────────────────
_nft_remove_uci_include() {
    local fw_conf=/etc/config/firewall
    if grep -q "nss_bypass_include" "$fw_conf" 2>/dev/null; then
        sed -i "/config include 'nss_bypass_include'/,+2d" "$fw_conf"
        dbg "UCI include removed from $fw_conf"
    fi
}

# ─── Remove all our nft chains from live ruleset (without reload) ─────────────
nft_remove_live_chains() {
    dbg "Removing live NSS-Switch chains from nft"
    local handles h
    for chain in mangle_prerouting mangle_postrouting; do
        handles=$(nft -a list chain inet fw4 "$chain" 2>/dev/null | grep -E "jump $NFT_CHAIN_PRE|jump $NFT_CHAIN_POST" | grep -oE 'handle [0-9]+' | awk '{print $2}')
        for h in $handles; do
            nft delete rule inet fw4 "$chain" handle "$h" 2>/dev/null
            dbg "Deleted jump handle $h from $chain"
        done
    done
    nft delete chain inet fw4 "$NFT_CHAIN_PRE"  2>/dev/null && dbg "Deleted $NFT_CHAIN_PRE"
    nft delete chain inet fw4 "$NFT_CHAIN_POST" 2>/dev/null && dbg "Deleted $NFT_CHAIN_POST"
}

# ─── Show only our rules from live ruleset ────────────────────────────────────
nft_show_our_rules() {
    ui_section "NSS-Switch live nftables rules"
    if nft list chain inet fw4 "$NFT_CHAIN_PRE" 2>/dev/null; then
        echo ""
        nft list chain inet fw4 "$NFT_CHAIN_POST" 2>/dev/null
    else
        ui_warn "NSS-Switch chains not present in live ruleset"
        ui_warn "Run 'nss-switch.sh apply' or reload the firewall"
    fi
}

# ─── Validate rule fields ─────────────────────────────────────────────────────
nft_validate_ipv6() {
    local ip="$1"
    local original="$ip"

    # Extraer parte IP y CIDR
    local cidr=""
    case "$ip" in
        */*)
            cidr="${ip##*/}"
            ip="${ip%%/*}"
            # Validar CIDR 0-128
            [ "$cidr" -ge 0 ] 2>/dev/null || return 1
            [ "$cidr" -le 128 ] 2>/dev/null || return 1
            ;;
    esac

    # Normalizar: convertir a minúsculas
    ip=$(echo "$ip" | tr 'A-F' 'a-f')

    # Regla 1: Solo caracteres válidos
    echo "$ip" | grep -qE '^[0-9a-f:]+$' || return 1

    # Regla 2: No puede empezar ni terminar con : (excepto ::)
    case "$ip" in
        :*) [ "$ip" != "::" ] && return 1 ;;
        *:) [ "$ip" != "::" ] && return 1 ;;
    esac

    # Regla 3: Contar :: (máximo uno)
    local double_colon_count=$(echo "$ip" | grep -o "::" | wc -l)
    [ "$double_colon_count" -gt 1 ] && return 1

    # Regla 4: Descomponer en grupos
    # Reemplazar :: por un marcador temporal
    local has_double_colon=0
    if echo "$ip" | grep -q "::"; then
        has_double_colon=1
        ip=$(echo "$ip" | sed 's/::/:FFFF:/')
    fi

    # Separar por :
    local old_ifs="$IFS"
    IFS=':'
    set -- $ip
    local groups=$#
    IFS="$old_ifs"

    # Regla 5: Número de grupos válido
    # Sin :: -> exactamente 8 grupos
    # Con :: -> entre 1 y 7 grupos visibles (los ceros implícitos completan hasta 8)
    if [ "$has_double_colon" -eq 0 ]; then
        # Sin ::, deben ser exactamente 8 grupos
        [ "$groups" -ne 8 ] && return 1
    else
        # Con ::, los grupos visibles deben ser entre 1 y 7
        # (porque :: ya cuenta como al menos un grupo de ceros)
        [ "$groups" -lt 1 ] && return 1
        [ "$groups" -gt 7 ] && return 1
    fi

    # Regla 6: Validar cada grupo
    old_ifs="$IFS"
    IFS=':'
    for group in $ip; do
        # Saltar el marcador FFFF (no es un grupo real)
        [ "$group" = "FFFF" ] && continue

        # Grupo vacío? (solo puede pasar si era :: y ya lo manejamos)
        [ -z "$group" ] && continue

        # Longitud del grupo: 1-4 caracteres
        len=$(echo -n "$group" | wc -c)
        [ "$len" -lt 1 ] && return 1
        [ "$len" -gt 4 ] && return 1

        # Validar que sea hexadecimal
        echo "$group" | grep -qE '^[0-9a-f]+$' || return 1

        # Convertir a decimal y validar rango (0-65535)
        local dec
        dec=$(printf "%d" "0x$group" 2>/dev/null)
        [ "$dec" -ge 0 ] 2>/dev/null || return 1
        [ "$dec" -le 65535 ] 2>/dev/null || return 1
    done
    IFS="$old_ifs"

    # Regla 7: IPv4 incrustada? (formato ::ffff:192.168.1.1)
    if echo "$original" | grep -qiE '::ffff:[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
        # Extraer la parte IPv4 y validarla
        local ipv4_part="${original##*:}"
        # Validar IPv4 con función existente
        nft_validate_ipv4 "$ipv4_part" || return 1
    fi

    return 0
}
nft_validate_ip() {
    local ip="$1"

    # IPv4
    if echo "$ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$'; then
        # Validación IPv4 existente
        local ip_only="${ip%%/*}"
        local oct1=$(echo "$ip_only" | cut -d'.' -f1)
        local oct2=$(echo "$ip_only" | cut -d'.' -f2)
        local oct3=$(echo "$ip_only" | cut -d'.' -f3)
        local oct4=$(echo "$ip_only" | cut -d'.' -f4)
        [ "$oct1" -le 255 ] && [ "$oct2" -le 255 ] && \
        [ "$oct3" -le 255 ] && [ "$oct4" -le 255 ] || return 1

        local cidr="${ip##*/}"
        if [ "$ip" != "$ip_only" ]; then
            [ "$cidr" -ge 0 ] 2>/dev/null && [ "$cidr" -le 32 ] 2>/dev/null || return 1
        fi
        return 0
    fi

    # IPv6
    if echo "$ip" | grep -q ":"; then
        nft_validate_ipv6 "$ip"
        return $?
    fi

    return 1
}

nft_validate_port() {
    echo "$1" | grep -qE '^[0-9]{1,5}$' && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

nft_validate_proto() {
    case "$1" in tcp|udp|icmp|icmpv6|any) return 0 ;; *) return 1 ;; esac
}

nft_validate_iface() {
    [ "$1" = "any" ] && return 0
    case "$1" in
        out:*) ip link show "${1#out:}" >/dev/null 2>&1 ;;
        *)     ip link show "$1" >/dev/null 2>&1 ;;
    esac
}


EOF
ok "lib/nft.sh created"

# ──────────────────────────────────────────────────────────────────────────────
# CREATE lib/detect.sh
# ──────────────────────────────────────────────────────────────────────────────
cat > "$INSTALL_DIR/lib/detect.sh" << 'EOF'
#!/usr/bin/env ash
# lib/detect.sh — Environment detection for NSS-Switch
# ASH compatible, BusyBox v1.37+

# ─── Detect firewall backend ──────────────────────────────────────────────────
detect_fw_backend() {
    if grep -q "fw4" /etc/init.d/firewall 2>/dev/null; then
        echo "fw4"
    elif grep -q "fw3" /etc/init.d/firewall 2>/dev/null; then
        echo "fw3"
    else
        echo "unknown"
    fi
}

# ─── List all network interfaces ─────────────────────────────────────────────
detect_interfaces() {
    ip link show 2>/dev/null | grep -E '^[0-9]+:' | \
        awk '{print $2}' | sed 's/://' | grep -v '^lo$'
}

# ─── Detect if interface is WAN ───────────────────────────────────────────────
detect_is_wan() {
    local iface="$1"
    # Check UCI network config
    grep -l "option ifname.*$iface\|option device.*$iface" /etc/config/network 2>/dev/null | \
        xargs grep -l "wan\|pppoe\|dhcp" 2>/dev/null | head -1 | grep -q . && return 0
    # Fallback: check if it's the default route interface
    ip route | grep "^default" | grep -q "$iface"
}

# ─── Detect if NAT/masquerade applies on an interface ────────────────────────
detect_has_nat() {
    local iface="$1"
    # Check if masquerade or dnat rules exist for this interface in live nft
    nft list ruleset 2>/dev/null | grep -q "oifname \"$iface\".*masquerade\|iifname \"$iface\".*dnat"
}

# ─── Detect if DNAT applies on an interface ───────────────────────────────────
detect_has_dnat() {
    local iface="$1"
    nft list ruleset 2>/dev/null | grep -q "iifname \"$iface\".*dnat"
}

# ─── Get zone name for an interface from fw4 chains ──────────────────────────
detect_zone_for_iface() {
    local iface="$1"
    # fw4 names chains like input_lan, forward_lan, etc.
    # Look for iifname matches in chain jumps
    nft list ruleset 2>/dev/null | \
        grep "iifname \"$iface\".*jump" | \
        grep -oE 'jump [a-z_]+' | \
        head -1 | awk '{print $2}' | sed 's/input_//;s/forward_//;s/output_//'
}

# ─── Get all interfaces that have DNAT rules ──────────────────────────────────
detect_dnat_ifaces() {
    nft list ruleset 2>/dev/null | \
        grep "iifname.*dnat" | \
        grep -oE '"[^"]+"' | head -1 | tr -d '"'
}

# ─── Full environment check ───────────────────────────────────────────────────
detect_check_all() {
    local ok=0 warn=0 err=0

    ui_section "System Environment"
    ui_kv "Kernel" "$(uname -r)"
    ui_kv "BusyBox" "$(busybox --version 2>/dev/null | head -1)"
    ui_kv "nft" "$(nft --version 2>/dev/null | head -1)"

    ui_section "Firewall"
    local fw
    fw=$(detect_fw_backend)
    ui_kv "Backend" "$fw"
    if [ "$fw" != "fw4" ]; then
        ui_warn "NSS-Switch is designed for fw4/nftables"
        warn=$((warn+1))
    else
        ui_ok "fw4 detected"
        ok=$((ok+1))
    fi

    ui_section "nftables Tables"
    nft list tables 2>/dev/null | while IFS= read -r t; do
        ui_kv "table" "$t"
    done

    ui_section "fw4 Mangle Chains (our injection points)"
    for chain in mangle_prerouting mangle_postrouting raw_prerouting; do
        if nft list chain inet fw4 "$chain" >/dev/null 2>&1; then
            ui_ok "$chain — present"
            ok=$((ok+1))
        else
            ui_warn "$chain — NOT present (unexpected)"
            warn=$((warn+1))
        fi
    done

    ui_section "ECM / NSS"
    if [ -d "$ECM_DEBUGFS" ]; then
        ui_ok "ECM debugfs present at $ECM_DEBUGFS"
        ok=$((ok+1))
    else
        ui_error "ECM debugfs NOT found — NSS offload may not be active"
        err=$((err+1))
    fi

    if ecm_mark_classifier_available; then
        ui_ok "ecm_classifier_mark — AVAILABLE (ct mark bypass will work)"
        ok=$((ok+1))
    else
        ui_error "ecm_classifier_mark — NOT present in debugfs"
        ui_error "Bypass via ct mark will NOT work without this classifier"
        err=$((err+1))
    fi

    ui_kv "ECM frontend" "$(ecm_frontend)"
    ui_kv "ECM engine (UCI)" "$(ecm_engine)"
    ui_kv "accel_delay_pkts" "$(ecm_accel_delay_pkts)"

    ui_section "Conntrack"
    if [ -f /proc/net/nf_conntrack ]; then
        ui_ok "nf_conntrack available"
        ui_kv "Total connections" "$(wc -l < /proc/net/nf_conntrack)"
        ok=$((ok+1))
    else
        ui_error "nf_conntrack not available"
        err=$((err+1))
    fi

    ui_section "NSS-Switch State"
    if [ -f "$RULES_FILE" ]; then
        local rule_count
        rule_count=$(grep -cv -e '^#' -e '^$' "$RULES_FILE" 2>/dev/null)
        ui_kv "Rules file" "$RULES_FILE"
        ui_kv "Active rules" "$rule_count"
    else
        ui_warn "No rules file yet (no rules defined)"
    fi

    if nft_chains_exist 2>/dev/null; then
        ui_ok "NSS-Switch nft chains present in live ruleset"
    else
        ui_warn "NSS-Switch chains NOT in live ruleset (firewall not reloaded yet?)"
    fi

    ui_section "NSS-Switch Mark"
    ui_kv "Our ct mark" "$NSS_MARK"
    ui_kv "QoS mark range" "0x000000ff (no conflict)"
    ui_kv "Bypassed connections" "$(ct_count_bypassed)"

    ui_section "Interfaces"
    detect_interfaces | while IFS= read -r iface; do
        local nat_flag="" dnat_flag="" zone
        detect_has_nat  "$iface" && nat_flag=" [NAT]"
        detect_has_dnat "$iface" && dnat_flag=" [DNAT]"
        zone=$(detect_zone_for_iface "$iface")
        [ -z "$zone" ] && zone="?"
        printf "  %-15s zone=%-10s%s%s\n" "$iface" "$zone" "$nat_flag" "$dnat_flag"
    done

    ui_section "Summary"
    printf "  ${C_GREEN}OK: %d${C_RESET}  ${C_YELLOW}WARN: %d${C_RESET}  ${C_RED}ERR: %d${C_RESET}\n" \
        "$ok" "$warn" "$err"
    [ "$err" -gt 0 ] && return 1 || return 0
}

EOF
ok "lib/detect.sh created"

# ──────────────────────────────────────────────────────────────────────────────
# CREATE lib/rules.sh
# ──────────────────────────────────────────────────────────────────────────────
cat > "$INSTALL_DIR/lib/rules.sh" << 'EOF'
#!/usr/bin/env ash
# lib/rules.sh — CRUD operations on state/rules.conf
# Format: id|proto|src_ip|dst_ip|src_port|dst_port|iface|persist|comment
# ASH compatible, BusyBox v1.37+

RULES_HEADER="# NSS-Switch rules — id|proto|src_ip|dst_ip|src_port|dst_port|iface|persist|comment"

# ─── Ensure rules file exists ─────────────────────────────────────────────────
rules_init() {
    if [ ! -f "$RULES_FILE" ]; then
        mkdir -p "$(dirname "$RULES_FILE")"
        printf "%s\n" "$RULES_HEADER" > "$RULES_FILE"
        dbg "Created $RULES_FILE"
    fi
}

# ─── Get next available ID ────────────────────────────────────────────────────
rules_next_id() {
    rules_init
    local max=0 id
    while IFS='|' read -r id _rest; do
        case "$id" in '#'*|'') continue ;; esac
        [ "$id" -gt "$max" ] 2>/dev/null && max="$id"
    done < "$RULES_FILE"
    echo $((max+1))
}

# ─── Add a rule ───────────────────────────────────────────────────────────────
rules_add() {
    local proto="${1:-any}"
    local src_ip="${2:-any}"
    local dst_ip="${3:-any}"
    local src_port="${4:-any}"
    local dst_port="${5:-any}"
    local iface="${6:-any}"
    local persist="${7:-$PERSIST_DEFAULT}"
    local comment="${8:-manual rule}"

    rules_init
    local id
    id=$(rules_next_id)
    printf "%s|%s|%s|%s|%s|%s|%s|%s|%s\n" \
        "$id" "$proto" "$src_ip" "$dst_ip" \
        "$src_port" "$dst_port" "$iface" "$persist" "$comment" \
        >> "$RULES_FILE"
    dbg "Rule $id added: $proto $src_ip->$dst_ip iface=$iface persist=$persist"
    echo "$id"
}

# ─── Remove a rule by ID ──────────────────────────────────────────────────────
rules_remove() {
    local target_id="$1"
    rules_init
    if ! rules_get "$target_id" >/dev/null 2>&1; then
        ui_error "Rule ID $target_id not found"
        return 1
    fi
    # Rewrite file without that ID
    local tmp="${RULES_FILE}.tmp"
    while IFS='|' read -r id rest; do
        case "$id" in
            '#'*|'') printf "%s\n" "$id${id:+|}$rest" ;;
            "$target_id") dbg "Removing rule $id" ;;
            *) printf "%s|%s\n" "$id" "$rest" ;;
        esac
    done < "$RULES_FILE" > "$tmp"
    mv "$tmp" "$RULES_FILE"
    ui_ok "Rule $target_id removed"
}

# ─── Get a rule by ID (print the raw line) ───────────────────────────────────
rules_get() {
    local target_id="$1"
    rules_init
    while IFS='|' read -r id rest; do
        case "$id" in '#'*|'') continue ;; esac
        if [ "$id" = "$target_id" ]; then
            printf "%s|%s\n" "$id" "$rest"
            return 0
        fi
    done < "$RULES_FILE"
    return 1
}

# ─── Count rules ──────────────────────────────────────────────────────────────
rules_count() {
    rules_init
    local n
    n=$(grep -cv -e '^#' -e '^$' "$RULES_FILE" 2>/dev/null)
    echo "${n:-0}"
}

# ─── List all rules (formatted) ───────────────────────────────────────────────
rules_list() {
    rules_init
    local count
    count=$(rules_count)
    if [ "$count" -eq 0 ]; then
        ui_warn "No bypass rules defined"
        return 0
    fi
    ui_rule_header
    while IFS='|' read -r id proto src_ip dst_ip src_port dst_port iface persist comment; do
        case "$id" in '#'*|'') continue ;; esac
        ui_rule_row "$id" "$proto" "$src_ip" "$dst_ip" \
            "$src_port" "$dst_port" "$iface" "$persist" "$comment"
    done < "$RULES_FILE"
    ui_sep
    ui_kv "Total rules" "$count"
}

# ─── Clear all rules ──────────────────────────────────────────────────────────
rules_clear() {
    printf "%s\n" "$RULES_HEADER" > "$RULES_FILE"
    ui_ok "All rules cleared from $RULES_FILE"
}

# ─── Clear only non-persistent rules ─────────────────────────────────────────
rules_clear_temp() {
    rules_init
    local tmp="${RULES_FILE}.tmp"
    local removed=0
    while IFS='|' read -r id proto src_ip dst_ip src_port dst_port iface persist comment; do
        case "$id" in
            '#'*|'')
                printf "%s\n" "$id${id:+|}$proto${proto:+|}$src_ip${src_ip:+|}$dst_ip${dst_ip:+|}$src_port${src_port:+|}$dst_port${dst_port:+|}$iface${iface:+|}$persist${persist:+|}$comment"
                continue
                ;;
        esac
        if [ "$persist" = "yes" ]; then
            printf "%s|%s|%s|%s|%s|%s|%s|%s|%s\n" \
                "$id" "$proto" "$src_ip" "$dst_ip" \
                "$src_port" "$dst_port" "$iface" "$persist" "$comment"
        else
            removed=$((removed+1))
            dbg "Removing temp rule $id"
        fi
    done < "$RULES_FILE" > "$tmp"
    mv "$tmp" "$RULES_FILE"
    ui_ok "Removed $removed temporary rule(s)"
}

# ─── Get fields of a rule as variables ───────────────────────────────────────
# Sets: RULE_ID RULE_PROTO RULE_SRC_IP RULE_DST_IP
#       RULE_SPORT RULE_DPORT RULE_IFACE RULE_PERSIST RULE_COMMENT
rules_parse() {
    local line="$1"
    RULE_ID=$(echo "$line"      | cut -d'|' -f1)
    RULE_PROTO=$(echo "$line"   | cut -d'|' -f2)
    RULE_SRC_IP=$(echo "$line"  | cut -d'|' -f3)
    RULE_DST_IP=$(echo "$line"  | cut -d'|' -f4)
    RULE_SPORT=$(echo "$line"   | cut -d'|' -f5)
    RULE_DPORT=$(echo "$line"   | cut -d'|' -f6)
    RULE_IFACE=$(echo "$line"   | cut -d'|' -f7)
    RULE_PERSIST=$(echo "$line" | cut -d'|' -f8)
    RULE_COMMENT=$(echo "$line" | cut -d'|' -f9)
}

# ─── Validate all fields of a pending rule ────────────────────────────────────
rules_validate() {
    local proto="$1" src_ip="$2" dst_ip="$3"
    local src_port="$4" dst_port="$5" iface="$6"
    local ok=1

    [ "$proto" != "any" ] && ! nft_validate_proto "$proto" && {
        ui_error "Invalid protocol: $proto (use tcp|udp|icmp|icmpv6|any)"
        ok=0
    }
    [ "$src_ip" != "any" ] && ! nft_validate_ip "$src_ip" && {
        ui_error "Invalid src IP/CIDR: $src_ip"
        ok=0
    }
    [ "$dst_ip" != "any" ] && ! nft_validate_ip "$dst_ip" && {
        ui_error "Invalid dst IP/CIDR: $dst_ip"
        ok=0
    }
    [ "$src_port" != "any" ] && ! nft_validate_port "$src_port" && {
        ui_error "Invalid src port: $src_port"
        ok=0
    }
    [ "$dst_port" != "any" ] && ! nft_validate_port "$dst_port" && {
        ui_error "Invalid dst port: $dst_port"
        ok=0
    }
    [ "$iface" != "any" ] && ! nft_validate_iface "$iface" && {
        ui_error "Interface not found: $iface"
        ok=0
    }
    # At least one criterion must be non-any
    if [ "$proto" = "any" ] && [ "$src_ip" = "any" ] && [ "$dst_ip" = "any" ] && \
       [ "$src_port" = "any" ] && [ "$dst_port" = "any" ] && [ "$iface" = "any" ]; then
        ui_warn "Rule matches ALL connections - NSS will be disabled for everything"
        ui_warn "This may impact routing performance significantly"
        # Permitir ANY a todo, venimos desde ct_clear_rule_marks(), que ahora permite lfush a todo ante un any all
        # ok=0
    fi
    [ "$ok" -eq 1 ]
}

EOF
ok "lib/rules.sh created"

# ──────────────────────────────────────────────────────────────────────────────
# CREATE lib/debug.sh
# ──────────────────────────────────────────────────────────────────────────────
cat > "$INSTALL_DIR/lib/debug.sh" << 'EOF'
#!/usr/bin/env ash
# lib/debug.sh - Real-time monitoring panel for NSS-Switch
# Usage: nss-switch debug monitor [interface]

# Guardar timestamp de inicio
DEBUG_SESSION_START=$(date +%Y%m%d_%H%M%S)
DEBUG_LOG_FILE="/tmp/nss-debug-${DEBUG_SESSION_START}.log"

# Colores para la UI de monitor (usar echo -e)
MON_GREEN='\033[0;32m'
MON_RED='\033[0;31m'
MON_YELLOW='\033[0;33m'
MON_CYAN='\033[0;36m'
MON_BOLD='\033[1m'
MON_DIM='\033[2m'
MON_RESET='\033[0m'

# Archivos temporales
PREV_FILE="/tmp/nss-debug-prev-$$"
RULES_SNAPSHOT="/tmp/nss-debug-rules-$$"
PID_FILE="/tmp/nss-debug-monitor.pid"

# Variables globales
total_conn_prev=0
bypassed_prev=0

# ──────────────────────────────────────────────────────────────────────────────
# Trap para limpieza al salir
_debug_cleanup() {
    rm -f "$PREV_FILE" "$RULES_SNAPSHOT" "$PID_FILE" 2>/dev/null
    echo "[$(date '+%H:%M:%S')] Monitor stopped" >> "$DEBUG_LOG_FILE"
    exit 0
}

# ──────────────────────────────────────────────────────────────────────────────
# Formatear bytes a human readable (B, KB, MB, GB)
_format_bytes() {
    local bytes=$1
    [ -z "$bytes" ] && bytes=0

    if [ "$bytes" -ge 1073741824 ]; then
        echo "$((bytes / 1073741824))G"
    elif [ "$bytes" -ge 1048576 ]; then
        echo "$((bytes / 1048576))M"
    elif [ "$bytes" -ge 1024 ]; then
        echo "$((bytes / 1024))K"
    else
        echo "${bytes}B"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Inicializar captura de valores previos
_debug_init() {
    rm -f "$PREV_FILE" "$RULES_SNAPSHOT" 2>/dev/null

    for iface in lan2 lan3 br-lan pppoe-wan; do
        local stats=$(ip -s link show "$iface" 2>/dev/null)
        if [ -n "$stats" ]; then
            local rx_bytes=$(echo "$stats" | awk '/RX:/{getline; print $1}')
            local tx_bytes=$(echo "$stats" | awk '/TX:/{getline; print $1}')
            local rx_packets=$(echo "$stats" | awk '/RX:/{getline; print $2}')
            local tx_packets=$(echo "$stats" | awk '/TX:/{getline; print $2}')

            echo "${iface}_rx_pkts=$rx_packets" >> "$PREV_FILE"
            echo "${iface}_tx_pkts=$tx_packets" >> "$PREV_FILE"
            echo "${iface}_rx_bytes=$rx_bytes" >> "$PREV_FILE"
            echo "${iface}_tx_bytes=$tx_bytes" >> "$PREV_FILE"
        fi
    done

    # Guardar snapshot inicial de reglas
    nft list chain inet fw4 nss_bypass_pre 2>/dev/null | grep "comment \"NSS-Switch" > "$RULES_SNAPSHOT"

    echo "[$(date '+%H:%M:%S')] Monitor started" >> "$DEBUG_LOG_FILE"
}

# ──────────────────────────────────────────────────────────────────────────────
# Obtener valor previo
_get_prev() {
    grep "^${1}=" "$PREV_FILE" 2>/dev/null | cut -d'=' -f2
}

# ──────────────────────────────────────────────────────────────────────────────
# Actualizar valor previo
_update_prev() {
    if grep -q "^${1}=" "$PREV_FILE" 2>/dev/null; then
        sed -i "s/^${1}=.*/${1}=${2}/" "$PREV_FILE"
    else
        echo "${1}=${2}" >> "$PREV_FILE"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Detectar cambios en reglas
_check_rule_changes() {
    local new_rules="/tmp/nss-debug-newrules-$$"
    nft list chain inet fw4 nss_bypass_pre 2>/dev/null | grep "comment \"NSS-Switch" > "$new_rules"

    if ! cmp -s "$RULES_SNAPSHOT" "$new_rules" 2>/dev/null; then
        local added=$(comm -13 "$RULES_SNAPSHOT" "$new_rules" 2>/dev/null | wc -l)
        local removed=$(comm -23 "$RULES_SNAPSHOT" "$new_rules" 2>/dev/null | wc -l)
        echo "[$(date '+%H:%M:%S')] RULES CHANGED: +$added -$removed" >> "$DEBUG_LOG_FILE"

        # Mostrar reglas nuevas
        comm -13 "$RULES_SNAPSHOT" "$new_rules" 2>/dev/null | while read line; do
            local comment=$(echo "$line" | sed -n 's/.*comment "NSS-Switch id=\([0-9]\+\): \(.*\)".*/\1: \2/p')
            [ -n "$comment" ] && echo "[$(date '+%H:%M:%S')]   ADDED: $comment" >> "$DEBUG_LOG_FILE"
        done

        # Mostrar reglas removidas
        comm -23 "$RULES_SNAPSHOT" "$new_rules" 2>/dev/null | while read line; do
            local comment=$(echo "$line" | sed -n 's/.*comment "NSS-Switch id=\([0-9]\+\): \(.*\)".*/\1: \2/p')
            [ -n "$comment" ] && echo "[$(date '+%H:%M:%S')]   REMOVED: $comment" >> "$DEBUG_LOG_FILE"
        done

        cp "$new_rules" "$RULES_SNAPSHOT"
    fi
    rm -f "$new_rules"
}

# ──────────────────────────────────────────────────────────────────────────────
# Función principal del monitor
cmd_debug_monitor() {
    local focus_iface="${1:-lan3}"

    # Verificar dependencias
    command -v nss_stats >/dev/null 2>&1 || { echo "nss_stats not found"; return 1; }

    # Configurar trap para Ctrl+C y salida limpia
    trap '_debug_cleanup; exit 0' INT TERM EXIT
    echo $$ > "$PID_FILE"

    echo -e "${MON_BOLD}Starting NSS-Switch Real-Time Monitor${MON_RESET}"
    echo "Log file: $DEBUG_LOG_FILE"
    echo "Focus interface: $focus_iface"
    echo -e "${MON_DIM}Press Ctrl+C to exit${MON_RESET}"

    _debug_init

    # Variables para tracking de cambios
    total_conn_prev=$(wc -l < /proc/net/nf_conntrack 2>/dev/null)
    bypassed_prev=$(ct_count_bypassed 2>/dev/null)

    while true; do
        clear

        # Banner
        echo -e "${MON_BOLD}${MON_CYAN}"
        echo "╔═══════════════════════════════════════════════════════════════════════════════════╗"
        echo "║                         NSS-Switch Real-Time Monitor                              ║"
        echo "╚═══════════════════════════════════════════════════════════════════════════════════╝"
        echo -e "${MON_RESET}"
        echo "  Session: $(basename "$DEBUG_LOG_FILE")"
        echo "  Time:    $(date '+%Y-%m-%d %H:%M:%S')"
        echo -e "  Focus:   ${focus_iface}"
        echo ""

        # === SECCIÓN 1: Resumen rápido con cambios ===
        echo -e "${MON_BOLD}${MON_CYAN}═══ 1. Quick Summary ═══${MON_RESET}"

        local total_conn=$(wc -l < /proc/net/nf_conntrack 2>/dev/null)
        local bypassed=$(ct_count_bypassed 2>/dev/null)
        local frontend=$(ecm_frontend 2>/dev/null)

        # Detectar cambios
        local conn_diff=$((total_conn - total_conn_prev))
        local bypass_diff=$((bypassed - bypassed_prev))

        printf "  %-25s %s" "Total connections:" "$total_conn"
        if [ "$conn_diff" -ne 0 ]; then
            echo -e " (${MON_GREEN}+$conn_diff${MON_RESET})"
            echo "[$(date '+%H:%M:%S')] CONN COUNT: $total_conn_prev → $total_conn ($([ $conn_diff -gt 0 ] && echo "+$conn_diff" || echo "$conn_diff"))" >> "$DEBUG_LOG_FILE"
        else
            echo ""
        fi

        printf "  %-25s %s" "Bypassed (CPU):" "$bypassed"
        if [ "$bypass_diff" -ne 0 ]; then
            echo -e " (${MON_GREEN}+$bypass_diff${MON_RESET})"
            echo "[$(date '+%H:%M:%S')] BYPASSED: $bypassed_prev → $bypassed ($([ $bypass_diff -gt 0 ] && echo "+$bypass_diff" || echo "$bypass_diff"))" >> "$DEBUG_LOG_FILE"
        else
            echo ""
        fi

        printf "  %-25s %s\n" "ECM Frontend:" "$frontend"
        echo ""

        # Actualizar previos
        total_conn_prev=$total_conn
        bypassed_prev=$bypassed

        # === SECCIÓN 2: Tráfico por interfaz (con KB/MB) ===
        echo -e "${MON_BOLD}${MON_CYAN}═══ 2. Interface Traffic (delta) ═══${MON_RESET}"
        echo -e "  ${MON_DIM}IFACE        RX_PKTS    RX_DATA    TX_PKTS    TX_DATA${MON_RESET}"

        for iface in lan2 lan3 br-lan pppoe-wan; do
            local stats=$(ip -s link show "$iface" 2>/dev/null)
            if [ -n "$stats" ]; then
                local rx_bytes=$(echo "$stats" | awk '/RX:/{getline; print $1}')
                local tx_bytes=$(echo "$stats" | awk '/TX:/{getline; print $1}')
                local rx_packets=$(echo "$stats" | awk '/RX:/{getline; print $2}')
                local tx_packets=$(echo "$stats" | awk '/TX:/{getline; print $2}')

                local prev_rx_pkt=$(_get_prev "${iface}_rx_pkts")
                local prev_tx_pkt=$(_get_prev "${iface}_tx_pkts")
                local prev_rx_byte=$(_get_prev "${iface}_rx_bytes")
                local prev_tx_byte=$(_get_prev "${iface}_tx_bytes")

                [ -z "$prev_rx_pkt" ] && prev_rx_pkt=0
                [ -z "$prev_tx_pkt" ] && prev_tx_pkt=0
                [ -z "$prev_rx_byte" ] && prev_rx_byte=0
                [ -z "$prev_tx_byte" ] && prev_tx_byte=0

                local delta_rx_pkt=$((rx_packets - prev_rx_pkt))
                local delta_tx_pkt=$((tx_packets - prev_tx_pkt))
                local delta_rx_data=$(_format_bytes $((rx_bytes - prev_rx_byte)))
                local delta_tx_data=$(_format_bytes $((tx_bytes - prev_tx_byte)))

                if [ "$iface" = "$focus_iface" ]; then
                    printf "  ${MON_GREEN}%-10s${MON_RESET} %-8s %-8s %-8s %-8s\n" \
                        "$iface" "$delta_rx_pkt" "$delta_rx_data" "$delta_tx_pkt" "$delta_tx_data"
                else
                    printf "  %-10s %-8s %-8s %-8s %-8s\n" \
                        "$iface" "$delta_rx_pkt" "$delta_rx_data" "$delta_tx_pkt" "$delta_tx_data"
                fi

                _update_prev "${iface}_rx_pkts" "$rx_packets"
                _update_prev "${iface}_tx_pkts" "$tx_packets"
                _update_prev "${iface}_rx_bytes" "$rx_bytes"
                _update_prev "${iface}_tx_bytes" "$tx_bytes"
            fi
        done
        echo ""

        # === SECCIÓN 3: Conexiones activas por interfaz ===
        echo -e "${MON_BOLD}${MON_CYAN}═══ 3. Active Connections (by interface) ═══${MON_RESET}"
        printf "  %-10s %8s %8s\n" "IFACE" "TOTAL" "BYPASSED"

        for iface in lan2 lan3 br-lan pppoe-wan; do
            local tmp_conn="/tmp/nss-debug-conn-$$"
            ct_dump_all_full 2>/dev/null | grep "|${iface}|" > "$tmp_conn"
            local total=$(wc -l < "$tmp_conn")
            local bypass_count=$(grep -c "|YES|" "$tmp_conn")
            rm -f "$tmp_conn"

            if [ "$iface" = "$focus_iface" ]; then
                printf "  ${MON_GREEN}%-10s${MON_RESET} %8s %8s\n" "$iface" "$total" "$bypass_count"
            else
                printf "  %-10s %8s %8s\n" "$iface" "$total" "$bypass_count"
            fi
        done
        echo ""

        # === SECCIÓN 4: Top conexiones (focus interface) ===
        echo -e "${MON_BOLD}${MON_CYAN}═══ 4. Top Connections (${focus_iface}) ═══${MON_RESET}"
        echo -e "  ${MON_DIM}PROTO  SRC:PORT -> DST:PORT                              BYPASS${MON_RESET}"

        ct_dump_all_full 2>/dev/null | grep "|${focus_iface}|" | head -8 | while IFS='|' read -r num proto src dst iface nss bypass mark state; do
            local src_ip=$(echo "$src" | cut -d'#' -f1 | cut -c1-30)
            local src_port=$(echo "$src" | cut -d'#' -f2)
            local dst_ip=$(echo "$dst" | cut -d'#' -f1 | cut -c1-30)
            local dst_port=$(echo "$dst" | cut -d'#' -f2)

            local bypass_color=""
            [ "$bypass" = "YES" ] && bypass_color="$MON_YELLOW"

            if [ "$bypass" = "YES" ]; then
                echo -e "  ${MON_DIM}${proto}${MON_RESET} ${MON_YELLOW}${src_ip}:${src_port} -> ${dst_ip}:${dst_port} BYPASS${MON_RESET}"
            else
                echo -e "  ${MON_DIM}${proto}${MON_RESET} ${src_ip}:${src_port} -> ${dst_ip}:${dst_port}"
            fi
        done
        echo ""

        # === SECCIÓN 5: Reglas activas ===
        echo -e "${MON_BOLD}${MON_CYAN}═══ 5. Active Bypass Rules ═══${MON_RESET}"

        # Guardar reglas en archivo temporal para evitar subshell
        local rules_tmp="/tmp/nss-debug-rules-display-$$"
        nft list chain inet fw4 nss_bypass_pre 2>/dev/null | grep "comment \"NSS-Switch" > "$rules_tmp"
        local rule_count=$(wc -l < "$rules_tmp")

        if [ "$rule_count" -gt 0 ]; then
            while read line; do
                local comment=$(echo "$line" | sed -n 's/.*comment "NSS-Switch id=\([0-9]\+\): \(.*\)".*/\1: \2/p')
                if [ -n "$comment" ]; then
                    echo -e "  • $comment"
                fi
            done < "$rules_tmp"
        else
            echo -e "  ${MON_DIM}No active rules${MON_RESET}"
        fi
        rm -f "$rules_tmp"
        echo ""


        echo -e "${MON_DIM}Press Ctrl+C to exit | Refreshing every 2 seconds${MON_RESET}"

        # === LOGGING: Registrar TODO el snapshot ===
        {
            echo "=== SNAPSHOT $(date '+%Y-%m-%d %H:%M:%S') ==="
            echo "═══ 1. Quick Summary ═══"
            echo "  Total connections:        $total_conn ($([ $conn_diff -ge 0 ] && echo "+$conn_diff" || echo "$conn_diff"))"
            echo "  Bypassed (CPU):           $bypassed ($([ $bypass_diff -ge 0 ] && echo "+$bypass_diff" || echo "$bypass_diff"))"
            echo "  ECM Frontend:             $frontend"
            echo ""
            echo "═══ 2. Interface Traffic (delta) ═══"
            echo "  IFACE        RX_PKTS    RX_DATA    TX_PKTS    TX_DATA"

            for iface in lan2 lan3 br-lan pppoe-wan; do
                local stats=$(ip -s link show "$iface" 2>/dev/null)
                if [ -n "$stats" ]; then
                    local rx_bytes=$(echo "$stats" | awk '/RX:/{getline; print $1}')
                    local tx_bytes=$(echo "$stats" | awk '/TX:/{getline; print $1}')
                    local rx_packets=$(echo "$stats" | awk '/RX:/{getline; print $2}')
                    local tx_packets=$(echo "$stats" | awk '/TX:/{getline; print $2}')

                    local prev_rx_pkt=$(_get_prev "${iface}_rx_pkts")
                    local prev_tx_pkt=$(_get_prev "${iface}_tx_pkts")
                    local prev_rx_byte=$(_get_prev "${iface}_rx_bytes")
                    local prev_tx_byte=$(_get_prev "${iface}_tx_bytes")

                    [ -z "$prev_rx_pkt" ] && prev_rx_pkt=0
                    [ -z "$prev_tx_pkt" ] && prev_tx_pkt=0
                    [ -z "$prev_rx_byte" ] && prev_rx_byte=0
                    [ -z "$prev_tx_byte" ] && prev_tx_byte=0

                    local delta_rx_pkt=$((rx_packets - prev_rx_pkt))
                    local delta_tx_pkt=$((tx_packets - prev_tx_pkt))
                    local delta_rx_data=$(_format_bytes $((rx_bytes - prev_rx_byte)))
                    local delta_tx_data=$(_format_bytes $((tx_bytes - prev_tx_byte)))

                    echo "  $iface       $delta_rx_pkt    $delta_rx_data     $delta_tx_pkt    $delta_tx_data"

                    _update_prev "${iface}_rx_pkts" "$rx_packets"
                    _update_prev "${iface}_tx_pkts" "$tx_packets"
                    _update_prev "${iface}_rx_bytes" "$rx_bytes"
                    _update_prev "${iface}_tx_bytes" "$tx_bytes"
                fi
            done
            echo ""
            echo "═══ 3. Active Connections (by interface) ═══"
            echo "  IFACE         TOTAL BYPASSED"

            for iface in lan2 lan3 br-lan pppoe-wan; do
                local tmp_conn="/tmp/nss-debug-conn-$$"
                ct_dump_all_full 2>/dev/null | grep "|${iface}|" > "$tmp_conn"
                local total=$(wc -l < "$tmp_conn")
                local bypass_count=$(grep -c "|YES|" "$tmp_conn")
                rm -f "$tmp_conn"
                echo "  $iface            $total       $bypass_count"
            done
            echo ""
            echo "═══ 4. Top Connections (${focus_iface}) ═══"

            ct_dump_all_full 2>/dev/null | grep "|${focus_iface}|" | head -8 | while IFS='|' read -r num proto src dst iface nss bypass mark state; do
                local src_ip=$(echo "$src" | cut -d'#' -f1 | cut -c1-30)
                local src_port=$(echo "$src" | cut -d'#' -f2)
                local dst_ip=$(echo "$dst" | cut -d'#' -f1 | cut -c1-30)
                local dst_port=$(echo "$dst" | cut -d'#' -f2)

                if [ "$bypass" = "YES" ]; then
                    echo "  $proto $src_ip:$src_port -> $dst_ip:$dst_port BYPASS"
                else
                    echo "  $proto $src_ip:$src_port -> $dst_ip:$dst_port"
                fi
            done
            echo ""
            echo "═══ 5. Active Bypass Rules ═══"

            nft list chain inet fw4 nss_bypass_pre 2>/dev/null | grep "comment \"NSS-Switch" | while read line; do
                local comment=$(echo "$line" | sed -n 's/.*comment "NSS-Switch id=\([0-9]\+\): \(.*\)".*/\1: \2/p')
                [ -n "$comment" ] && echo "  • $comment"
            done
            echo ""
            echo "=========================================="
            echo ""
        } >> "$DEBUG_LOG_FILE"

        # Detectar cambios en reglas (opcional, ya que el snapshot completo ya lo muestra todo)
        _check_rule_changes

        sleep 2
    done

}

EOF
ok "lib/debug.sh created"

# ──────────────────────────────────────────────────────────────────────────────
# CREATE firewall.d/nss-bypass
# ──────────────────────────────────────────────────────────────────────────────
cat > "$INSTALL_DIR/firewall.d/nss-bypass" << 'EOF'
#!/bin/sh
# NSS-Switch firewall.d hook — auto-generated, do not edit manually
# This file is regenerated by nss-switch.sh whenever rules change.
# To modify rules: use nss-switch.sh add / remove / pick
# To regenerate: nss-switch.sh apply

# Load config to get our constants
NSS_MARK=0x00010000
NFT_CHAIN_PRE=nss_bypass_pre
NFT_CHAIN_POST=nss_bypass_post

nft_add_chains() {
    nft add chain inet fw4 ${NFT_CHAIN_PRE}  2>/dev/null || true
    nft flush chain inet fw4 ${NFT_CHAIN_PRE} 2>/dev/null || true
    nft add chain inet fw4 ${NFT_CHAIN_POST} 2>/dev/null || true
    nft flush chain inet fw4 ${NFT_CHAIN_POST} 2>/dev/null || true

    # Remove stale jumps from fw4 mangle chains
    handles=$(nft -a list chain inet fw4 mangle_prerouting 2>/dev/null | grep "jump ${NFT_CHAIN_PRE}" | grep -oE 'handle [0-9]+' | awk '{print $2}')
    for h in $handles; do nft delete rule inet fw4 mangle_prerouting handle "$h" 2>/dev/null; done

    handles=$(nft -a list chain inet fw4 mangle_postrouting 2>/dev/null | grep "jump ${NFT_CHAIN_POST}" | grep -oE 'handle [0-9]+' | awk '{print $2}')
    for h in $handles; do nft delete rule inet fw4 mangle_postrouting handle "$h" 2>/dev/null; done

    # Inject our chains
    nft add rule inet fw4 mangle_prerouting  jump ${NFT_CHAIN_PRE}  comment '"NSS-Switch prerouting"'
    nft add rule inet fw4 mangle_postrouting jump ${NFT_CHAIN_POST} comment '"NSS-Switch postrouting"'

    # Postrouting: save our mark to conntrack (bidirectional persistence)
    nft add rule inet fw4 ${NFT_CHAIN_POST} meta mark and ${NSS_MARK} != 0 ct mark set meta mark and ${NSS_MARK} comment '"NSS-Switch: save bypass mark to conntrack"'

    # Prerouting: restore our mark from conntrack (for reply packets)
    nft add rule inet fw4 ${NFT_CHAIN_PRE} ct mark and ${NSS_MARK} != 0 meta mark set ct mark comment '"NSS-Switch: restore bypass mark from conntrack"'
}

nft_add_rules() {
    # No bypass rules defined yet.
    # Add rules using: nss-switch.sh add [options]
    true
}

nft_add_chains
nft_add_rules

EOF
ok "firewall.d/nss-bypass created"

# ──────────────────────────────────────────────────────────────────────────────
# CREATE state/rules.conf (only if not already present)
# ──────────────────────────────────────────────────────────────────────────────
if [ ! -f "$INSTALL_DIR/state/rules.conf" ]; then
    cat > "$INSTALL_DIR/state/rules.conf" << 'EOF'
# NSS-Switch rules — id|proto|src_ip|dst_ip|src_port|dst_port|iface|persist|comment
EOF
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
info "        nss-switch debug monitor [interface]"
info ""
warn "Firewall NOT reloaded automatically."
info "When ready: /etc/init.d/firewall restart"
info ""
