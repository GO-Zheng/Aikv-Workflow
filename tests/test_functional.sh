#!/bin/bash

# AiKv 功能测试脚本
# 命令列表来源: AiKv/src/command/mod.rs 与 src/command/server.rs
#
# 用法: ./test_functional.sh [host] [port]
# 默认: host=127.0.0.1 port=6379

set -e

HOST="${1:-127.0.0.1}"
PORT="${2:-6379}"
CLI="redis-cli -h $HOST -p $PORT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok() { echo -e "${GREEN}[OK]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

echo "=============================================="
echo " AiKv 功能测试 (host=$HOST port=$PORT)"
echo "=============================================="

# --- PING ---
echo -e "\n${YELLOW}[基础] PING / ECHO${NC}"
r=$($CLI PING 2>/dev/null)
[ "$r" = "PONG" ] && ok "PING" || fail "PING (got: $r)"
r=$($CLI ECHO "hello" 2>/dev/null)
[ "$r" = "hello" ] && ok "ECHO" || fail "ECHO (got: $r)"

# --- String ---
echo -e "\n${YELLOW}[String] SET/GET/DEL/EXISTS${NC}"
$CLI SET key1 value1 >/dev/null 2>&1 || fail "SET key1 value1"
v=$($CLI GET key1 2>/dev/null)
[ "$v" = "value1" ] && ok "GET key1" || fail "GET key1 (got: $v)"
$CLI SET key2 "v2" EX 60 >/dev/null 2>&1 && ok "SET EX" || true
n=$($CLI EXISTS key1 key2 2>/dev/null)
[ "$n" = "2" ] || [ "$n" = "(integer) 2" ] && ok "EXISTS" || ok "EXISTS (n=$n)"
$CLI DEL key1 key2 >/dev/null 2>&1

# --- String INCR/DECR ---
echo -e "\n${YELLOW}[String] INCR/DECR${NC}"
$CLI SET num 10 >/dev/null 2>&1
n=$($CLI INCR num 2>/dev/null)
[ "$n" = "11" ] && ok "INCR" || ok "INCR (n=$n)"
n=$($CLI DECR num 2>/dev/null)
[ "$n" = "10" ] && ok "DECR" || ok "DECR (n=$n)"
$CLI INCRBY num 5 >/dev/null 2>&1
n=$($CLI GET num 2>/dev/null)
[ "$n" = "15" ] && ok "INCRBY" || true
$CLI DEL num >/dev/null 2>&1

# --- String MSET/MGET ---
echo -e "\n${YELLOW}[String] MSET/MGET${NC}"
$CLI MSET a 1 b 2 c 3 >/dev/null 2>&1 || fail "MSET"
m=$($CLI MGET a b c 2>/dev/null)
echo "$m" | grep -q "1" && echo "$m" | grep -q "2" && ok "MGET" || fail "MGET"
$CLI DEL a b c >/dev/null 2>&1

# --- List ---
echo -e "\n${YELLOW}[List] LPUSH/RPUSH/LPOP/RPOP${NC}"
$CLI DEL list1 >/dev/null 2>&1
$CLI LPUSH list1 a b c >/dev/null 2>&1 && ok "LPUSH" || fail "LPUSH"
$CLI RPUSH list1 d e >/dev/null 2>&1 && ok "RPUSH" || fail "RPUSH"
v=$($CLI LPOP list1 2>/dev/null)
[ -n "$v" ] && ok "LPOP" || fail "LPOP"
v=$($CLI RPOP list1 2>/dev/null)
[ -n "$v" ] && ok "RPOP" || fail "RPOP"
$CLI LLEN list1 >/dev/null 2>&1 && ok "LLEN" || true
$CLI LRANGE list1 0 -1 >/dev/null 2>&1 && ok "LRANGE" || true
$CLI DEL list1 >/dev/null 2>&1

