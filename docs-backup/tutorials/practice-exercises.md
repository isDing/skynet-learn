# Skynet 框架实践练习手册

## 前言
本手册为 Skynet 学习者提供渐进式的实践练习，每个练习都包含明确的目标、提示和参考答案。建议按顺序完成练习，每个练习预计需要 1-3 小时。

---

## 第一部分：基础服务开发（初级）

### 练习 1：Hello World 服务

#### 目标
创建第一个 Skynet 服务，理解服务生命周期。

#### 要求
1. 创建一个服务，启动时打印 "Hello Skynet!"
2. 每秒打印一次当前时间
3. 运行 10 秒后自动退出

#### 提示
- 使用 `skynet.start()` 初始化服务
- 使用 `skynet.sleep()` 实现延时
- 使用 `os.date()` 获取时间

#### 参考答案
```lua
-- hello_world.lua
local skynet = require "skynet"

skynet.start(function()
    skynet.error("Hello Skynet!")
    
    for i = 1, 10 do
        skynet.sleep(100)  -- 睡眠 1 秒 (100 * 10ms)
        skynet.error("Current time: " .. os.date("%Y-%m-%d %H:%M:%S"))
    end
    
    skynet.error("Service exiting...")
    skynet.exit()
end)
```

---

### 练习 2：计数器服务

#### 目标
实现一个可以响应请求的计数器服务。

#### 要求
1. 维护一个计数器，初始值为 0
2. 支持 `add`、`sub`、`get`、`reset` 四种操作
3. 每次操作后返回当前值

#### 提示
- 使用 `skynet.dispatch()` 注册消息处理函数
- 使用 `skynet.ret()` 返回结果
- 使用 `skynet.pack()` 打包返回值

#### 参考答案
```lua
-- counter.lua
local skynet = require "skynet"

local counter = 0

local CMD = {}

function CMD.add(n)
    counter = counter + (n or 1)
    return counter
end

function CMD.sub(n)
    counter = counter - (n or 1)
    return counter
end

function CMD.get()
    return counter
end

function CMD.reset()
    counter = 0
    return counter
end

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

#### 测试代码
```lua
-- test_counter.lua
local skynet = require "skynet"

skynet.start(function()
    local counter = skynet.newservice("counter")
    
    skynet.error("Add 5: " .. skynet.call(counter, "lua", "add", 5))
    skynet.error("Sub 2: " .. skynet.call(counter, "lua", "sub", 2))
    skynet.error("Get: " .. skynet.call(counter, "lua", "get"))
    skynet.error("Reset: " .. skynet.call(counter, "lua", "reset"))
    
    skynet.exit()
end)
```

---

### 练习 3：键值存储服务

#### 目标
实现一个简单的内存键值存储服务。

#### 要求
1. 支持 `set(key, value)` - 设置键值对
2. 支持 `get(key)` - 获取值
3. 支持 `delete(key)` - 删除键
4. 支持 `exists(key)` - 检查键是否存在
5. 支持 `list()` - 列出所有键

#### 参考答案
```lua
-- kvstore.lua
local skynet = require "skynet"

local store = {}

local CMD = {}

function CMD.set(key, value)
    if not key then
        return false, "key required"
    end
    store[key] = value
    return true
end

function CMD.get(key)
    return store[key]
end

function CMD.delete(key)
    if store[key] then
        store[key] = nil
        return true
    end
    return false
end

function CMD.exists(key)
    return store[key] ~= nil
end

function CMD.list()
    local keys = {}
    for k, _ in pairs(store) do
        table.insert(keys, k)
    end
    return keys
end

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

---

## 第二部分：网络编程（中级）

### 练习 4：Echo 服务器

#### 目标
实现一个 TCP Echo 服务器。

#### 要求
1. 监听 8001 端口
2. 接收客户端消息并原样返回
3. 支持多个客户端同时连接
4. 客户端断开时清理资源

#### 提示
- 使用 `socket.listen()` 监听端口
- 使用 `socket.start()` 接收连接
- 使用 `socket.read()` 和 `socket.write()` 进行通信

