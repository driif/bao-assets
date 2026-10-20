#!/bin/sh
# Dev server (HTTP on :8200, root token "root") plus the KMIP listener on :5696.
cd "$(dirname "$0")"
exec ./bao server -dev -dev-root-token-id=root -config=kmip-listener.hcl
