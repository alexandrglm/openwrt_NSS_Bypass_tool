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