#### 参考答案
```lua
-- echo_server.lua
local skynet = require "skynet"
local socket = require "skynet.socket"

local function handle_client(id, addr)
    skynet.error(string.format("New connection from %s, fd = %d", addr, id))
    socket.start(id)
    
    while true do
        local data = socket.read(id)
        if data then
            skynet.error(string.format("Recv from %d: %s", id, data))
            socket.write(id, data .. "\n")
        else
            skynet.error(string.format("Client %d disconnected", id))
            socket.close(id)
            break
        end
    end
end

skynet.start(function()
    local listen_fd = socket.listen("0.0.0.0", 8001)
    skynet.error("Echo server listening on :8001")
    
    socket.start(listen_fd, function(id, addr)
        skynet.fork(function()
            handle_client(id, addr)
        end)
    end)
end)
```

#### 测试脚本
```bash
# 使用 telnet 测试
telnet 127.0.0.1 8001
# 或使用 nc
echo "Hello Server" | nc 127.0.0.1 8001
```

---

### 练习 5：HTTP 服务器

#### 目标
实现一个简单的 HTTP 服务器。

#### 要求
1. 监听 8080 端口
2. 解析 HTTP 请求
3. 返回 JSON 格式响应
4. 支持 GET 和 POST 方法

#### 参考答案
```lua
-- http_server.lua
local skynet = require "skynet"
local socket = require "skynet.socket"

local function parse_http_request(request)
    local method, path, version = request:match("^(%w+)%s+(.-)%s+HTTP/(.-)%s*$")
    local headers = {}
    local body = ""
    
    local header_end = request:find("\r\n\r\n")
    if header_end then
        local header_text = request:sub(1, header_end - 1)
        body = request:sub(header_end + 4)
        
        for line in header_text:gmatch("[^\r\n]+") do
            local key, value = line:match("^(.-):%s*(.*)$")
            if key and value then
                headers[key:lower()] = value
            end
        end
    end
    
    return {
        method = method,
        path = path,
        version = version,
        headers = headers,
        body = body
    }
end

local function build_http_response(status, body)
    local response = string.format(
        "HTTP/1.1 %d OK\r\n" ..
        "Content-Type: application/json\r\n" ..
        "Content-Length: %d\r\n" ..
        "Connection: close\r\n" ..
        "\r\n" ..
        "%s",
        status, #body, body
    )
    return response
end

local function handle_http_request(id)
    socket.start(id)
    local request_text = socket.read(id)
    
    if request_text then
        local request = parse_http_request(request_text)
        skynet.error(string.format("HTTP %s %s", request.method, request.path))
        
        local response_body = string.format(
            '{"method":"%s","path":"%s","time":"%s"}',
            request.method, request.path, os.date("%Y-%m-%d %H:%M:%S")
        )
        
        local response = build_http_response(200, response_body)
        socket.write(id, response)
    end
    
    socket.close(id)
end

skynet.start(function()
    local listen_fd = socket.listen("0.0.0.0", 8080)
    skynet.error("HTTP server listening on :8080")
    
    socket.start(listen_fd, function(id, addr)
        skynet.fork(function()
            handle_http_request(id)
        end)
    end)
end)
```

---

### 练习 6：WebSocket 服务器

#### 目标
实现 WebSocket 握手和基本通信。

#### 要求
1. 处理 WebSocket 握手
2. 解析 WebSocket 帧
3. 发送 WebSocket 消息
4. 支持 ping/pong 心跳

#### 提示
- 需要实现 SHA1 和 Base64 编码
- 理解 WebSocket 协议格式

