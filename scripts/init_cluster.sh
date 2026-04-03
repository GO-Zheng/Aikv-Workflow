#!/bin/bash
# AiKv 集群初始化脚本
#
# 本脚本使用 AiKv 的 MetaRaft 命令初始化集群:
# 1. 通过 CLUSTER METARAFT ADDLEARNER 将 master 节点（除 bootstrap 外）添加为 learner
# 2. 通过 CLUSTER METARAFT PROMOTE 将 learner 晋升为 voter
# 3. 通过 CLUSTER MEET 连接所有节点
# 4. 通过 CLUSTER ADDSLOTSRANGE 分配 hash slots 给 master 节点
# 5. 通过 CLUSTER ADDREPLICATION 设置主从复制关系
#
# AiKv 使用基于 OpenRaft 的 Multi-Raft 架构，区别于 Redis Cluster。

set -e

# 输出颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 默认配置
MASTERS=("127.0.0.1:6379" "127.0.0.1:6381" "127.0.0.1:6383")
REPLICAS=("127.0.0.1:6380" "127.0.0.1:6382" "127.0.0.1:6384")
REDIS_CLI="${REDIS_CLI:-redis-cli}"

# 打印函数
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

# 使用说明
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

# 验证配置
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

# 获取节点 ID 的函数
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

# 步骤 1: 检查所有节点是否可达
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

# 步骤 2: 获取所有 master 的节点 ID
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

# 步骤 3: 通过 MetaRaft 将非 bootstrap 的 master 添加为 learner
# 使用每个 master 的 **实际 node_id**（由 CLUSTER MYID 返回），而不是硬编码整数。
# 这样 MetaRaft membership 中的 node_id 与数据 Raft 组使用的 node_id 一致，
# 从而允许 peer_raft_grpc_addr() 通过 MetaRaft membership 查找正确的 gRPC 地址。
print_info "Step 3: Adding masters as MetaRaft learners..."
# Docker 容器内部 gRPC 端口映射: master-N 使用 raft_address 中配置的端口
declare -A RAFT_ADDRS
RAFT_ADDRS["127.0.0.1:6379"]="aikv-master-1:50051"
RAFT_ADDRS["127.0.0.1:6381"]="aikv-master-2:50053"
RAFT_ADDRS["127.0.0.1:6383"]="aikv-master-3:50055"

bs_host="${MASTERS[0]%:*}"
bs_port="${MASTERS[0]#*:}"

# 构建待晋升列表（实际 node_id）
promotion_master_ids=""

for i in "${!MASTERS[@]}"; do
    # 跳过 bootstrap（它已经是 voter）
    [ $i -eq 0 ] && continue

    node="${MASTERS[$i]}"
    node_id="${MASTER_IDS[$node]}"
    raft_addr="${RAFT_ADDRS[$node]}"

    if [ -z "${raft_addr}" ]; then
        print_error "No Raft address mapping for ${node}"
        exit 1
    fi

    print_info "Adding ${node} (ID: ${node_id}) as learner at ${raft_addr}..."
    ${REDIS_CLI} -h ${bs_host} -p ${bs_port} CLUSTER METARAFT ADDLEARNER ${node_id} ${raft_addr} 2>&1

    if [ -n "${promotion_master_ids}" ]; then
        promotion_master_ids="${promotion_master_ids} "
    fi
    promotion_master_ids="${promotion_master_ids}${node_id}"
done
echo

# Step 4: 晋升 learner 为 voter
print_info "Step 4: Promoting learners to voters..."
sleep 2
promote_output=$(${REDIS_CLI} -h ${bs_host} -p ${bs_port} CLUSTER METARAFT PROMOTE ${promotion_master_ids} 2>&1)
if echo "${promote_output}" | grep -q "OK"; then
    print_success "Learners promoted to voters"
else
    print_warn "METARAFT PROMOTE output: ${promote_output}"
fi
echo

# 步骤 5: 连接所有节点
print_info "Step 5: Meeting all nodes..."
bs_host="${MASTERS[0]%:*}"
bs_port="${MASTERS[0]#*:}"

# 获取所有节点 ID
declare -A ALL_NODE_IDS
for node in "${ALL_NODES[@]}"; do
    IFS=':' read -r host port <<< "${node}"
    node_id=$(get_node_id ${host} ${port})
    ALL_NODE_IDS["${node}"]="${node_id}"
done

# 首先连接所有 master（包括自身）
for node in "${MASTERS[@]}"; do
    node_id="${ALL_NODE_IDS[$node]}"
    IFS=':' read -r host port <<< "${node}"
    print_info "Meeting ${node} (ID: ${node_id})..."
    ${REDIS_CLI} -h ${bs_host} -p ${bs_port} CLUSTER MEET ${host} ${port} ${node_id} 2>&1 | grep -q "OK" || true
done

# 连接 replicas
for node in "${REPLICAS[@]}"; do
    node_id="${ALL_NODE_IDS[$node]}"
    IFS=':' read -r host port <<< "${node}"
    print_info "Meeting ${node} (ID: ${node_id})..."
    ${REDIS_CLI} -h ${bs_host} -p ${bs_port} CLUSTER MEET ${host} ${port} ${node_id} 2>&1 | grep -q "OK" || true
