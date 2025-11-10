-- 说明：
--  snax 封装了一套“类 RPC”的调用模式（accept/response/system 三组接口），
--  并通过 PTYPE_SNAX 协议进行消息分发与调用。
--  - accept : 异步通知（post），不等待结果
--  - response : 同步请求（req），等待结果
--  - system : 系统级方法（init/exit/hotfix等）
local skynet = require "skynet"
local snax_interface = require "snax.interface"

local snax = {}
local typeclass = {}

-- 允许从环境变量中注入一个全局接口命名空间（可供 snax.interface 使用）
local interface_g = skynet.getenv("snax_interface_g")
local G = interface_g and require (interface_g) or { require = function() end }
interface_g = nil

-- 注册 snax 协议：使用 pack/unpack 直接透传参数
skynet.register_protocol {
	name = "snax",
	id = skynet.PTYPE_SNAX,
	pack = skynet.pack,
	unpack = skynet.unpack,
}


-- 解析 snax 接口定义：
--  snax.interface(name) -> { name, accept = {name->id}, response={name->id}, system={name->id} }
function snax.interface(name)
	if typeclass[name] then
		return typeclass[name]
	end

	local si = snax_interface(name, G)

	local ret = {
		name = name,
		accept = {},
		response = {},
		system = {},
	}

	for _,v in ipairs(si) do
		local id, group, name, f = table.unpack(v)
		ret[group][name] = id
	end

	typeclass[name] = ret
	return ret
end

local meta = { __tostring = function(v) return string.format("[%s:%x]", v.type, v.handle) end}

local skynet_send = skynet.send
local skynet_call = skynet.call

-- 生成异步调用表：obj.post.method(...) => send(handle, "snax", id, ...)
local function gen_post(type, handle)
	return setmetatable({} , {
		__index = function( t, k )
			local id = type.accept[k]
			if not id then
				error(string.format("post %s:%s no exist", type.name, k))
			end
			return function(...)
				skynet_send(handle, "snax", id, ...)
			end
		end })
end

-- 生成同步调用表：obj.req.method(...) => call(handle, "snax", id, ...)
local function gen_req(type, handle)
	return setmetatable({} , {
		__index = function( t, k )
			local id = type.response[k]
			if not id then
				error(string.format("request %s:%s no exist", type.name, k))
			end
			return function(...)
				return skynet_call(handle, "snax", id, ...)
			end
		end })
end

-- 包装为 snax 对象：包含 post/req 表、类型名与句柄（toString 显示）
local function wrapper(handle, name, type)
	return setmetatable ({
		post = gen_post(type, handle),
		req = gen_req(type, handle),
		type = name,
		handle = handle,
		}, meta)
end

local handle_cache = setmetatable( {} , { __mode = "kv" } )

-- 启动 snax 服务，返回句柄：若接口包含 system.init 则先调用
function snax.rawnewservice(name, ...)
	local t = snax.interface(name)
	local handle = skynet.newservice("snaxd", name)
	assert(handle_cache[handle] == nil)
	if t.system.init then
		skynet.call(handle, "snax", t.system.init, ...)
	end
	return handle
end

-- 将已有句柄绑定为 snax 对象（便于 post/req 调用）
function snax.bind(handle, type)
	local ret = handle_cache[handle]
	if ret then
		assert(ret.type == type)
		return ret
	end
	local t = snax.interface(type)
	ret = wrapper(handle, type, t)
	handle_cache[handle] = ret
	return ret
end

-- 启动并绑定 snax 服务
function snax.newservice(name, ...)
	local handle = snax.rawnewservice(name, ...)
	return snax.bind(handle, name)
end

-- 获取/启动唯一 snax 服务（本地）
function snax.uniqueservice(name, ...)
	local handle = assert(skynet.call(".service", "lua", "LAUNCH", "snaxd", name, ...))
	return snax.bind(handle, name)
end

-- 获取/启动全局 snax 服务（跨 harbor）
function snax.globalservice(name, ...)
	local handle = assert(skynet.call(".service", "lua", "GLAUNCH", "snaxd", name, ...))
	return snax.bind(handle, name)
end

-- 查询本地 snax 服务
function snax.queryservice(name)
	local handle = assert(skynet.call(".service", "lua", "QUERY", "snaxd", name))
	return snax.bind(handle, name)
end

-- 查询全局 snax 服务
function snax.queryglobal(name)
	local handle = assert(skynet.call(".service", "lua", "GQUERY", "snaxd", name))
	return snax.bind(handle, name)
end

-- 以 system.exit 结束目标 snax 服务
function snax.kill(obj, ...)
	local t = snax.interface(obj.type)
	skynet_call(obj.handle, "snax", t.system.exit, ...)
end

-- 将当前服务绑定为 snax 对象（依赖全局 SERVICE_NAME）
function snax.self()
	return snax.bind(skynet.self(), SERVICE_NAME)
end

-- 退出当前 snax 服务（调用自身的 system.exit）
function snax.exit(...)
	snax.kill(snax.self(), ...)
end

-- 将 pcall 结果转化为直接返回/抛错
local function test_result(ok, ...)
	if ok then
		return ...
	else
		error(...)
	end
end

-- 触发目标 snax 服务的热更新（system.hotfix）
function snax.hotfix(obj, source, ...)
	local t = snax.interface(obj.type)
	return test_result(skynet_call(obj.handle, "snax", t.system.hotfix, source, ...))
end

-- 简单打印（包装 skynet.error）
function snax.printf(fmt, ...)
	skynet.error(string.format(fmt, ...))
end

function snax.profile_info(obj)
	local t = snax.interface(obj.type)
	return skynet_call(obj.handle, "snax", t.system.profile)
end

return snax
