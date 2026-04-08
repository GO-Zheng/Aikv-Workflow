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

# redis-cli 实际连接地址：默认同节点列表中的 host:port。
# 若设置 CLUSTER_REDIS_CONNECT_HOST（如 127.0.0.1），则主机用该值、端口仍取自列表，
# 用于「在 SERVER 本机跑初始化」时本机访问 192.168.x.x 失败（hairpin）而回环可通的情况。
# CLUSTER MEET 等仍使用列表中的对外地址，不影响 redis-cli -c 从其他机器连接。
redis_cli_host_port() {
    local node="$1"
    local announce_host="${node%:*}"
    local data_port="${node#*:}"
    if [[ -n "${CLUSTER_REDIS_CONNECT_HOST:-}" ]]; then
        echo "${CLUSTER_REDIS_CONNECT_HOST} ${data_port}"
    else
        echo "${announce_host} ${data_port}"
    fi
}

bootstrap_redis_cli() {
    redis_cli_host_port "${MASTERS[0]}"
}

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

# 根据 Redis 端口推导对应 master 的容器内 Raft 地址
# 这里必须使用容器可达地址，而不是外部访问 IP。
get_master_raft_addr() {
    local redis_port="$1"
    case "${redis_port}" in
        6379) echo "aikv-master-1:50051" ;;
        6381) echo "aikv-master-2:50051" ;;
        6383) echo "aikv-master-3:50051" ;;
        *) echo "" ;;
    esac
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

Environment:
    CLUSTER_REDIS_CONNECT_HOST   Optional. If set, redis-cli uses this host with ports from -m/-r
                                 (for init on the same machine as SERVER_HOST when LAN IP hairpin fails).

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

if [[ -n "${CLUSTER_REDIS_CONNECT_HOST:-}" ]]; then
    print_info "redis-cli 实际连接: ${CLUSTER_REDIS_CONNECT_HOST}:<端口>（与上表端口对应）；CLUSTER MEET 仍使用上表中的对外地址"
fi

if [ ${MASTER_COUNT} -lt 3 ]; then
    print_error "At least 3 master nodes are required for a cluster"
    exit 1
fi

# 获取节点 ID 的函数（参数为 host:port 列表中的单项）
get_node_id() {
    local node=$1
    read -r h p <<< "$(redis_cli_host_port "$node")"
    ${REDIS_CLI} -h "${h}" -p "${p}" CLUSTER MYID 2>&1
}

# Function to check if node is reachable（单次探测）
check_node_once() {
    local node=$1
    read -r h p <<< "$(redis_cli_host_port "$node")"
    if ${REDIS_CLI} -h "${h}" -p "${p}" PING 2>&1 | grep -q "PONG"; then
        return 0
    else
        return 1
    fi
}

# 等待节点就绪（容器刚起时 5s 往往不够）
wait_for_node() {
    local node=$1
    local max_wait="${2:-60}"
    local i=0
    read -r h p <<< "$(redis_cli_host_port "$node")"
    while [ "$i" -lt "$max_wait" ]; do
        if check_node_once "${node}"; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    local out
    out="$(${REDIS_CLI} -h "${h}" -p "${p}" PING 2>&1 || true)"
    print_error "节点 ${node} 在 ${max_wait}s 内不可达"
    print_error "  已尝试: redis-cli -h ${h} -p ${p} PING"
    print_error "  返回: ${out}"
    if [[ -z "${CLUSTER_REDIS_CONNECT_HOST:-}" ]] && [[ "${node}" == *:* ]]; then
        print_warn "若在 SERVER 本机初始化且 hairpin 不通，请同步最新 init_cluster.sh 后重试，或手动:"
        print_warn "  CLUSTER_REDIS_CONNECT_HOST=127.0.0.1 $0 -m ... -r ..."
    fi
    return 1
}

# 步骤 1: 检查所有节点是否可达
print_info "Step 1: Checking node connectivity..."
ALL_NODES=("${MASTERS[@]}" "${REPLICAS[@]}")
for node in "${ALL_NODES[@]}"; do
    if wait_for_node "${node}" 60; then
        read -r h p <<< "$(redis_cli_host_port "$node")"
        print_success "Node ${node} is reachable (via ${h}:${p})"
    else
        exit 1
    fi
done
echo

