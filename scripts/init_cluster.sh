#!/bin/bash
# AiKv Cluster Initialization Script
#
# This script initializes an AiKv cluster using AiKv's MetaRaft commands:
# 1. Add master nodes (except bootstrap) as learners via CLUSTER METARAFT ADDLEARNER
# 2. Promote learners to voters via CLUSTER METARAFT PROMOTE
# 3. Meet all nodes using CLUSTER MEET
# 4. Assign hash slots to master nodes using CLUSTER ADDSLOTSRANGE
# 5. Set up replication using CLUSTER ADDREPLICATION
#
# AiKv uses OpenRaft-based Multi-Raft architecture, different from Redis Cluster.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default configuration
MASTERS=("127.0.0.1:6379" "127.0.0.1:6381" "127.0.0.1:6383")
REPLICAS=("127.0.0.1:6380" "127.0.0.1:6382" "127.0.0.1:6384")
REDIS_CLI="${REDIS_CLI:-redis-cli}"

# Print functions
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Initialize an AiKv cluster with specified nodes.

Options:
    -m, --masters HOSTS     Comma-separated list of master nodes (host:port)
    -r, --replicas HOSTS    Comma-separated list of replica nodes (host:port)
    -h, --help              Show this help message

Example:
    $0 -m 127.0.0.1:6379,127.0.0.1:6381,127.0.0.1:6383 \\
       -r 127.0.0.1:6380,127.0.0.1:6382,127.0.0.1:6384

    This creates a 6-node cluster with 3 masters and 3 replicas:
    - Master 1: 127.0.0.1:6379 -> Replica: 127.0.0.1:6380
    - Master 2: 127.0.0.1:6381 -> Replica: 127.0.0.1:6382
    - Master 3: 127.0.0.1:6383 -> Replica: 127.0.0.1:6384

Default (when no options provided):
    Masters: 127.0.0.1:6379, 127.0.0.1:6381, 127.0.0.1:6383
    Replicas: 127.0.0.1:6380, 127.0.0.1:6382, 127.0.0.1:6384

EOF
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -m|--masters)
            IFS=',' read -ra MASTERS <<< "$2"
            shift 2
            ;;
        -r|--replicas)
            IFS=',' read -ra REPLICAS <<< "$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate configuration