#### 参考答案（简化版）
```lua
-- websocket_server.lua
local skynet = require "skynet"
local socket = require "skynet.socket"
local crypt = require "skynet.crypt"

local GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

local function compute_accept(key)
    local accept = crypt.base64encode(crypt.sha1(key .. GUID))
    return accept
end

local function websocket_handshake(id)
    local request = socket.read(id)
    if not request then
        return false
    end
    
    local key = request:match("Sec%-WebSocket%-Key:%s*(.-)%s*\r\n")
    if not key then
        return false
    end
    
    local accept = compute_accept(key)
    local response = string.format(
        "HTTP/1.1 101 Switching Protocols\r\n" ..
        "Upgrade: websocket\r\n" ..
        "Connection: Upgrade\r\n" ..
        "Sec-WebSocket-Accept: %s\r\n" ..
        "\r\n",
        accept
    )
    
    socket.write(id, response)
    return true
end

local function decode_frame(data)
    if #data < 2 then
        return nil
    end
    
    local byte1 = string.byte(data, 1)
    local byte2 = string.byte(data, 2)
    
    local fin = (byte1 & 0x80) ~= 0
    local opcode = byte1 & 0x0F
    local masked = (byte2 & 0x80) ~= 0
    local payload_len = byte2 & 0x7F
    
    local pos = 3
    if payload_len == 126 then
        payload_len = (string.byte(data, 3) << 8) | string.byte(data, 4)
        pos = 5
    elseif payload_len == 127 then
        -- 简化处理，不支持超长消息
        return nil
    end
    
    local mask_key
    if masked then
        mask_key = data:sub(pos, pos + 3)
        pos = pos + 4
    end
    
    local payload = data:sub(pos, pos + payload_len - 1)
    
    if masked then
        local unmasked = {}
        for i = 1, #payload do
            local j = ((i - 1) % 4) + 1
            unmasked[i] = string.char(
                string.byte(payload, i) ~ string.byte(mask_key, j)
            )
        end
        payload = table.concat(unmasked)
    end
    
    return {
        fin = fin,
        opcode = opcode,
        payload = payload
    }
end

local function encode_frame(payload)
    local len = #payload
    local frame = string.char(0x81)  -- FIN=1, opcode=1 (text)
    
    if len < 126 then
        frame = frame .. string.char(len)
    elseif len < 65536 then
        frame = frame .. string.char(126, (len >> 8) & 0xFF, len & 0xFF)
    else
        -- 简化处理
        return nil
    end
    
    return frame .. payload
end

local function handle_websocket(id)
    socket.start(id)
    
    if not websocket_handshake(id) then
        socket.close(id)
        return
    end
    
    skynet.error("WebSocket handshake success")
    
    while true do
        local data = socket.read(id)
        if not data then
            break
        end
        
        local frame = decode_frame(data)
        if frame then
            if frame.opcode == 0x8 then  -- Close
                break
            elseif frame.opcode == 0x9 then  -- Ping
                local pong = encode_frame(frame.payload)
                pong = string.char(0x8A) .. pong:sub(2)  -- Pong opcode
                socket.write(id, pong)
            elseif frame.opcode == 0x1 then  -- Text
                skynet.error("Recv: " .. frame.payload)
                local response = encode_frame("Echo: " .. frame.payload)
                socket.write(id, response)
            end
        end
    end
    
    socket.close(id)
end

skynet.start(function()
    local listen_fd = socket.listen("0.0.0.0", 8002)
    skynet.error("WebSocket server listening on :8002")
    
    socket.start(listen_fd, function(id, addr)
        skynet.fork(function()
            handle_websocket(id)
        end)
    end)
end)
```

---

## 第三部分：游戏服务开发（高级）

### 练习 7：玩家登录服务

#### 目标
实现完整的玩家登录流程。

#### 要求
1. 账号注册（用户名、密码）
2. 登录验证
3. Token 生成和验证
4. 在线状态管理
5. 防止重复登录

#### 参考答案
```lua
-- login_service.lua
local skynet = require "skynet"
local crypt = require "skynet.crypt"

local users = {}      -- 用户数据 {username = {password, info}}
local tokens = {}     -- Token 映射 {token = username}
local online = {}     -- 在线玩家 {username = true}

local CMD = {}

-- 密码加密
local function hash_password(password, salt)
    return crypt.base64encode(crypt.hmac_sha1(password, salt))
end

-- 生成 Token
local function generate_token(username)
    local token = crypt.base64encode(crypt.randomkey() .. username)
    tokens[token] = username
    return token
end

-- 注册
function CMD.register(username, password)
    if not username or not password then
        return {ok = false, error = "用户名和密码不能为空"}
    end
    
    if users[username] then
        return {ok = false, error = "用户已存在"}
    end
    
    local salt = crypt.base64encode(crypt.randomkey())
    users[username] = {
        password = hash_password(password, salt),
        salt = salt,
        create_time = os.time(),
        info = {}
    }
    
    skynet.error(string.format("User registered: %s", username))
    return {ok = true}
end

-- 登录
function CMD.login(username, password)
    local user = users[username]
    if not user then
        return {ok = false, error = "用户不存在"}
    end
    
    local hashed = hash_password(password, user.salt)
    if hashed ~= user.password then
        return {ok = false, error = "密码错误"}
    end
    
    if online[username] then
        return {ok = false, error = "用户已在线"}
    end
    
    online[username] = true
    local token = generate_token(username)
    
    skynet.error(string.format("User login: %s", username))
    return {
        ok = true,
        token = token,
        info = user.info
    }
end

-- 登出
function CMD.logout(token)
    local username = tokens[token]
    if not username then
        return {ok = false, error = "无效的 Token"}
    end
    
    tokens[token] = nil
    online[username] = nil
    
    skynet.error(string.format("User logout: %s", username))
    return {ok = true}
end

-- 验证 Token
function CMD.verify(token)
    local username = tokens[token]
    if not username then
        return {ok = false, error = "无效的 Token"}
    end
    
    if not online[username] then
        return {ok = false, error = "用户不在线"}
    end
    
    return {ok = true, username = username}
end

-- 获取在线玩家
function CMD.online_list()
    local list = {}
    for username, _ in pairs(online) do
        table.insert(list, username)
    end
    return list
end

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = CMD[cmd]
        if f then
            skynet.ret(skynet.pack(f(...)))
        else
            error(string.format("Unknown command %s", tostring(cmd)))
        end
    end)
    
    -- 测试数据
    CMD.register("test", "123456")
end)
```

