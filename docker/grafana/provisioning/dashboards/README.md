# AiKv Dashboard 说明

## CPU

### 指标说明

| 指标 | 采集器 | 含义 |
|------|--------|------|
| redis_cpu_sys_seconds_total | aikv-exporter | 进程在内核态消耗的 CPU 时间累计值 (秒) |
| redis_cpu_user_seconds_total | aikv-exporter | 进程在用户态消耗的 CPU 时间累计值 (秒) |

### 面板说明

#### AiKv CPU 使用率

| 曲线              | 曲线说明                  | AiKv 中对应的操作                                                          | 计算公式                                                                             | 公式说明                |
| --------------- | --------------------- | -------------------------------------------------------------------- | -------------------------------------------------------------------------------- | ------------------- |
| System CPU (橙色) | 内核态 CPU，反映系统调用、I/O 等待 | 网络收发字节（socket read/write）、文件 I/O（RDB/AOF 持久化）、内存映射文件、锁竞争（kernel 级同步） | `rate(redis_cpu_sys_seconds_total[1m])`                                          | 1 分钟内系统 CPU 每秒平均增长率 |
| User CPU (蓝色)   | 用户态 CPU，反映业务逻辑计算      | 命令解析、协议处理、数据结构操作（Hash/Set/ZSet 的读写）、复制（replication）逻辑                | `rate(redis_cpu_user_seconds_total[1m])`                                         | 1 分钟内用户 CPU 每秒平均增长率 |
| Total CPU (绿色)  | 两者之和                  | -                                                                    | `rate(redis_cpu_sys_seconds_total[1m]) + rate(redis_cpu_user_seconds_total[1m])` | 1 分钟内总 CPU 每秒平均增长率  |

| 实际场景 | 现象 | 说明 |
|------|------|------|
| 正常读写 | User CPU 高, System CPU 低 | 正常状态，命令解析和内存操作消耗 |
| 大量写入 | Total CPU 骤升 | 写请求突增，数据写入内存消耗 CPU |
| 大 Key 读取 | User CPU 飙升 | 解析大字符串、反序列化消耗 |
| 连接数过多 | System CPU 高 | 大量 socket I/O 系统调用 |

#### 总 CPU 使用率

| 对象 | 说明 |
|------|------|
| 显示内容 | 当前时刻的总 CPU 使用率 |
| 采集器 | aikv-exporter |
| AiKv 中对应情况 | 当前负载情况 |
| 计算公式 | `rate(redis_cpu_sys_seconds_total[1m]) + rate(redis_cpu_user_seconds_total[1m])` |

| 实际场景 | 现象 | 说明 |
|------|------|------|
| 空闲 | 指针接近 0 | 无请求或请求极少 |
| 正常负载 | 指针在 0.7 以下 | 负载正常 |
| 高负载 | 指针超过 0.7 | 警告，需排查原因或扩容 |
| 单核饱和 | 指针接近 1.0 | 单核已达上限，考虑水平扩容 |

---

## Memory

### 指标说明

| 指标 | 采集器 | 含义 |
|------|--------|------|
| redis_memory_used_bytes | aikv-exporter | AiKv 实际分配的内存 (字节) |
| redis_memory_used_peak_bytes | aikv-exporter | 历史峰值内存 (字节) |
| process_resident_memory_bytes | aikv-exporter | 进程常驻物理内存 (字节) |
| redis_mem_fragmentation_ratio | aikv-exporter | 内存碎片率 (RSS/Used) |

---

## AiDb (存储引擎)

### 指标说明

| 指标 | 采集器 | 含义 |
|------|--------|------|
| aidb_memtable_bytes | aidb-exporter | 活跃 MemTable 大小 (字节) |
| aidb_total_memtable_bytes | aidb-exporter | 活跃 + 不可变 MemTables 总大小 (字节) |
| aidb_wal_bytes | aidb-exporter | WAL (预写日志) 文件大小 (字节) |
| aidb_block_cache_bytes | aidb-exporter | Block Cache 当前使用量 (字节) |
| aidb_block_cache_capacity_bytes | aidb-exporter | Block Cache 容量 (字节) |

### 面板说明

#### AiDb MemTable & WAL

