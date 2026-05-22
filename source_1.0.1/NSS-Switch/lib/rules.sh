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
    # echo "DEBUG rules_parse recibió: [$line]" >&2

    RULE_ID=$(echo "$line" | cut -d'|' -f1)
    # echo "DEBUG RULE_ID = [$RULE_ID]" >&2

    RULE_PROTO=$(echo "$line" | cut -d'|' -f2)
    # echo "DEBUG RULE_PROTO = [$RULE_PROTO]" >&2

    RULE_SRC_IP=$(echo "$line" | cut -d'|' -f3)
    # echo "DEBUG RULE_SRC_IP = [$RULE_SRC_IP]" >&2

    RULE_DST_IP=$(echo "$line" | cut -d'|' -f4)
    # echo "DEBUG RULE_DST_IP = [$RULE_DST_IP]" >&2

    RULE_SPORT=$(echo "$line" | cut -d'|' -f5)
    # echo "DEBUG RULE_SPORT = [$RULE_SPORT]" >&2

    RULE_DPORT=$(echo "$line" | cut -d'|' -f6)
    # echo "DEBUG RULE_DPORT = [$RULE_DPORT]" >&2

    RULE_IFACE=$(echo "$line" | cut -d'|' -f7)
    # echo "DEBUG RULE_IFACE = [$RULE_IFACE]" >&2

    RULE_PERSIST=$(echo "$line" | cut -d'|' -f8)
    # echo "DEBUG RULE_PERSIST = [$RULE_PERSIST]" >&2

    RULE_COMMENT=$(echo "$line" | cut -d'|' -f9)
    # echo "DEBUG RULE_COMMENT = [$RULE_COMMENT]" >&2
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
