#!/usr/bin/env ash
# lib/chandler.sh: C compiled bin handler

# Rutas hardcodeadas porque si no es una puta pesadilla con los symlinks
BIN_DIR="/usr/bin/NSS-Switch/bin"
LIB_DIR="/usr/bin/NSS-Switch/lib"

# LISTA BINARIOS MIGRADOS
# conntrack.sh -> ct_dump_full_all
HAS_CT_DUMP="no"
if [ -f "$BIN_DIR/nss-ct-dump_aarch64" ] && [ -x "$BIN_DIR/nss-ct-dump_aarch64" ]; then
    HAS_CT_DUMP="yes"
    CT_DUMP_BIN="$BIN_DIR/nss-ct-dump_aarch64"
fi

# Exportar
export HAS_CT_DUMP
export BIN_DIR
export LIB_DIR
export CT_DUMP_BIN

# echo "DEBUG chandler.sh: BIN_DIR=$BIN_DIR" >&2
# echo "DEBUG chandler.sh: HAS_CT_DUMP=$HAS_CT_DUMP" >&2
