# Skynet系统服务层 - 网络服务详解 Part 2

## 目录

### Part 2 - 网络协议与应用服务
8. [登录服务器框架](#登录服务器框架)
9. [WebSocket服务](#websocket服务)
10. [HTTP服务](#http服务)
11. [协议处理框架](#协议处理框架)
12. [实战案例](#实战案例)

---

## 登录服务器框架

### 概述

LoginServer是Skynet提供的安全登录框架，实现了基于DH密钥交换和HMAC认证的安全登录协议。

### 协议流程

```
┌────────────────────────────────────────────────┐
│          Login Protocol Flow                    │
└────────────────────────────────────────────────┘

    Client                          Server
       │                               │
       │  1. Connect                   │
       ├──────────────────────────────►│
       │                               │
       │  2. Challenge (8 bytes)       │
       │◄──────────────────────────────┤
       │                               │
       │  3. Client Key (8 bytes)      │
       ├──────────────────────────────►│
       │                               │
       │  4. DH-Exchange(Server Key)   │
       │◄──────────────────────────────┤
       │                               │
       │  5. Compute DH-Secret         │
       ├─────────────────────────────► │
       │                               │
       │  6. HMAC(challenge, secret)   │
       ├──────────────────────────────►│
       │                               │ Verify HMAC
       │  7. DES(secret, token)        │
       ├──────────────────────────────►│
       │                               │ auth_handler(token)
       │                               │ login_handler(...)
       │  8. Response (200/4xx)        │
       │◄──────────────────────────────┤
       │                               │
       └───────────────────────────────┘
```

### 协议详解

**文件位置**: `lualib/snax/loginserver.lua`

#### 1. 挑战响应

```lua
-- 服务器生成随机挑战
local challenge = crypt.randomkey()  -- 8字节随机数
write("auth", fd, crypt.base64encode(challenge).."\n")
```

#### 2. 密钥交换

```lua
-- 客户端发送密钥
local handshake = socket.readline(fd)
local clientkey = crypt.base64decode(handshake)

-- 服务器生成密钥并交换
local serverkey = crypt.randomkey()
write("auth", fd, crypt.base64encode(
    crypt.dhexchange(serverkey)).."\n")

-- 计算共享密钥
local secret = crypt.dhsecret(clientkey, serverkey)
```

#### 3. HMAC认证

```lua
-- 客户端发送HMAC
local response = socket.readline(fd)
local hmac = crypt.hmac64(challenge, secret)

-- 验证HMAC
if hmac ~= crypt.base64decode(response) then
    error "challenge failed"
end
```

#### 4. Token处理

```lua
-- 接收加密的token
local etoken = socket.readline(fd)
local token = crypt.desdecode(secret, crypt.base64decode(etoken))

-- 调用认证处理器
local ok, server, uid = pcall(auth_handler, token)
```

### 服务器架构

```lua
-- Master-Slave架构
local function launch_master(conf)
    local host = conf.host or "0.0.0.0"
    local port = assert(conf.port)
    local slave = {}
    local balance = 1
    
    -- 创建多个slave处理认证
    for i=1, conf.worker or 8 do
        local s = skynet.newservice(SERVICE_NAME, "slave")
        skynet.call(s, "lua", "init", auth_handler)
        slave[i] = s
    end
    
    -- 监听端口
    local id = socket.listen(host, port)
    socket.start(id, function(fd, addr)
        -- 负载均衡到slave
        local s = slave[balance]
        balance = balance + 1
        if balance > #slave then
            balance = 1
        end
        
        -- slave处理认证
        local ok, server, uid, secret = skynet.call(s, "lua", fd, addr)
        
        -- master处理登录
        if ok then
            accept(conf, s, fd, addr, server, uid, secret)
        end
    end)
end
```

### 使用示例

#### 1. 实现登录服务

```lua
local login = require "snax.loginserver"
local crypt = require "skynet.crypt"

local server = {
    host = "0.0.0.0",
    port = 8001,
    multilogin = false,  -- 禁止多重登录
    name = "login_master",
}

-- 认证处理器
function server.auth_handler(token)
    -- token格式: user@server:password
    local user, server, password = token:match("([^@]+)@([^:]+):(.+)")
    user = crypt.base64decode(user)
    server = crypt.base64decode(server)
    password = crypt.base64decode(password)
    
    -- 验证密码
    assert(password == "password", "Invalid password")
    
    return server, user
end

-- 登录处理器
function server.login_handler(server, uid, secret)
    print(string.format("%s@%s is login", uid, server))
    
    -- 检查是否已登录
    if user_online[uid] then
        error(string.format("user %s is already online", uid))
    end
    
    -- 通知游戏服务器
    local gameserver = server_list[server]
    local subid = skynet.call(gameserver, "lua", "login", uid, secret)
    
    -- 记录在线状态
    user_online[uid] = { 
        address = gameserver, 
        subid = subid, 
        server = server 
    }
    
    return subid
end

-- 启动登录服务
login(server)
```

#### 2. 客户端实现

```lua
local socket = require "client.socket"
local crypt = require "client.crypt"

-- 连接登录服务器
local fd = socket.connect("127.0.0.1", 8001)

-- 接收挑战
local challenge = socket.readline(fd)
challenge = crypt.base64decode(challenge)

-- 发送客户端密钥
local clientkey = crypt.randomkey()
socket.write(fd, crypt.base64encode(clientkey).."\n")

-- 接收服务器密钥
local serverkey = socket.readline(fd)
serverkey = crypt.base64decode(serverkey)

-- 计算共享密钥
local secret = crypt.dhsecret(serverkey, clientkey)

-- 发送HMAC
local hmac = crypt.hmac64(challenge, secret)
socket.write(fd, crypt.base64encode(hmac).."\n")

-- 发送加密的token
local token = string.format("%s@%s:%s",
    crypt.base64encode("user"),
    crypt.base64encode("game1"),
    crypt.base64encode("password"))
local etoken = crypt.desencode(secret, token)
socket.write(fd, crypt.base64encode(etoken).."\n")

-- 接收响应
local response = socket.readline(fd)
if response:sub(1,3) == "200" then
    local subid = crypt.base64decode(response:sub(5))
    print("Login success, subid:", subid)
else
    print("Login failed:", response)
end
```

### 错误码

- **401 Unauthorized**: 认证失败
- **403 Forbidden**: 登录处理失败
- **406 Not Acceptable**: 已经登录（禁止多重登录）
- **200 OK**: 登录成功

---

## WebSocket服务

### 概述

WebSocket提供了全双工的通信通道，适用于实时应用如游戏、聊天、推送等。

### 协议实现

**文件位置**: `lualib/http/websocket.lua`

#### 握手过程

```lua
-- 客户端握手请求
local function write_handshake(self, host, url, header)
    -- 生成随机key
    local key = crypt.base64encode(crypt.randomkey()..crypt.randomkey())
    
    local request_header = {
        ["Upgrade"] = "websocket",
        ["Connection"] = "Upgrade",
        ["Sec-WebSocket-Version"] = "13",
        ["Sec-WebSocket-Key"] = key
    }
    
    -- 发送HTTP请求
    local code, payload = internal.request(self, "GET", 
                                          host, url, 
                                          recvheader, 
                                          request_header)
    
    -- 验证响应码
    if code ~= 101 then
        error(string.format("websocket handshake error: %s", code))
    end
    
    -- 验证Accept key
    local sw_key = recvheader["sec-websocket-accept"]
    sw_key = crypt.base64decode(sw_key)
    if sw_key ~= crypt.sha1(key .. GLOBAL_GUID) then
        error("invalid Sec-WebSocket-Accept")
    end
end
```

#### 帧格式

```
  0                   1                   2                   3
  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
 +-+-+-+-+-------+-+-------------+-------------------------------+
 |F|R|R|R| opcode|M| Payload len |    Extended payload length    |
 |I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
 |N|V|V|V|       |S|             |   (if payload len==126/127)   |
 | |1|2|3|       |K|             |                               |
 +-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - - +
 |     Extended payload length continued, if payload len == 127  |
 + - - - - - - - - - - - - - - - +-------------------------------+
 |                               |Masking-key, if MASK set to 1  |
 +-------------------------------+-------------------------------+
 | Masking-key (continued)       |          Payload Data         |
 +-------------------------------- - - - - - - - - - - - - - - - +
 :                     Payload Data continued ...                :
 + - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - +
 |                     Payload Data continued ...                |
 +---------------------------------------------------------------+
```

#### 帧解析

```lua
local function read_frame(self, force_masking)
    local frame = self.read(2)
    
    local op, fin, mask = string.unpack("BB", frame)
    
    -- 解析标志位
    fin = op & 0x80 ~= 0
    op = op & 0x0f
    mask = mask & 0x80 ~= 0
    local payload_len = mask & 0x7f
    
    -- 检查masking
    if force_masking and not mask then
        error("frame must be mask")
    end
    
    -- 读取扩展长度
    if payload_len == 126 then
        payload_len = string.unpack(">H", self.read(2))
    elseif payload_len == 127 then
        payload_len = string.unpack(">I8", self.read(8))
    end
    
    -- 检查大小限制
    if payload_len > MAX_FRAME_SIZE then
        error("payload too large")
    end
    
    -- 读取masking key
    local masking_key = mask and self.read(4) or false
    
    -- 读取payload
    local payload = payload_len > 0 and self.read(payload_len) or ""
    
    -- 解码masking
    if mask then
        payload = crypt.xor_str(payload, masking_key)
    end
    
    return fin, op, payload
end
```

#### 消息类型

```lua
local op_code = {
    ["continuation"] = 0x0,
    ["text"] = 0x1,
    ["binary"] = 0x2,
    ["close"] = 0x8,
    ["ping"] = 0x9,
    ["pong"] = 0xa,
}

-- 发送消息
local function write_frame(self, op, payload, masking)
    -- 构建帧头
    local op_v = op_code[op]
    local fin = 0x80  -- FIN=1
    local mask = masking and 0x80 or 0x00
    
    local frame = string.pack("B", fin | op_v)
    
    -- 处理payload长度
    local payload_len = #payload
    if payload_len < 126 then
        frame = frame .. string.pack("B", mask | payload_len)
    elseif payload_len < 0xffff then
        frame = frame .. string.pack("B>H", mask | 126, payload_len)
    else
        frame = frame .. string.pack("B>I8", mask | 127, payload_len)
    end
    
    -- 添加masking
    if masking then
        local masking_key = crypt.randomkey()
        frame = frame .. masking_key:sub(1,4)
        payload = crypt.xor_str(payload, masking_key)
    end
    
    -- 发送帧
    self.write(frame .. payload)
end
```

### WebSocket服务实现

#### 服务端

```lua
local skynet = require "skynet"
local socket = require "skynet.socket"
local websocket = require "http.websocket"

local handle = {}

-- 新连接
function handle.connect(id)
    print("ws connect from:", id)
end

-- 握手
function handle.handshake(id, header, url)
    local addr = websocket.addrinfo(id)
    print("ws handshake from:", id, "url:", url)
end

-- 接收消息
function handle.message(id, msg, msg_type)
    assert(msg_type == "binary" or msg_type == "text")
    print("ws message:", msg)
    -- 回显
    websocket.write(id, msg)
end

-- Ping
function handle.ping(id)
    print("ws ping from:", id)
end

-- Pong
function handle.pong(id)
    print("ws pong from:", id)
end

-- 连接关闭
function handle.close(id, code, reason)
    print("ws close:", id, code, reason)
end

-- 错误
function handle.error(id)
    print("ws error:", id)
end

-- 启动服务
skynet.start(function()
    -- 监听HTTP端口
    local id = socket.listen("0.0.0.0", 9948)
    
    socket.start(id, function(fd, addr)
        -- 接受WebSocket连接
        local ok, err = websocket.accept(fd, handle, "ws", addr)
        if not ok then
            print(err)
        end
    end)
end)
```

#### 客户端

```lua
local websocket = require "http.websocket"

-- 连接WebSocket服务器
local ws_id = websocket.connect("ws://127.0.0.1:9948/test")

-- 发送文本消息
websocket.write(ws_id, "hello", "text")

-- 发送二进制消息
websocket.write(ws_id, data, "binary")

-- 读取消息
local msg, msg_type = websocket.read(ws_id)
if msg then
    print("Received:", msg_type, msg)
else
    print("Connection closed")
end

-- 发送Ping
websocket.ping(ws_id)

-- 关闭连接
websocket.close(ws_id, 1000, "Normal close")
```

### 负载均衡

```lua
local skynet = require "skynet"
local socket = require "skynet.socket"
local websocket = require "http.websocket"

skynet.start(function()
    -- 创建Agent池
    local agent = {}
    for i = 1, 20 do
        agent[i] = skynet.newservice(SERVICE_NAME, "agent")
    end
    
    local balance = 1
    
    -- 监听端口
    local id = socket.listen("0.0.0.0", 9948)
    
    socket.start(id, function(fd, addr)
        -- 轮询分配到Agent
        skynet.send(agent[balance], "lua", fd, "ws", addr)
        balance = balance % #agent + 1
    end)
end)
```

---

## HTTP服务

### 概述

Skynet提供了完整的HTTP/1.1协议实现，支持作为客户端和服务端。

### HTTP请求处理

**文件位置**: `lualib/http/httpd.lua`

#### 请求解析

```lua
function httpd.read_request(readbytes, bodylimit)
    local tmpline = {}
    -- 读取header
    local body = internal.recvheader(readbytes, tmpline, "")
    if not body then
        return 413  -- Request Entity Too Large
    end
    
    -- 解析请求行
    local request = assert(tmpline[1])
    local method, url, httpver = request:match(
        "^(%a+)%s+(.-)%s+HTTP/([%d%.]+)$")
    
    -- 检查HTTP版本
    httpver = tonumber(httpver)
    if httpver < 1.0 or httpver > 1.1 then
        return 505  -- HTTP Version not supported
    end
    
    -- 解析header
    local header = internal.parseheader(tmpline, 2, {})
    
    -- 处理body
    local length = header["content-length"]
    if length then
        length = tonumber(length)
        if bodylimit and length > bodylimit then
            return 413
        end
    end
    
    -- 处理chunked编码
    local mode = header["transfer-encoding"]
    if mode == "chunked" then
        body, header = internal.recvchunkedbody(
            readbytes, bodylimit, header, body)
    elseif length then
        -- 读取固定长度body
        if #body < length then
            body = body .. readbytes(length - #body)
        else
            body = body:sub(1, length)
        end
    end
    
    return 200, url, method, header, body
end
```

#### 响应生成

```lua
function httpd.write_response(writefunc, statuscode, body, header)
    -- 状态行
    local statusline = string.format("HTTP/1.1 %03d %s\r\n", 
                                    statuscode, 
                                    http_status_msg[statuscode] or "")
    writefunc(statusline)
    
    -- Header
    if header then
        for k, v in pairs(header) do
            if type(v) == "table" then
                for _, v in ipairs(v) do
                    writefunc(string.format("%s: %s\r\n", k, v))
                end
            else
                writefunc(string.format("%s: %s\r\n", k, v))
            end
        end
    end
    
    -- Body
    local t = type(body)
    if t == "string" then
        -- 固定长度
        writefunc(string.format("content-length: %d\r\n\r\n", #body))
        writefunc(body)
    elseif t == "function" then
        -- Chunked编码
        writefunc("transfer-encoding: chunked\r\n\r\n")
        while true do
            local s = body()
            if s then
                if s ~= "" then
                    writefunc(string.format("%x\r\n", #s))
                    writefunc(s)
                    writefunc("\r\n")
                end
            else
                writefunc("0\r\n\r\n")
                break
            end
        end
    else
        -- 无body
        writefunc("\r\n")
    end
end
```

### HTTP服务器实现

#### 简单服务器

```lua
local skynet = require "skynet"
local socket = require "skynet.socket"
local httpd = require "http.httpd"
local sockethelper = require "http.sockethelper"
local urllib = require "http.url"

local function response(id, write, ...)
    local ok, err = httpd.write_response(write, ...)
    if not ok then
        skynet.error("response error:", err)
        socket.close(id)
    end
end

-- 处理请求
local function handle_request(id, addr)
    socket.start(id)
    
    -- 限制body大小为8K
    local code, url, method, header, body = httpd.read_request(
        sockethelper.readfunc(id), 8192)
    
    if code then
        if code ~= 200 then
            response(id, sockethelper.writefunc(id), code)
        else
            -- 解析URL
            local path, query = urllib.parse(url)
            
            -- 路由处理
            if path == "/api/hello" then
                response(id, sockethelper.writefunc(id), 200, 
                    '{"message":"Hello World"}',
                    {["content-type"] = "application/json"})
            elseif path == "/api/echo" then
                response(id, sockethelper.writefunc(id), 200, body)
            else
                response(id, sockethelper.writefunc(id), 404, 
                    "Not Found")
            end
        end
    else
        skynet.error("request error:", url)
        response(id, sockethelper.writefunc(id), 400)
    end
    
    socket.close(id)
end

skynet.start(function()
    local id = socket.listen("0.0.0.0", 8080)
    skynet.error("HTTP server listen on :8080")
    
    socket.start(id, function(fd, addr)
        skynet.fork(handle_request, fd, addr)
    end)
end)
```

#### RESTful API服务器

```lua
local skynet = require "skynet"
local json = require "json"

-- 路由表
local routes = {}

-- GET /users
routes["GET /users"] = function(query, header, body)
    local users = db.query("SELECT * FROM users")
    return 200, json.encode(users)
end

-- GET /users/:id
routes["GET /users/:id"] = function(query, header, body, id)
    local user = db.query("SELECT * FROM users WHERE id=?", id)
    if user then
        return 200, json.encode(user)
    else
        return 404, json.encode({error = "User not found"})
    end
end

-- POST /users
routes["POST /users"] = function(query, header, body)
    local data = json.decode(body)
    local id = db.insert("users", data)
    return 201, json.encode({id = id})
end

-- PUT /users/:id
routes["PUT /users/:id"] = function(query, header, body, id)
    local data = json.decode(body)
    local ok = db.update("users", id, data)
    if ok then
        return 200, json.encode({success = true})
    else
        return 404, json.encode({error = "User not found"})
    end
end

-- DELETE /users/:id
routes["DELETE /users/:id"] = function(query, header, body, id)
    local ok = db.delete("users", id)
    if ok then
        return 204  -- No Content
    else
        return 404, json.encode({error = "User not found"})
    end
end

-- 路由匹配
local function match_route(method, path)
    -- 精确匹配
    local route = routes[method .. " " .. path]
    if route then
        return route
    end
    
    -- 参数匹配
    for pattern, handler in pairs(routes) do
        local m, p = pattern:match("^(%S+) (.+)$")
        if m == method then
            -- 检查是否有参数
            local regex = p:gsub(":(%w+)", "([^/]+)")
            local params = {path:match("^" .. regex .. "$")}
            if #params > 0 then
                return handler, table.unpack(params)
            end
        end
    end
    
    return nil
end

-- 中间件
local function cors_middleware(handler)
    return function(...)
        local code, body, header = handler(...)
        header = header or {}
        header["Access-Control-Allow-Origin"] = "*"
        header["Access-Control-Allow-Methods"] = "GET,POST,PUT,DELETE"
        return code, body, header
    end
end

-- 请求处理
local function handle_request(id, addr)
    local code, url, method, header, body = httpd.read_request(
        sockethelper.readfunc(id), 1024*1024)  -- 1MB limit
    
    if code == 200 then
        local path, query = urllib.parse(url)
        local handler, ... = match_route(method, path)
        
        if handler then
            -- 应用中间件
            handler = cors_middleware(handler)
            
            -- 处理请求
            local status, result, response_header = handler(
                query, header, body, ...)
            
            response_header = response_header or {}
            response_header["content-type"] = "application/json"
            
            response(id, sockethelper.writefunc(id), 
                    status, result, response_header)
        else
            response(id, sockethelper.writefunc(id), 404,
                    json.encode({error = "Not Found"}),
                    {["content-type"] = "application/json"})
        end
    else
        response(id, sockethelper.writefunc(id), code or 400)
    end
    
    socket.close(id)
end
```

### HTTP客户端

```lua
local httpc = require "http.httpc"

-- GET请求
local status, body = httpc.get("www.example.com", "/api/users")

-- POST请求
local status, body = httpc.post("www.example.com", "/api/users",
    {["content-type"] = "application/json"},
    json.encode({name = "Alice", age = 25}))

-- 带超时的请求
local status, body = httpc.request("GET", "www.example.com", "/api/data",
    {}, "",  -- header和body
    {timeout = 5000})  -- 5秒超时

-- HTTPS请求
local status, body = httpc.request("GET", "www.example.com", "/api/secure",
    {}, "", {protocol = "https"})
```

---

## 协议处理框架

### 协议栈设计

```
┌─────────────────────────────────────┐
│       Application Protocol          │
│   (Game Protocol, Business Logic)   │
└──────────────┬──────────────────────┘
               │
┌──────────────┴──────────────────────┐
│       Serialization Layer           │
│  (Protobuf, JSON, MessagePack)      │
└──────────────┬──────────────────────┘
               │
┌──────────────┴──────────────────────┐
│        Framing Layer                │
│   (Length-Prefix, Delimiter)        │
└──────────────┬──────────────────────┘
               │
┌──────────────┴──────────────────────┐
│       Transport Layer               │
│    (TCP, WebSocket, HTTP)           │
└─────────────────────────────────────┘
```

### 协议处理器

```lua
-- 协议处理器基类
local ProtocolHandler = {}
ProtocolHandler.__index = ProtocolHandler

function ProtocolHandler:new()
    local o = {
        encoders = {},
        decoders = {},
        handlers = {},
    }
    return setmetatable(o, self)
end

-- 注册编码器
function ProtocolHandler:register_encoder(msg_type, encoder)
    self.encoders[msg_type] = encoder
end

-- 注册解码器
function ProtocolHandler:register_decoder(msg_id, decoder)
    self.decoders[msg_id] = decoder
end

-- 注册处理器
function ProtocolHandler:register_handler(msg_type, handler)
    self.handlers[msg_type] = handler
end

-- 编码消息
function ProtocolHandler:encode(msg_type, msg)
    local encoder = self.encoders[msg_type]
    if not encoder then
        error("Unknown message type: " .. msg_type)
    end
    
    local data = encoder(msg)
    local msg_id = MSG_ID[msg_type]
    
    -- 添加消息头
    return string.pack(">HH", #data + 2, msg_id) .. data
end

-- 解码消息
function ProtocolHandler:decode(data)
    local msg_id, body = string.unpack(">Hs2", data)
    
    local decoder = self.decoders[msg_id]
    if not decoder then
        error("Unknown message id: " .. msg_id)
    end
    
    return decoder(body)
end

-- 处理消息
function ProtocolHandler:handle(fd, data)
    local msg = self:decode(data)
    local handler = self.handlers[msg.__type]
    
    if handler then
        return handler(fd, msg)
    else
        skynet.error("No handler for:", msg.__type)
    end
end
```

### Protobuf协议

```lua
local protobuf = require "protobuf"
local proto_handler = ProtocolHandler:new()

-- 加载proto文件
protobuf.register_file("protocol.pb")

-- 注册Protobuf编解码器
proto_handler:register_encoder("LoginReq", function(msg)
    return protobuf.encode("game.LoginReq", msg)
end)

proto_handler:register_decoder(1001, function(data)
    local msg = protobuf.decode("game.LoginReq", data)
    msg.__type = "LoginReq"
    return msg
end)

-- 注册处理器
proto_handler:register_handler("LoginReq", function(fd, msg)
    -- 处理登录请求
    local user = db.get_user(msg.username)
    if user and user.password == msg.password then
        return proto_handler:encode("LoginResp", {
            code = 0,
            message = "Success",
            token = generate_token(user.id)
        })
    else
        return proto_handler:encode("LoginResp", {
            code = 1,
            message = "Invalid credentials"
        })
    end
end)
```

### JSON-RPC协议

```lua
local json = require "json"

local jsonrpc_handler = {}

-- 处理JSON-RPC请求
function jsonrpc_handler.handle(request)
    local req = json.decode(request)
    
    -- 验证请求格式
    if not req.jsonrpc or req.jsonrpc ~= "2.0" then
        return json.encode({
            jsonrpc = "2.0",
            error = {
                code = -32600,
                message = "Invalid Request"
            },
            id = req.id
        })
    end
    
    -- 查找方法
    local method = RPC_METHODS[req.method]
    if not method then
        return json.encode({
            jsonrpc = "2.0",
            error = {
                code = -32601,
                message = "Method not found"
            },
            id = req.id
        })
    end
    
    -- 执行方法
    local ok, result = pcall(method, req.params)
    
    if ok then
        return json.encode({
            jsonrpc = "2.0",
            result = result,
            id = req.id
        })
    else
        return json.encode({
            jsonrpc = "2.0",
            error = {
                code = -32603,
                message = result
            },
            id = req.id
        })
    end
end

-- RPC方法定义
RPC_METHODS = {
    ["user.login"] = function(params)
        return user_service.login(params.username, params.password)
    end,
    
    ["user.info"] = function(params)
        return user_service.get_info(params.user_id)
    end,
    
    ["game.enter"] = function(params)
        return game_service.enter(params.room_id)
    end,
}
```

---

## 实战案例

### 案例1: 游戏网关服务

#### 需求

构建一个支持多协议的游戏网关：

- TCP协议：游戏客户端
- WebSocket：网页客户端
- HTTP：管理接口
- 统一的消息路由

#### 架构设计

```
┌────────────────────────────────────────────────┐
│              Game Gateway                       │
└────────────────────────────────────────────────┘

     TCP:8001        WS:8002         HTTP:8003
         │              │                │
         ▼              ▼                ▼
    ┌─────────┐   ┌──────────┐   ┌────────────┐
    │TCP Gate │   │WS Service│   │HTTP Service│
    └────┬────┘   └────┬─────┘   └─────┬──────┘
         │             │                │
         └─────────────┼────────────────┘
                       │
                  ┌────▼────┐
                  │ Router   │
                  └────┬────┘
                       │
         ┌─────────────┼─────────────┐
         │             │             │
         ▼             ▼             ▼
    ┌────────┐   ┌────────┐   ┌────────┐
    │Login   │   │Game    │   │Chat    │
    │Service │   │Service │   │Service │
    └────────┘   └────────┘   └────────┘
```

#### 实现代码

```lua
-- gateway.lua
local skynet = require "skynet"

-- 协议类型
local PROTOCOL = {
    TCP = 1,
    WEBSOCKET = 2,
    HTTP = 3,
}

-- 连接管理
local connections = {}  -- fd -> { protocol, agent, ... }

-- 消息路由器
local router = {}

-- 注册路由
function router.register(msg_type, service)
    router[msg_type] = service
end

-- 路由消息
function router.route(fd, msg_type, msg)
    local service = router[msg_type]
    if not service then
        skynet.error("No route for:", msg_type)
        return
    end
    
    return skynet.call(service, "lua", "handle", fd, msg)
end

skynet.start(function()
    -- 启动TCP Gate
    skynet.newservice("tcp_gate", 8001)
    
    -- 启动WebSocket服务
    skynet.newservice("ws_service", 8002)
    
    -- 启动HTTP服务
    skynet.newservice("http_service", 8003)
    
    -- 启动业务服务
    local login = skynet.newservice("login_service")
    local game = skynet.newservice("game_service")
    local chat = skynet.newservice("chat_service")
    
    -- 注册路由
    router.register("login", login)
    router.register("game", game)
    router.register("chat", chat)
    
    -- 处理消息
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = CMD[cmd]
        if f then
            skynet.ret(skynet.pack(f(...)))
        end
    end)
end)
```

#### TCP Gate实现

```lua
-- tcp_gate.lua
local skynet = require "skynet"
local gateserver = require "snax.gateserver"
local netpack = require "skynet.netpack"
local proto = require "protocol"

local watchdog
local connections = {}

local handler = {}

function handler.open(source, conf)
    watchdog = conf.watchdog or source
    return conf.address, conf.port
end

function handler.connect(fd, addr)
    connections[fd] = {
        fd = fd,
        addr = addr,
        protocol = "tcp",
        buffer = "",
    }
    
    skynet.send(watchdog, "lua", "connect", fd, "tcp", addr)
end

function handler.message(fd, msg, sz)
    local conn = connections[fd]
    if not conn then
        return
    end
    
    -- 解包
    local data = netpack.tostring(msg, sz)
    conn.buffer = conn.buffer .. data
    
    -- 处理完整的包
    while #conn.buffer >= 4 do
        local len = string.unpack(">I4", conn.buffer)
        if #conn.buffer < 4 + len then
            break
        end
        
        local packet = conn.buffer:sub(5, 4 + len)
        conn.buffer = conn.buffer:sub(5 + len)
        
        -- 解析协议
        local msg = proto.decode(packet)
        
        -- 路由消息
        skynet.send(watchdog, "lua", "message", fd, msg)
    end
end

function handler.disconnect(fd)
    connections[fd] = nil
    skynet.send(watchdog, "lua", "disconnect", fd)
end

function handler.error(fd, msg)
    handler.disconnect(fd)
end

gateserver.start(handler)
```

### 案例2: 实时聊天系统

#### 需求

- 支持WebSocket和HTTP长轮询
- 消息广播和私聊
- 在线状态管理
- 历史消息存储

#### 实现

```lua
-- chat_service.lua
local skynet = require "skynet"
local websocket = require "http.websocket"

-- 在线用户
local online_users = {}  -- uid -> { fd, name, ... }

-- 聊天室
local rooms = {}  -- room_id -> { users = {}, messages = {} }

local CMD = {}

-- 用户上线
function CMD.online(uid, fd, name)
    online_users[uid] = {
        fd = fd,
        name = name,
        login_time = os.time(),
    }
    
    -- 广播上线通知
    broadcast({
        type = "user_online",
        uid = uid,
        name = name,
    })
end

-- 用户下线
function CMD.offline(uid)
    local user = online_users[uid]
    if user then
        online_users[uid] = nil
        
        -- 广播下线通知
        broadcast({
            type = "user_offline",
            uid = uid,
            name = user.name,
        })
    end
end

-- 发送消息
function CMD.send_message(uid, target, content)
    local user = online_users[uid]
    if not user then
        return {code = 1, msg = "User not online"}
    end
    
    local message = {
        from = uid,
        from_name = user.name,
        content = content,
        time = os.time(),
    }
    
    if target then
        -- 私聊
        local target_user = online_users[target]
        if target_user then
            send_to_user(target, {
                type = "private_message",
                message = message,
            })
            
            return {code = 0}
        else
            return {code = 2, msg = "Target not online"}
        end
    else
        -- 群聊
        broadcast({
            type = "public_message",
            message = message,
        })
        
        -- 保存历史消息
        save_message(message)
        
        return {code = 0}
    end
end

-- 加入聊天室
function CMD.join_room(uid, room_id)
    local room = rooms[room_id]
    if not room then
        room = {
            users = {},
            messages = {},
        }
        rooms[room_id] = room
    end
    
    room.users[uid] = true
    
    -- 发送历史消息
    local user = online_users[uid]
    if user then
        for _, msg in ipairs(room.messages) do
            send_to_user(uid, {
                type = "history_message",
                message = msg,
            })
        end
    end
    
    return {code = 0, room_id = room_id}
end

-- 发送给用户
function send_to_user(uid, msg)
    local user = online_users[uid]
    if user then
        websocket.write(user.fd, json.encode(msg))
    end
end

-- 广播消息
function broadcast(msg)
    local data = json.encode(msg)
    for uid, user in pairs(online_users) do
        websocket.write(user.fd, data)
    end
end

-- 保存消息
function save_message(msg)
    -- 保存到数据库或缓存
    table.insert(message_history, msg)
    
    -- 限制历史消息数量
    if #message_history > 1000 then
        table.remove(message_history, 1)
    end
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

#### WebSocket处理

```lua
-- ws_chat_handler.lua
local handle = {}

function handle.connect(id)
    skynet.error("Chat client connected:", id)
end

function handle.handshake(id, header, url)
    -- 从URL或Cookie获取认证信息
    local token = header["authorization"]
    if not verify_token(token) then
        return 401  -- Unauthorized
    end
end

function handle.message(id, msg, msg_type)
    local data = json.decode(msg)
    
    -- 处理不同类型的消息
    if data.type == "login" then
        -- 用户登录
        local uid = data.uid
        local name = data.name
        
        skynet.send(chat_service, "lua", "online", uid, id, name)
        
        websocket.write(id, json.encode({
            type = "login_success",
            uid = uid,
        }))
        
    elseif data.type == "send_message" then
        -- 发送消息
        local result = skynet.call(chat_service, "lua", 
                                  "send_message", 
                                  data.uid, 
                                  data.target, 
                                  data.content)
        
        websocket.write(id, json.encode(result))
        
    elseif data.type == "join_room" then
        -- 加入聊天室
        local result = skynet.call(chat_service, "lua", 
                                  "join_room", 
                                  data.uid, 
                                  data.room_id)
        
        websocket.write(id, json.encode(result))
    end
end

function handle.close(id, code, reason)
    -- 用户下线
    skynet.send(chat_service, "lua", "offline", get_uid_by_fd(id))
end
```

---

## 本章小结

本章详细介绍了Skynet的高层网络服务实现，包括：

### Part 1 - Gate服务核心
1. **Gate架构**: 分层设计，高性能网关
2. **C层实现**: 底层Socket管理和消息路由
3. **Lua封装**: 灵活的上层接口
4. **GateServer框架**: 通用网关框架
5. **消息转发**: Zero-Copy高效转发
6. **连接管理**: 完整的生命周期管理

### Part 2 - 网络协议与应用
1. **登录服务器**: 安全的DH密钥交换协议
2. **WebSocket**: 全双工实时通信
3. **HTTP服务**: RESTful API支持
4. **协议框架**: 可扩展的协议处理
5. **实战案例**: 游戏网关和聊天系统

### 关键要点

1. **分层架构**: 从底层Socket到高层协议的完整栈
2. **性能优化**: Zero-Copy、连接池、负载均衡
3. **协议支持**: TCP、WebSocket、HTTP等多协议
4. **安全性**: DH密钥交换、HMAC认证
5. **可扩展性**: 灵活的路由和协议框架

### 最佳实践

1. **连接管理**
   - 使用连接池减少创建开销
   - 实现心跳检测防止僵尸连接
   - 设置合理的超时和限制

2. **协议设计**
   - 选择合适的序列化方式
   - 添加版本号支持协议演进
   - 考虑消息压缩和加密

3. **性能优化**
   - 使用redirect避免消息拷贝
   - 批量处理减少系统调用
   - 合理的缓冲区大小

4. **错误处理**
   - 完善的错误码定义
   - 优雅的降级策略
   - 详细的日志记录

5. **安全防护**
   - 认证和授权机制
   - 防止DDoS攻击
   - 数据加密传输

网络服务是Skynet应用的核心组件，掌握这些服务的原理和使用方法，对构建高性能的网络应用至关重要。

---

**文档版本**: 1.0  
**最后更新**: 2024-01-XX  
**适用版本**: Skynet 1.x