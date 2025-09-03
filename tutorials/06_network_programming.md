# Network Programming with Skynet

## What You'll Learn
- Skynet's socket API and network programming model
- Building TCP servers with gate service
- Client connection management
- Protocol handling and message framing
- WebSocket and HTTP support
- Network security and optimization

## Prerequisites
- Completed Tutorial 5: Working with Lua Services
- Understanding of basic network programming concepts
- Knowledge of TCP/IP protocols

## Time Estimate
60 minutes

## Final Result
Ability to build scalable network services using Skynet's networking capabilities

---

## 1. Skynet Network Architecture

### 1.1 Network Stack Overview

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

### 1.2 Key Components

- **Socket Driver**: Low-level socket operations
- **Gate Service**: Connection management and message routing
- **Agent Services**: Per-client connection handlers
- **Watchdog Service**: Connection lifecycle management

## 2. Basic Socket Operations

### 2.1 Socket API Basics

```lua
local socket = require "skynet.socket"

-- Create TCP server
local fd = socket.listen("0.0.0.0", 8888)
socket.start(fd, function(fd, addr)
    -- New connection handler
    skynet.error("New connection from:", addr)
    
    -- Start reading from socket
    while true do
        local data = socket.read(fd)
        if not data then
            break
        end
        
        -- Echo back
        socket.write(fd, data)
    end
    
    socket.close(fd)
end)

-- TCP client connection
local fd = socket.connect("127.0.0.1", 8888)
if fd then
    socket.write(fd, "Hello, Server!\n")
    local response = socket.read(fd)
    print("Server response:", response)
    socket.close(fd)
end
```

### 2.2 Non-blocking Operations

```lua
-- Non-blocking read with timeout
local function read_with_timeout(fd, timeout)
    local co = coroutine.running()
    
    -- Set timeout
    local timer = skynet.timeout(timeout * 100, function()
        if coroutine.status(co) ~= "dead" then
            socket.close(fd)
            skynet.wakeup(co)
        end
    end)
    
    -- Read data
    local data = socket.read(fd)
    skynet.kill(timer)
    
    return data
end

-- Async write
local function async_write(fd, data)
    local ok, err = pcall(socket.write, fd, data)
    if not ok then
        skynet.error("Write error:", err)
        return false
    end
    return true
end
```

## 3. Building a TCP Server with Gate

### 3.1 Gate Service Configuration

```lua
-- mygate.lua
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
    
    -- Notify watchdog
    skynet.send(conf.watchdog, "lua", "connect", fd, addr)
end

function handlers.disconnect(fd)
    skynet.error("Client disconnected:", fd)
    connections[fd] = nil
    
    -- Notify watchdog
    skynet.send(conf.watchdog, "lua", "disconnect", fd)
end

function handlers.error(fd, msg)
    skynet.error("Socket error:", fd, msg)
    connections[fd] = nil
end

function handlers.message(fd, msg, sz)
    -- Forward message to agent
    local conn = connections[fd]
    if conn and conn.agent then
        skynet.redirect(conn.agent, conn.client, "client", fd, msg, sz)
    else
        -- No agent, notify watchdog
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

### 3.2 Watchdog Service

```lua
-- mywatchdog.lua
local skynet = require "skynet"

local CMD = {}
local SOCKET = {}
local gate
local agents = {}  -- fd -> agent

function SOCKET.connect(fd, addr)
    skynet.error("New client from:", addr)
    
    -- Create agent for this connection
    local agent = skynet.newservice("myagent")
    agents[fd] = agent
    
    -- Start agent
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
    -- Handle messages before agent is ready
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

### 3.3 Agent Service

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

-- Protocol handlers
function REQUEST:login(data)
    local username = data.username
    local password = data.password
    
    -- Validate login
    if username == "admin" and password == "secret" then
        -- Send success response
        send_response({
            status = "ok",
            message = "Login successful"
        })
        return true
    else
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

-- Helper functions
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

-- Main loop
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
    
    -- Register client protocol
    skynet.register_protocol {
        name = "client",
        id = skynet.PTYPE_CLIENT,
        unpack = function(msg, sz)
            return skynet.unpack(msg, sz)
        end,
        dispatch = function()
            -- Handled in client_loop
        end
    }
    
    -- Forward messages to this agent
    skynet.call(gate, "lua", "forward", client_fd, skynet.self())
    
    -- Start client loop in background
    skynet.fork(client_loop)
    
    -- Send welcome message
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

## 4. Protocol Handling

### 4.1 Message Framing

