# Network Programming with Skynet（Skynet 网络编程）

## What You'll Learn（你将学到的内容）
- Skynet's socket API and network programming model（Skynet 的 Socket API 与网络编程模型）
- Building TCP servers with gate service（使用 Gate 服务构建 TCP 服务器）
- Client connection management（客户端连接管理）
- Protocol handling and message framing（协议处理与消息封帧）
- WebSocket and HTTP support（WebSocket 与 HTTP 支持）
- Network security and optimization（网络安全与优化）

## Prerequisites（前置要求）
- Completed Tutorial 5: Working with Lua Services（已完成教程 5：Lua 服务开发实践）
- Understanding of basic network programming concepts（理解基础网络编程概念）
- Knowledge of TCP/IP protocols（掌握 TCP/IP 协议相关知识）

## Time Estimate（预计耗时）
60 minutes（60 分钟）

## Final Result（学习成果）
Ability to build scalable network services using Skynet's networking capabilities（能够使用 Skynet 的网络功能构建可扩展的网络服务）

---

## 1. Skynet Network Architecture（1. Skynet 网络架构）

### 1.1 Network Stack Overview（1.1 网络栈概述）

```
┌─────────────────────────────────────────────────┐
│                 Application Layer                │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────┐   │
│  │   Game      │  │   Chat      │  │  HTTP   │   │
│  │   Logic     │  │   Service   │  │  Server │   │
│  └─────────────┘  └─────────────┘  └─────────┘   │
├─────────────────────────────────────────────────┤
│                 Agent Layer                     │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────┐   │
│  │   Agent 1   │  │   Agent 2   │  │ Agent N │   │
│  └─────────────┘  └─────────────┘  └─────────┘   │
├─────────────────────────────────────────────────┤
│                 Gate Service                    │
│  ┌─────────────────────────────────────────────┐ │
│  │     Connection Management & Routing        │ │
│  └─────────────────────────────────────────────┘ │
├─────────────────────────────────────────────────┤
│                 Socket Layer                    │
│  ┌─────────────────────────────────────────────┐ │
│  │   skynet.socket API (Non-blocking I/O)     │ │
│  └─────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────┘
```

### 1.2 Key Components（1.2 核心组件）

- **Socket Driver**: Low-level socket operations（Socket 驱动：负责底层 Socket 操作，如连接建立、数据读写）
- **Gate Service**: Connection management and message routing（Gate 服务：连接管理与消息路由，统一处理客户端连接）
- **Agent Services**: Per-client connection handlers（Agent 服务：每个客户端连接的专属处理器，处理业务逻辑）
- **Watchdog Service**: Connection lifecycle management（Watchdog 服务：连接生命周期管理，协调 Gate 与 Agent 服务）

## 2. Basic Socket Operations（2. 基础 Socket 操作）

### 2.1 Socket API Basics（2.1 Socket API 基础）

```lua
local socket = require "skynet.socket"

-- Create TCP server（创建 TCP 服务器）
local fd = socket.listen("0.0.0.0", 8888)
socket.start(fd, function(fd, addr)
    -- New connection handler（新连接处理逻辑）
    skynet.error("New connection from:", addr)
    
    -- Start reading from socket（循环读取客户端数据）
    while true do
        local data = socket.read(fd)
        if not data then
            break
        end
        
        -- Echo back（回声服务：将接收到的数据原样返回给客户端）
        socket.write(fd, data)
    end
    
    socket.close(fd)
end)

-- TCP client connection（创建 TCP 客户端）
local fd = socket.connect("127.0.0.1", 8888)
if fd then
    socket.write(fd, "Hello, Server!\n")
    local response = socket.read(fd)
    print("Server response:", response)
    socket.close(fd)
end
```

### 2.2 Non-blocking Operations（2.2 非阻塞操作）

