#!/usr/bin/env ash
# lib/chandler.sh: C compiled bin handler

BIN_DIR="/usr/bin/NSS-Switch/bin"
LIB_DIR="/usr/bin/NSS-Switch/lib"

# LISTA BINARIOS MIGRADOS
# conntrack.sh -> ct_dump_full_all
HAS_CT_DUMP="no"
if [ -f "$BIN_DIR/nss-ct-dump" ] && [ -x "$BIN_DIR/nss-ct-dump" ]; then
    HAS_CT_DUMP="yes"
    CT_DUMP_BIN="$BIN_DIR/nss-ct-dump"
fi

# Exportar
export HAS_CT_DUMP
export BIN_DIR
export LIB_DIR
export CT_DUMP_BIN

