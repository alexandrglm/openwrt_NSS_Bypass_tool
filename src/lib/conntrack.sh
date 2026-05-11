#!/usr/bin/env ash
# lib/conntrack.sh — Parse /proc/net/nf_conntrack, correlate with NSS state
# NSS-Switch — ASH compatible, BusyBox v1.37+

CONNTRACK_FILE=/proc/net/nf_conntrack

# ─── Check conntrack available ────────────────────────────────────────────────
ct_check() {
    [ -f "$CONNTRACK_FILE" ] || { ui_error "conntrack not available"; return 1; }
}

# ─── Clear A rule handling with type of: iface? port? ip? protocol    ─────────────────────────────────────────────

ct_clear_rule_marks() {
    local proto="$1" src_ip="$2" dst_ip="$3"
    local sport="$4" dport="$5" iface="$6"
    local args=""

    [ "$proto"  != "any" ] && args="$args -p $proto"
    [ "$src_ip" != "any" ] && args="$args -s $src_ip"
    [ "$dst_ip" != "any" ] && args="$args -d $dst_ip"

    # iface → obtener subred y usar como src
    if [ "$iface" != "any" ]; then
        local subnet
        subnet=$(ip addr show "$iface" 2>/dev/null | grep 'inet ' | awk '{print $2}' | head -1)
        if [ -n "$subnet" ]; then
            # Convertir IP/prefix a network address
            local net
            net=$(ip route show dev "$iface" 2>/dev/null | grep -v default | awk '{print $1}' | head -1)
            [ -n "$net" ] && args="$args -s $net"
            dbg "iface $iface resolved to subnet $net"
        fi
    fi

    # sport/dport — no soportados en conntrack -D directamente
    # filtramos con -L y eliminamos entrada a entrada
    if [ "$sport" != "any" ] || [ "$dport" != "any" ]; then
        local tmp
        tmp=$(mktemp /tmp/nss-ct.XXXXXX)
        conntrack -L $args 2>/dev/null > "$tmp"
        while IFS= read -r line; do
            [ "$sport" != "any" ] && ! echo "$line" | grep -oE 'sport=[^ ]+' | head -1 | grep -q "=$sport$" && continue
            [ "$dport" != "any" ] && ! echo "$line" | grep -oE 'dport=[^ ]+' | head -1 | grep -q "=$dport$" && continue
            local e_proto e_src e_dst
            e_proto=$(echo "$line" | awk '{print $1}')
            e_src=$(echo "$line" | grep -oE 'src=[^ ]+' | head -1 | cut -d= -f2)
            e_dst=$(echo "$line" | grep -oE 'dst=[^ ]+' | head -1 | cut -d= -f2)
            conntrack -D -p "$e_proto" -s "$e_src" -d "$e_dst" 2>/dev/null; true
            dbg "Deleted: $e_proto $e_src -> $e_dst"
        done < "$tmp"
        rm -f "$tmp"
    else
        dbg "conntrack -D $args"
        conntrack -D $args 2>/dev/null; true
    fi

    ui_ok "Conntrack entries cleared for this rule"
}

# ─── Parse one conntrack line into variables ──────────────────────────────────
# Sets: CT_PROTO CT_SRC CT_SPORT CT_DST CT_DPORT CT_MARK CT_STATE CT_STATUS
ct_parse_line() {
    local line="$1"
    CT_PROTO=""
    CT_SRC="" CT_SPORT="" CT_DST="" CT_DPORT=""
    CT_MARK=0 CT_STATE="" CT_STATUS=""

    # Protocol
    CT_PROTO=$(echo "$line" | awk '{print $3}')

    # TCP has state field; UDP does not
    case "$CT_PROTO" in
        tcp|6)
            CT_STATE=$(echo "$line" | awk '{print $4}')
            ;;
        udp|17)
            CT_STATE="stateless"
            ;;
        *)
            CT_STATE="?"
            ;;
    esac

    # src/dst — first occurrence is original direction
    CT_SRC=$(echo "$line"  | grep -oE 'src=[^ ]+' | head -1 | cut -d= -f2)
    CT_DST=$(echo "$line"  | grep -oE 'dst=[^ ]+' | head -1 | cut -d= -f2)
    CT_SPORT=$(echo "$line" | grep -oE 'sport=[^ ]+' | head -1 | cut -d= -f2)
    CT_DPORT=$(echo "$line" | grep -oE 'dport=[^ ]+' | head -1 | cut -d= -f2)
    CT_MARK=$(echo "$line"  | grep -oE 'mark=[^ ]+' | head -1 | cut -d= -f2)
    CT_STATUS=$(echo "$line"| grep -oE 'status=[^ ]+' | head -1 | cut -d= -f2)

    # Defaults
    CT_SPORT="${CT_SPORT:-?}"
    CT_DPORT="${CT_DPORT:-?}"
    CT_MARK="${CT_MARK:-0}"
}

