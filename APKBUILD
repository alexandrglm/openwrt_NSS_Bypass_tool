# Maintainer: Alexander Gomez <alexandrglm@proton.me>
pkgname=nss-switch
pkgver=1.0.0
pkgrel=1
pkgdesc="Qualcomm NSS Bypass tool"
url="https://github.com/alexandrglm/openwrt_NSS_Bypass_tool"
arch="noarch"
license="GPL"
depends=""
makedepends=""
options="!check !strip !scanelf !checkdepends !default_install"
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
e4e494caa1a680f9bbae8696e88f0f800d495eac35418e49110c6d6047ffc9ee1295fb1c2b108cf555db15a2ab3759865677220f0be48790b49c0368c6409041  source.tar.gz
"