---

### 练习 8：游戏房间服务

#### 目标
实现多人游戏房间管理。

#### 要求
1. 创建/加入/离开房间
2. 房间内广播消息
3. 游戏状态同步
4. 房主权限管理
5. 自动清理空房间

#### 参考答案
```lua
-- room_service.lua
local skynet = require "skynet"

local room_id
local room_config
local players = {}
local owner
local game_state = "waiting"  -- waiting, playing, finished
local max_players

local CMD = {}

local function broadcast(msg, exclude)
    for pid, pinfo in pairs(players) do
        if pid ~= exclude then
            skynet.send(pinfo.agent, "lua", "room_msg", msg)
        end
    end
end

function CMD.init(id, config)
    room_id = id
    room_config = config
    max_players = config.max_players or 4
    return true
end

function CMD.join(player_id, player_info)
    if #players >= max_players then
        return {ok = false, error = "房间已满"}
    end
    
    if game_state ~= "waiting" then
        return {ok = false, error = "游戏已开始"}
    end
    
    players[player_id] = player_info
    
    -- 第一个加入的玩家成为房主
    if not owner then
        owner = player_id
    end
    
    -- 广播玩家加入
    broadcast({
        type = "player_join",
        player_id = player_id,
        player_info = player_info
    })
    
    skynet.error(string.format("Player %s joined room %s", player_id, room_id))
    
    return {
        ok = true,
        room_info = {
            id = room_id,
            owner = owner,
            players = players,
            state = game_state
        }
    }
end

function CMD.leave(player_id)
    if not players[player_id] then
        return {ok = false, error = "玩家不在房间内"}
    end
    
    players[player_id] = nil
    
    -- 广播玩家离开
    broadcast({
        type = "player_leave",
        player_id = player_id
    })
    
    -- 如果房主离开，转移房主
    if owner == player_id then
        owner = next(players)
        if owner then
            broadcast({
                type = "owner_change",
                new_owner = owner
            })
        end
    end
    
    skynet.error(string.format("Player %s left room %s", player_id, room_id))
    
    -- 如果房间空了，通知销毁
    if not next(players) then
        skynet.timeout(100, function()
            if not next(players) then
                skynet.send(".room_mgr", "lua", "remove_room", room_id)
                skynet.exit()
            end
        end)
    end
    
    return {ok = true}
end

function CMD.start_game(player_id)
    if player_id ~= owner then
        return {ok = false, error = "只有房主可以开始游戏"}
    end
    
    if game_state ~= "waiting" then
        return {ok = false, error = "游戏已经开始"}
    end
    
    local player_count = 0
    for _ in pairs(players) do
        player_count = player_count + 1
    end
    
    if player_count < 2 then
        return {ok = false, error = "至少需要2个玩家"}
    end
    
    game_state = "playing"
    
    -- 初始化游戏数据
    -- ...
    
    broadcast({
        type = "game_start",
        game_data = {}  -- 游戏初始数据
    })
    
    skynet.error(string.format("Game started in room %s", room_id))
    
    return {ok = true}
end

function CMD.game_action(player_id, action)
    if game_state ~= "playing" then
        return {ok = false, error = "游戏未开始"}
    end
    
    if not players[player_id] then
        return {ok = false, error = "玩家不在房间内"}
    end
    
    -- 处理游戏行为
    -- ...
    
    -- 广播行为结果
    broadcast({
        type = "game_action",
        player_id = player_id,
        action = action,
        result = {}  -- 行为结果
    })
    
    return {ok = true}
end

function CMD.chat(player_id, message)
    if not players[player_id] then
        return {ok = false, error = "玩家不在房间内"}
    end
    
    broadcast({
        type = "chat",
        player_id = player_id,
        message = message,
        time = os.time()
    })
    
    return {ok = true}
end

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

---

### 练习 9：匹配系统

#### 目标
实现游戏匹配系统。

#### 要求
1. 支持多种匹配模式（1v1, 2v2, 5v5）
2. 基于等级的匹配（MMR）
3. 匹配超时处理
4. 组队匹配支持
5. 取消匹配

#### 参考答案
```lua
-- match_service.lua
local skynet = require "skynet"