```lua
-- Protocol utilities
local protocol = {}

-- Pack message with length prefix
function protocol.pack_message(msg)
    local data = skynet.pack(msg)
    local len = #data
    return string.pack(">I4", len) .. data
end

-- Unpack message with length prefix
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

-- Stream reader
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

### 4.2 JSON Protocol Example

```lua
-- JSON protocol handler
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

-- Usage in agent
local function handle_json_message(fd)
    local reader = stream_reader(fd)
    
    while true do
        local msg = reader()
        if not msg then
            break
        end
        
        local request = json_protocol.decode(msg)
        if request then
            -- Process request
            local response = process_request(request)
            local response_data = json_protocol.encode(response)
            socket.write(fd, response_data)
        end
    end
end
```

## 5. WebSocket Support

### 5.1 WebSocket Server

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
            -- Handle text message
            local request = json.decode(data)
            local response = process_websocket_request(request)
            websocket.write(id, json.encode(response))
        elseif typ == "binary" then
            -- Handle binary message
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

-- Broadcast to all connected clients
local function broadcast(message)
    local data = json.encode(message)
    for id, conn in pairs(connections) do
        websocket.write(id, data)
    end
end
```

### 5.2 WebSocket Client

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
    
    -- Send message
    websocket.write(id, json.encode({
        type = "hello",
        data = "Client connected"
    }))
    
    -- Read responses
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

## 6. HTTP Server

### 6.1 Simple HTTP Server

```lua
-- http_server.lua
local skynet = require "skynet"
local httpd = require "http.httpd"
local sockethelper = require "http.sockethelper"

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
        -- Read POST data
        local len = tonumber(header["content-length"]) or 0
        local data = sockethelper.read(id, len)
        
        -- Process data
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
    
    -- Parse path and query
    local path, query = url:match("^([^?]+)%??(.*)$")
    
    -- Handle request
    local response = handle_request(id, header, method, path, query)
    
    -- Send response
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

## 7. Network Security

### 7.1 Connection Limiting

```lua
-- Connection limiter
local connection_limiter = {
    max_connections_per_ip = 10,
    ip_connections = {},
    total_connections = 0,
    max_total_connections = 1000
}

local function check_connection_limit(addr)
    local ip = addr:match("^(%d+%.%d+%.%d+%.%d+)")
    if not ip then return true end
    
    -- Check per-IP limit
    connection_limiter.ip_connections[ip] = connection_limiter.ip_connections[ip] or 0
    if connection_limiter.ip_connections[ip] >= connection_limiter.max_connections_per_ip then
        return false, "Too many connections from your IP"
    end
    
    -- Check total limit
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

### 7.2 Rate Limiting

```lua
-- Rate limiter using token bucket
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
    
    -- Update tokens
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

-- Usage
local function handle_request(client_ip)
    if not check_rate_limit(client_ip, 10, 100, 1) then
        return false, "Rate limit exceeded"
    end
    
    -- Process request
    return true
end
```

## 8. Example: Chat Server Implementation

```lua
-- chat_server.lua
local skynet = require "skynet"
local socket = require "skynet.socket"
local gateserver = require "snax.gateserver"

local rooms = {}
local clients = {}
local message_id = 0

-- Gate server handlers
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
    
    -- Parse message (simple protocol: command\nbody)
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
    
    -- Leave current room
    if client.room then
        leave_room(fd, client.room)
    end
    
    -- Join new room
    if not rooms[room_name] then
        rooms[room_name] = { clients = {} }
    end
    
    rooms[room_name].clients[fd] = true
    client.room = room_name
    
    -- Broadcast join message
    broadcast_to_room(room_name, {
        type = "join",
        user = client.name,
        message = client.name .. " joined the room"
    })
    
    -- Send room info
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
        
        -- Broadcast leave message
        broadcast_to_room(room_name, {
            type = "leave",
            user = client.name,
            message = client.name .. " left the room"
        }, fd)
        
        -- Clean up empty rooms
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

-- Utility functions
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

-- Start gate server
gateserver.start(handlers)
```

## 9. Exercise: Real-time Game Server

Create a real-time multiplayer game server with:
1. Player movement synchronization
2. Game state management
3. Room/lobby system
4. Player authentication
5. Lag compensation techniques

**Features to implement**:
- UDP support for fast updates
- Entity interpolation
- Client-side prediction
- Server reconciliation
- Anti-cheat measures

## Summary

In this tutorial, you learned:
- Skynet's socket API and network programming model
- Building scalable TCP servers with gate service
- Protocol handling and message framing
- WebSocket and HTTP server implementation
- Network security practices
- Connection and rate limiting
- Building a complete chat server

## Next Steps

Continue to [Tutorial 7: Distributed Skynet Applications](./tutorial7_distributed.md) to learn about building distributed systems with Skynet's cluster and harbor services.