| 曲线 | 曲线说明 | AiDb 中对应情况 | 计算公式 | 公式说明 |
|------|----------|------------------|----------|----------|
| MemTable (蓝色) | 活跃 MemTable 大小 | 当前正在写入的 MemTable | `aidb_memtable_bytes` | 直接取值 |
| WAL (橙色) | Write-Ahead Log 文件大小 | 已写入但未刷盘的操作日志 | `aidb_wal_bytes` | 直接取值 |

| 实际场景 | 现象 | 说明 |
|------|------|------|
| 正常写入 | MemTable 和 WAL 稳定在某一水平 | 数据正常写入和刷新 |
| 写入压力大 | MemTable 持续增长 | 数据写入速度快于刷新速度 |
| Flush 触发 | MemTable 突然下降 | 达到阈值触发 flush 到磁盘 |
| WAL 持续增长 | WAL 文件变大 | 刷新不及时或写入密集 |

#### AiDb Block Cache

| 曲线 | 曲线说明 | AiDb 中对应情况 | 计算公式 | 公式说明 |
|------|----------|------------------|----------|----------|
| Block Cache 使用量 (蓝色) | 当前使用的缓存大小 | 已缓存的 SSTable block | `aidb_block_cache_bytes` | 直接取值 |
| Block Cache 容量 (橙色) | 配置的最大容量 | 缓存层最大可用空间 | `aidb_block_cache_capacity_bytes` | 直接取值 |

| 实际场景 | 现象 | 说明 |
|------|------|------|
| 正常读 | 使用量稳定 | 读写请求命中缓存 |
| 缓存未命中 | 使用量较低 | 大量磁盘 I/O |
| 缓存饱和 | 使用量接近容量 | 缓存命中率高，接近满载 |

#### Block Cache 使用率

| 对象 | 说明 |
|------|------|
| 显示内容 | 当前 Block Cache 使用率 |
| 采集器 | aidb-exporter |
| AiDb 中对应情况 | 缓存饱和度 |
| 计算公式 | `aidb_block_cache_bytes / aidb_block_cache_capacity_bytes` |

| 实际场景 | 现象 | 说明 |
|------|------|------|
| 正常 | 使用率 70% 以下 | 缓存未饱和，命中率高 |
| 警告 | 使用率 70% - 90% | 缓存接近饱和，考虑扩容 |
| 危险 | 使用率超过 90% | 缓存饱和，可能影响命中率 |

### 面板说明

#### 内存使用量

| 曲线 | 曲线说明 | AiKv 中对应情况 | 计算公式 | 公式说明 |
|------|----------|------------------|----------|----------|
| RSS Memory (绿色) | 进程常驻物理内存 | 操作系统报告的实际物理内存占用 | `process_resident_memory_bytes{job="aikv-exporter"}` | 直接取值 |
| Peak Memory (橙色) | 历史峰值内存 | 进程运行以来的最大内存分配 | `redis_memory_used_peak_bytes` | 直接取值 |
| Used Memory (蓝色) | AiKv 实际分配的内存 | AiKv 进程分配的内存字节数 | `redis_memory_used_bytes` | 直接取值 |

| 实际场景 | 现象 | 说明 |
|------|------|------|
| 正常 | Used Memory 稳定在某一水平 | 内存使用正常 |
| 突发写入 | Used Memory 快速上升 | 大量数据写入，内存分配增加 |
| 内存泄漏 | Used Memory 持续增长不回落 | 内存未释放，可能是泄漏 |
| RSS 远大于 Used | 内存碎片高 | 分配了但未使用，碎片严重 |
| 持续高水位 | Peak Memory 接近机器内存 | 内存压力持续，迟早 OOM |

#### 内存碎片率

| 对象 | 说明 |
|------|------|
| 指标 | 当前内存碎片率 |
| 采集器 | aikv-exporter |
| AiKv 中对应情况 | 内存碎片情况 (RSS/Used ratio) |
| 计算公式 | `redis_mem_fragmentation_ratio` |

| 实际场景 | 现象 | 说明 |
|------|------|------|
| 正常 | 1.0 - 1.5 | 内存碎片较少 |
| 警告 | 1.5 - 3.0 | 内存碎片较多，考虑整理 |
| 危险 | > 3.0 | 碎片严重，建议重启 AiKv |

