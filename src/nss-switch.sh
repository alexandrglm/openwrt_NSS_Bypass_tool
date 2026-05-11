#!/usr/bin/env ash
# nss-switch.sh — Qualcomm NSS selective bypass manager
# /usr/bin/NSS-Switch/nss-switch.sh
# ASH compatible — BusyBox v1.37+
# Usage: nss-switch.sh <command> [options]

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

# ─── Root check ───────────────────────────────────────────────────────────────
check_root() {
    [ "$(id -u)" = "0" ] || { ui_error "Must be run as root"; exit 1; }
}

# ─── Log every invocation ────────────────────────────────────────────────────
dbg "Invoked: $0 $*"

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
        local num=0
        ct_dump_all | while IFS='|' read -r n proto src dst iface nss bypass mark state; do
            num=$((num+1))
            # Truncate long addresses for display
            local src_short dst_short
            src_short=$(echo "$src" | cut -c1-21)
            dst_short=$(echo "$dst" | cut -c1-21)
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
    ui_section "Connection Picker — Select a connection to bypass NSS"

    local tmpfile
    tmpfile=$(mktemp /tmp/nss-switch-pick.XXXXXX)
    ct_dump_all > "$tmpfile"

    local total
    total=$(wc -l < "$tmpfile")
    if [ "$total" -eq 0 ]; then
        ui_warn "No connections found in conntrack"
        rm -f "$tmpfile"
        return 0
    fi

    # Display — awk evita redireccion de stdin
    ui_conn_header
    awk -F'|' '{
        src=substr($3,1,21); dst=substr($4,1,21)
        printf "%-4s %-5s %-21s %-21s %-10s %-5s %-8s\n", $1,$2,src,dst,$5,$6,$7
    }' "$tmpfile"
    ui_sep

    # Pick
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

    # Parse sin heredoc ni pipe (ambos roban stdin)
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
    src_ip=$(echo "$src" | cut -d: -f1)
    src_port=$(echo "$src" | cut -d: -f2)
    dst_ip=$(echo "$dst" | cut -d: -f1)
    dst_port=$(echo "$dst" | cut -d: -f2)

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
        ui_ask_input "Source IP or CIDR" "$src_ip"
        r_src_ip="$UI_INPUT"
    fi
    if ui_ask_yn "Match on destination IP ($dst_ip)?" n; then
        ui_ask_input "Destination IP or CIDR" "$dst_ip"
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
        if ui_ask_yn "Match on interface ($iface)?" n; then
            r_iface="$iface"
        fi
    fi

    local persist="$PERSIST_DEFAULT"
    if ui_ask_yn "Make this rule persistent (survive reboot)?" "$([ "$PERSIST_DEFAULT" = "yes" ] && echo y || echo n)"; then
        persist="yes"
    else
        persist="no"
    fi

    ui_ask_input "Comment for this rule" "bypass from pick: $src -> $dst"
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

    ui_info "Defuncting matched connections in ECM..."
    if [ "$r_dport" != "any" ]; then
        ecm_defunct_by_port "$r_dport"
    elif [ "$r_sport" != "any" ]; then
        ecm_defunct_by_port "$r_sport"
    else
        ecm_defunct_all
    fi

    ui_ok "Done. Connection will be handled by CPU (not NSS) going forward."
}

# ─── COMMAND: add ─────────────────────────────────────────────────────────────
cmd_add() {
    check_root
    local proto="any" src_ip="any" dst_ip="any"
    local sport="any" dport="any" iface="any"
    local persist="$PERSIST_DEFAULT" comment="manual rule"
    local defunct_after=1

    # Parse args
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

    rules_validate "$proto" "$src_ip" "$dst_ip" "$sport" "$dport" "$iface" || return 1

    local new_id
    new_id=$(rules_add "$proto" "$src_ip" "$dst_ip" \
        "$sport" "$dport" "$iface" "$persist" "$comment")
    ui_ok "Rule $new_id added to $RULES_FILE"

    nft_apply

    if [ "$defunct_after" = "1" ]; then
        ui_info "Defuncting matched ECM connections..."
        if [ "$dport" != "any" ]; then
            ecm_defunct_by_port "$dport"
        elif [ "$sport" != "any" ]; then
            ecm_defunct_by_port "$sport"
        else
            ecm_defunct_all
        fi
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
        ui_warn "NSS-Switch chains NOT in live ruleset — run: nss-switch.sh apply"
    fi
}

# ─── COMMAND: remove ──────────────────────────────────────────────────────────
cmd_remove() {
    check_root
    local id="$1"
    if [ -z "$id" ]; then
        ui_error "Usage: nss-switch.sh remove <rule-id>"
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
            ui_error "Usage: nss-switch.sh flush [--rules|--all|--temp]"
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
    printf "\n${C_BOLD}Usage:${C_RESET}  nss-switch.sh <command> [options]\n\n"
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
    printf "  nss-switch.sh add --iface lan2 --persist --comment 'Deco off NSS'\n"
    printf "  nss-switch.sh add --src-ip 192.168.1.50 --comment 'PC off NSS'\n"
    printf "  nss-switch.sh add --proto tcp --dst-port 22 --temp\n"
    printf "  nss-switch.sh watch\n"
    printf "  nss-switch.sh pick\n"
    printf "  nss-switch.sh debug env\n"
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
