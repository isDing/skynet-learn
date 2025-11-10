# Skynet Lua 模块使用示例

本文档提供 Skynet 框架中各个模块的实际使用示例，帮助开发者快速上手。

---

## 目录

### 基础示例
- [1. Skynet 核心服务示例](#1-skynet-核心服务示例)
  - [1.1 简单服务](#11-简单服务)
  - [1.2 状态服务](#12-状态服务)
  - [1.3 使用环境变量](#13-使用环境变量)
- [2. 消息传递示例](#2-消息传递示例)
  - [2.1 异步消息](#21-异步消息)
  - [2.2 同步调用超时处理](#22-同步调用超时处理)
  - [2.3 批量请求](#23-批量请求)
  - [2.4 消息重定向](#24-消息重定向)
- [3. 协程和调度示例](#3-协程和调度示例)
  - [3.1 后台任务](#31-后台任务)
  - [3.2 定时任务](#32-定时任务)
  - [3.3 协程同步](#33-协程同步)
  - [3.4 协程池](#34-协程池)

### 网络编程
- [4. Socket 网络编程示例](#4-socket-网络编程示例)
  - [4.1 TCP 服务器](#41-tcp-服务器)
  - [4.2 TCP 客户端](#42-tcp-客户端)
  - [4.3 UDP 通信](#43-udp-通信)
  - [4.4 Socket 连接池](#44-socket-连接池)
  - [4.5 心跳检测](#45-心跳检测)

### 高级服务
- [5. Snax 服务示例](#5-snax-服务示例)
  - [5.1 创建 Snax 服务](#51-创建-snax-服务)
  - [5.2 热更新](#52-热更新)
  - [5.3 接口定义](#53-接口定义)
  - [5.4 性能分析](#54-性能分析)
- [6. 集群通信示例](#6-集群通信示例)
  - [6.1 跨节点服务调用](#61-跨节点服务调用)
  - [6.2 服务注册与发现](#62-服务注册与发现)
  - [6.3 集群代理](#63-集群代理)
  - [6.4 Snax 跨节点调用](#64-snax-跨节点调用)

### 网络协议
- [7. HTTP 和 WebSocket 示例](#7-http-和-websocket-示例)
  - [7.1 HTTP 服务器](#71-http-服务器)
  - [7.2 HTTP 客户端](#72-http-客户端)
  - [7.3 WebSocket 服务器](#73-websocket-服务器)
  - [7.4 WebSocket 客户端](#74-websocket-客户端)
- [8. Sproto 协议示例](#8-sproto-协议示例)
  - [8.1 基本序列化](#81-基本序列化)
  - [8.2 协议定义](#82-协议定义)
  - [8.3 请求响应](#83-请求响应)
  - [8.4 打包解包](#84-打包解包)

### 综合应用
- [9. 综合应用示例](#9-综合应用示例)
  - [9.1 聊天服务](#91-聊天服务)
  - [9.2 游戏网关](#92-游戏网关)
  - [9.3 分布式数据库](#93-分布式数据库)
  - [9.4 微服务架构](#94-微服务架构)

---

## 1. Skynet 核心服务示例

### 1.1 简单服务

创建一个简单的计算服务

```lua
-- calculator.lua
local skynet = require "skynet"

skynet.start(function()
    skynet.error("计算器服务启动")

    -- 注册消息处理
    skynet.dispatch("lua", function(session, address, cmd, a, b)
        local result
        if cmd == "add" then
            result = a + b
        elseif cmd == "sub" then
            result = a - b
        elseif cmd == "mul" then
            result = a * b
        elseif cmd == "div" then
            if b == 0 then
                skynet.ret(skynet.pack({error="除零错误"}))
                return
            end
            result = a / b
        else
            skynet.ret(skynet.pack({error="未知命令"}))
            return
        end

        skynet.ret(skynet.pack({result=result}))
    end)
end)
```

客户端调用：

```lua
local skynet = require "skynet"

local function test_calculator()
    -- 启动计算器服务
    local calc = skynet.newservice("calculator")

    -- 调用服务
    local r1 = skynet.call(calc, "lua", "add", 10, 20)
    local r2 = skynet.call(calc, "lua", "mul", 5, 6)

    print("10 + 20 =", r1.result)
    print("5 * 6 =", r2.result)
end

skynet.start(test_calculator)
```

### 1.2 状态服务

创建带状态的服务

```lua
-- player_service.lua
local skynet = require "skynet"

local players = {}  -- 玩家数据

skynet.start(function()
    skynet.error("玩家服务启动")

    skynet.dispatch("lua", function(session, address, cmd, ...)
        if cmd == "create" then
            local player_id = select(1, ...)
            if players[player_id] then
                skynet.ret(skynet.pack({error="玩家已存在"}))
                return
            end

            players[player_id] = {
                id = player_id,
                level = 1,
                hp = 100,
                mp = 100
            }

            skynet.ret(skynet.pack(players[player_id]))

        elseif cmd == "get" then
            local player_id = select(1, ...)
            if not players[player_id] then
                skynet.ret(skynet.pack({error="玩家不存在"}))
                return
            end

            skynet.ret(skynet.pack(players[player_id]))

        elseif cmd == "levelup" then
            local player_id = select(1, ...)
            local player = players[player_id]
            if not player then
                skynet.ret(skynet.pack({error="玩家不存在"}))
                return
            end

            player.level = player.level + 1
            player.hp = 100
            player.mp = 100

            skynet.ret(skynet.pack(player))
        end
    end)
end)
```

### 1.3 使用环境变量

```lua
-- config_service.lua
local skynet = require "skynet"

skynet.start(function()
    -- 设置配置
    skynet.setenv("db_host", "127.0.0.1")
    skynet.setenv("db_port", "3306")
    skynet.setenv("log_level", "info")

    -- 读取配置
    local db_host = skynet.getenv("db_host")
    local log_level = skynet.getenv("log_level")

    skynet.error("数据库地址:", db_host)
    skynet.error("日志级别:", log_level)

    -- 启动服务
    skynet.dispatch("lua", function(...)
        -- 服务逻辑
    end)
end)
```

---

## 2. 消息传递示例

### 2.1 异步消息

```lua
-- 异步日志服务
local log_service

skynet.start(function()
    log_service = skynet.newservice("logger")

    -- 发送异步日志
    skynet.send(log_service, "lua", "info", "系统启动")
    skynet.send(log_service, "lua", "debug", "调试信息")
    skynet.send(log_service, "lua", "error", "错误信息")

    -- 继续其他初始化
    init_service()
end)
```

### 2.2 同步调用超时处理

```lua
local function safe_call(service, cmd, timeout, ...)
    local response = skynet.response()
    local start_time = skynet.now()

    -- 启动超时协程
    skynet.fork(function()
        skynet.sleep(timeout)
        if response("TEST") then
            skynet.error("调用超时:", cmd, "耗时:", (skynet.now() - start_time) / 100, "秒")
            response(false, "timeout")
        end
    end)

    -- 发起调用
    local ok, result = pcall(skynet.call, service, "lua", cmd, ...)
    if ok then
        if response("TEST") then
            response(true, result)
        end
    else
        if response("TEST") then
            response(false, result)
        end
    end
end

-- 使用
local r = safe_call(my_service, "get_data", 500, "key1")
```

### 2.3 延迟响应

```lua
skynet.dispatch("lua", function(session, address, cmd, ...)
    if cmd == "async_task" then
        local resp = skynet.response()

        -- 启动异步任务
        skynet.fork(function()
            -- 模拟耗时操作
            skynet.sleep(100)  -- 1 秒

            local result = heavy_computation()
            resp(true, result)
        end)

        -- 立即返回，不等待
    end
end)
```

### 2.4 批量请求

```lua
local function batch_query(services, query, timeout)
    local req = skynet.request()

    -- 添加请求
    for i, svc in ipairs(services) do
        req(svc, "query", query, i)
    end

    -- 设置超时
    local iter, tbl, idx = req:select(timeout)

    local results = {}
    for req, resp in iter do
        table.insert(results, {
            service = req[1],
            result = resp
        })
    end

    return results
end

-- 使用
local services = {svc1, svc2, svc3, svc4, svc5}
local results = batch_query(services, "player_1001", 300)
for _, r in ipairs(results) do
    print("服务", r.service, "结果:", r.result)
end
```

---

## 3. 协程和调度示例

### 3.1 定时任务

```lua
-- 每秒执行的任务
local function start_timer_task()
    skynet.fork(function()
        while true do
            skynet.sleep(100)  -- 1 秒

            -- 执行定时任务
            check_online_players()
            update_global_data()
            save_dirty_data()
        end
    end)
end
```

### 3.2 工作协程池

```lua
-- 工作协程池
local work_queue = {}
local workers = {}

local function create_worker(id)
    skynet.fork(function()
        while true do
            -- 等待任务
            local task = table.remove(work_queue, 1)
            if not task then
                skynet.wait()
                task = table.remove(work_queue, 1)
                if not task then
                    break
                end
            end

            -- 执行任务
            local ok, result = pcall(task.func, table.unpack(task.args))
            if task.callback then
                task.callback(ok, result)
            end
        end
    end)
end

local function init_worker_pool(size)
    for i = 1, size do
        create_worker(i)
    end
end

local function submit_task(func, callback, ...)
    table.insert(work_queue, {
        func = func,
        callback = callback,
        args = {...}
    })
    skynet.wakeup(workers[1])  -- 唤醒一个工作协程
end

-- 使用
init_worker_pool(4)
submit_task(function(a, b)
    return a + b
end, function(ok, result)
    print("结果:", result)
end, 10, 20)
```

### 3.3 事件等待

```lua
-- 事件系统
local events = {}
local event_queue = {}

local function wait_event(name, timeout)
    local token = {}
    events[name] = events[name] or {}

    if events[name].has_value then
        local value = events[name].value
        events[name].value = nil
        events[name].has_value = false
        return true, value
    end

    table.insert(events[name].waiters, token)
    skynet.wait(token)

    if events[name].value then
        local value = events[name].value
        events[name].value = nil
        events[name].has_value = false
        return true, value
    end

    return false
end

local function fire_event(name, value)
    events[name] = events[name] or {waiters = {}}
    events[name].value = value
    events[name].has_value = true

    for _, token in ipairs(events[name].waiters) do
        skynet.wakeup(token)
    end
    events[name].waiters = {}
end

-- 使用
skynet.fork(function()
    local ok, data = wait_event("player_login", 500)
    if ok then
        print("玩家登录:", data.name)
    else
        print("等待超时")
    end
end)

-- 触发事件
fire_event("player_login", {name="Alice", id=1001})
```

---

## 4. Socket 网络编程示例

### 4.1 TCP 客户端

```lua
local skynet = require "skynet"
local socket = require "skynet.socket"

local function tcp_client()
    -- 连接到服务器
    local id = socket.open("127.0.0.1", 8888)
    if not id then
        skynet.error("连接失败")
        return
    end

    skynet.error("连接成功，ID:", id)

    -- 发送数据
    socket.write(id, "Hello Server\n")

    -- 启动读取协程
    skynet.fork(function()
        while true do
            local line = socket.readline(id, "\n")
            if not line then
                skynet.error("连接断开")
                break
            end
            skynet.error("收到:", line)
        end
    end)

    -- 定时发送心跳
    skynet.fork(function()
        while true do
            socket.write(id, "ping\n")
            skynet.sleep(600)  -- 6 秒
        end
    end)
end

skynet.start(tcp_client)
```

### 4.2 TCP 服务器

```lua
local skynet = require "skynet"
local socket = require "skynet.socket"

local clients = {}

local function handle_client(id, addr)
    skynet.error("新客户端连接:", id, addr)

    -- 启动读取协程
    skynet.fork(function()
        while true do
            local line = socket.readline(id, "\n")
            if not line then
                -- 客户端断开
                clients[id] = nil
                skynet.error("客户端断开:", id)
                return
            end

            -- 处理消息
            skynet.error("客户端", id, "说:", line)

            -- 回显
            socket.write(id, "服务器已收到: " .. line)
        end
    end)
end

local function tcp_server()
    -- 监听端口
    local id = socket.listen("0.0.0.0", 8888)
    skynet.error("TCP 服务器启动，监听端口 8888")

    -- 启动接受连接
    socket.start(id, function(newid, addr)
        handle_client(newid, addr)
    end)
end

skynet.start(tcp_server)
```

### 4.3 UDP 服务

```lua
local skynet = require "skynet"
local socket = require "skynet.socket"

local function udp_server()
    -- 创建 UDP socket
    local id = socket.udp(function(data, addr)
        skynet.error("收到 UDP 数据:", data, "来自:", addr)

        -- 回显
        socket.sendto(id, addr, "UDP 回显: " .. data)
    end, "0.0.0.0", 9999)

    skynet.error("UDP 服务器启动，端口 9999")
end

local function udp_client()
    local id = socket.udp_dial("127.0.0.1", 9999, function(data, addr)
        skynet.error("收到回应:", data)
    end)

    skynet.error("UDP 客户端启动")

    -- 发送数据
    socket.sendto(id, "127.0.0.1", 9999, "Hello UDP")
end
```

### 4.4 心跳和超时

```lua
local function tcp_client_with_timeout()
    local id = socket.open("127.0.0.1", 8888)

    -- 设置警告回调
    socket.warning(id, function(id, size)
        if size > 1024 * 1024 then
            skynet.error("发送缓冲区过大:", size / 1024, "KB")
        end
    end)

    -- 设置关闭回调
    socket.onclose(id, function(id)
        skynet.error("连接已关闭:", id)
    end)

    -- 读取数据（带超时）
    local function read_with_timeout(timeout)
        local co = coroutine.running()
        socket.read(id, 1024)  -- 会阻塞到有数据或超时
        skynet.fork(function()
            skynet.sleep(timeout)
            -- 超时处理
            coroutine.resume(co)
        end)
    end
end
```

---

## 5. Snax 服务示例

### 5.1 简单 Snax 服务

```lua
-- snax/gateserver.lua
local snax = require "snax"

function init(...)
    print("网关服务初始化", ...)
end

function exit(...)
    print("网关服务退出", ...)
end

function accept(id, addr)
    print("接受连接:", id, addr)
end

function disconnect(id)
    print("断开连接:", id)
end

function response.handshake(id)
    print("握手响应:", id)
    return {status="ok"}
end

function request.login(id, username, password)
    print("登录请求:", username)
    return {token="abc123", userid=1001}
end

function hotfix(source)
    print("热更新:", source)
    return "success"
end
```

客户端调用：

```lua
local snax = require "snax"

local gate = snax.newservice("gateserver", config)

-- 发送通知
gate.post.accept(100, "192.168.1.1")

-- 发送请求
local result = gate.req.handshake(100)
if result.status == "ok" then
    local login_result = gate.req.login(100, "user", "pass")
    print("登录成功，token:", login_result.token)
end

-- 热更新
local ret = snax.hotfix(gate, new_code)
print("热更新结果:", ret)
```

### 5.2 消息服务器

```lua
-- snax/msgserver.lua
local snax = require "snax"

local sessions = {}

function init(conf)
    print("消息服务初始化", conf.host, conf.port)
    self.response.listen(conf.port)
end

function response.listen(port)
    print("监听端口:", port)
    return true
end

function request.send_message(session_id, message)
    if sessions[session_id] then
        sessions[session_id](message)
        return {status="ok"}
    else
        return {error="session not found"}
    end
end

function accept.connection(session_id, callback)
    sessions[session_id] = callback
    print("新连接:", session_id)
end

function disconnect.disconnect(session_id)
    sessions[session_id] = nil
    print("连接断开:", session_id)
end
```

### 5.3 登录服务器

```lua
-- snax/loginserver.lua
local snax = require "snax"

local users = {}  -- 在线用户

function init(...)
    print("登录服务器启动", ...)
end

function request.login(username, password)
    -- 验证用户名密码
    if verify_user(username, password) then
        -- 生成 token
        local token = generate_token(username)
        users[username] = {
            token = token,
            login_time = skynet.time()
        }
        return {
            code = 0,
            message = "登录成功",
            token = token,
            gateway = select_gateway()
        }
    else
        return {
            code = 1,
            message = "用户名或密码错误"
        }
    end
end

function request.logout(token)
    for username, info in pairs(users) do
        if info.token == token then
            users[username] = nil
            return {code=0}
        end
    end
    return {code=1, message="用户未登录"}
end

function accept.register_gate(gate_id, gate_addr)
    print("注册网关:", gate_id, gate_addr)
    return true
end
```

---

## 6. 集群通信示例

### 6.1 跨节点调用

节点 A（游戏逻辑节点）：

```lua
-- game_node.lua
local skynet = require "skynet"
local cluster = require "skynet.cluster"

local function game_service()
    skynet.start(function()
        -- 启动集群
        cluster.open("0.0.0.0", 2525)

        -- 注册游戏服务
        skynet.dispatch("lua", function(session, address, cmd, ...)
            if cmd == "get_player" then
                local player_id = ...

                -- 调用数据库节点
                local player_data = cluster.call("db_node", 0x123456, "get_player", player_id)

                -- 调用缓存节点
                local cached = cluster.call("cache_node", "get", "player_" .. player_id)

                local result = {
                    id = player_id,
                    data = player_data,
                    cached = cached
                }

                skynet.ret(skynet.pack(result))
            end
        end)
    end)
end

skynet.start(game_service)
```

节点 B（数据库节点）：

```lua
-- db_node.lua
local skynet = require "skynet"
local cluster = require "skynet.cluster"

local function db_service()
    skynet.start(function()
        cluster.open("0.0.0.0", 2526)

        skynet.dispatch("lua", function(session, address, cmd, ...)
            if cmd == "get_player" then
                local player_id = ...
                local data = load_player_from_db(player_id)
                skynet.ret(skynet.pack(data))
            elseif cmd == "save_player" then
                local player_id, data = ...
                save_player_to_db(player_id, data)
                skynet.ret(skynet.pack({ok=true}))
            end
        end)
    end)
end

skynet.start(db_service)
```

### 6.2 集群服务发现

```lua
-- 服务发现
local function discover_services()
    local services = {}

    -- 查询所有节点
    for _, node in ipairs({"node1", "node2", "node3"}) do
        local game_addr = cluster.query(node, "game_service")
        if game_addr then
            services[#services + 1] = {
                node = node,
                addr = game_addr
            }
        end
    end

    return services
end

-- 负载均衡选择服务
local function select_service(services)
    local index = math.random(1, #services)
    return services[index]
end

-- 调用远程服务
local function call_remote_service(cmd, ...)
    local services = discover_services()
    if #services == 0 then
        error("没有可用的服务")
    end

    local svc = select_service(services)
    return cluster.call(svc.node, svc.addr, cmd, ...)
end
```

### 6.3 跨节点 Snax 服务

```lua
-- 调用远程 Snax 服务
local function call_remote_snax()
    -- 获取远程 Snax 服务代理
    local auth = cluster.snax("node1", "auth_service")

    -- 使用方式和本地服务相同
    local result = auth.req.login("user", "pass")
    auth.post.logout()

    -- 关闭远程服务
    snax.kill(auth)
end
```

---

## 7. HTTP 和 WebSocket 示例

### 7.1 HTTP 服务器

```lua
-- http_server.lua
local skynet = require "skynet"
local socket = require "skynet.socket"
local httpd = require "http.httpd"

local function response_write(sock, code, body, header)
    header = header or {}
    header["Content-Type"] = header["Content-Type"] or "text/plain"

    local ok, err = httpd.write_response(sock, code, body, header)
    if not ok then
        skynet.error("响应失败:", err)
    end
end

local function handle_request(sock, code, url, method, header, body)
    if url == "/" then
        response_write(sock, 200, "Hello, Skynet!")
    elseif url == "/api/data" then
        local data = {time = skynet.time(), now = skynet.now()}
        response_write(sock, 200, json.encode(data), {["Content-Type"] = "application/json"})
    else
        response_write(sock, 404, "Not Found")
    end
end

local function start_http_server()
    local id = socket.listen("0.0.0.0", 8080)
    skynet.error("HTTP 服务器启动，端口 8080")

    socket.start(id, function(newid, addr)
        skynet.fork(function()
            local ok, err = socket.start(newid)
            if not ok then
                return
            end

            local readbytes = function(maxsize)
                return socket.read(newid, maxsize or 8192)
            end

            local code, url, method, header, body = httpd.read_request(readbytes, 8192)
            if not code then
                return
            end

            handle_request(newid, code, url, method, header, body)
            socket.close(newid)
        end)
    end)
end

skynet.start(start_http_server)
```

### 7.2 HTTP 客户端

```lua
local httpc = require "http.httpc"

local function test_http_client()
    -- GET 请求
    local code, body = httpc.get("httpbin.org", "/get")
    skynet.error("GET 状态码:", code)

    -- POST 请求
    local code, body = httpc.post("httpbin.org", "/post",
        {username="user", password="pass"})
    skynet.error("POST 状态码:", code)

    -- 自定义请求
    local header = {
        ["User-Agent"] = "Skynet/1.0",
        ["Content-Type"] = "application/json"
    }
    local code, body = httpc.request("POST", "api.example.com", "/data",
        nil, header, json.encode({data="test"}))
end
```

### 7.3 WebSocket 客户端

```lua
local websocket = require "http.websocket"

local function ws_client()
    -- 连接 WebSocket
    local id = websocket.connect("ws://echo.websocket.org")
    skynet.error("WebSocket 连接成功:", id)

    -- 发送消息
    websocket.write(id, "Hello WebSocket", "text")

    -- 启动读取协程
    skynet.fork(function()
        while true do
            local data = websocket.read(id)
            if not data then
                skynet.error("WebSocket 断开")
                break
            end
            skynet.error("收到消息:", data)
        end
    end)

    -- 定时发送心跳
    skynet.fork(function()
        while not websocket.is_close(id) do
            websocket.ping(id)
            skynet.sleep(300)  -- 3 秒
        end
    end)

    -- 关闭连接
    skynet.sleep(1000)
    websocket.close(id, 1000, "normal closure")
end
```

### 7.4 WebSocket 服务器

```lua
local websocket = require "http.websocket"
local skynet = require "skynet"

local function start_ws_server()
    local id = socket.listen("0.0.0.0", 8080)
    skynet.error("WebSocket 服务器启动，端口 8080")

    socket.start(id, function(newid, addr)
        local ok, err = websocket.accept(newid, {
            connect = function(ws)
                skynet.error("WebSocket 连接:", ws.id, ws.addr)
            end,

            handshake = function(ws, header, url)
                skynet.error("握手成功:", url)
            end,

            message = function(ws, data, op)
                skynet.error("收到消息:", data, "操作码:", op)
                -- 回显消息
                websocket.write(ws.id, "回显: " .. data, op)
            end,

            close = function(ws, code, reason)
                skynet.error("WebSocket 关闭:", code, reason)
            end,

            error = function(ws, err)
                skynet.error("WebSocket 错误:", err)
            end
        })

        if not ok then
            skynet.error("WebSocket 接受失败:", err)
        end
    end)
end
```

---

## 8. Sproto 协议示例

### 8.1 定义协议

```lua
-- protocol.sproto
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

.Response {
    result 0 : integer
    message 1 : string
}
```

### 8.2 使用协议

```lua
local sproto = require "sproto"
local sp = sproto.parse(io.open("protocol.sproto"):read("*a"))

-- 编码数据
local person = {
    name = "Alice",
    id = 1001,
    email = "alice@example.com"
}

local data = sp:encode("Person", person)
skynet.error("编码长度:", #data)

-- 解码数据
local decoded = sp:decode("Person", data)
skynet.error("解码数据:", decoded.name, decoded.id)
```

### 8.3 使用 Host 对象

```lua
local host = sp:host()

-- 附加到 sproto
local pack = host:attach(sp)

-- 打包请求
local session = 1
local msg = pack("Request", {
    cmd = "get_person",
    data = {persons = {person}}
}, session)

-- 发送消息
skynet.send(remote_service, "lua", msg)

-- 在消息处理中
skynet.dispatch("lua", function(_, _, msg)
    -- 分发消息
    local type, name, request, response, ud = host:dispatch(msg)

    if type == "REQUEST" then
        skynet.error("收到请求:", name)

        -- 处理请求
        local result = handle_request(name, request)

        -- 发送响应
        if response then
            local resp_data = response(result)
            skynet.ret(skynet.pack(resp_data))
        end
    end
end)
```

---

## 9. 综合应用示例

### 9.1 完整的游戏服务器

```lua
-- main_service.lua
local skynet = require "skynet"
local socket = require "skynet.socket"
local cluster = require "skynet.cluster"
local sproto = require "sproto"

-- 配置
local CONFIG = {
    gateway_port = 8888,
    db_node = "db_node",
    cache_node = "cache_node"
}

local gate_socket
local players = {}  -- 在线玩家

local function load_player(player_id)
    -- 尝试从缓存获取
    local cache_key = "player_" .. player_id
    local cached = cluster.call(CONFIG.cache_node, "get", cache_key)

    if cached then
        return cached
    end

    -- 从数据库获取
    local db_data = cluster.call(CONFIG.db_node, 0x123456, "get_player", player_id)

    -- 存入缓存
    cluster.call(CONFIG.cache_node, "set", cache_key, db_data, 3600)

    return db_data
end

local function handle_client_message(fd, player_id, msg)
    -- 解析消息
    local type, cmd, data = decode_message(msg)

    if type == "login" then
        local player = load_player(player_id)
        players[player_id] = {
            fd = fd,
            data = player,
            last_active = skynet.now()
        }

        send_to_client(fd, encode_message("login_ok", player))

    elseif type == "move" then
        local player = players[player_id]
        if player then
            player.data.x = data.x
            player.data.y = data.y
            player.last_active = skynet.now()

            -- 广播给其他玩家
            broadcast_to_players(encode_message("player_move", {
                id = player_id,
                x = data.x,
                y = data.y
            }), player_id)
        end

    elseif type == "logout" then
        players[player_id] = nil
        skynet.error("玩家离线:", player_id)
    end
end

local function start_gate()
    gate_socket = socket.listen("0.0.0.0", CONFIG.gateway_port)
    skynet.error("网关启动，端口:", CONFIG.gateway_port)

    socket.start(gate_socket, function(fd, addr)
        skynet.fork(function()
            -- 认证玩家
            local auth_data = socket.readline(fd, "\n")
            local player_id = authenticate_player(auth_data)

            if not player_id then
                socket.write(fd, "auth_failed\n")
                socket.close(fd)
                return
            end

            skynet.error("玩家连接:", player_id, addr)

            -- 启动消息循环
            while true do
                local msg = socket.readline(fd, "\n")
                if not msg then
                    break
                end

                handle_client_message(fd, player_id, msg)
            end

            -- 清理
            players[player_id] = nil
            skynet.error("玩家断开:", player_id)
        end)
    end)
end

local function start_heartbeat()
    skynet.fork(function()
        while true do
            skynet.sleep(600)  -- 6 秒

            -- 检查超时玩家
            local now = skynet.now()
            for player_id, player in pairs(players) do
                if now - player.last_active > 6000 then  -- 60 秒超时
                    skynet.error("玩家超时断开:", player_id)
                    players[player_id] = nil
                end
            end

            -- 广播心跳
            broadcast_to_players(encode_message("heartbeat", {time = now}))
        end
    end)
end

skynet.start(function()
    -- 初始化集群
    cluster.open("0.0.0.0", 2527)

    -- 启动网关
    start_gate()

    -- 启动心跳
    start_heartbeat()

    skynet.error("游戏服务器启动完成")
end)
```

### 9.2 数据库代理服务

```lua
-- db_proxy_service.lua
local skynet = require "skynet"
local mysql = require "skynet.db.mysql"

local db

local function connect_db()
    db = mysql.connect({
        host = skynet.getenv("db_host") or "127.0.0.1",
        port = tonumber(skynet.getenv("db_port")) or 3306,
        database = skynet.getenv("db_name") or "game",
        user = skynet.getenv("db_user") or "root",
        password = skynet.getenv("db_pass") or "",
        max_packet_size = 1024 * 1024
    })

    if not db then
        skynet.error("数据库连接失败")
        error("数据库连接失败")
    end

    skynet.error("数据库连接成功")
end

local function query(sql, ...)
    local stmt = db:query(sql, ...)
    return stmt
end

skynet.start(function()
    connect_db()

    skynet.dispatch("lua", function(session, address, cmd, ...)
        if cmd == "get_player" then
            local player_id = ...
            local result = query("SELECT * FROM players WHERE id = ?", player_id)
            if result and #result > 0 then
                skynet.ret(skynet.pack(result[1]))
            else
                skynet.ret(skynet.pack(nil))
            end

        elseif cmd == "save_player" then
            local player_id, data = ...
            local affected = query("UPDATE players SET data = ? WHERE id = ?",
                json.encode(data), player_id)
            skynet.ret(skynet.pack({affected = affected}))

        elseif cmd == "create_player" then
            local data = ...
            local affected = query("INSERT INTO players (id, data) VALUES (?, ?)",
                data.id, json.encode(data))
            skynet.ret(skynet.pack({affected = affected, insert_id = db:insert_id()}))
        end
    end)
end)
```

### 9.3 缓存服务

```lua
-- cache_service.lua
local skynet = require "skynet"
local redis = require "skynet.db.redis"

local db

local function connect_redis()
    db = redis.connect{
        host = skynet.getenv("redis_host") or "127.0.0.1",
        port = tonumber(skynet.getenv("redis_port")) or 6379,
        db = tonumber(skynet.getenv("redis_db")) or 0
    }

    if not db then
        skynet.error("Redis 连接失败")
        error("Redis 连接失败")
    end

    skynet.error("Redis 连接成功")
end

skynet.start(function()
    connect_redis()

    skynet.dispatch("lua", function(session, address, cmd, ...)
        if cmd == "get" then
            local key = ...
            local value = db:get(key)
            skynet.ret(skynet.pack(value))

        elseif cmd == "set" then
            local key, value, expire = select(1, ...)
            expire = expire or 3600
            db:setex(key, expire, value)
            skynet.ret(skynet.pack("OK"))

        elseif cmd == "del" then
            local key = ...
            local count = db:del(key)
            skynet.ret(skynet.pack(count))

        elseif cmd == "incr" then
            local key = ...
            local value = db:incr(key)
            skynet.ret(skynet.pack(value))
        end
    end)
end)
```

---

## 总结

这些示例展示了 Skynet 框架的核心功能：

1. **服务管理**: 创建、查找、管理服务
2. **消息传递**: 同步、异步、延迟响应
3. **协程调度**: 后台任务、定时器、工作池
4. **网络编程**: TCP/UDP 客户端和服务器
5. **集群通信**: 跨节点调用和服务发现
6. **HTTP/WebSocket**: Web 服务开发
7. **协议处理**: Sproto 序列化和反序列化

实际项目中，可以根据需求选择合适的模块和模式进行组合使用。
