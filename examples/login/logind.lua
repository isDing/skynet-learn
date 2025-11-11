local login = require "snax.loginserver"
local crypt = require "skynet.crypt"
local skynet = require "skynet"

-- 说明：
--  登录 master 进程配置：
--   - host/port：监听地址
--   - multilogin：是否允许同一 uid 并发登录（false 表示禁止；返回 406）
--   - name：本地注册名（便于其他服务查找）
local server = {
	host = "127.0.0.1",
	port = 8001,
	multilogin = false,	-- disallow multilogin
	name = "login_master",
}

local server_list = {}
local user_online = {}
local user_login = {}

-- 解析客户端 token 并做初步认证：
--  token 约定：base64(user)@base64(server):base64(password)
function server.auth_handler(token)
	-- the token is base64(user)@base64(server):base64(password)
	local user, server, password = token:match("([^@]+)@([^:]+):(.+)")
	user = crypt.base64decode(user)
	server = crypt.base64decode(server)
	password = crypt.base64decode(password)
	assert(password == "password", "Invalid password")  -- 演示：固定密码
	return server, user
end

-- 业务登录：
--  - 检查已在线用户（将踢下线旧会话）
--  - 找到 gameserver，调用其 login 接口，返回 subid
--  - 记录在线状态（便于后续登出/kick）
function server.login_handler(server, uid, secret)
	print(string.format("%s@%s is login, secret is %s", uid, server, crypt.hexencode(secret)))
	local gameserver = assert(server_list[server], "Unknown server")
	-- only one can login, because disallow multilogin
	local last = user_online[uid]
	if last then
		skynet.call(last.address, "lua", "kick", uid, last.subid)
	end
	if user_online[uid] then
		error(string.format("user %s is already online", uid))
	end

	local subid = tostring(skynet.call(gameserver, "lua", "login", uid, secret))
	user_online[uid] = { address = gameserver, subid = subid , server = server}
	return subid
end

local CMD = {}

function CMD.register_gate(server, address)
	server_list[server] = address
end

function CMD.logout(uid, subid)
	local u = user_online[uid]
	if u then
		print(string.format("%s@%s is logout", uid, u.server))
		user_online[uid] = nil
	end
end

function server.command_handler(command, ...)
	local f = assert(CMD[command])
	return f(...)
end

login(server)
