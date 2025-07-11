#!/bin/bash
set -e

BAO="/Users/driif/Documents/dev/openbao/bin/bao"                         # change to path of your bao CLI binary
NS="stressns"
PKI_PATH="pki"
NUM_ROLES=100
NUM_CERTS=100

export BAO_ADDR='http://127.0.0.1:8200'

echo "==> Creating namespace: $NS"
$BAO namespace create "$NS"

echo "==> Enabling PKI at $PKI_PATH in $NS"
$BAO secrets enable -ns="$NS" -path="$PKI_PATH" pki

echo "==> Tuning PKI engine"
$BAO secrets tune -ns="$NS" -max-lease-ttl=87600h "$PKI_PATH"

echo "==> Generating root for PKI"
$BAO write -ns="$NS" "$PKI_PATH/root/generate/internal" \
    common_name="example.com" ttl=87600h >/dev/null

echo "==> Creating $NUM_ROLES roles in PKI"
for i in $(seq 1 $NUM_ROLES); do
    $BAO write -ns="$NS" "$PKI_PATH/roles/role$i" \
        allowed_domains="example.com" allow_subdomains=true \
        max_ttl="72h" >/dev/null
done

echo "==> Issuing $NUM_CERTS certs..."
for i in $(seq 1 $NUM_CERTS); do
    $BAO write -ns="$NS" "$PKI_PATH/issue/role1" \
        common_name="host$i.example.com" ttl=24h >/dev/null 2>&1 || true
done

for i in $(seq 1 20); do
  $BAO secrets enable -ns="$NS" -path="kv$i" kv || true
done

for i in $(seq 1 5); do
  $BAO auth enable -ns="$NS" -path="userpass$i" userpass || true
done

for mount in $(seq 1 20); do
  for j in $(seq 1 100); do
    $BAO kv put -ns="$NS" "kv${mount}/test${j}" foo=bar >/dev/null 2>&1 || true
  done
done

echo "==> Ready to race deletion..."

(
  echo "==> Deleting namespace $NS"
  $BAO namespace delete "$NS"
) &

(
  echo "==> Disabling PKI engine $PKI_PATH in $NS"
  $BAO secrets disable -ns="$NS" "$PKI_PATH"
) &

wait

echo "==> Deletion race trigger complete. Checking state:"
$BAO namespace list
