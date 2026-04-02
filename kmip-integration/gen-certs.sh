#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)/certs"
mkdir -p "$DIR"
cd "$DIR"

echo "==> Generating CA..."
openssl genrsa -out ca.key 4096
openssl req -new -x509 -days 3650 -key ca.key -out ca.crt \
  -subj "/CN=KmipTestCA/O=test/C=US"

echo "==> Generating OpenBao KMIP server cert (SAN: localhost + host.docker.internal)..."
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr \
  -subj "/CN=localhost/O=test/C=US"
openssl x509 -req -days 3650 -in server.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out server.crt \
  -extfile <(printf "subjectAltName=DNS:localhost,DNS:host.docker.internal,IP:127.0.0.1")

echo "==> Generating MongoDB client cert..."
openssl genrsa -out mongodb-client.key 2048
openssl req -new -key mongodb-client.key -out mongodb-client.csr \
  -subj "/CN=mongodb-kmip/O=test/C=US"
openssl x509 -req -days 3650 -in mongodb-client.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out mongodb-client.crt
# MongoDB requires cert+key in a single PEM file
cat mongodb-client.crt mongodb-client.key > mongodb-client-combined.pem

echo "==> Generating MySQL client cert..."
openssl genrsa -out mysql-client.key 2048
openssl req -new -key mysql-client.key -out mysql-client.csr \
  -subj "/CN=mysql-kmip/O=test/C=US"
openssl x509 -req -days 3650 -in mysql-client.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out mysql-client.crt

echo "Done. Certs in $DIR"
