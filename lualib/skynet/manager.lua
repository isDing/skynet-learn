-- 说明：
--  skynet.manager 提供服务命名与管理的扩展 API：
--   - 启动/杀死服务（launch/kill/abort）
--   - 本地/全局服务命名（register/name）
--   - 协议转发（forward_type）与分发过滤（filter）
--   - 系统监控服务设置（monitor）
--  本模块不改变调度逻辑，仅通过 c.command 与内核交互。
local skynet = require "skynet"
local c = require "skynet.core"

-- 将形如 ":08001234" 或数值地址转换为数值地址
local function number_address(name)
	local t = type(name)
	if t == "number" then
		return name
	elseif t == "string" then
		local hex = name:match "^:(%x+)"
		if hex then
			return tonumber(hex, 16)
		end
	end
end

-- 启动服务：返回服务地址（数值）。
-- 等价于在 shell 中执行 LAUNCH 指令：LAUNCH <args...>
function skynet.launch(...)
	local addr = c.command("LAUNCH", table.concat({...}," "))
	if addr then
		return tonumber(string.sub(addr , 2), 16)
	end
end

-- 杀死服务：可接受服务名、形如 ":ADDR" 的字符串、或数值地址。
-- 若传入数值或 ":ADDR"，会先通知 .launcher 进行 REMOVE，再发 KILL。
function skynet.kill(name)
	local addr = number_address(name)
	if addr then
		skynet.send(".launcher","lua","REMOVE", addr, true)
		name = skynet.address(addr)
	end
	c.command("KILL",name)
end

-- 立即中止当前服务（非正常退出）
function skynet.abort()
	c.command("ABORT")
end

-- 处理全局命名（跨 harbor）。
-- 返回 true 表示是全局名；false 表示本地名（以 '.' 开头）
local function globalname(name, handle)
	local c = string.sub(name,1,1)
	assert(c ~= ':')
	if c == '.' then
		return false
	end

	assert(#name < 16)	-- GLOBALNAME_LENGTH is 16, defined in skynet_harbor.h
	assert(tonumber(name) == nil)	-- global name can't be number

	local harbor = require "skynet.harbor"

	harbor.globalname(name, handle)

	return true
end

-- 注册服务名：
--  - 本地名以 '.' 开头，使用 REG 指令登记
--  - 全局名需通过 harbor.globalname 注册
function skynet.register(name)
	if not globalname(name) then
		c.command("REG", name)
	end
end

-- 为指定 handle 绑定服务名（与 register 类似，但可显式传入 handle）
function skynet.name(name, handle)
	if not globalname(name, handle) then
		c.command("NAME", name .. " " .. skynet.address(handle))
	end
end

local dispatch_message = skynet.dispatch_message

-- 协议转发：将 ptype(数字) 映射为已有协议名（字符串），复用相同的分发逻辑。
-- 例如：将 PTYPE_CLIENT 映射为 "lua"，这样客户端消息可直接由 lua 协议处理。
function skynet.forward_type(map, start_func)
	c.callback(function(ptype, msg, sz, ...)
		local prototype = map[ptype]
		if prototype then
			dispatch_message(prototype, msg, sz, ...)
		else
			local ok, err = pcall(dispatch_message, ptype, msg, sz, ...)
			c.trash(msg, sz)
			if not ok then
				error(err)
			end
		end
	end, true)
	skynet.timeout(0, function()
		skynet.init_service(start_func)
	end)
end

-- 分发过滤：在进入 dispatch_message 前对 (ptype,msg,sz,session,source) 进行转换
-- 可用于埋点、协议升级兼容、或统一接入。
function skynet.filter(f ,start_func)
	c.callback(function(...)
		dispatch_message(f(...))
	end)
	skynet.timeout(0, function()
		skynet.init_service(start_func)
	end)
end

-- 设置系统 monitor 服务：内核将向此地址汇报服务状态（如崩溃等）
function skynet.monitor(service, query)
	local monitor
	if query then
		monitor = skynet.queryservice(true, service)
	else
		monitor = skynet.uniqueservice(true, service)
	end
	assert(monitor, "Monitor launch failed")
	c.command("MONITOR", string.format(":%08x", monitor))
	return monitor
end

return skynet