# 步骤 2: 获取所有 master 的节点 ID
print_info "Step 2: Retrieving master node IDs..."
declare -A MASTER_IDS
for i in "${!MASTERS[@]}"; do
    node="${MASTERS[$i]}"
    node_id=$(get_node_id "${node}")
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

read -r bs_host bs_port <<< "$(bootstrap_redis_cli)"

# 构建待晋升列表（实际 node_id）
promotion_master_ids=""

for i in "${!MASTERS[@]}"; do
    # 跳过 bootstrap（它已经是 voter）
    [ $i -eq 0 ] && continue

    node="${MASTERS[$i]}"
    node_id="${MASTER_IDS[$node]}"
    node_port="${node#*:}"
    raft_addr="$(get_master_raft_addr "${node_port}")"

    if [ -z "${raft_addr}" ]; then
        print_error "No Raft address mapping for ${node} (port=${node_port})"
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
read -r bs_host bs_port <<< "$(bootstrap_redis_cli)"

# 获取所有节点 ID
declare -A ALL_NODE_IDS
for node in "${ALL_NODES[@]}"; do
    node_id=$(get_node_id "${node}")
    ALL_NODE_IDS["${node}"]="${node_id}"
done

# 首先连接所有 master（包括自身）
for node in "${MASTERS[@]}"; do
    node_id="${ALL_NODE_IDS[$node]}"
    IFS=':' read -r meet_host meet_port <<< "${node}"
    print_info "Meeting ${node} (ID: ${node_id})..."
    ${REDIS_CLI} -h ${bs_host} -p ${bs_port} CLUSTER MEET ${meet_host} ${meet_port} ${node_id} 2>&1 | grep -q "OK" || true
done

# 连接 replicas
for node in "${REPLICAS[@]}"; do
    node_id="${ALL_NODE_IDS[$node]}"
    IFS=':' read -r meet_host meet_port <<< "${node}"
    print_info "Meeting ${node} (ID: ${node_id})..."
    ${REDIS_CLI} -h ${bs_host} -p ${bs_port} CLUSTER MEET ${meet_host} ${meet_port} ${node_id} 2>&1 | grep -q "OK" || true
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
    read -r m_cli_host m_cli_port <<< "$(redis_cli_host_port "$master")"

    start_slot=$((i * SLOTS_PER_MASTER))
    if [ $i -eq $((MASTER_COUNT - 1)) ]; then
        end_slot=$((TOTAL_SLOTS - 1))
    else
        end_slot=$((start_slot + SLOTS_PER_MASTER - 1))
    fi

    print_info "Assigning slots ${start_slot}-${end_slot} to ${master} (ID: ${master_id})..."

    # 第一个 master (bootstrap) 不需要指定 node_id
    if [ $i -eq 0 ]; then
        ${REDIS_CLI} -h ${m_cli_host} -p ${m_cli_port} CLUSTER ADDSLOTSRANGE ${start_slot} ${end_slot} 2>&1 | grep -q "OK" || {
            print_error "Failed to assign slots to ${master}"
            exit 1
        }
    else
        # 其他 master 需要指定 node_id
        read -r bs_host bs_port <<< "$(bootstrap_redis_cli)"
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

    print_info "Setting ${replica} as replica of ${master}..."

    read -r bs_host bs_port <<< "$(bootstrap_redis_cli)"

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

read -r bs_host bs_port <<< "$(bootstrap_redis_cli)"

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

    # Get actual node ID from the replica itself (this is the hash-based ID)
    replica_node_id=$(get_node_id "${replica}")
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

read -r bs_host bs_port <<< "$(bootstrap_redis_cli)"
IFS=':' read -r pub_bs_host pub_bs_port <<< "${MASTERS[0]}"

print_info "Cluster info from bootstrap node (${pub_bs_host}:${pub_bs_port}, redis-cli -> ${bs_host}:${bs_port}):"
${REDIS_CLI} -h ${bs_host} -p ${bs_port} CLUSTER INFO
echo

print_info "Cluster nodes:"
${REDIS_CLI} -h ${bs_host} -p ${bs_port} CLUSTER NODES
echo

print_success "Cluster initialization completed!"
echo
print_info "You can now connect to the cluster using:"
echo "  redis-cli -c -h ${pub_bs_host} -p ${pub_bs_port}"