local match_queues = {}  -- {mode = {player_list}}
local matching_players = {}  -- {player_id = {mode, mmr, team, enter_time}}

local MATCH_MODES = {
    ["1v1"] = {players = 2, teams = 2},
    ["2v2"] = {players = 4, teams = 2},
    ["5v5"] = {players = 10, teams = 2},
}

local MATCH_TIMEOUT = 60  -- 60秒匹配超时
local MMR_RANGE_INIT = 100  -- 初始MMR范围
local MMR_RANGE_STEP = 50   -- 每10秒扩大范围

local CMD = {}

local function get_mmr_range(wait_time)
    return MMR_RANGE_INIT + math.floor(wait_time / 10) * MMR_RANGE_STEP
end

local function can_match(p1, p2, current_time)
    local wait_time1 = current_time - p1.enter_time
    local wait_time2 = current_time - p2.enter_time
    local mmr_range = math.max(get_mmr_range(wait_time1), get_mmr_range(wait_time2))
    
    return math.abs(p1.mmr - p2.mmr) <= mmr_range
end

local function try_match(mode)
    local config = MATCH_MODES[mode]
    if not config then
        return
    end
    
    local queue = match_queues[mode] or {}
    if #queue < config.players then
        return
    end
    
    local current_time = os.time()
    local matched = {}
    
    -- 简单匹配逻辑：按MMR排序，相近的组成一场
    table.sort(queue, function(a, b)
        return matching_players[a].mmr < matching_players[b].mmr
    end)
    
    for i = 1, #queue - config.players + 1 do
        local candidates = {}
        local valid = true
        
        -- 检查连续的玩家是否可以匹配
        for j = i, i + config.players - 1 do
            local p1 = matching_players[queue[j]]
            for k = i, j - 1 do
                local p2 = matching_players[queue[k]]
                if not can_match(p1, p2, current_time) then
                    valid = false
                    break
                end
            end
            if not valid then
                break
            end
            table.insert(candidates, queue[j])
        end
        
        if valid and #candidates == config.players then
            matched = candidates
            break
        end
    end
    
    if #matched > 0 then
        -- 创建游戏房间
        local room_id = skynet.call(".room_mgr", "lua", "create_match_room", {
            mode = mode,
            players = matched,
            config = config
        })
        
        -- 通知玩家匹配成功
        for _, player_id in ipairs(matched) do
            local pinfo = matching_players[player_id]
            skynet.send(pinfo.agent, "lua", "match_found", {
                room_id = room_id,
                mode = mode,
                players = matched
            })
            
            -- 从队列中移除
            matching_players[player_id] = nil
            for idx, pid in ipairs(match_queues[mode]) do
                if pid == player_id then
                    table.remove(match_queues[mode], idx)
                    break
                end
            end
        end
        
        skynet.error(string.format("Match found: mode=%s, room=%s", mode, room_id))
    end
end

function CMD.start_match(player_id, mode, mmr, team_id, agent)
    if matching_players[player_id] then
        return {ok = false, error = "已在匹配中"}
    end
    
    if not MATCH_MODES[mode] then
        return {ok = false, error = "无效的匹配模式"}
    end
    
    matching_players[player_id] = {
        mode = mode,
        mmr = mmr or 1500,
        team = team_id,
        enter_time = os.time(),
        agent = agent
    }
    
    match_queues[mode] = match_queues[mode] or {}
    table.insert(match_queues[mode], player_id)
    
    skynet.error(string.format("Player %s start matching: mode=%s, mmr=%d", 
        player_id, mode, mmr or 1500))
    
    -- 尝试立即匹配
    try_match(mode)
    
    return {ok = true}