```lua
-- Non-blocking read with timeout（带超时的非阻塞读取）
local function read_with_timeout(fd, timeout)
    local co = coroutine.running()
    
    -- Set timeout（设置超时定时器：超时后关闭连接并唤醒协程）
    local timer = skynet.timeout(timeout * 100, function()
        if coroutine.status(co) ~= "dead" then
            socket.close(fd)
            skynet.wakeup(co)
        end
    end)
    
    -- Read data（读取数据：Socket.read 为非阻塞操作，会挂起协程）
    local data = socket.read(fd)
    skynet.kill(timer)
    
    return data
end

-- Async write（异步写入：捕获写入错误，避免阻塞）
local function async_write(fd, data)
    local ok, err = pcall(socket.write, fd, data)
    if not ok then
        skynet.error("Write error:", err)
        return false
    end
    return true
end
```

## 3. Building a TCP Server with Gate（3. 使用 Gate 服务构建 TCP 服务器）

### 3.1 Gate Service Configuration（3.1 Gate 服务配置）

```lua
-- mygate.lua（Gate 服务实现文件）
local skynet = require "skynet"
local gateserver = require "snax.gateserver"

local handlers = {}
local connections = {}

function handlers.open(source, conf)
    skynet.error("Gate server started on", conf.address, conf.port)
    return conf.address, conf.port
end

function handlers.connect(fd, addr)
    skynet.error("Client connected:", fd, addr)
    connections[fd] = {
        fd = fd,
        addr = addr,
        connected = true
    }
    
    -- Notify watchdog（通知 Watchdog 服务有新连接）
    skynet.send(conf.watchdog, "lua", "connect", fd, addr)
end

function handlers.disconnect(fd)
    skynet.error("Client disconnected:", fd)
    connections[fd] = nil
    
    -- Notify watchdog（通知 Watchdog 服务连接已断开）
    skynet.send(conf.watchdog, "lua", "disconnect", fd)
end

function handlers.error(fd, msg)
    skynet.error("Socket error:", fd, msg)
    connections[fd] = nil
end

function handlers.message(fd, msg, sz)
    -- Forward message to agent（将消息转发给对应 Agent 服务）
    local conn = connections[fd]
    if conn and conn.agent then
        skynet.redirect(conn.agent, conn.client, "client", fd, msg, sz)
    else
        -- No agent, notify watchdog（未分配 Agent 时，通知 Watchdog 处理）
        skynet.send(conf.watchdog, "lua", "message", fd, msg, sz)
    end
end

function handlers.warning(fd, size)
    skynet.error("Socket buffer warning:", fd, size)
end

local function command_handler(cmd, source, ...)
    if cmd == "forward" then
        local fd, client, agent = ...
        local conn = connections[fd]
        if conn then
            conn.agent = agent
            conn.client = client
            gateserver.openclient(fd)
        end
    elseif cmd == "kick" then
        local fd = ...
        gateserver.closeclient(fd)
    end
end

handlers.command = command_handler

gateserver.start(handlers)
```

### 3.2 Watchdog Service（3.2 Watchdog 服务）

```lua
-- mywatchdog.lua
local skynet = require "skynet"

local CMD = {}
local SOCKET = {}
local gate
local agents = {}  -- 存储 fd 与 Agent 服务的映射关系（fd -> agent）

function SOCKET.connect(fd, addr)
    skynet.error("New client from:", addr)
    
    -- Create agent for this connection（为新连接创建专属 Agent 服务）
    local agent = skynet.newservice("myagent")
    agents[fd] = agent
    
    -- Start agent（初始化 Agent 服务，传递配置信息）
    skynet.call(agent, "lua", "start", {
        gate = gate,
        client = fd,
        watchdog = skynet.self(),
        addr = addr
    })
end

function SOCKET.disconnect(fd)
    skynet.error("Client disconnected:", fd)
    local agent = agents[fd]
    if agent then
        skynet.send(agent, "lua", "disconnect")
        agents[fd] = nil
    end
end

function SOCKET.message(fd, msg, sz)
    -- Handle messages before agent is ready（Agent 未就绪时的消息处理）
    skynet.error("Message before agent ready:", fd)
end

function CMD.start(conf)
    gate = skynet.newservice("mygate")
    return skynet.call(gate, "lua", "open", conf)
end

function CMD.close(fd)
    local agent = agents[fd]
    if agent then
        skynet.call(gate, "lua", "kick", fd)
        skynet.send(agent, "lua", "disconnect")
        agents[fd] = nil
    end
end

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, subcmd, ...)
        if cmd == "socket" then
            local f = SOCKET[subcmd]
            if f then
                f(...)
            end
        else
            local f = CMD[cmd]
            if f then
                skynet.ret(skynet.pack(f(subcmd, ...)))
            end
        end
    end)
end)
```

