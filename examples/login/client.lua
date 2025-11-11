-- 说明：
--  登录客户端示例：
--   1) 连接登录 master（127.0.0.1:8001），完成 DH 握手 + HMAC 校验 + DES 加密 token
--   2) 收到 200 base64(subid) 后，使用 subid + secret 与 game gate（:8888）握手
--   3) 发送两次请求演示会话与重放
package.cpath = "luaclib/?.so"

local socket = require "client.socket"
local crypt = require "client.crypt"

if _VERSION ~= "Lua 5.4" then
	error "Use lua 5.4"
end

local fd = assert(socket.connect("127.0.0.1", 8001))

local function writeline(fd, text)
	socket.send(fd, text .. "\n")
end

local function unpack_line(text)
	local from = text:find("\n", 1, true)
	if from then
		return text:sub(1, from-1), text:sub(from+1)
	end
	return nil, text
end

local last = ""

local function unpack_f(f)
	local function try_recv(fd, last)
		local result
		result, last = f(last)
		if result then
			return result, last
		end
		local r = socket.recv(fd)
		if not r then
			return nil, last
		end
		if r == "" then
			error "Server closed"
		end
		return f(last .. r)
	end

	return function()
		while true do
			local result
			result, last = try_recv(fd, last)
			if result then
				return result
			end
			socket.usleep(100)
		end
	end
end

local readline = unpack_f(unpack_line)

-- 登录阶段 1：服务端发来 base64(8byte challenge)
local challenge = crypt.base64decode(readline())

-- 登录阶段 2：客户端发出 base64(DH 交换值)，并收到服务端交换值后计算 secret
local clientkey = crypt.randomkey()
writeline(fd, crypt.base64encode(crypt.dhexchange(clientkey)))
local secret = crypt.dhsecret(crypt.base64decode(readline()), clientkey)

print("sceret is ", crypt.hexencode(secret))

-- 登录阶段 3：发送 base64(HMAC(challenge, secret))
local hmac = crypt.hmac64(challenge, secret)
writeline(fd, crypt.base64encode(hmac))

local token = {
	server = "sample",
	user = "hello",
	pass = "password",
}

local function encode_token(token)
	return string.format("%s@%s:%s",
		crypt.base64encode(token.user),
		crypt.base64encode(token.server),
		crypt.base64encode(token.pass))
end

-- 登录阶段 4：发送 DES(secret, base64(token))
local etoken = crypt.desencode(secret, encode_token(token))
writeline(fd, crypt.base64encode(etoken))

local result = readline()
print(result)
local code = tonumber(string.sub(result, 1, 3))
assert(code == 200)
socket.close(fd)

local subid = crypt.base64decode(string.sub(result, 5))  -- 业务 subid（字符串/数字皆可）

print("login ok, subid=", subid)

----- connect to game server

-- game gate 协议：([2B len][payload][1B ok?][4B session])，详见 examples 实现
local function send_request(v, session)
	local size = #v + 4
	local package = string.pack(">I2", size)..v..string.pack(">I4", session)
	socket.send(fd, package)
	return v, session
end

local function recv_response(v)
	local size = #v - 5
	local content, ok, session = string.unpack("c"..tostring(size).."B>I4", v)
	return ok ~=0 , content, session
end

-- 解包 2 字节帧长的回应
local function unpack_package(text)
	local size = #text
	if size < 2 then
		return nil, text
	end
	local s = text:byte(1) * 256 + text:byte(2)
	if size < s+2 then
		return nil, text
	end

	return text:sub(3,2+s), text:sub(3+s)
end

local readpackage = unpack_f(unpack_package)

local function send_package(fd, pack)
	local package = string.pack(">s2", pack)
	socket.send(fd, package)
end

local text = "echo"
local index = 1

print("connect")
fd = assert(socket.connect("127.0.0.1", 8888))
last = ""

local handshake = string.format("%s@%s#%s:%d", crypt.base64encode(token.user), crypt.base64encode(token.server),crypt.base64encode(subid) , index)
local hmac = crypt.hmac64(crypt.hashkey(handshake), secret)


send_package(fd, handshake .. ":" .. crypt.base64encode(hmac))

print(readpackage())
print("===>",send_request(text,0))
-- don't recv response
-- print("<===",recv_response(readpackage()))

print("disconnect")
socket.close(fd)

index = index + 1

print("connect again")
fd = assert(socket.connect("127.0.0.1", 8888))
last = ""

local handshake = string.format("%s@%s#%s:%d", crypt.base64encode(token.user), crypt.base64encode(token.server),crypt.base64encode(subid) , index)
local hmac = crypt.hmac64(crypt.hashkey(handshake), secret)

send_package(fd, handshake .. ":" .. crypt.base64encode(hmac))

print(readpackage())
print("===>",send_request("fake",0))	-- request again (use last session 0, so the request message is fake)
print("===>",send_request("again",1))	-- request again (use new session)
print("<===",recv_response(readpackage()))
print("<===",recv_response(readpackage()))


print("disconnect")
socket.close(fd)