end

function CMD.cancel_match(player_id)
    local pinfo = matching_players[player_id]
    if not pinfo then
        return {ok = false, error = "未在匹配中"}
    end
    
    matching_players[player_id] = nil
    
    local queue = match_queues[pinfo.mode]
    if queue then
        for i, pid in ipairs(queue) do
            if pid == player_id then
                table.remove(queue, i)
                break
            end
        end
    end
    
    skynet.error(string.format("Player %s cancelled matching", player_id))
    
    return {ok = true}
end

local function match_loop()
    while true do
        skynet.sleep(100)  -- 每秒检查一次
        
        local current_time = os.time()
        
        -- 检查超时
        for player_id, pinfo in pairs(matching_players) do
            if current_time - pinfo.enter_time > MATCH_TIMEOUT then
                skynet.send(pinfo.agent, "lua", "match_timeout")
                CMD.cancel_match(player_id)
            end
        end
        
        -- 尝试匹配
        for mode, _ in pairs(MATCH_MODES) do
            try_match(mode)
        end
    end
end

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = CMD[cmd]
        if f then
            skynet.ret(skynet.pack(f(...)))
        else
            error(string.format("Unknown command %s", tostring(cmd)))
        end
    end)
    
    skynet.fork(match_loop)
end)
```

---

## 第四部分：性能优化练习

### 练习 10：消息批处理优化

#### 目标
优化大量消息处理的性能。

#### 要求
1. 实现消息批量处理
2. 减少服务间通信次数
3. 实现消息合并
4. 添加性能统计

#### 参考答案
```lua
-- batch_processor.lua
local skynet = require "skynet"

local batch_queue = {}
local batch_size = 100
local batch_timeout = 10  -- 100ms
local processing = false

local stats = {
    total_messages = 0,
    total_batches = 0,
    total_time = 0,
}

local CMD = {}