### 3.3 Agent Service（3.3 Agent 服务）

```lua
-- myagent.lua
local skynet = require "skynet"
local socket = require "skynet.socket"

local client_fd
local gate
local watchdog
local client_addr

local CMD = {}
local REQUEST = {}

-- Protocol handlers（业务请求处理器：登录请求）
function REQUEST:login(data)
    local username = data.username
    local password = data.password
    
    -- Validate login（验证登录信息）
    if username == "admin" and password == "secret" then
        -- Send success response（发送登录成功响应）
        send_response({
            status = "ok",
            message = "Login successful"
        })
        return true
    else
        -- Send failure response（发送登录失败响应）
        send_response({
            status = "error",
            message = "Invalid credentials"
        })
        return false
    end
end

function REQUEST:echo(data)
    send_response({
        status = "ok",
        echo = data.text
    })
end

function REQUEST:quit()
    skynet.call(watchdog, "lua", "close", client_fd)
end

-- Helper functions（辅助函数：发送响应给客户端）
local function send_response(response)
    local pack = skynet.pack(response)
    local package = string.pack(">s2", pack)
    socket.write(client_fd, package)
end

local function read_message()
    local package = socket.read(client_fd)
    if not package then
        return nil
    end
    
    local size = #package
    if size < 2 then
        return nil
    end
    
    local msg_size = string.unpack(">I2", package:sub(1, 2))
    if size < msg_size + 2 then
        return nil
    end
    
    local msg = package:sub(3, 2 + msg_size)
    return skynet.unpack(msg)
end

-- Main loop（主循环：持续读取并处理客户端消息）
local function client_loop()
    while true do
        local request = read_message()
        if not request then
            break
        end
        
        skynet.error("Received request:", request.cmd)
        
        local handler = REQUEST[request.cmd]
        if handler then
            local ok, result = pcall(handler, REQUEST, request.data)
            if not ok then
                skynet.error("Handler error:", result)
                send_response({
                    status = "error",
                    message = "Internal server error"
                })
            end
        else
            send_response({
                status = "error",
                message = "Unknown command"
            })
        end
    end
end

function CMD.start(conf)
    client_fd = conf.client
    gate = conf.gate
    watchdog = conf.watchdog
    client_addr = conf.addr
    
    -- 注册 "client" 协议：用于接收 Gate 转发的客户端消息
    skynet.register_protocol {
        name = "client",
        id = skynet.PTYPE_CLIENT,
        unpack = function(msg, sz)
            return skynet.unpack(msg, sz)
        end,
        dispatch = function()
            -- 消息处理逻辑在 client_loop 中实现，此处留空
        end
    }
    
    -- 通知 Gate 服务：将当前客户端的消息转发给本 Agent
    skynet.call(gate, "lua", "forward", client_fd, skynet.self())
    
    -- 启动客户端消息处理循环（在新协程中执行，避免阻塞）
    skynet.fork(client_loop)
    
    -- 发送欢迎消息给客户端
    send_response({
        status = "ok",
        message = "Welcome to server"
    })
    
    return true
end

function CMD.disconnect()
    skynet.exit()
end

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = CMD[cmd]
        if f then
            skynet.ret(skynet.pack(f(...)))
        end
    end)
end)
```

## 4. Protocol Handling（4. 协议处理）

### 4.1 Message Framing（4.1 消息封帧）

