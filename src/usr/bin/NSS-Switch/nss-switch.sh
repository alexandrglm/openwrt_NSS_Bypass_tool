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

# ─── Clean tmp files ─────────────────────────────────────────────────────────
_clean_tmp() {
    rm -f /tmp/nss-switch-pick.* 2>/dev/null
    rm -f /tmp/nss-switch-watch.* 2>/dev/null
    rm -f /tmp/nss-ifmap.* 2>/dev/null
    rm -f /tmp/nss-switch-exit.* 2>/dev/null
    rm -f /tmp/nss-iface.* 2>/dev/null
    rm -f /tmp/nss-display.* 2>/dev/null
    rm -f /tmp/nss-page.* 2>/dev/null
}
trap '_clean_tmp' EXIT

# ─── COMMAND: watch ───────────────────────────────────────────────────────────
cmd_watch() {
    check_root
    local interval="${1:-$WATCH_INTERVAL}"
    local once=0
    [ "$1" = "--once" ] && { once=1; interval=0; }

    # Delegar al binario C
    if [ "$once" -eq 1 ]; then
        nss-watch watch --once "$interval"
    else
        nss-watch watch "$interval"
    fi
}

# ─── COMMAND: pick ────────────────────────────────────────────────────────────
cmd_pick() {
    check_root
    nss-watch pick
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
    local r_total r_temp r_persist
    r_total=$(rules_count)
    r_temp=$(grep -c '|no|'  "$RULES_FILE" 2>/dev/null || echo 0)
    r_persist=$(grep -c '|yes|' "$RULES_FILE" 2>/dev/null || echo 0)

    ui_kv "Rules defined"  "$r_total  (${r_persist} persist, ${r_temp} temp)"
    ui_kv "Rules file"     "$RULES_FILE"

    echo ""
    local fe eng mark_avail
    fe=$(ecm_frontend)
    eng=$(ecm_engine)
    mark_avail=$(ecm_mark_classifier_available && echo "AVAILABLE" || echo "MISSING")
    local fe_color="$FG_GREEN"
    case "$fe" in SFE) fe_color="$FG_YELLOW";; UNKNOWN) fe_color="$FG_RED";; esac
    local mk_color="$FG_GREEN"
    [ "$mark_avail" = "MISSING" ] && mk_color="$FG_RED"

    printf "  ${C_DIM}%-22s${C_RESET} %b${C_BOLD}%s${C_RESET}  ${C_DIM}engine=%s${C_RESET}\n" \
        "ECM frontend:" "$fe_color" "$fe" "$eng"
    printf "  ${C_DIM}%-22s${C_RESET} %b${C_BOLD}%s${C_RESET}\n" \
        "Mark classifier:" "$mk_color" "$mark_avail"

    echo ""
    local ct_total ct_bypass
    ct_total=$(ct_count)
    ct_bypass=$(ct_count_bypassed)
    ui_kv "Conntrack total"  "$ct_total"
    printf "  ${C_DIM}%-22s${C_RESET} ${FG_ORANGE}${C_BOLD}%s${C_RESET}" "Bypassed (CPU):" "$ct_bypass"
    if [ "$ct_total" -gt 0 ]; then
        printf "  "
        local prog_width=20
        [ $TERM_COLS -gt 80 ] && prog_width=30
        ui_progress_bar "$ct_bypass" "$ct_total" $prog_width "of total"
    fi
    printf "\n"

    echo ""
    if nft_chains_exist 2>/dev/null; then
        ui_ok "NSS-Switch nft chains: ${FG_GREEN}LIVE${C_RESET}"
    else
        ui_warn "NSS-Switch nft chains: NOT ACTIVE — run: nss-switch apply"
    fi
    ui_kv "Our ct mark" "$NSS_MARK"

    ui_section "Active Rules"
    rules_list
}

# ─── HELP ─────────────────────────────────────────────────────────────────────
cmd_help() {
    ui_banner
    printf "\n${C_BOLD}Usage:${C_RESET}  ${FG_ACCENT}nss-switch${C_RESET} ${C_BOLD}<command>${C_RESET} [options]\n\n"

    printf "${C_BOLD}${FG_BRIGHT}Commands:${C_RESET}\n"
    _help_cmd "watch [--once] [interval]"       "Live connection monitor  ${C_DIM}(btop-style, Ctrl+C to exit, use terminal scroll)${C_RESET}"
    _help_cmd "pick"                             "Interactive: browse connections and bypass one"
    _help_cmd "add [options]"                    "Manually add a bypass rule"
    _help_cmd "list"                             "List all defined bypass rules"
    _help_cmd "remove <id>"                      "Remove a bypass rule by ID"
    _help_cmd "flush [--rules|--all|--temp]"     "Remove rules from nftables"
    _help_cmd "apply"                            "Re-apply rules.conf to nftables"
    _help_cmd "status"                           "Full status dashboard"
    _help_cmd "config [KEY] [VALUE]"             "View or set configuration"
    _help_cmd "debug <subcommand>"               "Debug and diagnostic tools"
    printf "\n"

    printf "${C_BOLD}${FG_BRIGHT}add options:${C_RESET}\n"
    _help_opt "--proto tcp|udp|icmp|any"  "Match protocol"
    _help_opt "--src-ip <IP/CIDR>"        "Match source IP or subnet"
    _help_opt "--dst-ip <IP/CIDR>"        "Match destination IP or subnet"
    _help_opt "--src-port <port>"         "Match source port (tcp/udp)"
    _help_opt "--dst-port <port>"         "Match destination port"
    _help_opt "--iface <interface>"       "Match input interface  (out:<iface> for egress)"
    _help_opt "--persist"                 "Survive reboot"
    _help_opt "--temp"                    "Temporary, lost on reboot (default)"
    _help_opt "--comment <text>"          "Human-readable label"
    _help_opt "--no-defunct"             "Skip ECM defunct after adding"
    printf "\n"

    printf "${C_BOLD}${FG_BRIGHT}Examples:${C_RESET}\n"
    printf "  ${FG_ACCENT}nss-switch add --iface lan2 --persist --comment 'Deco off NSS'${C_RESET}\n"
    printf "  ${FG_ACCENT}nss-switch add --src-ip 192.168.1.50 --comment 'PC off NSS'${C_RESET}\n"
    printf "  ${FG_ACCENT}nss-switch add --proto tcp --dst-port 22 --temp${C_RESET}\n"
    printf "  ${FG_ACCENT}nss-switch watch${C_RESET}\n"
    printf "  ${FG_ACCENT}nss-switch pick${C_RESET}\n"
    printf "  ${FG_ACCENT}nss-switch debug env${C_RESET}\n"
    printf "\n"
    cmd_debug_help
    printf "\n"
}

_help_cmd() {
    printf "  ${FG_ACCENT}${C_BOLD}%-36s${C_RESET}  %b\n" "$1" "$2"
}

_help_opt() {
    printf "  ${C_DIM}%-32s${C_RESET}  %s\n" "$1" "$2"
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
