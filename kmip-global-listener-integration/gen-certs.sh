#!/bin/bash
# One test CA signs everything. In a real deployment the server cert and the
# client certs usually come from different CAs; see README.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)/certs"
mkdir -p "$DIR"
cd "$DIR"

echo "==> CA"
openssl genrsa -out ca.key 4096
openssl req -new -x509 -days 3650 -key ca.key -out ca.crt -subj "/CN=KmipTestCA/O=test/C=US"

echo "==> OpenBao KMIP server cert (SAN: localhost, host.docker.internal, 127.0.0.1)"
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr -subj "/CN=localhost/O=test/C=US"
openssl x509 -req -days 3650 -in server.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out server.crt \
  -extfile <(printf "subjectAltName=DNS:localhost,DNS:host.docker.internal,IP:127.0.0.1\nextendedKeyUsage=serverAuth")

# client <name>: CN=<name>-kmip, clientAuth EKU. Cert auth verifies the chain for client auth; a cert with no EKU at all also passes.
client() {
  openssl genrsa -out "$1-client.key" 2048
  openssl req -new -key "$1-client.key" -out "$1-client.csr" -subj "/CN=$1-kmip/O=test/C=US"
  openssl x509 -req -days 3650 -in "$1-client.csr" -CA ca.crt -CAkey ca.key \
    -CAcreateserial -out "$1-client.crt" -extfile <(printf "extendedKeyUsage=clientAuth")
}

echo "==> client certs: mongodb, mysql, rogue (matches no cert role)"
client mongodb
client mysql
client rogue
# MongoDB wants cert and key in one PEM file.
cat mongodb-client.crt mongodb-client.key > mongodb-client-combined.pem

echo "Done. Certs in $DIR"