# ─── Check if mark has our NSS bypass bit set ─────────────────────────────────
ct_is_bypassed() {
    local mark="$1"
    # NSS_MARK=0x00010000 — arithmetic check in ash (hex needs conversion)
    local mark_dec
    mark_dec=$(printf '%d' "$mark" 2>/dev/null) || mark_dec=0
    local nss_dec
    nss_dec=$(printf '%d' "$NSS_MARK" 2>/dev/null) || nss_dec=65536
    [ $(( mark_dec & nss_dec )) -ne 0 ]
}

# ─── Get interface for a src IP from routing table ────────────────────────────
ct_iface_for_src() {
    local src="$1"
    # Ask kernel which interface would receive from this src
    ip route get "$src" 2>/dev/null | grep -oE 'dev [^ ]+' | head -1 | awk '{print $2}'
}

# ─── Determine NSS status for a connection ────────────────────────────────────
# Returns: HW | SFE | CPU
# We use ct_is_bypassed for our bypass mark.
# For actual HW/SFE distinction we check ECM state if available.
ct_nss_status() {
    local mark="$1"
    if ct_is_bypassed "$mark"; then
        echo "CPU"
        return
    fi
    # If ECM is loaded and frontend is NSS → likely HW accelerated
    if [ -d "$ECM_DEBUGFS/ecm_nss_ipv4" ]; then
        echo "HW"
    elif [ -d "$ECM_DEBUGFS/ecm_sfe_ipv4" ]; then
        echo "SFE"
    else
        echo "CPU"
    fi
}

# ─── Dump all connections as structured records ───────────────────────────────
# Output format (one per line):
#   NUM|PROTO|SRC:SPORT|DST:DPORT|IFACE|NSS|BYPASS|MARK|STATE
ct_dump_all() {
    ct_check || return 1
    local num=0
    while IFS= read -r line; do
        # Skip IPv6 lines if needed (col 1 = ipv6 has different layout)
        # nf_conntrack format: "netns L3proto L4proto ..."
        # Skip lines that start with ipv6 to keep layout simple (handle both)
        local l3
        l3=$(echo "$line" | awk '{print $1}')
        [ "$l3" = "ipv6" ] && continue  # handled separately if needed

        ct_parse_line "$line"
        [ -z "$CT_SRC" ] && continue

        num=$((num+1))
        local iface
        iface=$(ct_iface_for_src "$CT_SRC")
        [ -z "$iface" ] && iface="?"

        local nss_status
        nss_status=$(ct_nss_status "$CT_MARK")

        local bypassed="NO"
        ct_is_bypassed "$CT_MARK" && bypassed="YES"

        local src_str="${CT_SRC}:${CT_SPORT}"
        local dst_str="${CT_DST}:${CT_DPORT}"

        printf "%d|%s|%s|%s|%s|%s|%s|%s|%s\n" \
            "$num" "$CT_PROTO" "$src_str" "$dst_str" \
            "$iface" "$nss_status" "$bypassed" "$CT_MARK" "$CT_STATE"
    done < "$CONNTRACK_FILE"
}

# ─── Dump connections with IPv6 too ──────────────────────────────────────────
ct_dump_all_v6() {
    ct_check || return 1
    local num=0
    while IFS= read -r line; do
        ct_parse_line "$line"
        [ -z "$CT_SRC" ] && continue
        num=$((num+1))
        local iface
        iface=$(ct_iface_for_src "$CT_SRC" 2>/dev/null)
        [ -z "$iface" ] && iface="?"
        local nss_status
        nss_status=$(ct_nss_status "$CT_MARK")
        local bypassed="NO"
        ct_is_bypassed "$CT_MARK" && bypassed="YES"
        printf "%d|%s|%s:%s|%s:%s|%s|%s|%s|%s|%s\n" \
            "$num" "$CT_PROTO" "$CT_SRC" "$CT_SPORT" "$CT_DST" "$CT_DPORT" \
            "$iface" "$nss_status" "$bypassed" "$CT_MARK" "$CT_STATE"
    done < "$CONNTRACK_FILE"
}

# ─── Get single connection by NUM ─────────────────────────────────────────────
ct_get_by_num() {
    local target="$1"
    ct_dump_all | awk -F'|' -v n="$target" '$1==n {print; exit}'
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
        local mark
        mark=$(echo "$line" | grep -oE 'mark=[^ ]+' | head -1 | cut -d= -f2)
        local mark_dec
        mark_dec=$(printf '%d' "${mark:-0}" 2>/dev/null) || mark_dec=0
        [ $(( mark_dec & nss_dec )) -ne 0 ] && count=$((count+1))
    done < "$CONNTRACK_FILE"
    echo "$count"
}

# ─── Debug: show conntrack lines matching our mark ────────────────────────────
ct_debug_mark() {
    ui_section "Conntrack entries with NSS-Switch mark ($NSS_MARK)"
    local found=0
    while IFS= read -r line; do
        local mark
        mark=$(echo "$line" | grep -oE 'mark=[^ ]+' | head -1 | cut -d= -f2)
        local mark_dec
        mark_dec=$(printf '%d' "${mark:-0}" 2>/dev/null) || mark_dec=0
        local nss_dec
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
