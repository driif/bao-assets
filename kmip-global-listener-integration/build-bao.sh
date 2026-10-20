#!/bin/sh
# Builds ./bao from the OpenBao checkout's working tree (uncommitted KMIP changes included).
set -e
SRC="${OPENBAO_SRC:-$HOME/Documents/work/bao/openbao}"
OUT="$(cd "$(dirname "$0")" && pwd)/bao"
cd "$SRC"
GOTOOLCHAIN="go$(cat .go-version)" go build -o "$OUT" .
echo "built $OUT from $SRC"
