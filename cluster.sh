#!/bin/bash

# =============================================================================
#
#  FINAL Cluster Manager Script with Separate Steps & Bulletproof Cleanup
#
# =============================================================================

# --- Configuration ---
VAULT_BINARY="./bao"
LEADER_CONFIG="leader.hcl"
STANDBY_CONFIG="standby.hcl"
LEADER_ADDR="http://127.0.0.1:8200"
STANDBY_ADDR="http://127.0.0.1:8210"
PID_FILE=".vault_pids"
CREDS_FILE="vault-credentials.txt"

# --- Colors for better output ---
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_RED='\033[0;31m'
COLOR_NC='\033[0m'

# --- Helper Functions ---
info() { echo -e "\n${COLOR_GREEN}[INFO]${COLOR_NC} $1"; }
warn() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_NC} $1"; }
error() { echo -e "${COLOR_RED}[ERROR]${COLOR_NC} $1" >&2; exit 1; }

# --- Main Script Logic ---
case "$1" in
    up-leader)
        info "Bringing up the LEADER node..."
        # First, run the new bulletproof shutdown to ensure a clean slate
        $0 down

        mkdir -p ./data-primary ./data-standby
        if ! command -v jq &> /dev/null; then error "'jq' is not installed."; fi

        info "Starting leader server in the background..."
        $VAULT_BINARY server -config=$LEADER_CONFIG > leader.log 2>&1 &
        echo $! > $PID_FILE

        info "Waiting 5 seconds for leader process to start..."
        sleep 5

        info "Initializing and Unsealing the leader node..."
        export VAULT_ADDR=$LEADER_ADDR
        INIT_OUTPUT=$($VAULT_BINARY operator init -key-shares=5 -key-threshold=3 -format=json)
        if [ $? -ne 0 ]; then error "Vault initialization failed. Check leader.log."; fi

        ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r .root_token)
        UNSEAL_KEYS=($(echo "$INIT_OUTPUT" | jq -r .unseal_keys_b64[]))
        if [ -z "$ROOT_TOKEN" ]; then error "Failed to parse root token."; fi

        echo "$ROOT_TOKEN" > $CREDS_FILE
        printf '%s\n' "${UNSEAL_KEYS[@]}" >> $CREDS_FILE
        info "Unseal keys and root token saved to ${COLOR_YELLOW}$CREDS_FILE${COLOR_NC}"

        for i in {0..2}; do $VAULT_BINARY operator unseal ${UNSEAL_KEYS[$i]} > /dev/null; done

        $VAULT_BINARY status | grep "HA Mode"
        info "Leader cluster is UP and UNSEALED."
        warn "You can now run './cluster-manager.sh up-standby'."
        ;;

    up-standby)
        info "Bringing up the STANDBY node..."
        if [ ! -f "$CREDS_FILE" ]; then error "Cannot find '$CREDS_FILE'. Please run 'up-cluster' first."; fi

        info "Starting standby server in the background..."
        $VAULT_BINARY server -config=$STANDBY_CONFIG > standby.log 2>&1 &
        echo $! >> $PID_FILE

        info "Waiting 7 seconds for standby to start and find the leader..."
        sleep 7

        info "Unsealing the standby node..."
        export VAULT_ADDR=$STANDBY_ADDR
        UNSEAL_KEYS=($(tail -n 5 $CREDS_FILE))
        for i in {0..2}; do $VAULT_BINARY operator unseal ${UNSEAL_KEYS[$i]} > /dev/null; done

        sleep 2 # Final wait for roles to sync
        $VAULT_BINARY status | grep "HA Mode"
        info "Standby node is UP and UNSEALED."
        warn "Run './cluster-manager.sh status' to see the state of the full cluster."
        ;;

    status)
        info "Checking Full Cluster Status..."
        echo "--------------------------------------------------"
        export VAULT_ADDR=$LEADER_ADDR
        echo -e "${COLOR_YELLOW}Leader Status ($LEADER_ADDR):${COLOR_NC}"
        $VAULT_BINARY status
        echo "--------------------------------------------------"
        export VAULT_ADDR=$STANDBY_ADDR
        echo -e "${COLOR_YELLOW}Standby Status ($STANDBY_ADDR):${COLOR_NC}"
        $VAULT_BINARY status
        echo "--------------------------------------------------"
        ;;

    down)
        info "Shutting down all cluster nodes and cleaning up..."
        # --- The NEW Bulletproof Shutdown Command ---
        # This finds any process with "./bao server" in its command line and kills it.
        pkill -f "$VAULT_BINARY server -config="
        sleep 1

        # This removes all generated files.
        rm -f .vault_pids *.log vault-credentials.txt*
        rm -rf ./data-primary ./data-standby
        info "Cleanup complete."
        ;;

    *)
        echo "Usage: $0 {up-cluster|up-standby|status|down}"
        exit 1
        ;;
esac
