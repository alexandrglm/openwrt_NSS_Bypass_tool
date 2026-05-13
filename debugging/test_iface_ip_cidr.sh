#!/usr/bin/env ash

_ip_to_dec() {
    local ip="$1"
    local a b c d
    a=$(echo "$ip" | cut -d'.' -f1)
    b=$(echo "$ip" | cut -d'.' -f2)
    c=$(echo "$ip" | cut -d'.' -f3)
    d=$(echo "$ip" | cut -d'.' -f4)
    echo $(( (a<<24) + (b<<16) + (c<<8) + d ))
}

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

ct_iface_for_src() {
    local src="$1"
    local found=""
    local tmp
    tmp=$(mktemp /tmp/nss-iface.XXXXXX)

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
    ' > "$tmp"

    while IFS=' ' read -r ip cidr iface; do
        if [ "$src" = "$ip" ]; then
            rm -f "$tmp"
            echo "local:$iface"
            return
        fi
        if _ct_ip_in_cidr "$src" "$cidr"; then
            found="$iface"
        fi
    done < "$tmp"

    rm -f "$tmp"
    [ -n "$found" ] && echo "$found" && return
    echo "?"
}

echo "=== ct_iface_for_src ==="
echo "192.168.1.128 → $(ct_iface_for_src 192.168.1.128)"
echo "192.168.2.193 → $(ct_iface_for_src 192.168.2.193)"
echo "192.168.3.192 → $(ct_iface_for_src 192.168.3.192)"
echo "79.116.179.218 → $(ct_iface_for_src 79.116.179.218)"
echo "192.168.1.1   → $(ct_iface_for_src 192.168.1.1)"
echo "192.168.2.1   → $(ct_iface_for_src 192.168.2.1)"
echo "10.0.3.98     → $(ct_iface_for_src 10.0.3.98)"
echo "1.1.1.1       → $(ct_iface_for_src 1.1.1.1)"
EOF
