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
| 纯内存读写（GET/SET） | User CPU 高, System CPU 低 | 正常状态，Aikv 主要在处理命令解析和数据结构访问 |
| 开启 AOF 持久化 | System CPU 高 | AOF 刷盘（fsync）消耗系统 CPU |
| RDB 快照生成 | System CPU 突然飙升 | fork() 创建子进程、COW 页面分配消耗 |
| 网络吞吐量瓶颈 | System CPU 高，CPU 核心打满 | 每个连接都消耗 System CPU（socket I/O） |

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

