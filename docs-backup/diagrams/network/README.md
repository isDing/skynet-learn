# Skynet 网络层架构图表

本目录包含Skynet网络层的详细架构图和流程图，使用Mermaid格式创建。

## 图表列表

### 1. 网络层整体架构图 (network-architecture.mmd)
展示Skynet网络层的五层架构：
- 🌐 应用层：各种服务（Gate、Client、Game等）
- 🔄 skynet_socket层：socket API和消息分发
- ⚙️ socket_server层：socket管理和控制
- 🔀 IO多路复用层：epoll/kqueue/select
- 🐧 系统内核层：网络协议栈和硬件

### 2. Socket状态机图 (socket-state-machine.mmd)
完整的socket状态转换图，包含：
- INVALID → RESERVE → PLISTEN/CONNECTING/BIND
- LISTEN → PACCEPT → CONNECTED
- CONNECTED → HALFCLOSE_READ/HALFCLOSE_WRITE
- 各状态间的转换条件和触发事件

### 3. 数据接收流程图 (data-receive-flow.mmd)
从网络数据到达到服务处理的完整流程：
- 网络数据到达 → epoll_wait → socket_server_poll
- forward_message_tcp/udp → 消息打包
- skynet_socket_poll → forward_message
- skynet_context_push → 服务消息队列 → 服务处理

### 4. 数据发送流程图 (data-send-flow.mmd)
从服务发送到网络传输的完整流程：
- 服务调用socket.write → skynet_socket_send
- 直写/缓冲写模式选择 → 控制管道传递
- 网络线程处理 → epoll监听EPOLLOUT
- send_buffer发送 → 双优先级队列处理

### 5. socket_server核心数据结构图 (socket-server-structure.mmd)
展示socket_server的内部数据结构：
- socket_server主结构体（event_fd、控制管道、ID分配器等）
- slot[MAX_SOCKET]数组和socket结构体
- 写缓冲区双优先级队列（high/low）
- 事件数组和事件结构体

### 6. 网络线程与工作线程交互图 (thread-interaction.mmd)
展示网络线程和工作线程池的交互机制：
- 网络线程：epoll_wait处理网络事件
- 控制管道：线程间通信机制
- 全局消息队列：工作线程竞争获取消息
- 同步机制和性能优化策略

### 7. Socket ID管理机制图 (socket-id-management.mmd)
详细展示socket ID的分配和管理：
- 原子计数器分配ID
- HASH映射到槽位
- 版本号机制防止ABA问题
- 槽位复用和生命周期管理

### 8. 写缓冲区管理图 (write-buffer-management.mmd)
展示双优先级队列的写缓冲区设计：
- high队列：控制消息优先
- low队列：普通数据
- 直写模式和缓冲写模式
- 流量控制和警告机制

## 使用说明

### 在线预览
可以使用以下工具在线预览Mermaid图表：
- [Mermaid Live Editor](https://mermaid.live/)
- [GitHub渲染](https://github.com) (直接在README中引用)
- [VS Code Mermaid插件](https://marketplace.visualstudio.com/items?itemName=bierner.markdown-mermaid)

### 本地渲染
```bash
# 安装mermaid-cli
npm install -g @mermaid-js/mermaid-cli

# 渲染为PNG
mmdc -i network-architecture.mmd -o network-architecture.png

# 渲染为SVG
mmdc -i network-architecture.mmd -o network-architecture.svg
```

### 在Markdown中使用
````markdown
```mermaid
graph TB
    %% 从文件中复制图表内容
```
````

## 颜色说明

每个图表都使用了一致的颜色方案来区分不同的层级和组件：

- 🔵 蓝色：应用层和Lua相关组件
- 🟣 紫色：skynet核心层组件
- 🟢 绿色：socket_server层和C层组件
- 🟠 橙色：IO多路复用和系统调用
- 🔴 红色：错误处理和异常情况
- 🟡 黄色：决策点和条件判断

## 图表关系

这些图表按照从宏观到微观的顺序组织：
1. **架构图**：整体架构概览
2. **状态机**：socket状态管理
3. **流程图**：数据收发流程
4. **结构图**：内部数据结构
5. **交互图**：线程间交互
6. **管理图**：ID和缓冲区管理

每个图表都可以独立理解，同时相互补充形成完整的网络层架构图谱。

## 更新日志

- 2025-09-27：创建初始版本的8个网络层图表
- 包含详细的架构、流程、数据结构和管理机制图