```lua
-- Protocol utilities（协议工具模块：实现消息的封帧与解帧）
local protocol = {}

-- Pack message with length prefix（消息封帧：添加 4 字节大端序长度前缀）
function protocol.pack_message(msg)
    local data = skynet.pack(msg)
    local len = #data
    return string.pack(">I4", len) .. data
end

-- Unpack message with length prefix（消息解帧：解析带长度前缀的消息流）
function protocol.unpack_message(data)
    local pos = 1
    local messages = {}
    
    while pos <= #data do
        if pos + 4 > #data then
            break
        end
        
        local len = string.unpack(">I4", data, pos)
        pos = pos + 4
        
        if pos + len > #data then
            break
        end
        
        local msg_data = data:sub(pos, pos + len - 1)
        local msg = skynet.unpack(msg_data)
        table.insert(messages, msg)
        
        pos = pos + len
    end
    
    return messages, data:sub(pos)
end

-- Stream reader（流读取器：处理 Socket 流数据，持续解析消息）
local function stream_reader(fd)
    local buffer = ""
    
    return function()
        while true do
            local messages, remaining = protocol.unpack_message(buffer)
            if #messages > 0 then
                buffer = remaining
                return messages[1]
            end
            
            local data = socket.read(fd)
            if not data then
                return nil
            end
            
            buffer = buffer .. data
        end
    end
end
```

### 4.2 JSON Protocol Example（4.2 JSON 协议示例）

```lua
-- JSON protocol handler（JSON 协议处理器：基于 JSON 格式的消息编码/解码）
local json = require "cjson"

local json_protocol = {}

function json_protocol.encode(msg)
    local json_str = json.encode(msg)
    return protocol.pack_message(json_str)
end

function json_protocol.decode(data)
    local json_str = protocol.unpack_message(data)
    if json_str then
        return json.decode(json_str)
    end
    return nil
end

-- Usage in agent（在 Agent 服务中使用 JSON 协议处理消息）
local function handle_json_message(fd)
    local reader = stream_reader(fd)
    
    while true do
        local msg = reader()
        if not msg then
            break
        end
        
        local request = json_protocol.decode(msg)
        if request then
            -- 处理请求（需实现 process_request 函数）
            local response = process_request(request)
            local response_data = json_protocol.encode(response)
            socket.write(fd, response_data)
        end
    end
end
```

## 5. WebSocket Support（5. WebSocket 支持）

### 5.1 WebSocket Server（5.1 WebSocket 服务器）

```lua
-- websocket_server.lua
local skynet = require "skynet"
local websocket = require "http.websocket"
local socket = require "skynet.socket"

local connections = {}

local function handle_connection(id, addr, url, header)
    skynet.error("WebSocket connected:", id, addr, url)
    
    connections[id] = {
        id = id,
        addr = addr,
        url = url
    }
    
    while true do
        local data, typ = websocket.read(id)
        if not data then
            break
        end
        
        if typ == "text" then
            -- Handle text message（处理文本消息：JSON 格式）
            local request = json.decode(data)
            local response = process_websocket_request(request)
            websocket.write(id, json.encode(response))
        elseif typ == "binary" then
            -- Handle binary message（处理二进制消息：如protobuf、自定义二进制格式）
            process_binary_data(id, data)
        elseif typ == "close" then
            break
        end
    end
    
    connections[id] = nil
    websocket.close(id)
end

local function start_websocket_server(host, port)
    local fd = socket.listen(host, port)
    skynet.error("WebSocket server listening on:", host, port)
    
    socket.start(fd, function(fd, addr)
        local ws_id = websocket.accept(fd, handle_connection, addr)
        if not ws_id then
            skynet.error("WebSocket accept failed")
            socket.close(fd)
        end
    end)
end

-- 广播消息：向所有已连接的 WebSocket 客户端发送消息
local function broadcast(message)
    local data = json.encode(message)
    for id, conn in pairs(connections) do
        websocket.write(id, data)
    end
end
```

### 5.2 WebSocket Client（5.2 WebSocket 客户端）

