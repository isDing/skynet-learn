# Skynet 网络层文档索引

本索引整理了Skynet网络层的所有相关文档和架构图，方便快速查阅和学习。

## 📚 核心文档

### [网络层完整架构文档](./skynet-network-layer-architecture.md)
详细介绍Skynet网络层的设计与实现，包括：
- 整体架构设计
- 核心数据结构
- 工作机制详解
- 性能优化策略
- 实际应用示例

## 🎨 架构图表

所有架构图表位于 `docs/diagrams/network/` 目录，使用Mermaid格式绘制。

### 架构设计图

#### 1. [网络层整体架构图](./diagrams/network/network-architecture.mmd)
展示五层架构设计，从应用层到系统内核层的完整结构。

#### 2. [Socket状态机图](./diagrams/network/socket-state-machine.mmd)
描述Socket在其生命周期中的所有状态转换。

#### 3. [socket_server核心数据结构](./diagrams/network/socket-server-structure.mmd)
详细展示socket_server内部的数据组织方式。

### 数据流程图

#### 4. [数据接收流程图](./diagrams/network/data-receive-flow.mmd)
从网络数据到达到服务处理的完整接收路径。

#### 5. [数据发送流程图](./diagrams/network/data-send-flow.mmd)
从服务发送数据到网络传输的完整发送路径。

### 机制原理图

#### 6. [网络线程与工作线程交互](./diagrams/network/thread-interaction.mmd)
展示网络线程和工作线程之间的协作机制。

#### 7. [Socket ID管理机制](./diagrams/network/socket-id-management.mmd)
解释Socket ID的分配、映射和复用机制。

#### 8. [写缓冲区管理](./diagrams/network/write-buffer-management.mmd)
说明双优先级队列和缓冲区链表的设计。

## 🗂 源码文件对照

网络层核心源码文件位于 `skynet-src/` 目录：

| 文件名 | 功能说明 | 代码行数 |
|--------|---------|----------|
| `socket_server.c` | Socket服务器核心实现 | 2400+ |
| `skynet_socket.c` | 上层接口封装 | 300+ |
| `socket_poll.h` | IO多路复用统一接口 | 33 |
| `socket_epoll.h` | Linux epoll实现 | 82 |
| `socket_kqueue.h` | BSD kqueue实现 | 120+ |

## 🔍 快速导航

### 初学者路线
1. 先阅读[网络层整体架构图](./diagrams/network/network-architecture.mmd)了解总体结构
2. 学习[Socket状态机图](./diagrams/network/socket-state-machine.mmd)理解连接管理
3. 通过[数据接收流程图](./diagrams/network/data-receive-flow.mmd)和[数据发送流程图](./diagrams/network/data-send-flow.mmd)理解数据传输
4. 最后阅读[完整架构文档](./skynet-network-layer-architecture.md)深入细节

### 进阶开发路线
1. 研究[socket_server核心数据结构](./diagrams/network/socket-server-structure.mmd)
2. 理解[Socket ID管理机制](./diagrams/network/socket-id-management.mmd)
3. 分析[写缓冲区管理](./diagrams/network/write-buffer-management.mmd)
4. 掌握[线程交互机制](./diagrams/network/thread-interaction.mmd)

### 性能优化路线
1. 关注写缓冲区管理的双优先级队列设计
2. 了解批量事件处理机制(MAX_EVENT=64)
3. 研究零拷贝和直写模式优化
4. 学习原子操作和无锁化设计

## 📈 性能指标

根据文档分析，Skynet网络层的关键性能指标：

- **并发连接数**：单机可支持数万并发连接
- **Socket槽位**：65536个(2^16)
- **事件批处理**：每次最多处理64个事件
- **缓冲区优先级**：双队列设计，保证控制消息优先
- **线程模型**：单网络线程，避免锁竞争

## 🛠 调试与监控

- 使用`skynet.stat`获取网络统计信息
- 通过socket_stat结构监控读写字节数
- 警告阈值机制(WARNING_SIZE)监控缓冲区状态
- 调试控制台查看连接状态

## 📝 相关文档

- [Skynet完整架构分析](./skynet-complete-architecture-analysis.md)
- [Skynet模块示例](./skynet_module_examples.md)
- [Require模块查找指南](./require_module_lookup_guide.md)

## 更新记录

- 2024-09-27: 创建网络层完整文档和架构图
- 文档版本: 1.0

---

*本索引基于Skynet源码分析生成，持续更新中。*