done

sleep 3
print_success "All nodes met"
echo

# 步骤 6: 分配 hash slots 给 masters
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

    # 第一个 master (bootstrap) 不需要指定 node_id
    if [ $i -eq 0 ]; then
        ${REDIS_CLI} -h ${host} -p ${port} CLUSTER ADDSLOTSRANGE ${start_slot} ${end_slot} 2>&1 | grep -q "OK" || {
            print_error "Failed to assign slots to ${master}"
            exit 1
        }
    else
        # 其他 master 需要指定 node_id
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

# 步骤 7: 设置主从复制
print_info "Step 7: Setting up replication..."

# 按索引映射 replicas 到 masters
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

# 步骤 7.5: 添加 replicas 到 MetaRaft 并提升为 voters
# 这是自动故障转移的关键 - replicas 必须是 MetaRaft voter 才能参与 leader 选举
print_info "Step 7.5: Adding replicas to MetaRaft and promoting to voters..."

bs_host="${MASTERS[0]%:*}"
bs_port="${MASTERS[0]#*:}"

# 获取当前的 MetaRaft members
print_info "Current MetaRaft members:"
${REDIS_CLI} -h ${bs_host} -p ${bs_port} CLUSTER METARAFT MEMBERS 2>/dev/null || true
echo ""

# 首先获取 replicas 的实际 node IDs（从 CLUSTER MYID 获取）
# 这些是 replica 节点通过 generate_node_id_from_addr() 生成的真实 ID
declare -A REPLICA_RAFT_IDS
declare -a REPLICA_RAFT_HOSTNAMES=("aikv-replica-1" "aikv-replica-2" "aikv-replica-3")

print_info "Getting actual node IDs for replicas from CLUSTER MYID..."
for i in "${!REPLICAS[@]}"; do
    replica="${REPLICAS[$i]}"
    raft_hostname="${REPLICA_RAFT_HOSTNAMES[$i]}"
    IFS=':' read -r r_host r_port <<< "${replica}"

    # Get actual node ID from the replica itself (this is the hash-based ID)
    replica_node_id=$(get_node_id ${r_host} ${r_port})
    if [ -z "${replica_node_id}" ] || [ "${replica_node_id}" == "(nil)" ]; then
        print_error "Failed to get node ID for replica ${replica}"
        exit 1
    fi
    REPLICA_RAFT_IDS["${replica}"]="${replica_node_id}"
    print_info "  Replica ${replica} -> Node ID ${replica_node_id}"
done

# 构建晋升列表
promotion_list=""
for replica in "${REPLICAS[@]}"; do
    raft_id="${REPLICA_RAFT_IDS[$replica]}"
    if [ -n "${promotion_list}" ]; then
        promotion_list="${promotion_list} "
    fi
    promotion_list="${promotion_list}${raft_id}"
done

# 添加 replicas 作为 MetaRaft learners
# 注意：地址使用 Docker 主机名和内部端口（50051），不是 127.0.0.1
# 因为 Raft leader 在容器内运行，必须用容器间可访问的地址
for i in "${!REPLICAS[@]}"; do
    replica="${REPLICAS[$i]}"
    raft_id="${REPLICA_RAFT_IDS[$replica]}"
    raft_hostname="${REPLICA_RAFT_HOSTNAMES[$i]}"
    # 内部端口 50051（每个容器的 gRPC 监听端口）
    raft_addr="${raft_hostname}:50051"

    print_info "Adding ${replica} (Raft ID: ${raft_id}, addr: ${raft_addr}) as MetaRaft learner..."
    add_output=$(${REDIS_CLI} -h ${bs_host} -p ${bs_port} CLUSTER METARAFT ADDLEARNER ${raft_id} ${raft_addr} 2>&1)
    if echo "${add_output}" | grep -q "OK"; then
        print_success "Added ${replica} as learner"
    else
        print_warn "Failed to add ${replica} as learner: ${add_output}"
    fi
done

# 等待 learners 被添加
sleep 2

# 获取当前的 voters 和 learners
# Parse the output of METARAFT MEMBERS - format is: ID, role, ID, role, etc.
voters_output=$(${REDIS_CLI} -h ${bs_host} -p ${bs_port} CLUSTER METARAFT MEMBERS 2>/dev/null || echo "")
print_info "MetaRaft members after adding learners:"
echo "${voters_output}"

print_info "Promoting to voters: ${promotion_list}"

# 执行晋升 - 注意 promotion_list 是空格分隔的参数
promo_output=$(${REDIS_CLI} -h ${bs_host} -p ${bs_port} CLUSTER METARAFT PROMOTE ${promotion_list} 2>&1)
if echo "${promo_output}" | grep -q "OK"; then
    print_success "Replicas promoted to MetaRaft voters"
else
    print_warn "Failed to promote replicas: ${promo_output}"
    print_warn "Automatic failover may not work"
fi

# 等待晋升传播
sleep 2

# 验证晋升结果
print_info "MetaRaft members after promotion:"
${REDIS_CLI} -h ${bs_host} -p ${bs_port} CLUSTER METARAFT MEMBERS 2>/dev/null || true
echo ""

# 步骤 8: 验证集群状态
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