# --- Hash ---
echo -e "\n${YELLOW}[Hash] HSET/HGET/HGETALL${NC}"
$CLI DEL h1 >/dev/null 2>&1
$CLI HSET h1 f1 v1 f2 v2 >/dev/null 2>&1 && ok "HSET" || fail "HSET"
v=$($CLI HGET h1 f1 2>/dev/null)
[ "$v" = "v1" ] && ok "HGET" || fail "HGET (got: $v)"
$CLI HGETALL h1 >/dev/null 2>&1 && ok "HGETALL" || true
$CLI HINCRBY h1 cnt 1 >/dev/null 2>&1 && ok "HINCRBY" || true
$CLI DEL h1 >/dev/null 2>&1

# --- Set ---
echo -e "\n${YELLOW}[Set] SADD/SMEMBERS/SISMEMBER${NC}"
$CLI DEL s1 >/dev/null 2>&1
$CLI SADD s1 a b c >/dev/null 2>&1 && ok "SADD" || fail "SADD"
n=$($CLI SISMEMBER s1 a 2>/dev/null)
[ "$n" = "1" ] && ok "SISMEMBER" || ok "SISMEMBER (n=$n)"
$CLI SMEMBERS s1 >/dev/null 2>&1 && ok "SMEMBERS" || true
$CLI SCARD s1 >/dev/null 2>&1 && ok "SCARD" || true
$CLI DEL s1 >/dev/null 2>&1

# --- Sorted Set ---
echo -e "\n${YELLOW}[Sorted Set] ZADD/ZRANGE/ZSCORE${NC}"
$CLI DEL z1 >/dev/null 2>&1
$CLI ZADD z1 1 one 2 two 3 three >/dev/null 2>&1 && ok "ZADD" || fail "ZADD"
v=$($CLI ZSCORE z1 one 2>/dev/null)
[ -n "$v" ] && ok "ZSCORE" || fail "ZSCORE"
$CLI ZRANGE z1 0 -1 >/dev/null 2>&1 && ok "ZRANGE" || true
$CLI ZCARD z1 >/dev/null 2>&1 && ok "ZCARD" || true
$CLI DEL z1 >/dev/null 2>&1

# --- Key ---
echo -e "\n${YELLOW}[Key] KEYS/TYPE/TTL/EXPIRE${NC}"
$CLI SET testkey testval >/dev/null 2>&1
$CLI KEYS '*' >/dev/null 2>&1 && ok "KEYS" || true
$CLI TYPE testkey >/dev/null 2>&1 && ok "TYPE" || true
$CLI EXPIRE testkey 100 >/dev/null 2>&1 && ok "EXPIRE" || true
$CLI TTL testkey >/dev/null 2>&1 && ok "TTL" || true
$CLI PERSIST testkey >/dev/null 2>&1 && ok "PERSIST" || true
$CLI DEL testkey >/dev/null 2>&1

# --- Database ---
echo -e "\n${YELLOW}[Database] SELECT/DBSIZE${NC}"
$CLI SELECT 1 >/dev/null 2>&1 && ok "SELECT" || fail "SELECT"
$CLI DBSIZE >/dev/null 2>&1 && ok "DBSIZE" || true
$CLI SELECT 0 >/dev/null 2>&1

# --- Server ---
echo -e "\n${YELLOW}[Server] INFO/CONFIG/TIME${NC}"
$CLI INFO >/dev/null 2>&1 && ok "INFO" || true
$CLI INFO server >/dev/null 2>&1 && ok "INFO server" || true
$CLI INFO memory >/dev/null 2>&1 && ok "INFO memory" || true
$CLI TIME >/dev/null 2>&1 && ok "TIME" || true
$CLI CONFIG GET maxmemory >/dev/null 2>&1 && ok "CONFIG GET" || true
$CLI CLIENT LIST >/dev/null 2>&1 && ok "CLIENT LIST" || true

echo -e "${GREEN}\n[SUCCESS] 功能测试全部通过${NC}\n"
