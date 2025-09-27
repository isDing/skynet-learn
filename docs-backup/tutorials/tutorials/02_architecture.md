# 理解 Skynet 架构

## 你将学到什么
- Skynet 的核心架构和设计原则
- Skynet 中的 Actor 模型实现
- 服务生命周期和管理
- 消息传递机制
- 线程调度和并发模型

## 先决条件
- 已完成教程 1：Skynet 入门
- 对并发编程概念的基本理解
- 熟悉 Lua 协程

## 预计时间
45 分钟

## 最终结果
深入理解 Skynet 的内部工作原理，并能够设计高效的服务架构

---

## 1. Skynet 架构概述

Skynet 遵循轻量级 Actor 模型，其中每个服务都是具有以下特性的独立实体：
- 自己的 Lua 状态
- 用于传入消息的消息队列
- 隔离的执行上下文

### 核心组件

```
┌─────────────────────────────────────────────────────────────┐
│                     Skynet 运行时                          │
├─────────────────┬─────────────────┬─────────────────────────┤
│   C 核心层      │   服务层        │   Lua 服务层           │
├─────────────────┼─────────────────┼─────────────────────────┤
│ • 调度器        │ • snlua         │ • 应用程序服务         │
│ • 消息队列      │ • gate          │ • 系统服务             │
│ • 定时器        │ • logger        │ • 用户服务             │
│ • Socket        │ • harbor        │                         │
│ • 模块加载器    │ • ...           │                         │
└─────────────────┴─────────────────┴─────────────────────────┘
```

## 2. Skynet 中的 Actor 模型

### 2.1 什么是 Actor？

Skynet 中的 Actor 是：
- 一个独立的执行单元
- 具有自己的状态和消息队列
- 仅通过异步消息进行通信
- 按顺序处理消息

### 2.2 服务作为 Actor

Skynet 中的每个服务都实现为 Actor：

```lua
local skynet = require "skynet"

-- 整个服务是一个 Actor
skynet.start(function()
    -- Actor 状态
    local state = {
        counter = 0,
        connections = {}
    }
    
    -- 消息处理器
    skynet.dispatch("lua", function(session, source, cmd, ...)
        -- 按顺序处理消息
        if cmd == "increment" then
            state.counter = state.counter + 1
            skynet.ret(skynet.pack(state.counter))
        end
    end)
    
    skynet.exit()
end)
```

## 3. 服务生命周期

### 3.1 服务创建

服务通过 launcher 服务创建：

```lua
-- 创建新服务
local service_addr = skynet.newservice("myservice")

-- 带参数创建
local service_addr = skynet.newservice("myservice", "arg1", "arg2")
```

创建过程：
1. Launcher 接收新服务请求
2. 创建新的 Lua 状态
3. 加载服务模块
4. 启动服务协程
5. 返回服务地址

### 3.2 服务执行

服务按以下流程执行：

```lua
skynet.start(function()
    -- 1. 初始化阶段
    local service_data = {}
    
    -- 2. 注册消息处理器
    skynet.dispatch("lua", function(session, source, ...)
        -- 处理传入消息
    end)
    
    -- 3. 开始处理消息
    -- skynet.exit() 被自动调用
end)
```

### 3.3 服务终止

服务可以通过多种方式退出：
- 正常退出：`skynet.exit()`
- 从其他服务杀死：`skynet.kill(address)`
- 错误终止：未处理的错误

## 4. 消息传递机制

### 4.1 消息类型

Skynet 支持几种消息类型：

```lua
-- 在 skynet.lua 中定义的协议类型
skynet.PTYPE_TEXT = 0        -- 文本消息
skynet.PTYPE_RESPONSE = 1    -- 响应消息
skynet.PTYPE_CLIENT = 3      -- 客户端消息
skynet.PTYPE_LUA = 10        -- Lua 调用消息
skynet.PTYPE_SOCKET = 6      -- Socket 事件
skynet.PTYPE_ERROR = 7       -- 错误消息
```

### 4.2 发送消息