MASTER_COUNT=${#MASTERS[@]}
REPLICA_COUNT=${#REPLICAS[@]}

print_info "Cluster Configuration:"
echo "  Masters: ${MASTER_COUNT}"
for i in "${!MASTERS[@]}"; do
    echo "    Master $((i+1)): ${MASTERS[$i]}"
done
echo "  Replicas: ${REPLICA_COUNT}"
for i in "${!REPLICAS[@]}"; do
    echo "    Replica $((i+1)): ${REPLICAS[$i]}"
done
echo

if [ ${MASTER_COUNT} -lt 3 ]; then
    print_error "At least 3 master nodes are required for a cluster"
    exit 1
fi

# Function to get node ID
get_node_id() {
    local host=$1
    local port=$2
    ${REDIS_CLI} -h ${host} -p ${port} CLUSTER MYID 2>&1
}

# Function to check if node is reachable
check_node() {
    local host=$1
    local port=$2
    if ${REDIS_CLI} -h ${host} -p ${port} PING 2>&1 | grep -q "PONG"; then
        return 0
    else
        return 1
    fi
}

# Step 1: Check all nodes are reachable
print_info "Step 1: Checking node connectivity..."
ALL_NODES=("${MASTERS[@]}" "${REPLICAS[@]}")
for node in "${ALL_NODES[@]}"; do
    IFS=':' read -r host port <<< "${node}"
    if check_node ${host} ${port}; then
        print_success "Node ${node} is reachable"
    else
        print_error "Node ${node} is not reachable"
        exit 1
    fi
done
echo

# Step 2: Get node IDs for all masters
print_info "Step 2: Retrieving master node IDs..."
declare -A MASTER_IDS
for i in "${!MASTERS[@]}"; do
    node="${MASTERS[$i]}"
    IFS=':' read -r host port <<< "${node}"
    node_id=$(get_node_id ${host} ${port})
    if [ -z "${node_id}" ] || [ "${node_id}" == "(nil)" ]; then
        print_error "Failed to get node ID for ${node}"
        exit 1
    fi
    MASTER_IDS["${node}"]="${node_id}"
    echo "  Master $((i+1)) ${node} -> ID ${node_id}"
done
echo

# Step 3: Add non-bootstrap masters as learners via MetaRaft
print_info "Step 3: Adding masters as MetaRaft learners..."
# Node 1 (bootstrap) is already a voter, add nodes 2 and 3 as learners
if [ ${MASTER_COUNT} -gt 1 ]; then
    node2="${MASTERS[1]}"
    node2_id="${MASTER_IDS[$node2]}"
    IFS=':' read -r host2 port2 <<< "${node2}"
    # Get Raft address for node 2 (port 50053 for second master)
    raft_port2=$((50051 + (${port2#127.0.0.1:} - 6379) + 50051 - 6379 + 1))
    # Actually, calculate raft port based on container hostname pattern
    # master-1 -> 50051, master-2 -> 50053, master-3 -> 50055
    if [[ ${node2} == *"6381"* ]]; then
        raft_addr="aikv-master-2:50053"
    elif [[ ${node2} == *"6383"* ]]; then
        raft_addr="aikv-master-3:50055"
    fi

    print_info "Adding ${node2} as learner..."
    if ! ${REDIS_CLI} -h ${host2} -p ${port2} CLUSTER METARAFT ADDLEARNER 2 ${raft_addr} 2>&1 | grep -q "OK"; then
        # Try from bootstrap node
        bs_host="${MASTERS[0]%:*}"
        bs_port="${MASTERS[0]#*:}"
        ${REDIS_CLI} -h ${bs_host} -p ${bs_port} CLUSTER METARAFT ADDLEARNER 2 ${raft_addr} 2>&1
    fi
fi

if [ ${MASTER_COUNT} -gt 2 ]; then
    node3="${MASTERS[2]}"
    node3_id="${MASTER_IDS[$node3]}"
    IFS=':' read -r host3 port3 <<< "${node3}"
    if [[ ${node3} == *"6381"* ]]; then
        raft_addr="aikv-master-2:50053"
    elif [[ ${node3} == *"6383"* ]]; then
        raft_addr="aikv-master-3:50055"
    fi

    print_info "Adding ${node3} as learner..."
    bs_host="${MASTERS[0]%:*}"
    bs_port="${MASTERS[0]#*:}"
    ${REDIS_CLI} -h ${bs_host} -p ${bs_port} CLUSTER METARAFT ADDLEARNER 3 ${raft_addr} 2>&1
fi
echo

# Step 4: Promote learners to voters
print_info "Step 4: Promoting learners to voters..."
sleep 2
bs_host="${MASTERS[0]%:*}"
bs_port="${MASTERS[0]#*:}"
promote_output=$(${REDIS_CLI} -h ${bs_host} -p ${bs_port} CLUSTER METARAFT PROMOTE 2 3 2>&1)
if echo "${promote_output}" | grep -q "OK"; then
    print_success "Learners promoted to voters"
else
    print_warn "METARAFT PROMOTE output: ${promote_output}"
fi
echo

# Step 5: Meet all nodes
print_info "Step 5: Meeting all nodes..."
bs_host="${MASTERS[0]%:*}"
bs_port="${MASTERS[0]#*:}"

# Get all node IDs
declare -A ALL_NODE_IDS
for node in "${ALL_NODES[@]}"; do
    IFS=':' read -r host port <<< "${node}"
    node_id=$(get_node_id ${host} ${port})
    ALL_NODE_IDS["${node}"]="${node_id}"
done

# Meet all masters first (including self)
for node in "${MASTERS[@]}"; do
    node_id="${ALL_NODE_IDS[$node]}"
    IFS=':' read -r host port <<< "${node}"
    print_info "Meeting ${node} (ID: ${node_id})..."
    ${REDIS_CLI} -h ${bs_host} -p ${bs_port} CLUSTER MEET ${host} ${port} ${node_id} 2>&1 | grep -q "OK" || true
done

# Meet replicas
for node in "${REPLICAS[@]}"; do
    node_id="${ALL_NODE_IDS[$node]}"
    IFS=':' read -r host port <<< "${node}"
    print_info "Meeting ${node} (ID: ${node_id})..."
    ${REDIS_CLI} -h ${bs_host} -p ${bs_port} CLUSTER MEET ${host} ${port} ${node_id} 2>&1 | grep -q "OK" || true
done

sleep 3
print_success "All nodes met"
echo

# Step 6: Assign hash slots to masters
print_info "Step 6: Assigning hash slots to masters..."
TOTAL_SLOTS=16384
SLOTS_PER_MASTER=$((TOTAL_SLOTS / MASTER_COUNT))

for i in "${!MASTERS[@]}"; do
    master="${MASTERS[$i]}"
    master_id="${ALL_NODE_IDS[$master]}"
    IFS=':' read -r host port <<< "${master}"

    start_slot=$((i * SLOTS_PER_MASTER))
    if [ $i -eq $((MASTER_COUNT - 1)) ]; then
        end_slot=$((TOTAL_SLOTS - 1))
    else
        end_slot=$((start_slot + SLOTS_PER_MASTER - 1))
    fi

    print_info "Assigning slots ${start_slot}-${end_slot} to ${master} (ID: ${master_id})..."

    # For first master (bootstrap), no node_id needed
    if [ $i -eq 0 ]; then
        ${REDIS_CLI} -h ${host} -p ${port} CLUSTER ADDSLOTSRANGE ${start_slot} ${end_slot} 2>&1 | grep -q "OK" || {
            print_error "Failed to assign slots to ${master}"
            exit 1
        }
    else
        # For other masters, specify node_id
        bs_host="${MASTERS[0]%:*}"
        bs_port="${MASTERS[0]#*:}"
        ${REDIS_CLI} -h ${bs_host} -p ${bs_port} CLUSTER ADDSLOTSRANGE ${start_slot} ${end_slot} ${master_id} 2>&1 | grep -q "OK" || {
            print_error "Failed to assign slots to ${master}"
            exit 1
        }
    fi
    print_success "Assigned slots ${start_slot}-${end_slot} to ${master}"
done
echo

# Step 7: Set up replication
print_info "Step 7: Setting up replication..."

# Map replicas to masters (by index)
for i in "${!REPLICAS[@]}"; do
    replica="${REPLICAS[$i]}"
    replica_id="${ALL_NODE_IDS[$replica]}"
    master="${MASTERS[$i]}"
    master_id="${ALL_NODE_IDS[$master]}"

    IFS=':' read -r r_host r_port <<< "${replica}"

    print_info "Setting ${replica} as replica of ${master}..."

    bs_host="${MASTERS[0]%:*}"
    bs_port="${MASTERS[0]#*:}"

    if ${REDIS_CLI} -h ${bs_host} -p ${bs_port} CLUSTER ADDREPLICATION ${replica_id} ${master_id} 2>&1 | grep -q "OK"; then
        print_success "${replica} is now a replica of ${master}"
    else
        print_warn "Failed to set up replication for ${replica}"
    fi
done
echo

# Step 8: Verify cluster status
print_info "Step 8: Verifying cluster status..."
sleep 2

bs_host="${MASTERS[0]%:*}"
bs_port="${MASTERS[0]#*:}"

print_info "Cluster info from bootstrap node (${bs_host}:${bs_port}):"
${REDIS_CLI} -h ${bs_host} -p ${bs_port} CLUSTER INFO
echo

print_info "Cluster nodes:"
${REDIS_CLI} -h ${bs_host} -p ${bs_port} CLUSTER NODES
echo

print_success "Cluster initialization completed!"
echo
print_info "You can now connect to the cluster using:"
echo "  redis-cli -c -h ${bs_host} -p ${bs_port}"