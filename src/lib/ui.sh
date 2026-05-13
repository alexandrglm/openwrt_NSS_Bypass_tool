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
    printf "%-4s %-6s %-36s %-36s %-17s %-5s %-8s\n" \
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

    printf "%-4s %-6s %-36s %-36s %-17s ${nss_color}%-5s${C_RESET} ${byp_color}%-8s${C_RESET}\n" \
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
