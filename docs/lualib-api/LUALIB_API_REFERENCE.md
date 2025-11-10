# Skynet Lua 模块 API 参考手册

本文档提供了 Skynet 框架中 lualib 目录下所有 Lua 模块的详细 API 参考。Skynet 是一个轻量级、多线程、基于 Actor 模型的游戏服务器框架。

---

## 目录

### 核心模块
- [1. 核心模块 (skynet.lua)](#1-核心模块-skynetlua)
  - [1.1 常量定义](#11-常量定义)
  - [1.2 协议管理](#12-协议管理)
  - [1.3 服务管理](#13-服务管理)
  - [1.4 消息传递](#14-消息传递)
  - [1.5 协程与调度](#15-协程与调度)
  - [1.6 定时器](#16-定时器)
  - [1.7 内存与性能](#17-内存与性能)
  - [1.8 调试与跟踪](#18-调试与跟踪)
  - [1.9 批量请求](#19-批量请求)
  - [1.10 环境变量](#110-环境变量)
  - [1.11 服务状态](#111-服务状态)
  - [1.12 初始化](#112-初始化)
  - [1.13 消息重定向](#113-消息重定向)
  - [1.14 错误处理](#114-错误处理)
  - [1.15 会话管理](#115-会话管理)
  - [1.16 消息ID生成与追踪](#116-消息id生成与追踪)

### 功能模块
- [2. Snax 框架 (snax/)](#2-snax-框架-snax)
- [3. 协议处理 (sproto)](#3-协议处理-sproto)
- [4. 网络通信 (http/)](#4-网络通信-http)
- [5. Socket API (skynet/socket.lua)](#5-socket-api-skynetsocketlua)
- [6. 集群通信 (skynet/cluster.lua)](#6-集群通信-skynetclusterlua)
- [7. DNS 解析 (skynet/dns.lua)](#7-dns-解析-skynetdnslua)
- [8. 其他工具模块](#8-其他工具模块)

### 详细内容
- [附录](#附录)

---

## 1. 核心模块 (skynet.lua)

**模块路径**: `lualib/skynet.lua`

**说明**: Skynet 框架的核心 API 模块，提供了服务管理、消息传递、协程调度、定时器等核心功能。

### 1.1 常量定义

#### 消息类型常量

```lua
skynet.PTYPE_TEXT = 0       -- 文本/调试用途
skynet.PTYPE_RESPONSE = 1   -- 响应（对端发回调用结果）
skynet.PTYPE_MULTICAST = 2  -- 多播
skynet.PTYPE_CLIENT = 3     -- 客户端（网关）
skynet.PTYPE_SYSTEM = 4     -- 系统消息
skynet.PTYPE_HARBOR = 5     -- harbor 相关
skynet.PTYPE_SOCKET = 6     -- socket 事件
skynet.PTYPE_ERROR = 7      -- 错误通知
skynet.PTYPE_QUEUE = 8      -- 队列（已废弃，使用 skynet.queue 替代）
skynet.PTYPE_DEBUG = 9      -- 调试
skynet.PTYPE_LUA = 10       -- Lua 协议（最常用）
skynet.PTYPE_SNAX = 11      -- SNAX 协议
skynet.PTYPE_TRACE = 12     -- 跟踪
```

### 1.2 协议管理

#### [skynet.register_protocol(class)](../../lualib/skynet.lua#L69)

**功能**: 注册消息协议

**参数**:
- `class` (table): 协议配置
  - `name` (string): 协议名称
  - `id` (number): 协议 ID (0-255)
  - `pack` (function, optional): 序列化函数
  - `unpack` (function, optional): 反序列化函数
  - `dispatch` (function, optional): 消息分发函数
  - `trace` (boolean, optional): 是否开启跟踪

**示例**:
```lua
skynet.register_protocol {
    name = "lua",
    id = skynet.PTYPE_LUA,
    pack = skynet.pack,
    unpack = skynet.unpack,
}
```

#### [skynet.dispatch(typename, func)](../../lualib/skynet.lua#L943)

**功能**: 注册或查询指定协议的消息分发函数

**参数**:
- `typename` (string): 协议名称
- `func` (function, optional): 分发函数

**返回**: 之前的分发函数（如果有）

**示例**:
```lua
skynet.dispatch("lua", function(session, address, ...)
    -- 处理消息
    skynet.ret(skynet.pack("response"))
end)
```

### 1.3 服务管理

#### [skynet.self()](../../lualib/skynet.lua#L670)

**功能**: 获取当前服务地址（数值形式）

**返回**: number - 服务地址

#### [skynet.localname(name)](../../lualib/skynet.lua#L675)

**功能**: 查询本地名称对应的服务地址

**参数**: `name` (string) - 服务名称

**返回**: number - 服务地址

#### [skynet.newservice(name, ...)](../../lualib/skynet.lua#L1089)

**功能**: 启动新服务

**参数**:
- `name` (string): 服务名称
- `...`: 传递给服务的参数

**返回**: number - 新服务地址

**示例**:
```lua
local auth = skynet.newservice("authservice", "config.lua")
```

#### [skynet.uniqueservice(name, ...)](../../lualib/skynet.lua#L1093)

**功能**: 启动或获取唯一服务

**参数**:
- `name` (string): 服务名称
- `global` (boolean): 是否全局唯一
- `...`: 服务参数

**返回**: number - 服务地址

**示例**:
```lua
local db = skynet.uniqueservice(true, "database")
```

#### [skynet.queryservice(name)](../../lualib/skynet.lua#L1101)

**功能**: 查询已存在的服务地址

**参数**:
- `name` (string): 服务名称
- `global` (boolean): 是否全局查询

**返回**: number - 服务地址

#### [skynet.exit()](../../lualib/skynet.lua#L721)

**功能**: 退出当前服务，关闭所有连接并通知相关服务

**示例**:
```lua
skynet.exit()
```

### 1.4 消息传递

#### [skynet.send(addr, typename, ...)](../../lualib/skynet.lua#L768)

**功能**: 异步发送消息（不等待响应）

**参数**:
- `addr` (number): 目标服务地址
- `typename` (string): 协议名称
- `...`: 消息内容

**返回**: session ID

**示例**:
```lua
skynet.send(log_service, "lua", "info", "User login")
```

#### [skynet.rawsend(addr, typename, msg, sz)](../../lualib/skynet.lua#L774)

**功能**: 发送原始消息（已打包）

**参数**:
- `addr` (number): 目标服务地址
- `typename` (string): 协议名称
- `msg` (string): 消息数据
- `sz` (number): 消息大小

**返回**: session ID

#### [skynet.call(addr, typename, ...)](../../lualib/skynet.lua#L807)

**功能**: 同步发送消息（等待响应）

**参数**:
- `addr` (number): 目标服务地址
- `typename` (string): 协议名称
- `...`: 消息内容

**返回**: 响应数据

**示例**:
```lua
local result = skynet.call(player_service, "lua", "get_player", player_id)
```

#### [skynet.rawcall(addr, typename, msg, sz)](../../lualib/skynet.lua#L823)

**功能**: 同步发送原始消息

**参数**:
- `addr` (number): 目标服务地址
- `typename` (string): 协议名称
- `msg` (string): 已打包的消息
- `sz` (number): 消息大小

**返回**: msg, sz - 响应数据

#### [skynet.ret(msg, sz)](../../lualib/skynet.lua#L846)

**功能**: 返回响应给调用方

**参数**:
- `msg` (string, optional): 响应消息
- `sz` (number, optional): 消息大小

**返回**: boolean - 是否成功

**示例**:
```lua
skynet.dispatch("lua", function(_, _, cmd, ...)
    if cmd == "get" then
        skynet.ret(skynet.pack(data))
    end
end)
```

#### [skynet.response(pack)](../../lualib/skynet.lua#L886)

**功能**: 创建响应闭包（可用于异步响应）

**参数**: `pack` (function, optional): 打包函数，默认 skynet.pack

**返回**: function - 响应闭包

**示例**:
```lua
skynet.dispatch("lua", function(session, _, cmd)
    local resp = skynet.response()
    skynet.fork(function()
        -- 异步处理
        local result = process()
        resp(true, result)
    end)
end)
```

### 1.5 协程与调度

#### [skynet.fork(func, ...)](../../lualib/skynet.lua#L981)

**功能**: 创建新协程（不阻塞当前协程）

**参数**:
- `func` (function): 协程函数
- `...`: 传递给函数的参数

**返回**: thread - 协程对象

**示例**:
```lua
skynet.fork(function()
    skynet.sleep(10)
    skynet.error("10 秒后执行")
end)
```

#### [skynet.yield()](../../lualib/skynet.lua#L594)

**功能**: 让出时间片（sleep 0）

**示例**:
```lua
skynet.yield()
```

#### [skynet.sleep(ti, token)](../../lualib/skynet.lua#L577)

**功能**: 休眠指定时间

**参数**:
- `ti` (number): 时间片数量（1/100 秒为单位）
- `token` (optional): 唤醒令牌

**返回**: "BREAK" 或 nil

**示例**:
```lua
skynet.sleep(100)  -- 休眠 1 秒
```

#### [skynet.wait(token)](../../lualib/skynet.lua#L599)

**功能**: 等待唤醒（无超时）

**参数**: `token` (optional): 唤醒令牌

**示例**:
```lua
skynet.wait()
```

#### [skynet.wakeup(token)](../../lualib/skynet.lua#L935)

**功能**: 唤醒等待的协程

**参数**: `token` (string/number): 唤醒令牌

**返回**: boolean - 是否成功唤醒

#### [skynet.killthread(thread)](../../lualib/skynet.lua#L608)

**功能**: 杀死指定协程

**参数**: `thread` (thread/string): 协程对象或字符串标识

**返回**: thread - 被杀死的协程

### 1.6 定时器

#### [skynet.timeout(ti, func)](../../lualib/skynet.lua#L556)

**功能**: 在指定时间后执行函数

**参数**:
- `ti` (number): 时间片数量
- `func` (function): 要执行的函数

**返回**: thread - 协程对象（用于调试）

**示例**:
```lua
skynet.timeout(100, function()
    skynet.error("1 秒后执行")
end)
```

#### skynet.now()

**功能**: 获取当前 tick 数（1/100 秒）

**返回**: number - 当前 tick

#### [skynet.starttime()](../../lualib/skynet.lua#L708)

**功能**: 获取进程启动时间（秒）

**返回**: number - 启动时间戳

#### [skynet.time()](../../lualib/skynet.lua#L716)

**功能**: 获取当前时间（秒）

**返回**: number - 当前时间戳

### 1.7 内存与性能

#### skynet.pack(...)

**功能**: 打包数据为字符串

**参数**: `...`: 要打包的数据

**返回**: string - 打包后的数据

#### skynet.unpack(msg, sz)

**功能**: 解包数据

**参数**:
- `msg` (string): 消息数据
- `sz` (number, optional): 消息大小

**返回**: 解包后的数据

#### skynet.tostring(msg, sz)

**功能**: 将消息转换为字符串表示

**参数**:
- `msg` (string): 消息数据
- `sz` (number, optional): 消息大小

**返回**: string - 字符串表示

#### skynet.trash(msg, sz)

**功能**: 释放消息内存

**参数**:
- `msg` (string): 消息数据
- `sz` (number): 消息大小

#### [skynet.memlimit(bytes)](../../lualib/skynet.lua#L1288)

**功能**: 设置 Lua 内存上限

**参数**: `bytes` (number): 内存限制（字节）

**注意**: 只能设置一次

### 1.8 调试与跟踪

#### [skynet.trace(info)](../../lualib/skynet.lua#L684)

**功能**: 开启跟踪

**参数**: `info` (string, optional): 跟踪信息

#### [skynet.tracetag()](../../lualib/skynet.lua#L701)

**功能**: 获取当前协程的跟踪标签

**返回**: string/nil - 跟踪标签

#### [skynet.traceproto(prototype, flag)](../../lualib/skynet.lua#L1127)

**功能**: 设置协议跟踪策略

**参数**:
- `prototype` (string/number): 协议
- `flag` (boolean/nil): 跟踪标志
  - `true`: 强制开启
  - `false`: 强制关闭
  - `nil`: 可选（调用 skynet.trace() 开启）

#### [skynet.trace_timeout(on)](../../lualib/skynet.lua#L534)

**功能**: 开启/关闭定时器跟踪

**参数**: `on` (boolean): 是否开启

#### skynet.error(...)

**功能**: 输出错误信息到控制台

**参数**: `...`: 要输出的信息

**示例**:
```lua
skynet.error("错误信息")
```

#### [skynet.task(ret)](../../lualib/skynet.lua#L1211)

**功能**: 查看协程任务信息

**参数**: `ret` (optional): 查询参数
- `nil`: 返回挂起的协程数量
- `"init"`: 返回初始化线程的堆栈
- `table`: 填充所有协程的堆栈信息
- `number`: 返回指定 session 的协程堆栈
- `thread`: 返回协程对应的 session

**返回**: 取决于参数类型

#### [skynet.uniqtask()](../../lualib/skynet.lua#L1258)

**功能**: 归并相同堆栈的协程，统计分布

**返回**: table - {堆栈摘要 = 堆栈信息}

### 1.9 批量请求

#### skynet.request(obj)

**功能**: 创建批量请求对象

**参数**: `obj` (table, optional): 请求配置

**返回**: request_meta - 批量请求对象

**示例**:
```lua
local req = skynet.request()
req(add_service, "add", 1, 2)
req(mul_service, "mul", 3, 4)
for req, resp in req:select() do
    print(req[2], resp)
end
```

### 1.10 环境变量

#### [skynet.getenv(key)](../../lualib/skynet.lua#L757)

**功能**: 获取环境变量

**参数**: `key` (string): 变量名

**返回**: string - 变量值

#### [skynet.setenv(key, value)](../../lualib/skynet.lua#L762)

**功能**: 设置环境变量

**参数**:
- `key` (string): 变量名
- `value` (string): 变量值

**注意**: 只能设置一次

### 1.11 服务状态

#### [skynet.endless()](../../lualib/skynet.lua#L1186)

**功能**: 检查当前服务是否处于无尽循环（无消息但仍在运行）

**返回**: boolean - 是否无尽循环

#### [skynet.mqlen()](../../lualib/skynet.lua#L1191)

**功能**: 获取当前服务消息队列长度

**返回**: number - 队列长度

#### [skynet.stat(what)](../../lualib/skynet.lua#L1196)

**功能**: 读取内部统计项

**参数**: `what` (string): 统计项名称

**返回**: number - 统计值

### 1.12 初始化

#### [skynet.start(start_func)](../../lualib/skynet.lua#L1176)

**功能**: 设置服务启动函数

**参数**: `start_func` (function): 启动函数

**示例**:
```lua
skynet.start(function()
    skynet.dispatch("lua", function(...)
        -- 处理消息
    end)
end)
```

#### [skynet.init_service(start)](../../lualib/skynet.lua#L1161)

**功能**: 初始化服务（内部使用）

#### [skynet.init(func)](../../lualib/skynet.lua#L)

**功能**: 注册服务初始化函数

**参数**: `func` (function): 初始化函数

### 1.13 消息重定向

#### [skynet.redirect(dest, source, typename, ...)](../../lualib/skynet.lua#L)

**功能**: 重定向消息到其他服务

**参数**:
- `dest` (number): 目标地址
- `source` (number): 原始源地址
- `typename` (string): 协议名称
- `...`: 消息内容

### 1.14 错误处理

#### [skynet.term(service)](../../lualib/skynet.lua#L1283)

**功能**: 模拟服务宕机，触发错误清理流程

**参数**: `service` (number): 服务地址

#### [skynet.dispatch_unknown_request(unknown)](../../lualib/skynet.lua#L961)

**功能**: 设置未知请求处理函数

**参数**: `unknown` (function): 处理函数

**返回**: function - 原处理函数

#### [skynet.dispatch_unknown_response(unknown)](../../lualib/skynet.lua#L974)

**功能**: 设置未知响应处理函数

**参数**: `unknown` (function): 处理函数

**返回**: function - 原处理函数

### 1.15 会话管理

#### skynet.genid()

**功能**: 生成新的会话 ID

**返回**: number - 会话 ID

#### [skynet.context()](../../lualib/skynet.lua#L873)

**功能**: 获取当前协程的会话上下文

**返回**: session, address - 会话 ID 和对端地址

#### [skynet.ignoreret()](../../lualib/skynet.lua#L880)

**功能**: 忽略当前会话的返回值

### 1.16 消息ID生成与追踪

#### [skynet.address(addr)](../../lualib/skynet.lua#L1109)

**功能**: 将地址转换为十六进制字符串

**参数**: `addr` (number/string): 地址

**返回**: string - 格式化的地址

**示例**:
```lua
local str_addr = skynet.address(0x12345678)  -- ":12345678"
```

#### [skynet.harbor(addr)](../../lualib/skynet.lua#L1117)

**功能**: 获取地址的 harbor ID

**参数**: `addr` (number): 服务地址

**返回**: number - harbor ID

---

## 2. Snax 框架 (snax/)

**模块路径**: `lualib/snax/`

**说明**: Snax 是基于 Skynet 的 Actor 模型框架，提供了更简洁的 API。

### 2.1 snax.lua

#### [snax.interface(name)](../../lualib/snax/interface.lua#L)

**功能**: 获取服务接口描述

**参数**: `name` (string): 服务名称

**返回**: table - 接口描述
- `accept`: 通知类方法
- `response`: 请求响应类方法
- `system`: 系统方法（init、exit、hotfix、profile）

#### [snax.newservice(name, ...)](../../lualib/snax/interface.lua#L)

**功能**: 创建新 Snax 服务

**参数**:
- `name` (string): 服务名称
- `...`: 初始化参数

**返回**: service_obj - 服务对象

**示例**:
```lua
local auth = snax.newservice("auth", "config.lua")
```

#### [snax.rawnewservice(name, ...)](../../lualib/snax/interface.lua#L)

**功能**: 创建原始 Snax 服务（不绑定接口）

**参数**:
- `name` (string): 服务名称
- `...`: 初始化参数

**返回**: handle - 服务句柄

#### [snax.bind(handle, type)](../../lualib/snax/interface.lua#L)

**功能**: 绑定服务句柄到接口

**参数**:
- `handle` (number): 服务句柄
- `type` (string): 服务类型

**返回**: service_obj - 服务对象

#### [snax.uniqueservice(name, ...)](../../lualib/snax/interface.lua#L)

**功能**: 创建或获取唯一 Snax 服务

**参数**:
- `name` (string): 服务名称
- `...`: 初始化参数

**返回**: service_obj - 服务对象

#### [snax.globalservice(name, ...)](../../lualib/snax/interface.lua#L)

**功能**: 创建或获取全局唯一 Snax 服务

**参数**:
- `name` (string): 服务名称
- `...`: 初始化参数

**返回**: service_obj - 服务对象

#### [snax.queryservice(name)](../../lualib/snax/interface.lua#L)

**功能**: 查询已存在的 Snax 服务

**参数**: `name` (string): 服务名称

**返回**: service_obj - 服务对象

#### [snax.queryglobal(name)](../../lualib/snax/interface.lua#L)

**功能**: 查询全局 Snax 服务

**参数**: `name` (string): 服务名称

**返回**: service_obj - 服务对象

#### [snax.kill(obj, ...)](../../lualib/snax/interface.lua#L)

**功能**: 关闭 Snax 服务

**参数**:
- `obj` (service_obj): 服务对象
- `...`: 关闭参数

#### [snax.exit(...)](../../lualib/snax/interface.lua#L)

**功能**: 退出当前 Snax 服务

**参数**: `...`: 退出参数

#### [snax.self()](../../lualib/snax/interface.lua#L)

**功能**: 获取当前 Snax 服务对象

**返回**: service_obj - 服务对象

#### [snax.hotfix(obj, source, ...)](../../lualib/snax/hotfix.lua#L)

**功能**: 热更新 Snax 服务

**参数**:
- `obj` (service_obj): 服务对象
- `source` (string): 新代码源
- `...`: 传递给热更新函数的参数

**返回**: 热更新结果

**示例**:
```lua
local result = snax.hotfix(auth, new_code, param1, param2)
```

#### [snax.profile_info(obj)](../../lualib/snax/interface.lua#L)

**功能**: 获取 Snax 服务性能信息

**参数**: `obj` (service_obj): 服务对象

**返回**: table - 性能统计信息

#### [snax.printf(fmt, ...)](../../lualib/snax/interface.lua#L)

**功能**: 格式化输出日志

**参数**:
- `fmt` (string): 格式字符串
- `...`: 参数

**示例**:
```lua
snax.printf("用户 %d 登录", user_id)
```

#### Service Object 方法

**服务对象** 包含以下方法：

- `post` - 发送通知（不等待响应）
  ```lua
  auth.post.login(user_id, password)
  ```

- `req` - 发送请求（等待响应）
  ```lua
  local result = auth.req.auth(user_id, password)
  ```

### 2.2 snax/interface.lua

**功能**: 解析 Snax 服务接口定义

### 2.3 snax/hotfix.lua

**功能**: 提供热更新机制

### 2.4 snax/gateserver.lua

**功能**: 网关服务器基类

**主要方法**:
- `start()` - 启动网关
- `accept(id)` - 接受连接
- `close(id)` - 关闭连接
- `disconnect(id)` - 断开连接

### 2.5 snax/msgserver.lua

**功能**: 消息服务器基类

**主要方法**:
- `start()` - 启动服务
- `accept(id)` - 接受连接
- `disconnect(id)` - 断开连接

### 2.6 snax/loginserver.lua

**功能**: 登录服务器基类

**主要方法**:
- `start()` - 启动服务
- `accept(id)` - 接受连接
- `disconnect(id)` - 断开连接

---

## 3. 协议处理 (sproto)

**模块路径**: `lualib/sproto.lua`, `lualib/sprotoparser.lua`, `lualib/sprotoloader.lua`

**说明**: Sproto 是 Skynet 内置的二进制协议库，提供高效的序列化和反序列化功能。

### 3.1 sproto.lua

#### [sproto.new(bin)](../../lualib/sproto.lua#L)

**功能**: 从二进制数据创建 sproto 对象

**参数**: `bin` (string): 二进制数据

**返回**: sproto_obj - sproto 对象

#### [sproto.parse(ptext)](../../lualib/sproto.lua#L)

**功能**: 从文本描述创建 sproto 对象

**参数**: `ptext` (string): 协议文本描述

**返回**: sproto_obj - sproto 对象

**示例**:
```lua
local sp = sproto.parse[[
    .Person {
        name 0 : string
        id 1 : integer
        email 2 : string
    }

    .AddressBook {
        persons 0 : *Person
    }

    .Request {
        cmd 0 : string
        data 1 : AddressBook
    }
]]
```

#### [sproto.sharenew(cobj)](../../lualib/sproto.lua#L)

**功能**: 共享 sproto 对象（无 GC）

**参数**: `cobj` (userdata): C 对象

**返回**: sproto_obj - sproto 对象

#### sproto 对象方法

##### :host(packagename)

**功能**: 创建协议主机对象

**参数**: `packagename` (string, optional): 包名，默认 "package"

**返回**: host_obj - 主机对象

##### :encode(typename, tbl)

**功能**: 编码数据

**参数**:
- `typename` (string): 类型名称
- `tbl` (table): 要编码的数据

**返回**: string - 编码后的数据

##### :decode(typename, ...)

**功能**: 解码数据

**参数**:
- `typename` (string): 类型名称
- `...`: 编码数据

**返回**: table - 解码后的数据

##### :pencode(typename, tbl)

**功能**: 打包编码（编码后压缩）

**参数**:
- `typename` (string): 类型名称
- `tbl` (table): 要编码的数据

**返回**: string - 编码后的数据

##### :pdecode(typename, ...)

**功能**: 解包解码（解压缩后解码）

**参数**:
- `typename` (string): 类型名称
- `...`: 编码数据

**返回**: table - 解码后的数据

##### :queryproto(pname)

**功能**: 查询协议信息

**参数**: `pname` (string/number): 协议名称或标签

**返回**: table - 协议信息
```lua
{
    request = request_type,
    response = response_type,
    name = "协议名",
    tag = 123
}
```

##### :exist_proto(pname)

**功能**: 检查协议是否存在

**参数**: `pname` (string): 协议名称

**返回**: boolean - 是否存在

##### :request_encode(protoname, tbl)

**功能**: 编码请求数据

**参数**:
- `protoname` (string): 协议名称
- `tbl` (table): 请求数据

**返回**: msg, tag - 编码数据和协议标签

##### :response_encode(protoname, tbl)

**功能**: 编码响应数据

**参数**:
- `protoname` (string): 协议名称
- `tbl` (table): 响应数据

**返回**: string - 编码数据

##### :request_decode(protoname, ...)

**功能**: 解码请求数据

**参数**:
- `protoname` (string): 协议名称
- `...`: 编码数据

**返回**: data, name - 解码数据和协议名

##### :response_decode(protoname, ...)

**功能**: 解码响应数据

**参数**:
- `protoname` (string): 协议名称
- `...`: 编码数据

**返回**: data - 解码数据

##### :exist_type(typename)

**功能**: 检查类型是否存在

**参数**: `typename` (string): 类型名称

**返回**: boolean - 是否存在

##### :default(typename, type)

**功能**: 获取默认值

**参数**:
- `typename` (string): 类型名称
- `type` (string, optional): "REQUEST" 或 "RESPONSE"

**返回**: table - 默认值

#### host 对象方法

##### :dispatch(...)

**功能**: 分发消息

**参数**: `...`: 接收到的数据

**返回**:
- `"REQUEST"`, name, data, response, ud - 请求消息
- `"RESPONSE"`, session, data, ud - 响应消息

**示例**:
```lua
host:dispatch(data)
```

##### :attach(sp)

**功能**: 附加到 sproto 对象，返回打包函数

**参数**: `sp` (sproto_obj): sproto 对象

**返回**: function - 打包函数

**示例**:
```lua
local pack = host:attach(sp)
local msg = pack("request_name", {arg1=1, arg2=2}, session_id)
```

### 3.2 sprotoparser.lua

#### [sparser.parse(text, name)](../../lualib/sprotoparser.lua#L)

**功能**: 解析协议文本

**参数**:
- `text` (string): 协议文本
- `name` (string, optional): 名称

**返回**: string - 二进制数据

#### [sparser.dump(str)](../../lualib/sprotoparser.lua#L)

**功能**: 打印协议的十六进制表示

**参数**: `str` (string): 二进制数据

### 3.3 sprotoloader.lua

#### [loader.register(filename, index)](../../lualib/sprotoloader.lua#L)

**功能**: 注册并保存协议文件

**参数**:
- `filename` (string): 文件名
- `index` (string): 索引

#### [loader.save(bin, index)](../../lualib/sprotoloader.lua#L)

**功能**: 保存二进制数据

**参数**:
- `bin` (string): 二进制数据
- `index` (string): 索引

#### [loader.load(index)](../../lualib/sprotoloader.lua#L)

**功能**: 加载协议

**参数**: `index` (string): 索引

**返回**: sproto_obj - sproto 对象

---

## 4. 网络通信 (http/)

**模块路径**: `lualib/http/`

**说明**: 提供 HTTP 客户端、服务器和 WebSocket 支持。

### 4.1 httpd.lua (HTTP 服务器)

#### [httpd.read_request(readbytes, bodylimit)](../../lualib/http/httpd.lua#L)

**功能**: 读取 HTTP 请求

**参数**:
- `readbytes` (function): 读取字节函数
- `bodylimit` (number, optional): 主体大小限制

**返回**:
- `ok, code, url, method, header, body` - 成功时
- `nil, code` - 失败时

#### [httpd.write_response(writefunc, statuscode, bodyfunc, header)](../../lualib/http/httpd.lua#L)

**功能**: 写入 HTTP 响应

**参数**:
- `writefunc` (function): 写入函数
- `statuscode` (number): 状态码
- `bodyfunc` (string/function): 主体内容或生成函数
- `header` (table, optional): 响应头

**返回**: boolean - 是否成功

**示例**:
```lua
local function write(sock, data)
    sock:send(data)
end

httpd.write_response(write, 200, "Hello World", {
    ["Content-Type"] = "text/plain"
})
```

### 4.2 httpc.lua (HTTP 客户端)

#### [httpc.dns(server, port)](../../lualib/http/httpc.lua#L)

**功能**: 设置 DNS 服务器

**参数**:
- `server` (string): DNS 服务器地址
- `port` (number, optional): 端口

#### [httpc.request(method, hostname, url, recvheader, header, content)](../../lualib/http/httpc.lua#L)

**功能**: 发起 HTTP 请求

**参数**:
- `method` (string): HTTP 方法（GET/POST 等）
- `hostname` (string): 主机名
- `url` (string): URL 路径
- `recvheader` (table, optional): 接收的响应头
- `header` (table, optional): 请求头
- `content` (string, optional): 请求体

**返回**: statuscode, body - 状态码和响应体

**示例**:
```lua
local code, body = httpc.request("GET", "example.com", "/api/data")
local code, body = httpc.post("api.example.com", "/login", {username="user", password="pass"})
```

#### [httpc.get(...)](../../lualib/http/httpc.lua#L154)

**功能**: 发起 GET 请求

**参数**: `...`: 同 request

**返回**: statuscode, body

#### [httpc.head(hostname, url, recvheader, header, content)](../../lualib/http/httpc.lua#L)

**功能**: 发起 HEAD 请求

**参数**: `...`: 同 request

**返回**: statuscode

#### [httpc.post(host, url, form, recvheader)](../../lualib/http/httpc.lua#L)

**功能**: 发起 POST 请求（表单）

**参数**:
- `host` (string): 主机
- `url` (string): URL
- `form` (table): 表单数据
- `recvheader` (table, optional): 接收头

**返回**: statuscode, body

#### [httpc.request_stream(method, hostname, url, recvheader, header, content)](../../lualib/http/httpc.lua#L)

**功能**: 发起流式请求

**参数**: 同 request

**返回**: stream 对象

### 4.3 websocket.lua (WebSocket)

#### [websocket.accept(socket_id, handle, protocol, addr, options)](../../lualib/http/websocket.lua#L)

**功能**: 接受 WebSocket 连接（服务器端）

**参数**:
- `socket_id` (number): Socket ID
- `handle` (table): 处理器
- `protocol` (string, optional): 协议（"ws" 或 "wss"）
- `addr` (string, optional): 地址
- `options` (table, optional): 选项

**返回**: boolean, err - 是否成功

**示例**:
```lua
websocket.accept(id, {
    connect = function(ws) end,
    handshake = function(ws, header, url) end,
    message = function(ws, data, op) end,
    close = function(ws, code, reason) end,
    ping = function(ws) end,
    pong = function(ws) end,
    error = function(ws, err) end,
})
```

#### [websocket.connect(url, header, timeout)](../../lualib/http/websocket.lua#L)

**功能**: 连接 WebSocket（客户端）

**参数**:
- `url` (string): WebSocket URL
- `header` (table, optional): 请求头
- `timeout` (number, optional): 超时

**返回**: socket_id

**示例**:
```lua
local id = websocket.connect("ws://example.com/ws")
```

#### [websocket.read(id)](../../lualib/http/websocket.lua#L)

**功能**: 读取 WebSocket 消息

**参数**: `id` (number): WebSocket ID

**返回**: data, false - 数据（正常）或 false, data（关闭时）

#### [websocket.write(id, data, fmt, masking_key)](../../lualib/http/websocket.lua#L)

**功能**: 写入 WebSocket 消息

**参数**:
- `id` (number): WebSocket ID
- `data` (string): 数据
- `fmt` (string, optional): 格式（"text" 或 "binary"）
- `masking_key` (string, optional): 掩码键

#### [websocket.ping(id)](../../lualib/http/websocket.lua#L)

**功能**: 发送 ping 帧

**参数**: `id` (number): WebSocket ID

#### [websocket.close(id, code, reason)](../../lualib/http/websocket.lua#L)

**功能**: 关闭 WebSocket 连接

**参数**:
- `id` (number): WebSocket ID
- `code` (number, optional): 关闭码
- `reason` (string, optional): 关闭原因

#### [websocket.addrinfo(id)](../../lualib/http/websocket.lua#L)

**功能**: 获取 WebSocket 地址信息

**参数**: `id` (number): WebSocket ID

**返回**: string - 地址信息

#### [websocket.real_ip(id)](../../lualib/http/websocket.lua#L)

**功能**: 获取真实 IP（如果通过代理）

**参数**: `id` (number): WebSocket ID

**返回**: string - 真实 IP

#### [websocket.is_close(id)](../../lualib/http/websocket.lua#L)

**功能**: 检查 WebSocket 是否已关闭

**参数**: `id` (number): WebSocket ID

**返回**: boolean - 是否关闭

### 4.4 http/sockethelper.lua

**功能**: Socket 辅助函数

### 4.5 http/internal.lua

**功能**: HTTP 内部处理函数

### 4.6 http/url.lua

**功能**: URL 解析

### 4.7 http/tlshelper.lua

**功能**: TLS/SSL 辅助函数

---

## 5. Socket API (skynet/socket.lua)

**模块路径**: `lualib/skynet/socket.lua`

**说明**: 提供高层 Socket API，支持 TCP/UDP，封装底层 socketdriver。

### 5.1 TCP 连接

#### [socket.open(addr, port)](../../lualib/skynet/socket.lua#L255)

**功能**: 连接到 TCP 服务

**参数**:
- `addr` (string): 地址
- `port` (number): 端口

**返回**: id - Socket ID

**示例**:
```lua
local id = socket.open("127.0.0.1", 8080)
```

#### [socket.bind(os_fd)](../../lualib/skynet/socket.lua#L)

**功能**: 绑定已有文件描述符

**参数**: `os_fd` (number): 系统文件描述符

**返回**: id - Socket ID

#### [socket.stdin()](../../lualib/skynet/socket.lua#L)

**功能**: 将标准输入封装为 socket

**返回**: id - Socket ID

#### [socket.start(id, func)](../../lualib/skynet/socket.lua#L)

**功能**: 启动监听 socket

**参数**:
- `id` (number): Socket ID
- `func` (function): 接受连接回调 `func(newid, addr)`

**示例**:
```lua
socket.start(id, function(newid, addr)
    skynet.error("新连接:", newid, addr)
end)
```

#### [socket.listen(host, port, backlog)](../../lualib/skynet/socket.lua#L)

**功能**: 监听端口

**参数**:
- `host` (string): 主机地址
- `port` (number): 端口
- `backlog` (number, optional):  backlog 大小

**返回**: id, addr, port - Socket ID, 地址, 端口

**示例**:
```lua
socket.listen("0.0.0.0", 8888)
```

### 5.2 读取数据

#### [socket.read(id, sz)](../../lualib/skynet/socket.lua#L)

**功能**: 读取指定字节数

**参数**:
- `id` (number): Socket ID
- `sz` (number, optional): 字节数（nil 表示读所有可用数据）

**返回**: data 或 false, data - 成功时返回数据，失败时返回 false

**示例**:
```lua
local data = socket.read(id, 1024)
```

#### [socket.readall(id)](../../lualib/skynet/socket.lua#L)

**功能**: 读取所有数据直到连接关闭

**参数**: `id` (number): Socket ID

**返回**: data - 所有数据（连接关闭后）

#### [socket.readline(id, sep)](../../lualib/skynet/socket.lua#L)

**功能**: 读取一行（以分隔符结尾）

**参数**:
- `id` (number): Socket ID
- `sep` (string, optional): 分隔符，默认 "\n"

**返回**: line - 读取的行

**示例**:
```lua
local line = socket.readline(id, "\r\n")
```

#### [socket.block(id)](../../lualib/skynet/socket.lua#L)

**功能**: 阻塞直到有数据

**参数**: `id` (number): Socket ID

**返回**: boolean - 连接是否仍然有效

### 5.3 写入数据

#### [socket.write(id, data)](../../lualib/skynet/socket.lua#L)

**功能**: 写入数据

**参数**:
- `id` (number): Socket ID
- `data` (string): 数据

**返回**: boolean - 是否成功

#### [socket.lwrite(id, data)](../../lualib/skynet/socket.lua#L)

**功能**: 低延迟写入

**参数**:
- `id` (number): Socket ID
- `data` (string): 数据

### 5.4 关闭连接

#### [socket.close(id)](../../lualib/skynet/socket.lua#L)

**功能**: 关闭连接

**参数**: `id` (number): Socket ID

#### [socket.shutdown(id)](../../lualib/skynet/socket.lua#L)

**功能**: 半关闭（发送完缓冲后关闭）

**参数**: `id` (number): Socket ID

#### [socket.close_fd(id)](../../lualib/skynet/socket.lua#L)

**功能**: 强制关闭

**参数**: `id` (number): Socket ID

**注意**: 必须确保 socket 不在使用中

#### [socket.abandon(id)](../../lualib/skynet/socket.lua#L)

**功能**: 放弃 socket（不关闭，用于转发）

**参数**: `id` (number): Socket ID

### 5.5 控制与状态

#### [socket.pause(id)](../../lualib/skynet/socket.lua#L)

**功能**: 暂停读取（反压）

**参数**: `id` (number): Socket ID

#### [socket.warning(id, callback)](../../lualib/skynet/socket.lua#L)

**功能**: 设置发送警告回调

**参数**:
- `id` (number): Socket ID
- `callback` (function): 回调函数 `callback(id, size)`

#### [socket.onclose(id, callback)](../../lualib/skynet/socket.lua#L)

**功能**: 设置关闭回调

**参数**:
- `id` (number): Socket ID
- `callback` (function): 回调函数 `callback(id)`

#### [socket.invalid(id)](../../lualib/skynet/socket.lua#L)

**功能**: 检查 socket 是否无效

**参数**: `id` (number): Socket ID

**返回**: boolean

#### [socket.disconnected(id)](../../lualib/skynet/socket.lua#L)

**功能**: 检查是否已断开

**参数**: `id` (number): Socket ID

**返回**: boolean

#### [socket.limit(id, limit)](../../lualib/skynet/socket.lua#L)

**功能**: 设置缓冲区限制

**参数**:
- `id` (number): Socket ID
- `limit` (number): 字节数

### 5.6 UDP

#### [socket.udp(callback, host, port)](../../lualib/skynet/socket.lua#L)

**功能**: 创建 UDP socket

**参数**:
- `callback` (function): 接收回调 `callback(data, address)`
- `host` (string, optional): 主机
- `port` (number, optional): 端口

**返回**: id - Socket ID

#### [socket.udp_connect(id, addr, port, callback)](../../lualib/skynet/socket.lua#L)

**功能**: UDP 连接

**参数**:
- `id` (number): Socket ID
- `addr` (string): 地址
- `port` (number): 端口
- `callback` (function, optional): 接收回调

#### [socket.udp_listen(addr, port, callback)](../../lualib/skynet/socket.lua#L)

**功能**: UDP 监听

**参数**:
- `addr` (string): 地址
- `port` (number): 端口
- `callback` (function): 接收回调

**返回**: id - Socket ID

#### [socket.udp_dial(addr, port, callback)](../../lualib/skynet/socket.lua#L)

**功能**: UDP 拨号

**参数**:
- `addr` (string): 地址
- `port` (number): 端口
- `callback` (function): 接收回调

**返回**: id - Socket ID

#### [socket.sendto(id, addr, port, data)](../../lualib/skynet/socket.lua#L)

**功能**: 发送 UDP 数据

**参数**:
- `id` (number): Socket ID
- `addr` (string): 目标地址
- `port` (number): 目标端口
- `data` (string): 数据

#### [socket.udp_address(id)](../../lualib/skynet/socket.lua#L)

**功能**: 获取 UDP 地址信息

**参数**: `id` (number): Socket ID

**返回**: addr, port - 地址和端口

#### [socket.netstat(id)](../../lualib/skynet/socket.lua#L)

**功能**: 获取网络状态

**参数**: `id` (number): Socket ID

**返回**: table - 网络状态信息

#### [socket.resolve(host, port)](../../lualib/skynet/socket.lua#L)

**功能**: 解析地址

**参数**:
- `host` (string): 主机
- `port` (number): 端口

**返回**: addr - IP 地址

---

## 6. 集群通信 (skynet/cluster.lua)

**模块路径**: `lualib/skynet/cluster.lua`

**说明**: 提供跨节点的集群通信功能。

### 6.1 集群调用

#### [cluster.call(node, address, ...)](../../lualib/skynet/cluster.lua#L60)

**功能**: 跨节点同步调用

**参数**:
- `node` (string): 节点名称
- `address` (number/string): 服务地址或名称
- `...`: 调用参数

**返回**: 响应数据

**示例**:
```lua
local result = cluster.call("node1", 0x123456, "get_player", 1001)
```

#### [cluster.send(node, address, ...)](../../lualib/skynet/cluster.lua#L)

**功能**: 跨节点异步发送

**参数**:
- `node` (string): 节点名称
- `address` (number/string): 服务地址或名称
- `...`: 消息内容

#### [cluster.query(node, name)](../../lualib/skynet/cluster.lua#L)

**功能**: 跨节点查询服务

**参数**:
- `node` (string): 节点名称
- `name` (string): 服务名称

**返回**: 服务地址

### 6.2 集群管理

#### [cluster.open(port, maxclient)](../../lualib/skynet/cluster.lua#L)

**功能**: 打开集群监听

**参数**:
- `port` (string/number): 端口（字符串为 "host:port"，数字为端口号）
- `maxclient` (number, optional): 最大客户端数

**返回**: boolean - 是否成功

#### [cluster.reload(config)](../../lualib/skynet/cluster.lua#L)

**功能**: 重新加载集群配置

**参数**: `config` (table): 配置表

#### [cluster.proxy(node, name)](../../lualib/skynet/cluster.lua#L)

**功能**: 获取远程服务代理

**参数**:
- `node` (string): 节点名称
- `name` (string): 服务名称或地址

**返回**: service - 代理服务

#### [cluster.snax(node, name, address)](../../lualib/skynet/cluster.lua#L)

**功能**: 获取远程 Snax 服务代理

**参数**:
- `node` (string): 节点名称
- `name` (string): 服务名称
- `address` (number, optional): 服务地址

**返回**: snax_obj - Snax 服务对象

### 6.3 服务注册

#### [cluster.register(name, addr)](../../lualib/skynet/cluster.lua#L)

**功能**: 注册服务到集群

**参数**:
- `name` (string): 服务名称
- `addr` (number, optional): 服务地址（默认当前服务）

#### [cluster.unregister(name)](../../lualib/skynet/cluster.lua#L)

**功能**: 取消注册服务

**参数**: `name` (string): 服务名称

### 6.4 内部方法

#### [cluster.get_sender(node)](../../lualib/skynet/cluster.lua#L)

**功能**: 获取节点发送器（内部使用）

**参数**: `node` (string): 节点名称

**返回**: sender - 发送器

---

## 7. DNS 解析 (skynet/dns.lua)

**模块路径**: `lualib/skynet/dns.lua`

**说明**: 提供异步 DNS 解析功能。

### 7.1 常量

```lua
dns.DEFAULT_HOSTS = "/etc/hosts"        -- 默认 hosts 文件
dns.DEFAULT_RESOLV_CONF = "/etc/resolv.conf"  -- 默认 DNS 配置
```

### 7.2 主要方法

#### [dns.server(server, port)](../../lualib/skynet/dns.lua#L)

**功能**: 设置 DNS 服务器

**参数**:
- `server` (string): DNS 服务器地址
- `port` (number, optional): 端口

**示例**:
```lua
dns.server("8.8.8.8", 53)
```

#### [dns.resolve(name, callback)](../../lualib/skynet/dns.lua#L)

**功能**: 解析域名

**参数**:
- `name` (string): 域名
- `callback` (function): 回调函数 `callback(ip, err)`

**示例**:
```lua
dns.resolve("example.com", function(ip, err)
    if ip then
        print("IP:", ip)
    else
        print("Error:", err)
    end
end)
```

#### [dns.resolve_sync(name, timeout)](../../lualib/skynet/dns.lua#L)

**功能**: 同步解析域名

**参数**:
- `name` (string): 域名
- `timeout` (number, optional): 超时时间

**返回**: ip - IP 地址

**示例**:
```lua
local ip = dns.resolve_sync("example.com", 5000)
```

#### [dns.ip_to_str(ip)](../../lualib/skynet/dns.lua#L)

**功能**: 将 IP 转换为字符串

**参数**: `ip` (number): IP 地址（网络字节序）

**返回**: string - IP 字符串

#### [dns.str_to_ip(str)](../../lualib/skynet/dns.lua#L)

**功能**: 将字符串转换为 IP

**参数**: `str` (string): IP 字符串

**返回**: number - IP 地址（网络字节序）

---

## 8. 其他工具模块

### 8.1 工具模块列表

#### 8.1.1 loader.lua

**功能**: 服务加载器

**说明**: 根据 SERVICE_NAME 加载对应的 Lua 服务文件

#### 8.1.2 md5.lua

**功能**: MD5 哈希算法

**主要方法**:

##### core.sumhexa(k)

**功能**: 计算 MD5 哈希值（十六进制）

**参数**: `k` (string): 输入字符串

**返回**: string - MD5 哈希值（十六进制）

**示例**:
```lua
local hash = core.sumhexa("Hello World")
```

##### core.sum(k)

**功能**: 计算 MD5 哈希值（二进制）

**参数**: `k` (string): 输入字符串

**返回**: string - MD5 哈希值（二进制）

##### core.hmacmd5(data, key)

**功能**: 计算 HMAC-MD5

**参数**:
- `data` (string): 数据
- `key` (string): 密钥

**返回**: string - HMAC-MD5 值（十六进制）

#### 8.1.3 skynet/coroutine.lua

**功能**: 协程辅助工具

**主要方法**:

##### skynet.coroutine.resume(co, ...)

**功能**: 恢复协程

##### skynet.coroutine.running()

**功能**: 获取当前运行的协程

##### skynet.coroutine.create(f)

**功能**: 创建协程

##### skynet.coroutine.status(co)

**功能**: 获取协程状态

**返回**: "running", "suspended", "normal", "dead"

#### 8.1.4 skynet/datacenter.lua

**功能**: 数据中心服务

**主要方法**:

##### datacenter.call(name, ...)

**功能**: 调用数据中心服务

##### datacenter.acall(name, ...)

**功能**: 异步调用数据中心服务

##### datacenter.map(name, func)

**功能**: 映射数据中心数据

#### 8.1.5 skynet/debug.lua

**功能**: 调试工具

**主要方法**:

##### debug.debug()

**功能**: 进入调试模式

##### debug.sethook(hook, mask, count)

**功能**: 设置钩子函数

#### 8.1.6 skynet/harbor.lua

**功能**: Harbor 管理

**主要方法**:

##### harbor.queryname(name)

**功能**: 查询服务名称

##### harbor.register(name, addr)

**功能**: 注册服务

##### harbor.link(id)

**功能**: 链接到远程节点

##### harbor.linkmaster()

**功能**: 链接到主节点

##### harbor.unlink(id)

**功能**: 取消链接

#### 8.1.7 skynet/inject.lua

**功能**: 代码注入

**主要方法**:

##### inject.attach(service, command, handler)

**功能**: 附加注入处理

##### inject.execute(sn, command, ...)

**功能**: 执行注入

#### 8.1.8 skynet/manager.lua

**功能**: 服务管理器

**主要方法**:

##### manager.register(name, impl)

**功能**: 注册服务实现

##### manager.unregister(name)

**功能**: 取消注册

#### 8.1.9 skynet/mqueue.lua

**功能**: 消息队列（已废弃）

**注意**: 使用 `skynet.queue` 替代

#### 8.1.10 skynet/multicast.lua

**功能**: 多播服务

**主要方法**:

##### multicast.create(channel, group, member)

**功能**: 创建多播

##### multicast.send(channel, data)

**功能**: 发送多播数据

##### multicast.del_group(group)

**功能**: 删除组

#### 8.1.11 skynet/queue.lua

**功能**: 队列服务

**主要方法**:

##### queue.create()

**功能**: 创建队列

##### queue.push(q, data)

**功能**: 推入数据

##### queue.pop(q, timeout)

**功能**: 弹出数据

#### 8.1.12 skynet/remotedebug.lua

**功能**: 远程调试

**主要方法**:

##### remotedebug.start()

**功能**: 启动远程调试

#### 8.1.13 skynet/require.lua

**功能**: 模块加载器

**主要方法**:

##### require.init()

**功能**: 初始化加载器

##### require.init_all()

**功能**: 初始化所有模块

##### require.reload(name)

**功能**: 重新加载模块

#### 8.1.14 skynet/service.lua

**功能**: 服务管理

#### 8.1.15 skynet/sharedata.lua

**功能**: 共享数据

**主要方法**:

##### sharedata.query(name)

**功能**: 查询共享数据

##### sharedata.update(name, value)

**功能**: 更新共享数据

##### sharedata.delete(name)

**功能**: 删除共享数据

#### 8.1.16 skynet/sharemap.lua

**功能**: 共享映射表

**主要方法**:

##### sharemap.new()

**功能**: 创建共享映射表

##### sharemap.update(map, data)

**功能**: 更新映射表

##### sharemap.get(map, key)

**功能**: 获取值

#### 8.1.17 skynet/sharetable.lua

**功能**: 共享表

**主要方法**:

##### sharetable.load(filename)

**功能**: 加载共享表

##### sharetable.update(filename, tbl)

**功能**: 更新共享表

##### sharetable.save(filename, tbl)

**功能**: 保存共享表

#### 8.1.18 skynet/socketchannel.lua

**功能**: Socket 通道（高层封装）

**主要方法**:

##### channel.new(conf)

**功能**: 创建新通道

##### channel:connect()

**功能**: 连接

##### channel:close()

**功能**: 关闭

##### channel:change(f)

**功能**: 切换连接

#### 8.1.19 skynet/socket.lua

**功能**: Socket API（见第 5 节）

#### 8.1.20 skynet/crypt.lua

**功能**: 加密工具

**主要方法**:

##### crypt.hexencode(s)

**功能**: 十六进制编码

##### crypt.hexdecode(s)

**功能**: 十六进制解码

##### crypt.base64encode(s)

**功能**: Base64 编码

##### crypt.base64decode(s)

**功能**: Base64 解码

##### crypt.xor_str(s, key)

**功能**: 异或加密

##### crypt.dhsecret交换)

**功能**: DH 密钥交换

##### crypt.hmac_hash(k, s)

**功能**: HMAC 哈希

##### crypt.md5hash(s)

**功能**: MD5 哈希

##### crypt.sha1(s)

**功能**: SHA1 哈希

##### crypt.desencode(key, s)

**功能**: DES 编码

##### crypt.desdecode(key, s)

**功能**: DES 解码

##### crypt.randomkey()

**功能**: 生成随机密钥

#### 8.1.21 skynet/db/redis.lua

**功能**: Redis 客户端

**主要方法**:

##### redis.connect(conf)

**功能**: 连接 Redis

##### redis.pipeline()

**功能**: 创建管道

#### 8.1.22 skynet/db/mongo.lua

**功能**: MongoDB 客户端

**主要方法**:

##### mongo.client(conf)

**功能**: 创建 MongoDB 客户端

##### mongo.official()

**功能**: 官方驱动

#### 8.1.23 skynet/db/mysql.lua

**功能**: MySQL 客户端

**主要方法**:

##### mysql.connect(conf)

**功能**: 连接 MySQL

#### 8.1.24 compat10/

**功能**: 兼容层（为 1.0 版本提供兼容）

**说明**: 包含多个兼容模块，如 socket、cluster、redis、mongo 等的 1.0 版本兼容实现

---

## 附录

### A. 错误处理

所有可能阻塞的函数都遵循以下错误处理模式：
- 成功时返回实际数据
- 失败时返回 `nil, error` 或抛出错误

### B. 性能建议

1. **消息传递**: 优先使用 `send` 而非 `call`，避免不必要的等待
2. **协程管理**: 及时释放不需要的协程，避免资源泄漏
3. **内存管理**: 及时调用 `skynet.trash` 释放大消息
4. **批量操作**: 使用 `skynet.request` 进行批量请求
5. **Socket 缓冲**: 设置适当的 `buffer_limit` 避免内存溢出

### C. 调试技巧

1. **使用 `skynet.error`**: 输出日志信息
2. **使用 `skynet.trace`**: 开启消息跟踪
3. **使用 `skynet.task`**: 查看协程状态
4. **使用 `skynet.uniqtask`**: 统计相同堆栈的协程
5. **使用 `skynet.endless`**: 检查服务是否无尽循环

### D. 常见问题

1. **服务无法启动**: 检查 `SERVICE_NAME` 和服务路径配置
2. **消息超时**: 检查网络连接和对端服务状态
3. **内存泄漏**: 检查协程是否正确结束，是否有未响应请求
4. **CPU 占用高**: 使用 `skynet.task` 查看是否有阻塞协程

### E. 参考资料

- [Skynet 官方 Wiki](https://github.com/cloudwu/skynet/wiki)
- [Skynet 源码](https://github.com/cloudwu/skynet)
- [Sproto 协议](https://github.com/cloudwu/sproto)
- [Lua 5.4 参考手册](https://www.lua.org/manual/5.4/)

---

**版本**: 基于 Skynet 最新版本
**更新日期**: 2025-11-10
