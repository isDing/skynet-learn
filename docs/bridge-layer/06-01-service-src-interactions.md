# Skynet C 服务（service-src）与主框架交互详解

## 目录

1. 设计总览
2. C 服务生命周期与主框架钩子
3. SNLua：Lua 容器与启动链路
4. Gate：网络网关与数据转发
5. Logger：集中式日志消费
6. Harbor：跨节点消息编解码与转发
7. 典型调用链与问题定位要点
8. 开发注意事项与最佳实践

---

## 1. 设计总览

service-src/ 下的 C 服务是 Skynet 运行时的“系统级服务”，它们以 C 模块形式被 `skynet_module` 动态加载，并作为普通服务（有独立 `skynet_context`）参与消息调度，与 Lua 层服务通过消息互通。核心服务包括：

- `service_snlua.c`：Lua 服务容器（每个 Lua 服务运行于一个 SNLua 实例）
- `service_gate.c`：网关服务（连接管理、分包、转发）
- `service_logger.c`：日志消费服务（集中写文件/标准输出）
- `service_harbor.c`：跨节点 Harbor 服务（远程消息转发/握手）

这些服务通过统一的导出符号 `*_create/_init/_release/_signal` 与主框架对接，由 `skynet_server.c` 调度消息，`skynet_module.c` 提供动态加载，`skynet_handle.c` 负责句柄注册和名字服务。

---

## 2. C 服务生命周期与主框架钩子

### 2.1 模块导出与加载

- 模块导出符号：`<name>_create`、`<name>_init`、`<name>_release`、`<name>_signal`
- 动态加载：`skynet-src/skynet_module.c:104` 查询或加载 `.so`，并绑定上述符号
- 句柄注册与上下文创建：`skynet-src/skynet_server.c:130` 通过 `skynet_context_new` 完成

模块缓存说明：模块只加载一次，常驻进程生命周期（参见 docs/core-modules/02-service-management.md 的“模块查询和缓存”节）。

### 2.2 回调注册与消息派发

- C 服务通过 `skynet_callback(ctx, ud, cb)` 注册消息回调
- 派发路径：`skynet_context_message_dispatch` → `dispatch_message` → `cb`
  - `dispatch_message` 源码：`skynet-src/skynet_server.c:284`
  - 批处理/过载/监控触发：`skynet-src/skynet_server.c:326`

### 2.3 与命令系统交互

- 使用 `skynet_command(ctx, "CMD", param)` 与 `skynet_server.c` 的命令表交互（如 `REG/NAME/STAT/STARTTIME/EXIT`）
- 名字解析：`.name` 本地，`:hex` 句柄，见 `skynet-src/skynet_server.c:380`、`465`、`788`

### 2.4 消息发送与内存责任

- `skynet_send/ skynet_sendname` 统一入口（`skynet-src/skynet_server.c:735/788`）
- `PTYPE_TAG_DONTCOPY`：由框架负责释放数据（错误/无目的地时避免泄漏）
- `destination==0` 且 `data!=NULL`：报错并释放；若 `data==NULL`，返回当前 `session`

---

## 3. SNLua：Lua 容器与启动链路

SNLua 将 C 运行时与 Lua 生态桥接，是一切 Lua 服务的宿主。

### 3.1 核心结构与内存控制

- 结构体：`service-src/service_snlua.c:26`
  - 记录 `lua_State`、上下文、内存统计、活跃协程、信号陷阱等
- 自定义分配器：`lalloc`（`service-src/service_snlua.c:482`）
  - 统计内存、限制检查（`mem_limit`）、指数警告（`mem_report`）
  - 触发 `skynet_error` 输出内存警告，最终委托 `skynet_lalloc`

### 3.2 初始化与第一条消息

- 初始化入口：`snlua_init`（`service-src/service_snlua.c:469`）
  - 将 `launch_cb` 注册为回调，随后发送第一条“自举消息”（`PTYPE_TAG_DONTCOPY`）给自己触发 `launch_cb`
- 初始化回调：`launch_cb`（`service-src/service_snlua.c:456`）
  - 取消回调绑定（避免重复），调用 `init_cb` 完成 Lua 环境搭建
