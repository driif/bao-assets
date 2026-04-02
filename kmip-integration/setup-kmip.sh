#!/bin/sh
set -e
CERTS="./certs"

export BAO_ADDR='http://127.0.0.1:8200'
export BAO_TOKEN='root'

echo "==> Enabling transit engine..."
./bao secrets enable transit || true

echo "==> Configuring KMIP server on 0.0.0.0:5696..."
./bao write transit/config/kmip \
  enabled=true \
  listen_addr="0.0.0.0:5696" \
  server_cert_pem=@"$CERTS/server.crt" \
  server_key_pem=@"$CERTS/server.key" \
  tls_ca_cert_pem=@"$CERTS/ca.crt" \
  require_client_cert=true

echo "==> Creating KMIP role for Percona MongoDB..."
./bao write transit/kmip/roles/mongodb-kmip \
  cert_subject_dn="CN=mongodb-kmip,O=test,C=US" \
  allowed_operations="Create,Register,Get,GetAttributes,Locate,Activate,Destroy,Query"

echo "==> Creating KMIP role for Percona MySQL..."
./bao write transit/kmip/roles/mysql-kmip \
  cert_subject_dn="CN=mysql-kmip,O=test,C=US" \
  allowed_operations="Create,Register,Get,GetAttributes,Locate,Activate,Destroy,Query"

echo "==> Verifying setup..."
./bao read transit/config/kmip
./bao list transit/kmip/roles

echo ""
echo "==> Verifying KMIP port is listening..."
nc -zv 127.0.0.1 5696 && echo "Port 5696 OK" || echo "FAIL: port 5696 not open"
