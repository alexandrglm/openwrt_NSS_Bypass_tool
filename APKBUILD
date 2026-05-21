# Maintainer: Alexander Gomez <alexandrglm@proton.me>
pkgname=nss-switch
pkgver=1.0.0
pkgrel=1
pkgdesc="Qualcomm NSS Bypass tool"
url="https://github.com/alexandrglm/openwrt_NSS_Bypass_tool"
arch="noarch"
license="MIT"
depends=""
makedepends=""
options="!check !strip !scanelf"
source="source.tar.gz"
install="nss-switch.post-install nss-switch.pre-deinstall"

prepare() {
    mkdir -p "$builddir"
    cp -r "$startdir/source"/* "$builddir/" 2>/dev/null || true
}

build() {
    return 0
}

package() {
    # Install main executable
    install -Dm755 "$builddir/usr/bin/NSS-Switch/nss-switch.sh" "$pkgdir/usr/bin/NSS-Switch/nss-switch.sh"

    # Install config
    install -Dm644 "$builddir/usr/bin/NSS-Switch/config" "$pkgdir/usr/bin/NSS-Switch/config"

    # Install libraries
    for lib in ui ecm conntrack nft detect rules debug; do
        install -Dm755 "$builddir/usr/bin/NSS-Switch/lib/${lib}.sh" "$pkgdir/usr/bin/NSS-Switch/lib/${lib}.sh"
    done

    # Install firewall hook
    install -Dm755 "$builddir/usr/bin/NSS-Switch/firewall.d/nss-bypass" "$pkgdir/usr/bin/NSS-Switch/firewall.d/nss-bypass"

    # Install state directory with empty rules.conf
    mkdir -p "$pkgdir/usr/bin/NSS-Switch/state"
    echo "# NSS-Switch rules — id|proto|src_ip|dst_ip|src_port|dst_port|iface|persist|comment" > "$pkgdir/usr/bin/NSS-Switch/state/rules.conf"
    chmod 644 "$pkgdir/usr/bin/NSS-Switch/state/rules.conf"

    # Install lifecycle scripts en el mismo directorio que espera post-install
    install -Dm755 "$builddir/usr/bin/NSS-Switch/lifecycle/nss-switch_postinst.source" "$pkgdir/usr/bin/NSS-Switch/lifecycle/nss-switch_postinst.source"
    install -Dm755 "$builddir/usr/bin/NSS-Switch/lifecycle/nss-switch_prerm.source" "$pkgdir/usr/bin/NSS-Switch/lifecycle/nss-switch_prerm.source"
}
sha512sums="
f9b402d24998d9ffa7f7ca6aaeada3ee1f9fd938e9826850576f259c8897cc12a65ecb3d8d3c37d8f8e2535cd70e27fb856683d235255882277984f5be07a037  source.tar.gz
"
