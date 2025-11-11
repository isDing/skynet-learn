-- 说明：
--  .service 管理器：提供 LAUNCH/QUERY/GLAUNCH/GQUERY 等接口，集中管理命名服务。
--  特点：
--   - 并发请求同名服务会排队（waitfor），仅首个触发真正创建
--   - 支持 snaxd 与普通服务（snlua）的启动与查询
--   - 在 standalone 模式下，还提供全局管理（SERVICE）
--  约定与技巧：
--   - 名字以 '@' 开头表示全局名（跨 harbor），其余为本地名
--   - GLAUNCH/GQUERY 在 standalone 模式下由本服务集约，在非 standalone 模式转发到远端 SERVICE
--   - waitfor 负责“仅一次创建”的并发控制：失败时以文本错误缓存，后续立即抛错
local skynet = require "skynet"
require "skynet.manager"	-- import skynet.register
local snax = require "skynet.snax"

local cmd = {}
local service = {}

-- 实际启动动作：调用 func，记录成功的地址或失败原因，并唤醒等待队列
local function request(name, func, ...)
	local ok, handle = pcall(func, ...)
	local s = service[name]
	assert(type(s) == "table")
	if ok then
		service[name] = handle
	else
		service[name] = tostring(handle)
	end

	for _,v in ipairs(s) do
		skynet.wakeup(v.co)
	end

	if ok then
		return handle
	else
		error(tostring(handle))
	end
end

-- 等待 name 对应的地址：
--  - 第一次带 func 调用触发启动，其余并发请求等待
--  - 若之前失败，直接抛错（字符串）
-- 创建/等待 name 对应的服务地址：
--  - 带 func 的第一个调用方作为“创建者”；其余并发调用方进入队列等待
--  - 若历史失败：直接抛出错误文本
local function waitfor(name , func, ...)
	local s = service[name]
	if type(s) == "number" then
		return s
	end
	local co = coroutine.running()

	if s == nil then
		s = {}
		service[name] = s
	elseif type(s) == "string" then
		error(s)
	end

	assert(type(s) == "table")

	local session, source = skynet.context()

	if s.launch == nil and func then
		s.launch = {
			session = session,
			source = source,
			co = co,
		}
		return request(name, func, ...)
	end

	table.insert(s, {
		co = co,
		session = session,
		source = source,
	})
	skynet.wait()
	s = service[name]
	if type(s) == "string" then
		error(s)
	end
	assert(type(s) == "number")
	return s
end

-- @name -> 去掉 '@' 的真实名，其它情况返回原始字符串
local function read_name(service_name)
	if string.byte(service_name) == 64 then -- '@'
		return string.sub(service_name , 2)
	else
		return service_name
	end
end

function cmd.LAUNCH(service_name, subname, ...)
    -- 启动服务或 snax：按 @name 判断是否全局/是否 snaxd
	local realname = read_name(service_name)

	if realname == "snaxd" then
		return waitfor(service_name.."."..subname, snax.rawnewservice, subname, ...)
	else
		return waitfor(service_name, skynet.newservice, realname, subname, ...)
	end
end

function cmd.QUERY(service_name, subname)
    -- 查询服务或 snax：同上逻辑
	local realname = read_name(service_name)

	if realname == "snaxd" then
		return waitfor(service_name.."."..subname)
	else
		return waitfor(service_name)
	end
end

local function list_service()
    -- 生成服务列表：已就绪地址/错误文本/启动中队列详情
	local result = {}
	for k,v in pairs(service) do
		if type(v) == "string" then
			v = "Error: " .. v
		elseif type(v) == "table" then
			local querying = {}
			if v.launch then
				local session = skynet.task(v.launch.co)
				local launching_address = skynet.call(".launcher", "lua", "QUERY", session)
				if launching_address then
					table.insert(querying, "Init as " .. skynet.address(launching_address))
					table.insert(querying,  skynet.call(launching_address, "debug", "TASK", "init"))
					table.insert(querying, "Launching from " .. skynet.address(v.launch.source))
					table.insert(querying, skynet.call(v.launch.source, "debug", "TASK", v.launch.session))
				end
			end
			if #v > 0 then
				table.insert(querying , "Querying:" )
				for _, detail in ipairs(v) do
					table.insert(querying, skynet.address(detail.source) .. " " .. tostring(skynet.call(detail.source, "debug", "TASK", detail.session)))
				end
			end
			v = table.concat(querying, "\n")
		else
			v = skynet.address(v)
		end

		result[k] = v
	end

	return result
end


local function register_global()
    -- standalone 模式下作为全局服务管理者
	function cmd.GLAUNCH(name, ...)
		local global_name = "@" .. name
		return cmd.LAUNCH(global_name, ...)
	end

	function cmd.GQUERY(name, ...)
		local global_name = "@" .. name
		return cmd.QUERY(global_name, ...)
	end

	local mgr = {}

	function cmd.REPORT(m)
		mgr[m] = true
	end

	local function add_list(all, m)
		local harbor = "@" .. skynet.harbor(m)
		local result = skynet.call(m, "lua", "LIST")
		for k,v in pairs(result) do
			all[k .. harbor] = v
		end
	end

	function cmd.LIST()
        -- 汇总其它 service_mgr 的 LIST 与本地 LIST
		local result = {}
		for k in pairs(mgr) do
			pcall(add_list, result, k)
		end
		local l = list_service()
		for k, v in pairs(l) do
			result[k] = v
		end
		return result
	end
end

local function register_local()
    -- 非 standalone 模式：转发到远端 global SERVICE
	local function waitfor_remote(cmd, name, ...)
		local global_name = "@" .. name
		local local_name
		if name == "snaxd" then
			local_name = global_name .. "." .. (...)
		else
			local_name = global_name
		end
		return waitfor(local_name, skynet.call, "SERVICE", "lua", cmd, global_name, ...)
	end

	function cmd.GLAUNCH(...)
		return waitfor_remote("LAUNCH", ...)
	end

	function cmd.GQUERY(...)
		return waitfor_remote("QUERY", ...)
	end

	function cmd.LIST()
		return list_service()
	end

	skynet.call("SERVICE", "lua", "REPORT", skynet.self())
end

skynet.start(function()
	skynet.dispatch("lua", function(session, address, command, ...)
		local f = cmd[command]
		if f == nil then
			skynet.ret(skynet.pack(nil, "Invalid command " .. command))
			return
		end

		local ok, r = pcall(f, ...)

		if ok then
			skynet.ret(skynet.pack(r))
		else
			skynet.ret(skynet.pack(nil, r))
		end
	end)
	local handle = skynet.localname ".service"
	if  handle then
		skynet.error(".service is already register by ", skynet.address(handle))
		skynet.exit()
	else
		skynet.register(".service")
	end
	if skynet.getenv "standalone" then
		skynet.register("SERVICE")
		register_global()
	else
		register_local()
	end
end)