- 关键初始化：`init_cb`（`service-src/service_snlua.c:383`）
  - 暂停 GC → 加载标准库、profile 库 → 替换 coroutine `resume/wrap` 以注入计时 → 设置 `LUA_PATH/LUA_CPATH/LUA_SERVICE/LUA_PRELOAD` → 加载并执行 `loader.lua`
  - 若加载失败，向 `.launcher` 报错（`report_launcher_error`，`service-src/service_snlua.c:369`）并 `EXIT`

### 3.3 信号与性能采样

- 信号处理：`snlua_signal`（`service-src/service_snlua.c:520`）
  - 信号 0：设置 hook 中断活跃协程执行，抛出 `signal 0`
  - 信号 1：打印当前内存
- 协程切换计时：`switchL/lua_resumeX`（`service-src/service_snlua.c:76/84`）

与主框架交互要点：
- 启动链路通过框架发送第一条消息驱动（`skynet_send`），而非直接函数调用
- 通过命令通道访问环境变量（`GETENV`）、注册自身句柄（`REG`）并读取 `STARTTIME`

---

## 4. Gate：网络网关与数据转发

Gate 将 socket 事件抽象为服务消息，负责分包与转发，是客户端入口服务。

### 4.1 核心结构

- 连接：`struct connection`（`service-src/service_gate.c:15`）
  - `id/agent/client/remote_name/buffer`
- 网关：`struct gate`（`service-src/service_gate.c:23`）
  - `ctx/listen_id/watchdog/broker/client_tag/header_size/max_connection/hash/conn/messagepool`

### 4.2 控制命令与运行参数

- 初始化：`gate_init`（`service-src/service_gate.c:343`）解析参数：`<S|L> <watchdog> <host:port> <client_tag> <max>`
  - `S/L` 表示 2/4 字节长度头；`PTYPE_CLIENT` 为默认 `client_tag`
  - `watchdog` 为服务名或 `!`（禁用）→ 通过 `skynet_queryname` 解析
  - 注册回调 `_cb` 并启动监听 `start_listen`
- 运行时控制：`_ctrl`（`service-src/service_gate.c:88`）
  - `kick <fd>` 关闭连接
  - `forward <fd> :agent :client` 设置转发目标
  - `broker <name>` 设置 broker 服务（统一收包）
  - `start <fd>` 开启接收
  - `close` 关闭监听 socket

### 4.3 分包与转发

- 数据进入：`PTYPE_SOCKET` → `dispatch_socket_message`（`service-src/service_gate.c:217`）
- 分包：`dispatch_message`（`service-src/service_gate.c:194`）
  - `databuffer_readheader` 读取包长（大于 16MB 则关连接并报错）
  - 完整包则 `_forward`，随后 `databuffer_reset`
- 转发策略：`_forward`（`service-src/service_gate.c:168`）
  - 优先 `broker`，否则 `agent`，否则通知 `watchdog`
  - 使用 `PTYPE_TAG_DONTCOPY` 避免多次拷贝

### 4.4 客户端写回

- `_cb` 中 `PTYPE_CLIENT` 分支：将消息末尾 4 字节视作 `uid`，写回 socket（`skynet_socket_send`），返回 `1` 表示不释放 `msg`（`service-src/service_gate.c:281`）

与主框架交互要点：
- 经由 `skynet_socket_*` 与内核 `socket_server` 交互，事件以 `PTYPE_SOCKET` 回送服务层
- 控制面通过文本命令（`PTYPE_TEXT`）

---

## 5. Logger：集中式日志消费

Logger 作为系统日志汇聚点，消费 `PTYPE_TEXT` 并输出到文件或标准输出。

### 5.1 初始化与回调

- `logger_init`（`service-src/service_logger.c:72`）
  - 读取 `STARTTIME`、打开文件（或 stdout）、注册回调 `logger_cb`
- 回调 `logger_cb`（`service-src/service_logger.c:48`）
  - `PTYPE_SYSTEM`：执行日志轮转（`freopen`）
  - `PTYPE_TEXT`：打印 `[timestamp][:source] <text>` 并 flush

与主框架交互要点：
- 框架侧 `skynet_logon/logoff` 原子切换每个服务的日志文件句柄；Logger 仅为集中落盘服务

---

## 6. Harbor：跨节点消息编解码与转发

Harbor 负责远程消息的序列化、路由与握手，连接 master/slave 节点。