```lua
-- websocket_client.lua
local skynet = require "skynet"
local websocket = require "http.websocket"

local function start_client(url)
    local id = websocket.connect(url)
    if not id then
        skynet.error("Failed to connect to WebSocket:", url)
        return
    end
    
    -- 发送连接消息（JSON 格式）
    websocket.write(id, json.encode({
        type = "hello",
        data = "Client connected"
    }))
    
    -- 持续读取服务器响应
    while true do
        local data, typ = websocket.read(id)
        if not data then
            break
        end
        
        if typ == "text" then
            local msg = json.decode(data)
            skynet.error("Received:", msg)
        end
    end
    
    websocket.close(id)
end
```

## 6. HTTP Server（6. HTTP 服务器）

### 6.1 Simple HTTP Server（6.1 简单 HTTP 服务器）

```lua
-- http_server.lua
local skynet = require "skynet"
local httpd = require "http.httpd"
local sockethelper = require "http.sockethelper"
local json = require "cjson"

local function handle_request(id, header, method, path, query)
    skynet.error("HTTP request:", method, path)
    
    if method == "GET" and path == "/" then
        local response = {
            code = 200,
            headers = {
                ["Content-Type"] = "text/html",
                ["Connection"] = "keep-alive"
            },
            body = [[
                <html>
                <head><title>Skynet HTTP Server</title></head>
                <body>
                <h1>Welcome to Skynet HTTP Server</h1>
                <p>Current time: ]] .. os.date() .. [[</p>
                </body>
                </html>
            ]]
        }
        return response
    elseif method == "POST" and path == "/api/data" then
        -- Read POST data（读取 POST 数据：根据 Content-Length 头获取数据长度）
        local len = tonumber(header["content-length"]) or 0
        local data = sockethelper.read(id, len)
        
        -- Process data（处理 POST 数据：需实现 process_post_data 函数）
        local result = process_post_data(data)
        
        return {
            code = 200,
            headers = {
                ["Content-Type"] = "application/json"
            },
            body = json.encode(result)
        }
    end
    
    return {
        code = 404,
        body = "Not Found"
    }
end

local function http_session(id)
    sockethelper.init(id)
    
    local code, url, method, header, body = httpd.read_request(sockethelper.readfunc(id))
    if not code then
        skynet.error("HTTP read request error:", url)
        return
    end
    
    if code ~= 200 then
        skynet.error("HTTP request error:", code, url)
        return
    end
    
    -- Parse path and query（解析请求路径和查询参数：拆分 URL 中的路径和 ? 后的查询串）
    local path, query = url:match("^([^?]+)%??(.*)$")
    
    -- Handle request（处理请求，获取响应）
    local response = handle_request(id, header, method, path, query)
    
    -- Send response（发送 HTTP 响应：写入状态码、响应头、响应体）
    httpd.write_response(sockethelper.writefunc(id), 
                         response.code, 
                         response.body or "", 
                         response.headers)
end

local function start_http_server(host, port)
    local fd = socket.listen(host, port)
    skynet.error("HTTP server listening on:", host, port)
    
    socket.start(fd, function(fd, addr)
        skynet.fork(http_session, fd)
    end)
end
```

## 7. Network Security（7. 网络安全）

### 7.1 Connection Limiting（7.1 连接限制）

```lua
-- Connection limiter（连接限制器：限制单 IP 连接数和总连接数）
local connection_limiter = {
    max_connections_per_ip = 10,
    ip_connections = {},
    total_connections = 0,
    max_total_connections = 1000
}

local function check_connection_limit(addr)
    local ip = addr:match("^(%d+%.%d+%.%d+%.%d+)")
    if not ip then return true end
    
    -- Check per-IP limit（检查单 IP 连接数限制）
    connection_limiter.ip_connections[ip] = connection_limiter.ip_connections[ip] or 0
    if connection_limiter.ip_connections[ip] >= connection_limiter.max_connections_per_ip then
        return false, "Too many connections from your IP"
    end
    
    -- Check total limit（检查总连接数限制）
    if connection_limiter.total_connections >= connection_limiter.max_total_connections then
        return false, "Server full"
    end
    
    return true
end

local function record_connection(addr, fd)
    local ip = addr:match("^(%d+%.%d+%.%d+%.%d+)")
    if ip then
        connection_limiter.ip_connections[ip] = connection_limiter.ip_connections[ip] + 1
    end
    connection_limiter.total_connections = connection_limiter.total_connections + 1
end

local function remove_connection(addr, fd)
    local ip = addr:match("^(%d+%.%d+%.%d+%.%d+)")
    if ip and connection_limiter.ip_connections[ip] then
        connection_limiter.ip_connections[ip] = connection_limiter.ip_connections[ip] - 1
        if connection_limiter.ip_connections[ip] <= 0 then
            connection_limiter.ip_connections[ip] = nil
        end
    end
    connection_limiter.total_connections = connection_limiter.total_connections - 1
end
```

