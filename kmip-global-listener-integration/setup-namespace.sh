#!/bin/bash
# One listener, cert auth in root, keys in the child namespace tenant-a.
# Run after setup-kmip.sh. Safe to re-run.
set -e
cd "$(dirname "$0")"
CERTS=./certs
export BAO_ADDR='http://127.0.0.1:8200'
export BAO_TOKEN='root'

if [ ! -f "$CERTS/tenanta-client.crt" ]; then
  echo "==> Client cert CN=tenanta-kmip"
  openssl genrsa -out "$CERTS/tenanta-client.key" 2048
  openssl req -new -key "$CERTS/tenanta-client.key" -out "$CERTS/tenanta-client.csr" \
    -subj "/CN=tenanta-kmip/O=test/C=US"
  openssl x509 -req -days 3650 -in "$CERTS/tenanta-client.csr" -CA "$CERTS/ca.crt" \
    -CAkey "$CERTS/ca.key" -CAcreateserial -out "$CERTS/tenanta-client.crt" \
    -extfile <(printf "extendedKeyUsage=clientAuth")
fi

echo "==> Namespace tenant-a with its own transit mount"
./bao namespace create tenant-a || true
./bao secrets enable -ns=tenant-a -path=transit transit || true

echo "==> Policy and cert role, both in root"
./bao policy write kmip-tenanta policies/kmip-tenanta.hcl
./bao write auth/cert/certs/tenanta \
  certificate=@"$CERTS/ca.crt" \
  allowed_common_names="tenanta-kmip" \
  token_policies="kmip-tenanta" \
  token_type=batch token_ttl=1h \
  kmip_transit_mount="tenant-a/transit" \
  kmip_key_prefix="ta-"

echo "Done. Try: (cd smoke && go run . -as tenanta); ./bao list -ns=tenant-a transit/keys"
