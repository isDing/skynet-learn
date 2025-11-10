-- 说明：
--  提供以“服务名”为键的轻量服务管理工具：new/query/close
--  依赖内部的唯一服务 service_provider 执行实际的启动/查询/关闭逻辑。
local skynet = require "skynet"

local service = {}
local cache = {}
local provider

local function get_provider()
	-- service_provider 是全局唯一服务，负责按名称提供服务地址
	provider = provider or skynet.uniqueservice "service_provider"
	return provider
end

local function check(func)
	-- 确保 mainfunc 是一个标准的 Lua chunk（仅 1 个 _ENV upvalue），便于 string.dump
	local info = debug.getinfo(func, "u")
	assert(info.nups == 1)
	assert(debug.getupvalue(func,1) == "_ENV")
end

function service.new(name, mainfunc, ...)
	-- 根据给定名称创建/获取服务：
	--  - 已存在：直接返回地址
	--  - 正在启动：等待查询
	--  - 不存在：将 mainfunc dump 为 bytecode，通过 provider 启动
	local p = get_provider()
	local addr, booting = skynet.call(p, "lua", "test", name)
	local address
	if addr then
		address = addr
	else
		if booting then
			address = skynet.call(p, "lua", "query", name)
		else
			check(mainfunc)
			local code = string.dump(mainfunc)
			address = skynet.call(p, "lua", "launch", name, code, ...)
		end
	end
	cache[name] = address
	return address
end

function service.close(name)
	-- 关闭命名服务：请求 provider 回收并 kill 对应服务
	local addr = skynet.call(get_provider(), "lua", "close", name)
	if addr then
        cache[name] = nil
		skynet.kill(addr)
		return true
	end
	return false
end

function service.query(name)
	-- 查询命名服务，缓存结果避免重复查询
	if not cache[name] then
		cache[name] = skynet.call(get_provider(), "lua", "query", name)
	end
	return cache[name]
end

return service
