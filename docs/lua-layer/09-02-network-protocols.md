# Skynet Lua框架层 - 网络通信高级协议详解

## 目录

- [1. HTTP协议支持](#1-http协议支持)
  - [1.1 HTTP客户端](#11-http客户端)
  - [1.2 HTTP服务器](#12-http服务器)
  - [1.3 HTTPS支持](#13-https支持)
- [2. 登录服务器架构](#2-登录服务器架构)
  - [2.1 认证协议](#21-认证协议)
  - [2.2 加密机制](#22-加密机制)
  - [2.3 会话管理](#23-会话管理)
- [3. 消息服务器框架](#3-消息服务器框架)
  - [3.1 协议设计](#31-协议设计)
  - [3.2 用户管理](#32-用户管理)
  - [3.3 消息缓存](#33-消息缓存)
- [4. WebSocket支持](#4-websocket支持)
  - [4.1 协议升级](#41-协议升级)
  - [4.2 帧处理](#42-帧处理)
- [5. 自定义协议](#5-自定义协议)
  - [5.1 Sproto协议](#51-sproto协议)
  - [5.2 协议扩展](#52-协议扩展)
- [6. 网络安全](#6-网络安全)
  - [6.1 加密通信](#61-加密通信)
  - [6.2 防护措施](#62-防护措施)
- [7. 实战案例](#7-实战案例)
  - [7.1 游戏服务器架构](#71-游戏服务器架构)
  - [7.2 性能优化](#72-性能优化)

## 1. HTTP协议支持

### 1.1 HTTP客户端

#### 1.1.1 基本使用

```lua
-- lualib/http/httpc.lua
local httpc = {}

function httpc.request(method, hostname, url, recvheader, header, content)
    local fd, interface, host = connect(hostname, httpc.timeout)
    local ok, statuscode, body, header = pcall(internal.request, 
        interface, method, host, url, recvheader, header, content)
    
    if ok then
        ok, body = pcall(internal.response, interface, statuscode, body, header)
    end
    
    close_interface(interface, fd)
    
    if ok then
        return statuscode, body
    else
        error(body or statuscode)
    end
end
```

**使用示例：**
```lua
local httpc = require "http.httpc"
local skynet = require "skynet"

-- GET请求
local status, body = httpc.request("GET", "www.example.com", "/api/data")

-- POST请求
local header = {
    ["content-type"] = "application/json",
}
local status, body = httpc.request("POST", "www.example.com", "/api/submit",
    nil, header, '{"key":"value"}')

-- 带超时的请求
httpc.timeout = 500  -- 5秒超时
local status, body = httpc.request("GET", "www.example.com", "/api/data")
```

#### 1.1.2 连接管理

```lua
local function connect(host, timeout)
    local protocol
    protocol, host = check_protocol(host)
    
    local hostaddr, port = host:match"([^:]+):?(%d*)$"
    if port == "" then
        port = protocol == "http" and 80 or protocol == "https" and 443
    else
        port = tonumber(port)
    end
    
    -- DNS解析
    local hostname
    if not hostaddr:match(".*%d+$") then
        hostname = hostaddr
        if async_dns then
            hostaddr = dns.resolve(hostname)
        end
    end
    
    local fd = socket.connect(hostaddr, port, timeout)
    if not fd then
        error(string.format("%s connect error host:%s, port:%s, timeout:%s", 
            protocol, hostaddr, port, timeout))
    end
    
    local interface = gen_interface(protocol, fd, hostname)
    
    -- 设置超时
    if timeout then
        skynet.timeout(timeout, function()
            if not interface.finish then
                socket.shutdown(fd)
            end
        end)
    end
    
    if interface.init then
        interface.init(host)
    end
    
    return fd, interface, host
end
```

#### 1.1.3 流式响应

```lua
function httpc.request_stream(method, hostname, url, recvheader, header, content)
    local fd, interface, host = connect(hostname, httpc.timeout)
    local ok, statuscode, body, header = pcall(internal.request,
        interface, method, host, url, recvheader, header, content)

    interface.finish = true  -- 不在超时时关闭

    local function close_fd()
        close_interface(interface, fd)
    end

    if not ok then
        close_fd()
        error(statuscode)
    end

    -- 注意：response_stream 暂无内置超时；调用方需负责在适当时机 stream:close()
    local stream = internal.response_stream(interface, statuscode, body, header)
    stream._onclose = close_fd
    return stream
end

-- 使用流式响应（推荐迭代器用法）
local stream = httpc.request_stream("GET", "www.example.com", "/api/stream")
for chunk in stream do
    if not chunk then break end
    process_chunk(chunk)
end
stream:close()
```

### 1.2 HTTP服务器

#### 1.2.1 基本架构

```lua
-- lualib/http/httpd.lua
local httpd = {}

function httpd.read_request(readbytes, bodylimit)
    -- 返回值次序为 (code, url, method, header, body)
    local ok, code, url, method, header, body = pcall(function()
        local tmpline = {}
        local body = internal.recvheader(readbytes, tmpline, "")
        if not body then
            return 413
        end
        local request = assert(tmpline[1])
        local method, url, httpver = request:match "^(%a+)%s+(.-)%s+HTTP/([%d%.]+)$"
        assert(method and url and httpver)
        httpver = assert(tonumber(httpver))
        if httpver < 1.0 or httpver > 1.1 then
            return 505
        end
        local header = internal.parseheader(tmpline, 2, {})
        if not header then
            return 400
        end
        local length = header["content-length"]
        if length then length = tonumber(length) end
        local mode = header["transfer-encoding"]
        if mode then
            if mode ~= "identity" and mode ~= "chunked" then
                return 501
            end
        end
        if mode == "chunked" then
            body, header = internal.recvchunkedbody(readbytes, bodylimit, header, body)
            if not body then return 413 end
        else
            if length then
                if bodylimit and length > bodylimit then return 413 end
                if #body >= length then
                    body = body:sub(1, length)
                else
                    local padding = readbytes(length - #body)
                    body = body .. padding
                end
            end
        end
        return 200, url, method, header, body
    end)
    if ok then
        return code, url, method, header, body
    else
        return nil, code
    end
end
```

#### 1.2.2 响应生成

```lua
function httpd.write_response(writefunc, statuscode, body, header)
    -- 返回 ok, err（pcall 包装）
    return pcall(function()
        local statusline = string.format("HTTP/1.1 %03d %s\r\n",
            statuscode, http_status_msg[statuscode] or "")
        writefunc(statusline)
        if header then
            for k, v in pairs(header) do
                if type(v) == "table" then
                    for _, vv in ipairs(v) do
                        writefunc(string.format("%s: %s\r\n", k, vv))
                    end
                else
                    writefunc(string.format("%s: %s\r\n", k, v))
                end
            end
        end
        local t = type(body)
        if t == "string" then
            writefunc(string.format("content-length: %d\r\n\r\n", #body))
            writefunc(body)
        elseif t == "function" then
            writefunc("transfer-encoding: chunked\r\n")
            while true do
                local chunk = body()
                if chunk then
                    if chunk ~= "" then
                        writefunc(string.format("\r\n%x\r\n", #chunk))
                        writefunc(chunk)
                    end
                else
                    writefunc("\r\n0\r\n\r\n")
                    break
                end
            end
        else
            writefunc("\r\n")
        end
    end)
end
```

### 1.3 HTTPS支持

```lua
local function gen_interface(protocol, fd, hostname)
    if protocol == "http" then
        return {
            init = nil,
            close = nil,
            read = socket.readfunc(fd),
            write = socket.writefunc(fd),
            readall = function()
                return socket.readall(fd)
            end,
        }
    elseif protocol == "https" then
        local tls = require "http.tlshelper"
        SSLCTX_CLIENT = SSLCTX_CLIENT or tls.newctx()
        local tls_ctx = tls.newtls("client", SSLCTX_CLIENT, hostname)
        
        return {
            init = tls.init_requestfunc(fd, tls_ctx),
            close = tls.closefunc(tls_ctx),
            read = tls.readfunc(fd, tls_ctx),
            write = tls.writefunc(fd, tls_ctx),
            readall = tls.readallfunc(fd, tls_ctx),
        }
    else
        error(string.format("Invalid protocol: %s", protocol))
    end
end
```

## 2. 登录服务器架构

### 2.1 认证协议

登录服务器使用基于挑战-响应的认证协议：

```lua
-- lualib/snax/loginserver.lua
--[[
Protocol:
    1. Server->Client : base64(8bytes random challenge)
    2. Client->Server : base64(8bytes handshake client key)
    3. Server: Gen a 8bytes handshake server key
    4. Server->Client : base64(DH-Exchange(server key))
    5. Server/Client secret := DH-Secret(client key/server key)
    6. Client->Server : base64(HMAC(challenge, secret))
    7. Client->Server : DES(secret, base64(token))
    8. Server : call auth_handler(token) -> server, uid
    9. Server : call login_handler(server, uid, secret) -> subid
    10. Server->Client : 200 base64(subid)
]]
```

### 2.2 加密机制

#### 2.2.1 认证流程实现

```lua
local function auth(fd, addr)
    -- 设置socket缓冲限制，防止攻击
    socket.limit(fd, 8192)
    
    -- 1. 发送随机挑战
    local challenge = crypt.randomkey()
    write("auth", fd, crypt.base64encode(challenge).."\n")
    
    -- 2. 接收客户端密钥
    local handshake = assert_socket("auth", socket.readline(fd), fd)
    local clientkey = crypt.base64decode(handshake)
    if #clientkey ~= 8 then
        error "Invalid client key"
    end
    
    -- 3. 生成服务器密钥并交换
    local serverkey = crypt.randomkey()
    write("auth", fd, crypt.base64encode(crypt.dhexchange(serverkey)).."\n")
    
    -- 4. 计算共享密钥
    local secret = crypt.dhsecret(clientkey, serverkey)
    
    -- 5. 验证HMAC
    local response = assert_socket("auth", socket.readline(fd), fd)
    local hmac = crypt.hmac64(challenge, secret)
    
    if hmac ~= crypt.base64decode(response) then
        error "challenge failed"
    end
    
    -- 6. 解密token
    local etoken = assert_socket("auth", socket.readline(fd), fd)
    local token = crypt.desdecode(secret, crypt.base64decode(etoken))
    
    -- 7. 调用认证处理器
    local ok, server, uid = pcall(auth_handler, token)
    
    return ok, server, uid, secret
end
```

#### 2.2.2 DH密钥交换

```lua
-- Diffie-Hellman密钥交换
-- 客户端生成私钥a，计算公钥A = g^a mod p
local clientkey = crypt.randomkey()
local client_public = crypt.dhexchange(clientkey)

-- 服务器生成私钥b，计算公钥B = g^b mod p  
local serverkey = crypt.randomkey()
local server_public = crypt.dhexchange(serverkey)

-- 双方计算共享密钥
-- 客户端: secret = B^a mod p
-- 服务器: secret = A^b mod p
local secret = crypt.dhsecret(clientkey, server_public)
```

### 2.3 会话管理

```lua
local user_login = {}

local function accept(conf, s, fd, addr)
    -- 调用slave认证
    local ok, server, uid, secret = skynet.call(s, "lua", fd, addr)
    
    if not ok then
        if ok ~= nil then
            write("response 401", fd, "401 Unauthorized\n")
        end
        error(server)
    end
    
    -- 检查多重登录
    if not conf.multilogin then
        if user_login[uid] then
            write("response 406", fd, "406 Not Acceptable\n")
            error(string.format("User %s is already login", uid))
        end
        user_login[uid] = true
    end
    
    -- 调用登录处理器
    local ok, err = pcall(conf.login_handler, server, uid, secret)
    user_login[uid] = nil
    
    if ok then
        err = err or ""
        write("response 200", fd, "200 "..crypt.base64encode(err).."\n")
    else
        write("response 403", fd, "403 Forbidden\n")
        error(err)
    end
end
```

## 3. 消息服务器框架

### 3.1 协议设计

消息服务器使用握手认证+请求响应模式：

```lua
-- lualib/snax/msgserver.lua
--[[
Shakehands Protocol:
    Client -> Server:
    base64(uid)@base64(server)#base64(subid):index:base64(hmac)
    
    Server -> Client:
    XXX ErrorCode
        404 User Not Found
        403 Index Expired
        401 Unauthorized
        400 Bad Request
        200 OK

Req-Resp Protocol:
    Client -> Server: Request
        word size (Not include self)
        string content (size-4)
        dword session
    
    Server -> Client: Response
        word size (Not include self)
        string content (size-5)
        byte ok (1 is ok, 0 is error)
        dword session
]]
```

### 3.2 用户管理

```lua
local user_online = {}
local handshake = {}
local connection = {}

function server.userid(username)
    -- base64(uid)@base64(server)#base64(subid)
    local uid, servername, subid = username:match "([^@]*)@([^#]*)#(.*)"
    return b64decode(uid), b64decode(subid), b64decode(servername)
end

function server.username(uid, subid, servername)
    return string.format("%s@%s#%s", 
        b64encode(uid), b64encode(servername), b64encode(tostring(subid)))
end

function server.login(username, secret)
    assert(user_online[username] == nil)
    user_online[username] = {
        secret = secret,
        version = 0,
        index = 0,
        username = username,
        response = {},  -- 响应缓存
    }
end

function server.logout(username)
    local u = user_online[username]
    user_online[username] = nil
    if u.fd then
        if connection[u.fd] then
            gateserver.closeclient(u.fd)
            connection[u.fd] = nil
        end
    end
end
```

### 3.3 消息缓存

```lua
-- 伪代码：与实现一致的结构与流程
local function do_request(fd, message)
    local u = assert(connection[fd], "invalid fd")
    local session = string.unpack(">I4", message, -4)
    message = message:sub(1, -5)

    local p = u.response[session]
    if p and p[3] == u.version then
        -- 同一版本下复用：若已生成响应，直接重投递；否则为冲突
        if not p[2] then error("Conflict session") end
        return socketdriver.send(fd, p[2])
    end

    if not p then p = { fd }; u.response[session] = p end

    local ok, result = pcall(conf.request_handler, u.username, message)
    result = (ok and (result or "") or "") .. string.pack(">BI4", ok and 1 or 0, session)

    p[2] = string.pack(">s2", result)
    p[3] = u.version
    p[4] = u.index
    u.index = u.index + 1

    local rfd = p[1]
    if connection[rfd] then
        socketdriver.send(rfd, p[2])
    end
    p[1] = nil
    retire_response(u)
end
```

## 4. WebSocket支持

### 4.1 协议升级

```lua
-- WebSocket 服务端握手（简化示例）：建议同时校验 Upgrade/Connection/Version
local function accept_handshake(fd, header)
    local key = header["sec-websocket-key"]
    if not key then return false end
    if not header["upgrade"] or header["upgrade"]:lower() ~= "websocket" then return false end
    if not header["connection"] or not header["connection"]:lower():find("upgrade", 1, true) then return false end
    if header["sec-websocket-version"] ~= "13" then return false end

    local accept = crypt.base64encode(crypt.sha1(key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
    local response = "HTTP/1.1 101 Switching Protocols\r\n"
        .. "Upgrade: websocket\r\n"
        .. "Connection: Upgrade\r\n"
        .. string.format("Sec-WebSocket-Accept: %s\r\n", accept)
        .. "\r\n"
    socket.write(fd, response)
    return true
end
```

### 4.2 帧处理

```lua
-- WebSocket帧结构
local function parse_frame(data)
    if #data < 2 then
        return nil
    end
    
    local byte1, byte2 = string.byte(data, 1, 2)
    local fin = (byte1 & 0x80) ~= 0
    local opcode = byte1 & 0x0F
    local mask = (byte2 & 0x80) ~= 0
    local payload_len = byte2 & 0x7F
    
    local pos = 3
    if payload_len == 126 then
        if #data < 4 then
            return nil
        end
        payload_len = string.unpack(">I2", data, 3)
        pos = 5
    elseif payload_len == 127 then
        if #data < 10 then
            return nil
        end
        payload_len = string.unpack(">I8", data, 3)
        pos = 11
    end
    
    local mask_key
    if mask then
        if #data < pos + 3 then
            return nil
        end
        mask_key = data:sub(pos, pos + 3)
        pos = pos + 4
    end
    
    if #data < pos + payload_len - 1 then
        return nil
    end
    
    local payload = data:sub(pos, pos + payload_len - 1)
    
    -- 解码payload
    if mask then
        local decoded = {}
        for i = 1, #payload do
            local j = (i - 1) % 4 + 1
            decoded[i] = string.char(string.byte(payload, i) ~ 
                string.byte(mask_key, j))
        end
        payload = table.concat(decoded)
    end
    
    return {
        fin = fin,
        opcode = opcode,
        mask = mask,
        payload = payload,
    }, pos + payload_len
end
```

## 5. 自定义协议

### 5.1 Sproto协议

Sproto是Skynet的高效二进制协议：

```lua
-- 定义协议
local proto = {}

proto.c2s = sproto.parse [[
.package {
    type 0 : integer
    session 1 : integer
}

handshake 1 {
    request {
        client_key 0 : string
    }
    response {
        server_key 0 : string
        challenge 1 : string
    }
}

login 2 {
    request {
        token 0 : string
        server 1 : string
    }
    response {
        result 0 : boolean
        uid 1 : integer
    }
}
]]

proto.s2c = sproto.parse [[
.package {
    type 0 : integer
    session 1 : integer
}

heartbeat 1 {}

push 2 {
    request {
        data 0 : string
    }
}
]]
```

### 5.2 协议扩展

```lua
-- 注册自定义协议
skynet.register_protocol {
    name = "myproto",
    id = 20,  -- 自定义协议ID
    pack = function(...)
        -- 打包函数
        local msg = table.pack(...)
        return msgpack.pack(msg)
    end,
    unpack = function(msg, sz)
        -- 解包函数
        return msgpack.unpack(msg, sz)
    end,
    dispatch = function(session, source, ...)
        -- 消息分发
        handle_myproto(session, source, ...)
    end,
}

-- 使用自定义协议
skynet.send(target, "myproto", "hello", {data = 123})
```

## 6. 网络安全

### 6.1 加密通信

#### 6.1.1 AES加密

```lua
local aes = require "skynet.crypt"

-- AES加密
local key = crypt.randomkey()  -- 16字节密钥
local plaintext = "Hello World"
local ciphertext = crypt.aesencode(key, plaintext)
local decrypted = crypt.aesdecode(key, ciphertext)

-- 带IV的AES-CBC
local iv = crypt.randomkey()  -- 16字节IV
local encrypted = crypt.aesencode_cbc(key, iv, plaintext)
local decrypted = crypt.aesdecode_cbc(key, iv, encrypted)
```

#### 6.1.2 消息认证

```lua
-- HMAC认证
local secret = "shared_secret"
local message = "important_message"
local hmac = crypt.hmac64(secret, message)

-- 验证
local function verify_message(msg, hmac_received)
    local hmac_calculated = crypt.hmac64(secret, msg)
    return hmac_calculated == hmac_received
end

-- 数字签名
local private_key, public_key = crypt.dhkeypair()
local signature = crypt.sign(private_key, message)
local verified = crypt.verify(public_key, message, signature)
```

### 6.2 防护措施

#### 6.2.1 流量限制

```lua
-- 连接频率限制
local connection_limit = {}
local LIMIT_INTERVAL = 1  -- 1秒
local LIMIT_COUNT = 10    -- 最多10个连接

local function check_connection_limit(addr)
    local now = skynet.time()
    local record = connection_limit[addr] or {
        count = 0,
        time = now
    }
    
    if now - record.time > LIMIT_INTERVAL then
        record.count = 1
        record.time = now
    else
        record.count = record.count + 1
        if record.count > LIMIT_COUNT then
            return false  -- 超过限制
        end
    end
    
    connection_limit[addr] = record
    return true
end
```

#### 6.2.2 缓冲区保护

```lua
-- 设置socket缓冲区限制
socket.limit(fd, 8192)  -- 8KB限制

-- 自定义缓冲区溢出处理
local function safe_receive(fd, limit)
    local buffer = {}
    local total = 0
    
    while true do
        local data = socket.read(fd, 1024)
        if not data then
            break
        end
        
        total = total + #data
        if total > limit then
            error("Buffer overflow")
        end
        
        table.insert(buffer, data)
    end
    
    return table.concat(buffer)
end
```

## 7. 实战案例

### 7.1 游戏服务器架构

```lua
-- 典型游戏服务器架构
--[[
    Client
      ↓
    Gate (连接管理)
      ↓
    Login Server (认证)
      ↓
    Agent (业务逻辑)
      ↓
    Game Services (游戏逻辑)
]]

-- Gate服务
local gate = skynet.newservice("gate")
skynet.call(gate, "lua", "open", {
    port = 8888,
    maxclient = 1024,
    nodelay = true,
})

-- 登录服务器
local loginserver = skynet.newservice("loginserver")
skynet.call(loginserver, "lua", "start", {
    port = 8001,
    multilogin = false,
    auth_handler = function(token)
        -- 验证token
        return verify_token(token)
    end,
    login_handler = function(server, uid, secret)
        -- 创建agent
        local agent = skynet.newservice("agent")
        skynet.call(agent, "lua", "init", uid, secret)
        return agent
    end,
})

-- Agent服务
skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = CMD[cmd]
        if f then
            skynet.ret(skynet.pack(f(...)))
        else
            error(string.format("Unknown command %s", tostring(cmd)))
        end
    end)
end)
```

### 7.2 性能优化

#### 7.2.1 连接池

```lua
local connection_pool = {}
local pool_size = 100

local function get_connection(addr, port)
    local key = addr .. ":" .. port
    local pool = connection_pool[key]
    
    if pool and #pool > 0 then
        local fd = table.remove(pool)
        -- 检查连接是否有效
        if not socket.invalid(fd) then
            return fd
        end
    end
    
    return socket.open(addr, port)
end

local function release_connection(addr, port, fd)
    local key = addr .. ":" .. port
    local pool = connection_pool[key] or {}
    
    if #pool < pool_size then
        table.insert(pool, fd)
        connection_pool[key] = pool
    else
        socket.close(fd)
    end
end
```

#### 7.2.2 消息批处理

```lua
-- 批量发送消息
local message_queue = {}
local BATCH_SIZE = 100
local BATCH_INTERVAL = 10  -- 100ms

local function batch_send()
    while true do
        skynet.sleep(BATCH_INTERVAL)
        
        if #message_queue > 0 then
            local batch = {}
            local count = math.min(#message_queue, BATCH_SIZE)
            
            for i = 1, count do
                table.insert(batch, table.remove(message_queue, 1))
            end
            
            -- 批量发送
            send_batch(batch)
        end
    end
end

local function queue_message(msg)
    table.insert(message_queue, msg)
    
    -- 队列满时立即发送
    if #message_queue >= BATCH_SIZE then
        skynet.wakeup(batch_send_co)
    end
end
```

#### 7.2.3 协议压缩

```lua
-- 使用zlib压缩
local zlib = require "zlib"

local function compress_message(data)
    if #data > 1024 then  -- 只压缩大消息
        local compressed = zlib.compress(data)
        if #compressed < #data * 0.9 then  -- 压缩率超过10%才使用
            return compressed, true
        end
    end
    return data, false
end

local function decompress_message(data, compressed)
    if compressed then
        return zlib.decompress(data)
    end
    return data
end
```

## 总结

Skynet的网络通信高级协议层提供了：

1. **完整的HTTP/HTTPS支持**：客户端和服务器实现
2. **安全的登录认证**：基于DH密钥交换和HMAC认证
3. **高效的消息服务**：支持消息缓存和重发机制
4. **WebSocket协议**：支持长连接和实时通信
5. **灵活的协议扩展**：自定义协议和Sproto支持
6. **全面的安全保护**：加密、认证、流量控制

这些特性使Skynet成为构建高性能网络服务的理想选择，特别适合游戏服务器、实时通信等场景。通过合理使用这些组件，可以快速构建安全、高效、可扩展的网络服务。
