#!/bin/sh
# Configures a dev server started with start-bao.sh. Nothing KMIP-specific is
# configured in transit: only cert auth roles and plain ACL policies.
set -e
cd "$(dirname "$0")"
CERTS=./certs
export BAO_ADDR='http://127.0.0.1:8200'
export BAO_TOKEN='root'

echo "==> One transit mount per client"
./bao secrets enable -path=transit-mongodb transit || true
./bao secrets enable -path=transit-mysql transit || true

echo "==> Policies"
./bao policy write kmip-mongodb policies/kmip-mongodb.hcl
./bao policy write kmip-mysql policies/kmip-mysql.hcl

echo "==> Cert auth (the mount named by the listener's auth_mount)"
./bao auth enable cert || true

# certificate: CA that must have issued the client cert.
# allowed_common_names: which cert this role matches (no role name is sent at login).
# kmip_transit_mount: where this client's keys live.
# kmip_key_prefix: name prefix for keys the client creates without a Name.
./bao write auth/cert/certs/mongodb \
  certificate=@"$CERTS/ca.crt" \
  allowed_common_names="mongodb-kmip" \
  token_policies="kmip-mongodb" \
  token_type=batch token_ttl=1h \
  kmip_transit_mount="transit-mongodb" \
  kmip_key_prefix="mongodb-"

./bao write auth/cert/certs/mysql \
  certificate=@"$CERTS/ca.crt" \
  allowed_common_names="mysql-kmip" \
  token_policies="kmip-mysql" \
  token_type=batch token_ttl=1h \
  kmip_transit_mount="transit-mysql" \
  kmip_key_prefix="mysql-"

echo "==> Verify"
./bao read auth/cert/certs/mongodb | grep kmip_
./bao read auth/cert/certs/mysql | grep kmip_
nc -zv 127.0.0.1 5696 && echo "Port 5696 OK" || echo "FAIL: port 5696 not open"
