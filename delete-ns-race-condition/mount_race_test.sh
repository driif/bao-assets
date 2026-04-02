#!/bin/bash
set -e

BAO="/Users/driif/Documents/dev/openbao/bin/bao"                         # change to path of your bao CLI binary
NS="mountrace"
KV_PATH="testkv"
NUM_WRITERS=5
NUM_WRITES=200

export BAO_ADDR='http://127.0.0.1:8200'

echo "==> Creating namespace: $NS"
$BAO namespace create "$NS"

echo "==> Enabling KV v1 at $KV_PATH in $NS"
$BAO secrets enable -ns="$NS" -path="$KV_PATH" -version=1 kv

echo "==> Pre-populating KV store with test data"
for i in $(seq 1 50); do
    $BAO kv put -ns="$NS" "$KV_PATH/initial$i" value="test$i" >/dev/null 2>&1 || true
done

echo "==> Adding bulk data to make deletion slower"
# Add lots of data with nested paths to make deletion take longer
for category in $(seq 1 20); do
    for subcategory in $(seq 1 10); do
        for item in $(seq 1 20); do
            $BAO kv put -ns="$NS" "$KV_PATH/bulk/cat${category}/sub${subcategory}/item${item}" \
                category="$category" \
                subcategory="$subcategory" \
                item="$item" \
                data="bulk-data-$(date +%s)-${RANDOM}" >/dev/null 2>&1 || true
        done
    done
done

echo "==> Adding large values to slow down deletion further"
# Add entries with large values
large_value=$(head -c 1000 /dev/zero | tr '\0' 'x')
for i in $(seq 1 100); do
    $BAO kv put -ns="$NS" "$KV_PATH/large/entry$i" \
        large_data="$large_value" \
        index="$i" >/dev/null 2>&1 || true
done

echo "==> Mount now contains ~4000+ entries to slow deletion"

echo "==> Ready to race deletion..."

# Start mount deletion first
(
    echo "==> Disabling KV mount $KV_PATH in $NS"
    $BAO secrets disable -ns="$NS" "$KV_PATH"
) &

# Start multiple writers that will try to write to the mount being deleted
sleep 0.01  # Small delay to let deletion start
for writer in $(seq 1 $NUM_WRITERS); do
    (
        echo "==> Writer $writer starting $NUM_WRITES operations to $KV_PATH (during deletion)"
        for i in $(seq 1 $NUM_WRITES); do
            $BAO kv put -ns="$NS" "$KV_PATH/writer${writer}_entry${i}" \
                writer="$writer" operation="$i" timestamp="$(date +%s)" >/dev/null 2>&1 || true
            sleep 0.001
        done
        echo "==> Writer $writer completed"
    ) &
done

wait

echo "==> Mount deletion race complete. Checking state:"

echo "==> Checking if mount still exists:"
$BAO secrets list -ns="$NS" || echo "Could not list mounts"

echo "==> Trying to access deleted mount (multiple methods):"

echo "  -> Method 1: KV get command"
$BAO kv get -ns="$NS" "$KV_PATH/initial1" 2>&1 || echo "KV get failed (expected)"

echo "  -> Method 2: Direct read via API"
$BAO read -ns="$NS" "$KV_PATH/initial1" 2>&1 || echo "Direct read failed (expected)"

echo "  -> Method 3: List keys in mount"
$BAO list -ns="$NS" "$KV_PATH/" 2>&1 || echo "List keys failed (expected)"

echo "  -> Method 4: Try to write new data"
$BAO kv put -ns="$NS" "$KV_PATH/test_after_delete" value="should_fail" 2>&1 || echo "Write after delete failed (expected)"

echo "  -> Method 6: Check if race-written data survived"
for writer in $(seq 1 3); do  # Check first few writers
    $BAO kv get -ns="$NS" "$KV_PATH/writer${writer}_entry1" 2>&1 | head -1 || true
done

echo "==> Checking namespace state:"
$BAO namespace lookup "$NS" | grep tainted || echo "Namespace not tainted (good)"

echo "==> Cleaning up:"
$BAO namespace delete "$NS"
