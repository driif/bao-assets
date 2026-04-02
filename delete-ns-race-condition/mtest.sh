#!/bin/bash
set -e

# --- Configuration ---
BAO="/Users/driif/Documents/dev/openbao/bin/bao"              # Change to path of your bao CLI binary
NS="mountrace"
KV_PATH="testkv"
NUM_WRITERS=2
NUM_WRITES=20
NUM_READERS=2
NUM_READS=20

# --- Environment Setup ---
export BAO_ADDR='http://127.0.0.1:8200'

# Clean up previous runs just in case
echo "==> Cleaning up any previous test runs..."
$BAO namespace delete "$NS" >/dev/null 2>&1 || true
rm -f writer_log.txt reader_log.txt

# --- Test Preparation ---
echo "==> Creating namespace: $NS"
$BAO namespace create "$NS"

echo "==> Enabling KV v1 at $KV_PATH in $NS"
$BAO secrets enable -ns="$NS" -path="$KV_PATH" -version=1 kv

echo "==> Pre-populating KV store with test data for readers"
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

echo "==> Mount now contains a large number of entries to slow deletion."
echo "==> Ready to race deletion..."
read -p "Press Enter to start the race..."

# --- Race Condition Test ---

# Start mount deletion in the background
(
    echo "==> Disabling KV mount $KV_PATH in $NS (background job)"
    $BAO secrets disable -ns="$NS" "$KV_PATH"
    echo "==> Mount deletion command finished."
) &

# Immediately start concurrent readers and writers
(
    # Start writer processes
    for i in $(seq 1 $NUM_WRITERS); do
        (
            # Each writer attempts a number of writes
            for j in $(seq 1 $NUM_WRITES); do
                # Log the attempt and the full command output/error
                echo "--- Writer $i, Write $j ---" >> writer_log.txt
                $BAO kv put -ns="$NS" "$KV_PATH/writer-$i/key-$j" value="writer-$i-data-$j" >> writer_log.txt 2>&1 || true
                sleep 0.01 # Small delay
            done
        ) &
    done

    # Start reader processes
    for i in $(seq 1 $NUM_READERS); do
        (
            # Each reader attempts a number of reads
            for j in $(seq 1 $NUM_READS); do
                # Pick a random initial key to read
                key_to_read=$(( ( RANDOM % 50 ) + 1 ))
                # Log the attempt and the full command output/error
                echo "--- Reader $i, Read $j (key: initial$key_to_read) ---" >> reader_log.txt
                $BAO kv get -ns="$NS" "$KV_PATH/initial$key_to_read" >> reader_log.txt 2>&1 || true
                sleep 0.01 # Small delay
            done
        ) &
    done
)

# --- Analysis and Cleanup ---
echo "==> Waiting for all race operations to complete..."
wait

echo "==> Race finished."
echo ""
echo "========================================"
echo "==> Analysis of Results"
echo "========================================"

echo "--- Writer Log ---"
if [ -f "writer_log.txt" ]; then
    cat writer_log.txt
else
    echo "No writer log found."
fi
echo "--------------------"

echo ""
echo "--- Reader Log ---"
if [ -f "reader_log.txt" ]; then
    cat reader_log.txt
else
    echo "No reader log found."
fi
echo "--------------------"


echo ""
echo "==> Cleaning up..."
# Clean up the log files
rm -f writer_log.txt reader_log.txt

# Clean up the namespace
$BAO namespace delete "$NS" || echo "Namespace $NS already deleted or failed to delete."

echo "==> Test complete."