### 6.1 关键结构与队列

- `struct harbor`（`service-src/service_harbor.c:81`）：上下文、节点 id、slave 表、名字映射
- 环形队列 `harbor_msg_queue`（`service-src/service_harbor.c:46`）用于缓存待发远程消息

### 6.2 指令与状态机

- Harbor 控制命令处理：`harbor_command`（`service-src/service_harbor.c:603`）
  - `N name`：更新全局名映射
  - `S fd id`：主动连接到远端 harbor，发送自 id → 等待确认 → 发送队列
  - `A fd id`：接受来自远端 harbor 连接，发送自 id → 发送队列
- 套接字状态机：`STATUS_*`（`service-src/service_harbor.c:65`）

### 6.3 主回调与消息路径

- 主回调 `mainloop`（`service-src/service_harbor.c:666`）
  - `PTYPE_SOCKET`：收取网络数据/错误/关闭/警告
  - `PTYPE_HARBOR`：处理上面的控制命令（N/S/A）
  - `PTYPE_SYSTEM`：从框架收到 `struct remote_message`，根据 `destination`（句柄/名字）发送到远端；发送完成由 Harbor 释放 `rmsg->message`

与主框架交互要点：
- 本地 `skynet_send` 如果目标是远程句柄或远程名字，会被框架打包成 `PTYPE_SYSTEM` 投递给 Harbor（`skynet-src/skynet_server.c:735/788`）
- Harbor 完成跨节点编解码、路由以及套接字握手与维护

---

## 7. 典型调用链与问题定位要点

### 7.1 Lua 服务启动链（SNLua）

1) Loader 配置：`snlua_init` 发第一条消息 → `launch_cb` → `init_cb` → 加载 `loader.lua`（`service-src/service_snlua.c:469/456/383`）
2) 环境变量拉取：通过 `GETENV` 获取 `lua_path/lua_cpath/luaservice` 等配置
3) 失败上报：加载失败 → `.launcher` 发送 `ERROR`（`service-src/service_snlua.c:369`）

排障要点：检查 `LUA_PATH/LUA_CPATH/LUA_SERVICE` 与 `loader.lua` 路径，核对 `skynet_command`/`skynet_error` 日志

### 7.2 网络数据转发（Gate）

1) `PTYPE_SOCKET(DATA)` → `dispatch_socket_message` → `dispatch_message` 分包 → `_forward`
2) 优先级：`broker` > `agent` > `watchdog`；客户端写回在 `_cb(PTYPE_CLIENT)` 分支

排障要点：观察 16MB 限制、`PTYPE_TAG_DONTCOPY`、`header_size` 配置与 `watchdog` 报告

### 7.3 跨节点转发（Harbor）

1) 框架识别远程 → 投递 `PTYPE_SYSTEM` 给 Harbor → Harbor 进行 `remote_send_handle/name`
2) 连接事件与错误在 `PTYPE_SOCKET` 分支处理，失败会上报 slave 服务

排障要点：核对名字表、握手状态、队列积压（`WARNING`）与失败日志

### 7.4 日志落盘（Logger）

1) Logger 作为普通服务消费 `PTYPE_TEXT`，与 `LOGON/LOGOFF` 配合
2) 轮转通过 `PTYPE_SYSTEM` 触发（`freopen`）

---

## 8. 开发注意事项与最佳实践

- 消息内存责任：若回调返回 0 由框架释放；Gate/Harbor 下行发送建议使用 `PTYPE_TAG_DONTCOPY`
- 名字服务边界：C 层仅支持本地名字注册与查询（不支持直接注册全局名），跨节点名字由 Harbor 维护
- 错误与超限：Gate 丢弃并关闭超大包（≥16MB）；Harbor 网络异常要及时上报 slave/monitor
- 监控与诊断：结合 `STAT` 与 `skynet_monitor_trigger`，定位队列过载、卡线程、处理耗时
- 资源释放：`_release` 中统一释放 socket/队列/内存；注意回调并发安全（如 Logger / 日志句柄）

---

以上内容聚焦 service-src 四大核心 C 服务的职责与与主框架的交互细节，并配套源码行号便于快速跳转核查。实际开发建议对照 `docs/core-modules/02-service-management.md` 的服务生命周期、消息派发与模块加载章节进行交叉阅读。