### 7.2 Rate Limiting（7.2 速率限制）

```lua
-- Rate limiter using token bucket（基于令牌桶算法的速率限制器）
local rate_limiter = {
    buckets = {}
}

local function get_token_bucket(key, rate, capacity)
    local bucket = rate_limiter.buckets[key]
    if not bucket then
        bucket = {
            tokens = capacity,
            last_update = skynet.time(),
            rate = rate,
            capacity = capacity
        }
        rate_limiter.buckets[key] = bucket
    end
    
    -- Update tokens（更新令牌数量：根据时间差和速率生成新令牌）
    local now = skynet.time()
    local elapsed = now - bucket.last_update
    bucket.tokens = math.min(bucket.capacity, 
                            bucket.tokens + elapsed * bucket.rate)
    bucket.last_update = now
    
    return bucket
end

local function check_rate_limit(key, rate, capacity, cost)
    local bucket = get_token_bucket(key, rate, capacity)
    
    if bucket.tokens >= cost then
        bucket.tokens = bucket.tokens - cost
        return true
    end
    
    return false
end

-- Usage（使用示例：限制客户端 IP 的请求速率）
local function handle_request(client_ip)
    if not check_rate_limit(client_ip, 10, 100, 1) then
        return false, "Rate limit exceeded"
    end
    
    -- Process request（处理请求）
    return true
end
```

## 8. Example: Chat Server Implementation（8. 示例：聊天室服务器实现）

