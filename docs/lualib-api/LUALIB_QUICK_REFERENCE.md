# Skynet Lua 模块快速参考指南

本文档提供 Skynet 框架中最常用 API 的快速参考。

---

## 目录

- [核心服务操作](#核心服务操作)
  - [启动和退出](#启动和退出)
  - [服务创建和查找](#服务创建和查找)
  - [地址转换](#地址转换)
- [消息传递](#消息传递)
  - [异步消息（不等待响应）](#异步消息不等待响应)
  - [同步消息（等待响应）](#同步消息等待响应)
  - [响应消息](#响应消息)
  - [批量请求](#批量请求)
- [协程和调度](#协程和调度)
  - [创建协程](#创建协程)
  - [休眠和等待](#休眠和等待)
  - [杀死协程](#杀死协程)
- [定时器](#定时器)
  - [延迟执行](#延迟执行)
  - [时间获取](#时间获取)
- [Socket 操作](#socket-操作)
  - [TCP 连接](#tcp-连接)
  - [TCP 监听](#tcp-监听)
  - [UDP](#udp)
- [Snax 服务](#snax-服务)
  - [创建 Snax 服务](#创建-snax-服务)
  - [热更新](#热更新)
- [集群通信](#集群通信)
  - [跨节点调用](#跨节点调用)
  - [集群管理](#集群管理)
- [HTTP 客户端](#http-客户端)
  - [GET 请求](#get-请求)
  - [POST 请求](#post-请求)
  - [完整请求](#完整请求)
- [WebSocket](#websocket)
  - [客户端连接](#客户端连接)
  - [发送消息](#发送消息)
  - [关闭连接](#关闭连接)
- [调试和错误](#调试和错误)
- [内存管理](#内存管理)
- [最佳实践](#最佳实践)

---

## 核心服务操作

### 启动和退出
```lua
-- 启动服务
skynet.start(function()
    -- 初始化代码
end)

-- 退出服务
skynet.exit()
```

### 服务创建和查找
```lua
-- 创建新服务
local svc = skynet.newservice("service_name", arg1, arg2)

-- 创建唯一服务
local svc = skynet.uniqueservice(true, "unique_service")

-- 查询服务
local svc = skynet.queryservice("service_name")
```

### 地址转换
```lua
-- 获取当前服务地址
local my_addr = skynet.self()

-- 查询本地名称
local addr = skynet.localname(".service_name")

-- 地址格式化
local str = skynet.address(0x12345678)  -- ":12345678"
```

---

## 消息传递

### 异步消息（不等待响应）
```lua
-- 发送消息
skynet.send(addr, "lua", "command", arg1, arg2)

-- 例子：记录日志
skynet.send(log_service, "lua", "info", "User login")
```

### 同步消息（等待响应）
```lua
-- 调用并等待响应
local result = skynet.call(addr, "lua", "get_data", key)

-- 例子：获取玩家数据
local player = skynet.call(player_service, "lua", "get_player", 1001)
```

### 响应消息
```lua
-- 在消息处理中返回响应
skynet.dispatch("lua", function(_, _, cmd, ...)
    if cmd == "get" then
        skynet.ret(skynet.pack(data))
    end
end)

-- 延迟响应（异步）
skynet.dispatch("lua", function(session, _, cmd)
    local resp = skynet.response()
    skynet.fork(function()
        local result = heavy_task()
        resp(true, result)
    end)
end)
```

### 批量请求
```lua
local req = skynet.request()
req(service1, "add", 1, 2)
req(service2, "mul", 3, 4)

for req, resp in req:select() do
    print("Request:", req[2], "Response:", resp)
end
```

---

## 协程和调度

### 创建协程
```lua
-- 创建后台协程
skynet.fork(function()
    skynet.sleep(100)  -- 休眠 1 秒
    print("执行完成")
end)

-- 带参数
skynet.fork(function(a, b)
    print(a + b)
end, 1, 2)
```

### 休眠和等待
```lua
-- 休眠（时间片）
skynet.sleep(100)  -- 100 个时间片 = 1 秒

-- 让出时间片
skynet.yield()

-- 等待唤醒
skynet.wait()

-- 唤醒协程
skynet.wakeup(token)
```

### 杀死协程
```lua
-- 杀死指定协程
skynet.killthread(thread)

-- 根据字符串查找并杀死
skynet.killthread("some_pattern")
```

---

## 定时器

### 延迟执行
```lua
-- 1 秒后执行
skynet.timeout(100, function()
    print("1 秒后执行")
end)

-- 使用睡眠（推荐）
skynet.fork(function()
    skynet.sleep(100)
    print("1 秒后执行")
end)
```

### 时间获取
```lua
-- 当前 tick（1/100 秒）
local now = skynet.now()

-- 进程启动时间（秒）
local start = skynet.starttime()

-- 当前时间（秒）
local time = skynet.time()
```

---

## Socket 操作

### TCP 连接
```lua
-- 连接到服务器
local id = socket.open("127.0.0.1", 8080)

-- 读取数据
local data = socket.read(id, 1024)

-- 读取一行
local line = socket.readline(id, "\n")

-- 写入数据
socket.write(id, "Hello")

-- 关闭连接
socket.close(id)
```

### TCP 监听
```lua
-- 监听端口
socket.listen("0.0.0.0", 8888)

-- 启动接受连接
socket.start(id, function(newid, addr)
    print("新连接:", newid, addr)
end)
```

### UDP
```lua
-- 创建 UDP socket
local id = socket.udp(function(data, addr)
    print("收到:", data, "来自:", addr)
end)

-- 发送 UDP 数据
socket.sendto(id, "127.0.0.1", 8888, "Hello")
```

---

## Snax 服务

### 创建 Snax 服务
```lua
-- 创建新服务
local auth = snax.newservice("auth", "config.lua")

-- 唯一服务
local db = snax.uniqueservice("database", "db_config")

-- 发送通知（不等待响应）
auth.post.login(user_id, password)

-- 发送请求（等待响应）
local result = auth.req.auth(user_id, password)

-- 关闭服务
snax.kill(auth)
```

### 热更新
```lua
local new_code = "新的服务代码"
snax.hotfix(service, new_code, param1, param2)
```

---

## 集群通信

### 跨节点调用
```lua
-- 同步调用
local result = cluster.call("node1", 0x123456, "cmd", arg1, arg2)

-- 异步发送
cluster.send("node2", "service_name", "cmd", arg1, arg2)

-- 查询服务
local addr = cluster.query("node1", "service_name")
```

### 集群管理
```lua
-- 打开集群监听
cluster.open("0.0.0.0", 2525)

-- 注册服务
cluster.register("my_service", 0x123456)

-- 取消注册
cluster.unregister("my_service")
```

---

## HTTP 客户端

### GET 请求
```lua
local code, body = httpc.get("example.com", "/api/data")
```

### POST 请求
```lua
local code, body = httpc.post("api.example.com", "/login",
    {username="user", password="pass"})
```

### 完整请求
```lua
local header = {["User-Agent"] = "Skynet"}
local code, body = httpc.request("POST", "api.example.com", "/data",
    nil, header, post_data)
```

---

## WebSocket

### 客户端连接
```lua
local id = websocket.connect("ws://example.com/ws")

-- 读取消息
local data = websocket.read(id)

-- 发送消息
websocket.write(id, "Hello", "text")

-- 发送二进制
websocket.write(id, binary_data, "binary")

-- 关闭
websocket.close(id, 1000, "normal closure")
```

### 服务器端
```lua
websocket.accept(id, {
    connect = function(ws) end,
    handshake = function(ws, header, url) end,
    message = function(ws, data, op) end,
    close = function(ws, code, reason) end,
    error = function(ws, err) end,
})
```

---

## Sproto 协议

### 定义协议
```lua
local sp = sproto.parse[[
    .Person {
        name 0 : string
        id 1 : integer
    }

    .Request {
        cmd 0 : string
        data 1 : Person
    }

    .Response {
        result 0 : string
    }
]]
```

### 编码解码
```lua
-- 编码
local data = sp:encode("Person", {name="Alice", id=1001})

-- 解码
local person = sp:decode("Person", data)

-- 使用 host 对象
local host = sp:host()
local pack = host:attach(sp)
local msg = pack("Request", {cmd="get", data=person}, session)
```

---

## 调试工具

### 日志输出
```lua
-- 输出错误信息
skynet.error("错误信息")
skynet.error("格式化: %d", value)
```

### 消息跟踪
```lua
-- 开启跟踪
skynet.trace("操作描述")

-- 获取跟踪标签
local tag = skynet.tracetag()
```

### 查看协程
```lua
-- 查看协程数量
local count = skynet.task()

-- 查看所有协程堆栈
local t = {}
skynet.task(t)
for k, v in pairs(t) do
    print(k, v)
end

-- 查看统计信息
local stats = skynet.uniqtask()
```

### 服务状态
```lua
-- 检查无尽循环
if skynet.endless() then
    skynet.error("检测到无尽循环！")
end

-- 查看消息队列长度
local qlen = skynet.mqlen()
```

---

## 数据序列化

### 打包解包
```lua
-- 打包数据
local packed = skynet.pack(data1, data2, "string")

-- 解包数据
local d1, d2, d3 = skynet.unpack(packed)

-- 转换为字符串表示
local str = skynet.tostring(packed)

-- 释放内存
skynet.trash(packed, #packed)
```

---

## 环境变量

```lua
-- 获取环境变量
local log_level = skynet.getenv("log_level")

-- 设置环境变量（只能设置一次）
skynet.setenv("config_path", "/path/to/config")
```

---

## 内存管理

```lua
-- 设置内存限制
skynet.memlimit(100 * 1024 * 1024)  -- 100MB
```

---

## DNS 解析

```lua
-- 异步解析
dns.resolve("example.com", function(ip, err)
    if ip then
        print("IP:", ip)
    else
        print("Error:", err)
    end
end)

-- 同步解析
local ip = dns.resolve_sync("example.com")
```

---

## 常用模式

### 服务初始化模式
```lua
skynet.start(function()
    -- 注册消息处理
    skynet.dispatch("lua", function(session, address, cmd, ...)
        local f = handlers[cmd]
        if f then
            f(...)
        else
            skynet.ret(skynet.pack({error="unknown_cmd"}))
        end
    end)

    -- 初始化服务
    local ok, err = pcall(init_service)
    if not ok then
        skynet.error("初始化失败:", err)
    end
end)
```

### 连接池模式
```lua
local connection_pool = {}

local function get_connection()
    -- 复用已有连接或创建新连接
    if #connection_pool > 0 then
        return table.remove(connection_pool)
    end
    return socket.open(host, port)
end

local function release_connection(id)
    -- 归还连接到池中
    if #connection_pool < MAX_POOL_SIZE then
        table.insert(connection_pool, id)
    else
        socket.close(id)
    end
end
```

### 超时调用模式
```lua
local function call_with_timeout(addr, cmd, timeout, ...)
    local response = skynet.response()
    skynet.fork(function()
        skynet.sleep(timeout)
        response(false, "timeout")
    end)

    local ok, result = pcall(skynet.call, addr, "lua", cmd, ...)
    if ok then
        response(true, result)
    else
        response(false, result)
    end
end
```

### 消息路由模式
```lua
skynet.dispatch("lua", function(session, source, cmd, ...)
    -- 路由到不同处理函数
    if cmd == "get" then
        handle_get(...)
    elseif cmd == "set" then
        handle_set(...)
    else
        skynet.ret(skynet.pack({error="unknown_cmd"}))
    end
end)
```

---

## 注意事项

1. **协程安全**: 所有阻塞操作必须在协程中执行
2. **内存管理**: 大消息使用后及时调用 `skynet.trash` 释放
3. **错误处理**: 使用 `pcall` 包装可能出错的代码
4. **超时处理**: 设置合理的超时时间，避免死锁
5. **资源释放**: 及时关闭 socket 和协程
6. **配置管理**: 使用环境变量管理配置

---

**快速索引**
- `skynet.send()` - 异步发送
- `skynet.call()` - 同步调用
- `skynet.ret()` - 返回响应
- `skynet.fork()` - 创建协程
- `skynet.sleep()` - 休眠
- `skynet.timeout()` - 定时器
- `socket.open()` - 连接
- `socket.read()` - 读取
- `socket.write()` - 写入
- `snax.newservice()` - 创建 Snax 服务
- `cluster.call()` - 集群调用
- `httpc.get()` - HTTP GET
- `websocket.connect()` - WebSocket 连接
- `sproto.parse()` - 解析协议