#### 调用（同步）
```lua
-- 发送消息并等待响应
local response = skynet.call(target_addr, "lua", "command", arg1, arg2)
```

#### 发送（异步）
```lua
-- 发送消息而不等待
skynet.send(target_addr, "lua", "command", arg1, arg2)
```

#### 重定向（高效转发）
```lua
-- 将消息转发到另一个服务
skynet.redirect(new_target, source, protocol, session, msg, sz)
```

### 4.3 消息处理

```lua
skynet.dispatch("lua", function(session, source, cmd, ...)
    -- session：用于发送响应
    -- source：发送者地址
    -- cmd：命令名称
    -- ...：参数
    
    -- 处理命令
    local result = process_command(cmd, ...)
    
    -- 发送响应
    skynet.ret(skynet.pack(result))
end)
```

## 5. 线程调度

### 5.1 工作线程

Skynet 使用多个工作线程（在配置中通过 `thread` 配置）：

```lua
-- 配置示例
thread = 8  -- 8 个工作线程
```

每个线程：
- 运行调度循环
- 处理就绪的服务
- 处理 I/O 事件

### 5.2 协程调度

每个服务在自己的协程中运行：

```lua
-- 服务协程
local co = coroutine.create(function()
    -- 服务代码在这里
    skynet.start(function()
        -- 这在服务协程中运行
    end)
end)
```

调度器：
- 在协程有消息时恢复它们
- 在等待时让出协程
- 在线程间平衡负载

## 6. 服务地址系统

### 6.1 地址格式

服务地址是 32 位句柄：
```
Harbor ID (8 位) | 句柄 ID (24 位)
```

### 6.2 地址管理

```lua
-- 获取当前服务地址
local my_address = skynet.self()

-- 按名称获取服务地址
local service_addr = skynet.query("servicename")

-- 注册服务名称
skynet.register("myservice")
```

## 7. 核心服务架构

### 7.1 Bootstrap 服务

第一个启动的服务：
- 加载配置
- 启动基本服务
- 初始化系统

### 7.2 Launcher 服务

创建新服务：
- 管理服务生命周期
- 处理服务创建请求

### 7.3 Gate 服务

网络网关：
- 管理客户端连接
- 将消息路由到代理
- 处理连接事件

## 8. 示例：Echo 服务架构

让我们看看 echo 服务是如何工作的：

```lua
-- examples/echo_service.lua
local skynet = require "skynet"

local function echo_handler(session, source, msg)
    skynet.error("Received:", msg)
    skynet.ret(skynet.pack("ECHO: " .. msg))
end

skynet.start(function()
    -- 注册消息处理器
    skynet.dispatch("lua", echo_handler)
    
    -- 注册服务名称
    skynet.register("ECHO_SERVICE")
    
    skynet.exit()
end)
```

消息流程：
1. 客户端向 ECHO_SERVICE 发送消息
2. 调度器将消息放入服务队列
3. 服务协程恢复
4. 处理器处理消息
5. 响应发送回客户端

## 9. 练习：服务通信链

创建形成处理链的三个服务：
- 服务 A：接收输入，乘以 2
- 服务 B：从 A 接收，加 10
- 服务 C：从 B 接收，返回最终结果

**结构**：
```
客户端 -> 服务 A -> 服务 B -> 服务 C -> 客户端
```

## 10. 性能考虑

### 10.1 消息队列优化

- 保持消息处理快速
- 避免阻塞操作
- 使用适当的消息类型

### 10.2 服务粒度

- 细粒度：许多小服务
- 粗粒度：几个大服务
- 根据用例平衡

### 10.3 内存管理

- 每个服务都有自己的 Lua 状态
- 使用调试控制台监控内存使用
- 对大型数据集使用共享数据

## 总结

在本教程中，你学到了：
- Skynet 的 Actor 模型实现
- 服务生命周期和管理
- 消息传递机制
- 线程调度和并发
- 核心服务架构
- 性能考虑因素

## 下一步

继续学习 [教程 3：创建你的第一个服务](./03_first_service.md) 以使用你学到的架构概念构建实际服务。