```lua
-- chat_server.lua
local skynet = require "skynet"
local socket = require "skynet.socket"
local gateserver = require "snax.gateserver"

local rooms = {}
local clients = {}
local message_id = 0

-- Gate server handlers（Gate 服务事件处理器）
local handlers = {}

function handlers.connect(fd, addr)
    skynet.error("Chat client connected:", fd, addr)
    clients[fd] = {
        fd = fd,
        addr = addr,
        name = "Guest" .. fd,
        room = nil
    }
end

function handlers.disconnect(fd)
    local client = clients[fd]
    if client and client.room then
        leave_room(fd, client.room)
    end
    clients[fd] = nil
    skynet.error("Chat client disconnected:", fd)
end

function handlers.message(fd, msg, sz)
    local client = clients[fd]
    if not client then return end
    
    -- 解析消息（简单协议：命令\n消息体）
    local cmd, body = string.match(msg, "^(%w+)\n(.*)$")
    if not cmd then
        cmd = msg
        body = ""
    end
    
    if cmd == "JOIN" then
        join_room(fd, body)
    elseif cmd == "MSG" then
        send_message(fd, body)
    elseif cmd == "LEAVE" then
        leave_room(fd, client.room)
    elseif cmd == "NICK" then
        change_nick(fd, body)
    end
end

-- Room management
local function join_room(fd, room_name)
    local client = clients[fd]
    if not client then return end
    
    -- Leave current room（若已在其他房间，先离开）
    if client.room then
        leave_room(fd, client.room)
    end
    
    -- Join new room（加入新房间：若房间不存在则创建）
    if not rooms[room_name] then
        rooms[room_name] = { clients = {} }
    end
    
    rooms[room_name].clients[fd] = true
    client.room = room_name
    
    -- Broadcast join message（广播加入消息：通知房间内所有用户）
    broadcast_to_room(room_name, {
        type = "join",
        user = client.name,
        message = client.name .. " joined the room"
    })
    
    -- Send room info（向新加入用户发送房间信息）
    send_to_client(fd, {
        type = "room_joined",
        room = room_name,
        users = get_room_users(room_name)
    })
end

local function leave_room(fd, room_name)
    local client = clients[fd]
    if not client or not room_name then return end
    
    local room = rooms[room_name]
    if room then
        room.clients[fd] = nil
        
        -- Broadcast leave message（广播离开消息：通知房间内所有用户，排除自己）
        broadcast_to_room(room_name, {
            type = "leave",
            user = client.name,
            message = client.name .. " left the room"
        }, fd)
        
        -- Clean up empty rooms（若房间无用户，删除房间以节省内存）
        if next(room.clients) == nil then
            rooms[room_name] = nil
        end
    end
    
    client.room = nil
end

local function send_message(fd, text)
    local client = clients[fd]
    if not client or not client.room then return end
    
    message_id = message_id + 1
    
    local message = {
        type = "message",
        id = message_id,
        user = client.name,
        text = text,
        time = os.date("%H:%M:%S")
    }
    
    broadcast_to_room(client.room, message, fd)
end

-- Utility functions（辅助函数）
local function broadcast_to_room(room_name, message, exclude_fd)
    local room = rooms[room_name]
    if not room then return end
    
    local msg_str = json.encode(message) .. "\n"
    
    for fd, _ in pairs(room.clients) do
        if fd ~= exclude_fd then
            socket.write(fd, msg_str)
        end
    end
end

local function send_to_client(fd, message)
    local msg_str = json.encode(message) .. "\n"
    socket.write(fd, msg_str)
end

local function get_room_users(room_name)
    local room = rooms[room_name]
    if not room then return {} end
    
    local users = {}
    for fd, _ in pairs(room.clients) do
        if clients[fd] then
            table.insert(users, clients[fd].name)
        end
    end
    return users
end

local function change_nick(fd, new_name)
    local client = clients[fd]
    if not client then return end
    
    local old_name = client.name
    client.name = new_name
    
    if client.room then
        broadcast_to_room(client.room, {
            type = "nick_change",
            old_name = old_name,
            new_name = new_name,
            message = old_name .. " is now known as " .. new_name
        })
    end
end

-- Start gate server（启动 Gate 服务，运行聊天室）
gateserver.start(handlers)
```

## 9. Exercise: Real-time Game Server（9. 练习：实时游戏服务器）

Create a real-time multiplayer game server with:（创建一个实时多人游戏服务器，需包含以下功能）
1. Player movement synchronization（玩家移动同步）
2. Game state management（游戏状态管理）
3. Room/lobby system（房间/大厅系统）
4. Player authentication（玩家认证）
5. Lag compensation techniques（延迟补偿技术）

**Features to implement**:（需实现的额外特性）
- UDP support for fast updates（支持 UDP 协议以实现快速更新）
- Entity interpolation（实体插值：平滑显示远程玩家移动）
- Client-side prediction（客户端预测：本地预测移动结果，减少延迟感）
- Server reconciliation（服务器修正：服务器验证并修正客户端预测结果）
- Anti-cheat measures（反作弊措施：如移动速度限制、位置验证等）

## Summary（总结）

In this tutorial, you learned:（在本教程中，你学习了）
- Skynet's socket API and network programming model（Skynet 的 Socket API 与网络编程模型）
- Building scalable TCP servers with gate service（使用 Gate 服务构建可扩展的 TCP 服务器）
- Protocol handling and message framing（协议处理与消息封帧技术）
- WebSocket and HTTP server implementation（WebSocket 与 HTTP 服务器实现）
- Network security practices（网络安全实践：连接限制与速率限制）
- Connection and rate limiting（连接管理与速率控制）
- Building a complete chat server（完整聊天室服务器的构建）

## Next Steps（下一步）

Continue to [Tutorial 7: Distributed Skynet Applications](./tutorial7_distributed.md) to learn about building distributed systems with Skynet's cluster and harbor services.（继续学习《教程 7：分布式 Skynet 应用》，了解如何使用 Skynet 的 cluster 和 harbor 服务构建分布式系统。）