local function process_batch(batch)
    local start_time = skynet.now()
    
    -- 批量处理逻辑
    for _, msg in ipairs(batch) do
        -- 处理单个消息
        -- ...
    end
    
    local cost_time = skynet.now() - start_time
    stats.total_time = stats.total_time + cost_time
    stats.total_batches = stats.total_batches + 1
    
    skynet.error(string.format("Processed batch: size=%d, time=%.2fms", 
        #batch, cost_time))
end

local function batch_worker()
    while true do
        if #batch_queue > 0 then
            local batch = {}
            local count = math.min(#batch_queue, batch_size)
            
            for i = 1, count do
                table.insert(batch, table.remove(batch_queue, 1))
            end
            
            process_batch(batch)
        else
            skynet.sleep(batch_timeout)
        end
    end
end

function CMD.add(msg)
    table.insert(batch_queue, msg)
    stats.total_messages = stats.total_messages + 1
    
    -- 如果达到批量大小，立即处理
    if #batch_queue >= batch_size and not processing then
        processing = true
        skynet.wakeup(batch_worker)
        processing = false
    end
    
    return true
end

function CMD.stats()
    return {
        total_messages = stats.total_messages,
        total_batches = stats.total_batches,
        avg_batch_size = stats.total_batches > 0 
            and stats.total_messages / stats.total_batches or 0,
        avg_batch_time = stats.total_batches > 0 
            and stats.total_time / stats.total_batches or 0,
        queue_size = #batch_queue
    }
end

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = CMD[cmd]
        if f then
            skynet.ret(skynet.pack(f(...)))
        else
            error(string.format("Unknown command %s", tostring(cmd)))
        end
    end)
    
    skynet.fork(batch_worker)
end)
```

---

## 第五部分：调试与测试

### 练习 11：压力测试工具

#### 目标
创建服务压力测试工具。

#### 要求
1. 模拟并发请求
2. 统计响应时间
3. 计算 QPS
4. 生成测试报告

#### 参考答案
```lua
-- stress_test.lua
local skynet = require "skynet"

local function test_service(service_addr, test_config)
    local results = {
        total = 0,
        success = 0,
        failed = 0,
        total_time = 0,
        min_time = math.huge,
        max_time = 0,
        errors = {}
    }
    
    local function send_request()
        local start = skynet.now()
        local ok, ret = pcall(skynet.call, service_addr, "lua", 
            test_config.cmd, table.unpack(test_config.args or {}))
        local cost = skynet.now() - start
        
        results.total = results.total + 1
        results.total_time = results.total_time + cost
        
        if ok then
            results.success = results.success + 1
            results.min_time = math.min(results.min_time, cost)
            results.max_time = math.max(results.max_time, cost)
        else
            results.failed = results.failed + 1
            results.errors[ret] = (results.errors[ret] or 0) + 1
        end
    end
    
    local start_time = skynet.now()
    local tasks = {}
    
    -- 创建并发任务
    for i = 1, test_config.concurrent do
        tasks[i] = skynet.fork(function()
            for j = 1, test_config.requests do
                send_request()
                if test_config.delay then
                    skynet.sleep(test_config.delay)
                end
            end
        end)
    end
    
    -- 等待所有任务完成
    for _, task in ipairs(tasks) do
        skynet.wait(task)
    end
    
    local total_time = skynet.now() - start_time
    
    -- 生成报告
    local report = string.format([[
========== Stress Test Report ==========
Service: %s
Command: %s
Concurrent: %d
Total Requests: %d
Total Time: %.2f seconds
Success: %d
Failed: %d
QPS: %.2f
Avg Response Time: %.2f ms
Min Response Time: %.2f ms
Max Response Time: %.2f ms
]], 
        tostring(service_addr),
        test_config.cmd,
        test_config.concurrent,
        results.total,
        total_time / 100,
        results.success,
        results.failed,
        results.total / (total_time / 100),
        results.total > 0 and results.total_time / results.total or 0,
        results.min_time,
        results.max_time
    )
    
    if results.failed > 0 then
        report = report .. "\nErrors:\n"
        for err, count in pairs(results.errors) do
            report = report .. string.format("  %s: %d\n", err, count)
        end
    end
    
    return report
end

skynet.start(function()
    -- 测试配置
    local test_configs = {
        {
            service = "counter",
            cmd = "add",
            args = {1},
            concurrent = 10,
            requests = 100,
            delay = nil
        },
        {
            service = "kvstore", 
            cmd = "set",
            args = {"test_key", "test_value"},
            concurrent = 20,
            requests = 50,
            delay = 1
        }
    }
    
    for _, config in ipairs(test_configs) do
        local service = skynet.newservice(config.service)
        local report = test_service(service, config)
        skynet.error(report)
    end
    
    skynet.exit()
end)
```

---

## 练习答案验证方法

### 自动化测试脚本
```bash
#!/bin/bash
# test_all.sh

echo "Building Skynet..."
make linux

echo "Running tests..."
for test in test_*.lua; do
    echo "Testing: $test"
    ./skynet test_config --start=$test
    if [ $? -eq 0 ]; then
        echo "✓ $test passed"
    else
        echo "✗ $test failed"
    fi
done
```

### 测试配置文件
```lua
-- test_config
include "config.path"

thread = 4
logger = nil
harbor = 0
start = os.getenv("start") or "test_main"
bootstrap = "snlua bootstrap"
```

---

## 进阶挑战

### 挑战 1：分布式锁服务
实现基于 Skynet 的分布式锁服务，支持：
- 可重入锁
- 锁超时
- 死锁检测
- 锁等待队列

### 挑战 2：分布式缓存
实现分布式缓存系统，支持：
- LRU/LFU 淘汰策略
- 缓存预热
- 缓存更新策略
- 多级缓存

### 挑战 3：消息队列
实现消息队列服务，支持：
- 多种消息模式（点对点、发布订阅）
- 消息持久化
- 消息确认机制
- 死信队列

---

## 学习建议

1. **循序渐进**：从简单的 Hello World 开始，逐步增加复杂度
2. **理解原理**：不要只是复制代码，要理解背后的设计思想
3. **多写多练**：每个概念都要亲手实现一遍
4. **阅读源码**：遇到问题时查看 Skynet 源码
5. **性能意识**：始终关注代码的性能影响
6. **错误处理**：养成良好的错误处理习惯
7. **日志记录**：合理使用日志帮助调试
8. **代码复用**：将通用功能封装成库

## 总结

通过完成这些练习，你将：
- 掌握 Skynet 的核心概念和 API
- 理解 Actor 模型和消息驱动架构
- 学会使用 Skynet 开发网络服务
- 具备开发游戏服务器的能力
- 了解分布式系统的基本原理

记住，实践是最好的学习方式。动手编码，遇到问题就调试，在错误中学习，在成功中前进！