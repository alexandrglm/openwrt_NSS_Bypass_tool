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
