--[[
	Harbor Dummy（单节点占位的 .cslave 实现）

	职责概述：
	- 在 harbor=0 的单节点模式下，提供与 .cslave 一致的 Lua 接口（REGISTER / QUERYNAME / LINK / CONNECT）。
	- 仅做本地全局名字缓存与分发，不涉及任何跨节点网络连接。
	- 启动 C 层 harbor 服务（harbor_id 必须为 0），便于引擎端调用路径统一。
	- 通过注册 "harbor" 与 "text" 协议，承接来自 C 层 harbor 的内部控制消息（在单机下均为 no-op）。
]]

local skynet = require "skynet"
require "skynet.manager"	-- import skynet.launch, ...

-- 全局名字缓存：name -> handle（本地）
local globalname = {}
-- 查询等待队列：name -> { response() ... }
local queryname = {}
-- 导出给 skynet.harbor 的 Lua 命令集合
local harbor = {}
-- C 层 harbor 服务句柄（单机也会启动，harbor_id = 0）
local harbor_service

skynet.register_protocol {
	name = "harbor",
	id = skynet.PTYPE_HARBOR,
	pack = function(...) return ... end,
	unpack = skynet.tostring,
}

skynet.register_protocol {
	name = "text",
	id = skynet.PTYPE_TEXT,
	pack = function(...) return ... end,
	unpack = skynet.tostring,
}

-- 将缓存中的 name -> address 分发给所有等待者
local function response_name(name)
	local address = globalname[name]
	if queryname[name] then
		local tmp = queryname[name]
		queryname[name] = nil
		for _,resp in ipairs(tmp) do
			resp(true, address)
		end
	end
end

-- 注册全局名字（仅本地缓存）：更新缓存 -> 唤醒等待 -> 通知 C 层 harbor（内部 N name）
function harbor.REGISTER(name, handle)
	assert(globalname[name] == nil)
	globalname[name] = handle
	response_name(name)
	skynet.redirect(harbor_service, handle, "harbor", 0, "N " .. name)
end

-- 查询名字：'.xxx' 为本地名；缓存命中直接返回；否则挂起等待（Master 不存在，等待其他注册触发）
function harbor.QUERYNAME(name)
	if name:byte() == 46 then	-- "." , local name
		skynet.ret(skynet.pack(skynet.localname(name)))
		return
	end
	local result = globalname[name]
	if result then
		skynet.ret(skynet.pack(result))
		return
	end
	local queue = queryname[name]
	if queue == nil then
		queue = { skynet.response() }
		queryname[name] = queue
	else
		table.insert(queue, skynet.response())
	end
end

-- 监听某个 harbor 的联通性（单机下直接返回）
function harbor.LINK(id)
	skynet.ret()
end

-- 连接其它 harbor（单机下不支持，仅提示）
function harbor.CONNECT(id)
	skynet.error("Can't connect to other harbor in single node mode")
end

skynet.start(function()
	local harbor_id = tonumber(skynet.getenv "harbor")
	assert(harbor_id == 0)

	-- 绑定 .cslave 的 Lua 命令（REGISTER/QUERYNAME/LINK/CONNECT/...）
	skynet.dispatch("lua", function (session,source,command,...)
		local f = assert(harbor[command])
		f(...)
	end)
	skynet.dispatch("text", function(session,source,command)
		-- ignore all the command
	end)

	-- 启动 C 层 harbor 服务（harbor_id = 0，单机模式）
	harbor_service = assert(skynet.launch("harbor", harbor_id, skynet.self()))
end)
