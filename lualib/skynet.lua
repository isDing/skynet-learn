-- read https://github.com/cloudwu/skynet/wiki/FAQ for the module "skynet.core"
-- 说明：
--  本文件是 Skynet 的 Lua 框架层核心实现（对 C 模块 skynet.core 的封装），
--  负责：消息协议注册与分发、会话管理、协程池复用、同步/异步请求、
--  睡眠/唤醒、错误传播与服务退出等。为了便于学习理解，补充了中文注释。
--  注意：仅添加注释，不改变任何逻辑。
local c = require "skynet.core"
local skynet_require = require "skynet.require"
local tostring = tostring
local coroutine = coroutine
local assert = assert
local error = error
local pairs = pairs
local pcall = pcall
local table = table
local next = next
local tremove = table.remove
local tinsert = table.insert
local tpack = table.pack
local tunpack = table.unpack
local traceback = debug.traceback

local cresume = coroutine.resume
local running_thread = nil  -- 当前正在运行的 Lua 协程（用于 trace、上下文）
local init_thread = nil     -- 服务启动阶段的初始化线程句柄（用于定位启动错误）

-- 统一的 resume 包装：在恢复协程前设置 running_thread，确保后续逻辑可获取上下文
local function coroutine_resume(co, ...)
	running_thread = co
	return cresume(co, ...)
end
local coroutine_yield = coroutine.yield
local coroutine_create = coroutine.create

-- 协议表：name/id ↔ class 映射（见 skynet.register_protocol）
local proto = {}
local skynet = {
	-- read skynet.h
	-- 消息类型常量，数值与 C 层一致（见 skynet.h）。
	PTYPE_TEXT = 0,       -- 文本/调试用途
	PTYPE_RESPONSE = 1,   -- 响应（对端以此类型发回调用结果）
	PTYPE_MULTICAST = 2,  -- 多播
	PTYPE_CLIENT = 3,     -- 客户端（网关）
	PTYPE_SYSTEM = 4,     -- 系统消息
	PTYPE_HARBOR = 5,     -- harbor 相关
	PTYPE_SOCKET = 6,     -- socket 事件
	PTYPE_ERROR = 7,      -- 错误通知（对端挂掉、包太大等）
	PTYPE_QUEUE = 8,      -- used in deprecated mqueue, use skynet.queue instead 早期 mqueue 已废弃，使用 skynet.queue 替代
	PTYPE_DEBUG = 9,      -- 调试
	PTYPE_LUA = 10,       -- Lua 协议（最常用）
	PTYPE_SNAX = 11,      -- SNAX 协议
	PTYPE_TRACE = 12,     -- use for debug trace Trace 跟踪
}

-- code cache
-- 代码缓存：避免重复加载模块，提升热路径性能
skynet.cache = require "skynet.codecache"
skynet._proto = proto

-- 注册协议：
--  class = {
--    name = "lua",                  -- 协议名
--    id = skynet.PTYPE_LUA,         -- 协议 id（0-255）
--    pack = function(...) end,      -- 序列化函数（可选）
--    unpack = function(msg,sz) end, -- 反序列化函数（可选）
--    dispatch = function(...) end,  -- 消息分发函数（可选，后续可通过 skynet.dispatch 设置）
--    trace = true/false/nil,        -- 是否强制开启/关闭 trace（可选）
--  }
function skynet.register_protocol(class)
	local name = class.name
	local id = class.id
	assert(proto[name] == nil and proto[id] == nil)
	assert(type(name) == "string" and type(id) == "number" and id >=0 and id <=255)
	proto[name] = class
	proto[id] = class
end

-- 会话/协程映射：
--  session_id_coroutine[session] = thread | "BREAK"
--    用于从 C 回调推进协程或打断等待。
--  session_coroutine_id[thread] = session
--  session_coroutine_address[thread] = remote address（对端服务地址）
--  session_coroutine_tracetag[thread] = trace tag（字符串或 false 表示关闭）
--  unresponse[response_closure] = remote address（尚未发送回应前保留，见 skynet.response）
local session_id_coroutine = {}
local session_coroutine_id = {}
local session_coroutine_address = {}
local session_coroutine_tracetag = {}
local unresponse = {}

-- 睡眠/唤醒：
--  wakeup_queue = { token1, token2, ... }  FIFO
--  sleep_session[token] = session         记录 token 对应的超时/等待会话
local wakeup_queue = {}
local sleep_session = {}

-- 监控与错误：
--  watching_session[session] = service address   call 等待中记录对端，以便错误分发
--  error_queue : 本地错误待分发的 session 列表
--  fork_queue  : fork 出来的协程队列（h/t 为队头/队尾索引）
local watching_session = {}
local error_queue = {}
local fork_queue = { h = 1, t = 0 }

local auxsend, auxtimeout, auxwait
do ---- avoid session rewind conflict
	-- 说明：Skynet 的会话 id 为 32 位有符号整数，接近上界会回绕。
	-- 此处通过“安全区/危险区”机制，避免新生成的 session 与活跃 session 冲突。
	local csend = c.send
	local cintcommand = c.intcommand
	local dangerzone
	local dangerzone_size = 0x1000
	local dangerzone_low = 0x70000000
	local dangerzone_up	= dangerzone_low + dangerzone_size

	local set_checkrewind	-- set auxsend and auxtimeout for safezone
	local set_checkconflict -- set auxsend and auxtimeout for dangerzone

	local function reset_dangerzone(session)
		-- 根据当前活跃会话重算危险区边界，并将所有活跃 session 收集到 dangerzone 表
		dangerzone_up = session
		dangerzone_low = session
		dangerzone = { [session] = true }
		for s in pairs(session_id_coroutine) do
			if s < dangerzone_low then
				dangerzone_low = s
			elseif s > dangerzone_up then
				dangerzone_up = s
			end
			dangerzone[s] = true
		end
		dangerzone_low = dangerzone_low - dangerzone_size
	end

	-- in dangerzone, we should check if the next session already exist.
	local function checkconflict(session)
		-- 检查 session+1 是否可能与已有活跃会话冲突；必要时跳过并进入/退出危险区
		if session == nil then
			return
		end
		local next_session = session + 1
		if next_session > dangerzone_up then
			-- leave dangerzone
			reset_dangerzone(session)
			assert(next_session > dangerzone_up)
			set_checkrewind()
		else
			while true do
				if not dangerzone[next_session] then
					break
				end
				if not session_id_coroutine[next_session] then
					reset_dangerzone(session)
					break
				end
				-- skip the session already exist.
				next_session = c.genid() + 1
			end
		end
		-- session will rewind after 0x7fffffff
		if next_session == 0x80000000 and dangerzone[1] then
			assert(c.genid() == 1)
			return checkconflict(1)
		end
	end

	-- 在危险区内发送：需要对刚生成的 session 做冲突校验
	local function auxsend_checkconflict(addr, proto, msg, sz)
		local session = csend(addr, proto, nil, msg, sz)
		checkconflict(session)
		return session
	end

	local function auxtimeout_checkconflict(timeout)
		local session = cintcommand("TIMEOUT", timeout)
		checkconflict(session)
		return session
	end

	local function auxwait_checkconflict()
		local session = c.genid()
		checkconflict(session)
		return session
	end

	-- 在安全区发送：若发现落入危险区范围，则切换策略到 checkconflict
	local function auxsend_checkrewind(addr, proto, msg, sz)
		local session = csend(addr, proto, nil, msg, sz)
		if session and session > dangerzone_low and session <= dangerzone_up then
			-- enter dangerzone
			set_checkconflict(session)
		end
		return session
	end

	local function auxtimeout_checkrewind(timeout)
		local session = cintcommand("TIMEOUT", timeout)
		if session and session > dangerzone_low and session <= dangerzone_up then
			-- enter dangerzone
			set_checkconflict(session)
		end
		return session
	end

	local function auxwait_checkrewind()
		local session = c.genid()
		if session > dangerzone_low and session <= dangerzone_up then
			-- enter dangerzone
			set_checkconflict(session)
		end
		return session
	end

	set_checkrewind = function()
		-- 默认处于安全区策略
		auxsend = auxsend_checkrewind
		auxtimeout = auxtimeout_checkrewind
		auxwait = auxwait_checkrewind
	end

	set_checkconflict = function(session)
		reset_dangerzone(session)
		auxsend = auxsend_checkconflict
		auxtimeout = auxtimeout_checkconflict
		auxwait = auxwait_checkconflict
	end

	-- in safezone at the beginning
	-- 初始进入安全区（正常情况）
	set_checkrewind()
end

do ---- request/select
	-- 批量请求发送：遍历 self 中的 {addr, typename, ...}，发起 request
	local function send_requests(self)
		local sessions = {}
		self._sessions = sessions
		local request_n = 0
		local err
		for i = 1, #self do
			local req = self[i]
			local addr = req[1]
			local p = proto[req[2]]
			assert(p.unpack)
			local tag = session_coroutine_tracetag[running_thread]
			if tag then
				c.trace(tag, "call", 4)
				c.send(addr, skynet.PTYPE_TRACE, 0, tag)
			end
			local session = auxsend(addr, p.id , p.pack(tunpack(req, 3, req.n)))
			if session == nil then
				err = err or {}
				err[#err+1] = req
			else
				sessions[session] = req
				watching_session[session] = addr
				session_id_coroutine[session] = self._thread
				request_n = request_n + 1
			end
		end
		self._request = request_n
		return err
	end

	-- 批量请求处理协程：被 C 回调推进，收集各 session 的结果
	local function request_thread(self)
		while true do
			local succ, msg, sz, session = coroutine_yield "SUSPEND"
			if session == self._timeout then
				self._timeout = nil
				self.timeout = true
			else
				watching_session[session] = nil
				local req = self._sessions[session]
				local p = proto[req[2]]
				if succ then
					self._resp[session] = tpack( p.unpack(msg, sz) )
				else
					self._resp[session] = false
				end
			end
			skynet.wakeup(self)
		end
	end

	-- 批量请求结果迭代器：逐条返回 {req, resp}
	local function request_iter(self)
		return function()
			if self._error then
				-- invalid address
				local e = tremove(self._error)
				if e then
					return e
				end
				self._error = nil
			end
			local session, resp = next(self._resp)
			if session == nil then
				if self._request == 0 then
					return
				end
				if self.timeout then
					return
				end
				skynet.wait(self)
				if self.timeout then
					return
				end
				session, resp = next(self._resp)
			end

			self._request = self._request - 1
			local req = self._sessions[session]
			self._resp[session] = nil
			self._sessions[session] = nil
			return req, resp
		end
	end

	local request_meta = {}	; request_meta.__index = request_meta

	function request_meta:add(obj)
		assert(type(obj) == "table" and not self._thread)
		self[#self+1] = obj
		return self
	end

	request_meta.__call = request_meta.add

	function request_meta:close()
		if self._request > 0 then
			local resp = self._resp
			for session, req in pairs(self._sessions) do
				if not resp[session] then
					session_id_coroutine[session] = "BREAK"
					watching_session[session] = nil
				end
			end
			self._request = 0
		end
		if self._timeout then
			session_id_coroutine[self._timeout] = "BREAK"
			self._timeout = nil
		end
	end

	request_meta.__close = request_meta.close

	function request_meta:select(timeout)
		-- 发出所有请求，挂上处理线程，返回一个迭代器用于遍历响应
		assert(self._thread == nil)
		self._thread = coroutine_create(request_thread)
		self._error = send_requests(self)
		self._resp = {}
		if timeout then
			self._timeout = auxtimeout(timeout)
			session_id_coroutine[self._timeout] = self._thread
		end

		local running = running_thread
		coroutine_resume(self._thread, self)
		running_thread = running
		return request_iter(self), nil, nil, self
	end

	function skynet.request(obj)
		local ret = setmetatable({}, request_meta)
		if obj then
			return ret(obj)
		end
		return ret
	end
end

-- suspend is function
-- suspend 是框架核心的“调度器”：
--  用于统一处理协程 yield 返回的指令（SUSPEND/QUIT/USER/nil），
--  并在出错时进行清理、通知对端、抛出 Lua 错误栈。
local suspend

----- monitor exit

-- 错误队列派发：逐条将 error_queue 中记录的 session 恢复并返回失败
local function dispatch_error_queue()
	local session = tremove(error_queue,1)
	if session then
		local co = session_id_coroutine[session]
		session_id_coroutine[session] = nil
		return suspend(co, coroutine_resume(co, false, nil, nil, session))
	end
end

-- C 回调错误分发入口：
--  error_session == 0 表示对端服务宕机，需清理所有指向该服务的未完成请求；
--  否则将该具体 session 标记入错误队列，稍后恢复等待的协程并返回失败。
local function _error_dispatch(error_session, error_source)
	skynet.ignoreret()	-- don't return for error
	if error_session == 0 then
		-- error_source is down, clear unreponse set
		for resp, address in pairs(unresponse) do
			if error_source == address then
				unresponse[resp] = nil
			end
		end
		for session, srv in pairs(watching_session) do
			if srv == error_source then
				tinsert(error_queue, session)
			end
		end
	else
		-- capture an error for error_session
		if watching_session[error_session] then
			tinsert(error_queue, error_session)
		end
	end
end

-- coroutine reuse

-- 协程池（弱引用）：避免频繁创建/销毁，提升吞吐
local coroutine_pool = setmetatable({}, { __mode = "kv" })

-- 从协程池取出一个协程执行函数 f；若无可复用则创建新的
local function co_create(f)
	local co = tremove(coroutine_pool)
	if co == nil then
		co = coroutine_create(function(...)
			f(...)
			while true do
				-- 会话检查和清理：若仍有未响应的会话，打印警告（可能忘记 skynet.ret/response）
				local session = session_coroutine_id[co]
				if session and session ~= 0 then
					local source = debug.getinfo(f,"S")
					skynet.error(string.format("Maybe forgot response session %s from %s : %s:%d",
						session,
						skynet.address(session_coroutine_address[co]),
						source.source, source.linedefined))
				end
				-- coroutine exit  协程退出：清理 trace 标签
				local tag = session_coroutine_tracetag[co]
				if tag ~= nil then
					if tag then c.trace(tag, "end")	end
					session_coroutine_tracetag[co] = nil
				end
				-- 地址信息清理（防止悬挂引用）
				local address = session_coroutine_address[co]
				if address then
					session_coroutine_id[co] = nil
					session_coroutine_address[co] = nil
				end

				-- recycle co into pool
				-- 回收协程到池
				f = nil
				coroutine_pool[#coroutine_pool+1] = co
				-- recv new main function f 等待新的入口函数 f（两次 yield 协调：先传入 f，再传入参数 ...）
				f = coroutine_yield "SUSPEND"
				f(coroutine_yield())
			end
		end)
	else
		-- pass the main function f to coroutine, and restore running thread
		-- 将新的入口函数 f 传给复用协程，并恢复原 running_thread
		local running = running_thread
		coroutine_resume(co, f)
		running_thread = running
	end
	return co
end

-- 唤醒队列派发：根据 token 找到对应的 session，恢复其协程
local function dispatch_wakeup()
	while true do
		local token = tremove(wakeup_queue,1)
		if token then
			local session = sleep_session[token]
			if session then
				local co = session_id_coroutine[session]
				local tag = session_coroutine_tracetag[co]
				if tag then c.trace(tag, "resume") end
				session_id_coroutine[session] = "BREAK"
				return suspend(co, coroutine_resume(co, false, "BREAK", nil, session))
			end
		else
			break
		end
	end
	return dispatch_error_queue()
end

-- suspend is local function
function suspend(co, result, command)
	if not result then
		-- 协程执行出错：通知对端（若有 session>0），清理当前协程的上下文并抛出栈
		local session = session_coroutine_id[co]
		if session then -- coroutine may fork by others (session is nil)
			local addr = session_coroutine_address[co]
			if session ~= 0 then
				-- only call response error
				local tag = session_coroutine_tracetag[co]
				if tag then c.trace(tag, "error") end
				c.send(addr, skynet.PTYPE_ERROR, session, "")
			end
			session_coroutine_id[co] = nil
		end
		session_coroutine_address[co] = nil
		session_coroutine_tracetag[co] = nil
		skynet.fork(function() end)	-- trigger command "SUSPEND"
		local tb = traceback(co,tostring(command))
		coroutine.close(co)
		error(tb)
	end
	if command == "SUSPEND" then
		-- 继续处理唤醒/错误队列，驱动调度前进
		return dispatch_wakeup()
	elseif command == "QUIT" then
		coroutine.close(co)
		-- service exit
		return
	elseif command == "USER" then
		-- See skynet.coutine for detail
		error("Call skynet.coroutine.yield out of skynet.coroutine.resume\n" .. traceback(co))
	elseif command == nil then
		-- debug trace
		return
	else
		error("Unknown command : " .. command .. "\n" .. traceback(co))
	end
end

local co_create_for_timeout
local timeout_traceback

function skynet.trace_timeout(on)
	local function trace_coroutine(func, ti)
		local co
		co = co_create(function()
			timeout_traceback[co] = nil
			func()
		end)
		local info = string.format("TIMER %d+%d : ", skynet.now(), ti)
		timeout_traceback[co] = traceback(info, 3)
		return co
	end
	if on then
		timeout_traceback = timeout_traceback or {}
		co_create_for_timeout = trace_coroutine
	else
		timeout_traceback = nil
		co_create_for_timeout = co_create
	end
end

skynet.trace_timeout(false)	-- turn off by default

function skynet.timeout(ti, func)
	-- 在 ti 个计时片后（1/100 秒为单位）执行 func
	local session = auxtimeout(ti)
	assert(session)
	local co = co_create_for_timeout(func, ti)
	assert(session_id_coroutine[session] == nil)
	session_id_coroutine[session] = co
	return co	-- for debug
end

local function suspend_sleep(session, token)
	-- 将当前协程登记到 session，使用 token 建立反向索引，随后挂起
	local tag = session_coroutine_tracetag[running_thread]
	if tag then c.trace(tag, "sleep", 2) end
	session_id_coroutine[session] = running_thread
	assert(sleep_session[token] == nil, "token duplicative")
	sleep_session[token] = session

	return coroutine_yield "SUSPEND"
end

function skynet.sleep(ti, token)
	-- 休眠 ti 个计时片；可以通过 skynet.wakeup(token) 唤醒
	local session = auxtimeout(ti)
	assert(session)
	token = token or coroutine.running()
	local succ, ret = suspend_sleep(session, token)
	sleep_session[token] = nil
	if succ then
		return
	end
	if ret == "BREAK" then
		return "BREAK"
	else
		error(ret)
	end
end

function skynet.yield()
	-- 让出时间片（sleep 0）
	return skynet.sleep(0)
end

function skynet.wait(token)
	-- 等待直到被唤醒（无超时），通过 wakeup(token) 推进
	local session = auxwait()
	token = token or coroutine.running()
	suspend_sleep(session, token)
	sleep_session[token] = nil
	session_id_coroutine[session] = nil
end

function skynet.killthread(thread)
	-- 杀死指定协程：
	--  - 若入参为字符串，则按 tostring(co) 模糊查找匹配的协程
	--  - 若在 fork 队列中，直接移除并返回该协程
	--  - 若为挂起在 session 上的协程，通知对端 ERROR 并关闭该协程
	local session
	-- find session
	if type(thread) == "string" then
		for k,v in pairs(session_id_coroutine) do
			local thread_string = tostring(v)
			if thread_string:find(thread) then
				session = k
				break
			end
		end
	else
		local t = fork_queue.t
		for i = fork_queue.h, t do
			if fork_queue[i] == thread then
				table.move(fork_queue, i+1, t, i)
				fork_queue[t] = nil
				fork_queue.t = t - 1
				return thread
			end
		end
		for k,v in pairs(session_id_coroutine) do
			if v == thread then
				session = k
				break
			end
		end
	end
	local co = session_id_coroutine[session]
	if co == nil then
		return
	end
	local addr = session_coroutine_address[co]
	if addr then
		session_coroutine_address[co] = nil
		session_coroutine_tracetag[co] = nil
		local session = session_coroutine_id[co]
		if session > 0 then
			c.send(addr, skynet.PTYPE_ERROR, session, "")
		end
		session_coroutine_id[co] = nil
	end
	if watching_session[session] then
		session_id_coroutine[session] = "BREAK"
		watching_session[session] = nil
	else
		session_id_coroutine[session] = nil
	end
	for k,v in pairs(sleep_session) do
		if v == session then
			sleep_session[k] = nil
			break
		end
	end
	coroutine.close(co)
	return co
end

function skynet.self()
	-- 返回当前服务地址（数值形式）
	return c.addresscommand "REG"
end

function skynet.localname(name)
	-- 查询本地名对应的地址（.name）
	return c.addresscommand("QUERY", name)
end

skynet.now = c.now   -- 当前 tick（1/100 秒）
skynet.hpc = c.hpc	-- high performance counter 高性能计数器（高精度时钟）

local traceid = 0
function skynet.trace(info)
	skynet.error("TRACE", session_coroutine_tracetag[running_thread])
	if session_coroutine_tracetag[running_thread] == false then
		-- force off trace log
		return
	end
	traceid = traceid + 1

	local tag = string.format(":%08x-%d",skynet.self(), traceid)
	session_coroutine_tracetag[running_thread] = tag
	if info then
		c.trace(tag, "trace " .. info)
	else
		c.trace(tag, "trace")
	end
end

function skynet.tracetag()
	-- 读取当前协程的 trace tag（若为 false 表示被强制关闭）
	return session_coroutine_tracetag[running_thread]
end

local starttime

function skynet.starttime()
	-- 进程启动时刻（秒），只查询一次并缓存
	if not starttime then
		starttime = c.intcommand("STARTTIME")
	end
	return starttime
end

function skynet.time()
	-- 当前时间（秒），= starttime + now/100
	return skynet.now()/100 + (starttime or skynet.starttime())
end

function skynet.exit()
	fork_queue = { h = 1, t = 0 }	-- no fork coroutine can be execute after skynet.exit
	skynet.send(".launcher","lua","REMOVE",skynet.self(), false)
	-- report the sources that call me
	for co, session in pairs(session_coroutine_id) do
		local address = session_coroutine_address[co]
		if session~=0 and address then
			c.send(address, skynet.PTYPE_ERROR, session, "")
		end
	end
	for session, co in pairs(session_id_coroutine) do
		if type(co) == "thread" and co ~= running_thread then
			coroutine.close(co)
		end
	end
	for resp in pairs(unresponse) do
		resp(false)
	end
	-- report the sources I call but haven't return
	local tmp = {}
	for session, address in pairs(watching_session) do
		tmp[address] = true
	end
	for address in pairs(tmp) do
		c.send(address, skynet.PTYPE_ERROR, 0, "")
	end
	c.callback(function(prototype, msg, sz, session, source)
		if session ~= 0 and source ~= 0 then
			c.send(source, skynet.PTYPE_ERROR, session, "")
		end
	end)
	c.command("EXIT")
	-- quit service
	coroutine_yield "QUIT"
end

function skynet.getenv(key)
	-- 读取启动配置中的环境变量（来自 config 文件或 setenv）
	return (c.command("GETENV",key))
end

function skynet.setenv(key, value)
	-- 设置环境变量（仅能设置一次，若已存在会报错）
	assert(c.command("GETENV",key) == nil, "Can't setenv exist key : " .. key)
	c.command("SETENV",key .. " " ..value)
end

function skynet.send(addr, typename, ...)
	-- 异步发送：session=0，不等待对端响应（适合通知类）
	local p = proto[typename]
	return c.send(addr, p.id, 0 , p.pack(...))
end

function skynet.rawsend(addr, typename, msg, sz)
	-- 异步发送（原始消息体）：msg/sz 由调用方准备
	local p = proto[typename]
	return c.send(addr, p.id, 0 , msg, sz)
end

skynet.genid = assert(c.genid)

skynet.redirect = function(dest,source,typename,...)
	-- 将一条消息从当前服务转发到 dest，保持 source 为原始来源
	-- 常用于网关或代理场景
	return c.redirect(dest, source, proto[typename].id, ...)
end

-- 底层打包/解包/字符串化与内存回收接口（C 实现，性能更优）
skynet.pack = assert(c.pack)
skynet.packstring = assert(c.packstring)
skynet.unpack = assert(c.unpack)
skynet.tostring = assert(c.tostring)
skynet.trash = assert(c.trash)

local function yield_call(service, session)
	-- 将当前协程与 session 绑定并监控对端地址，然后挂起等待响应
	watching_session[session] = service
	session_id_coroutine[session] = running_thread
	local succ, msg, sz = coroutine_yield "SUSPEND"
	watching_session[session] = nil
	if not succ then
		error "call failed"
	end
	return msg,sz
end

function skynet.call(addr, typename, ...)
	-- 同步调用：分配会话 id，记录监控，yield 等待响应，然后解包返回
	local tag = session_coroutine_tracetag[running_thread]
	if tag then
		c.trace(tag, "call", 2)
		c.send(addr, skynet.PTYPE_TRACE, 0, tag)
	end

	local p = proto[typename]
	local session = auxsend(addr, p.id , p.pack(...))
	if session == nil then
		error("call to invalid address " .. skynet.address(addr))
	end
	return p.unpack(yield_call(addr, session))
end

function skynet.rawcall(addr, typename, msg, sz)
	-- 同步调用（已打包的消息体）
	local tag = session_coroutine_tracetag[running_thread]
	if tag then
		c.trace(tag, "call", 2)
		c.send(addr, skynet.PTYPE_TRACE, 0, tag)
	end
	local p = proto[typename]
	local session = assert(auxsend(addr, p.id , msg, sz), "call to invalid address")
	return yield_call(addr, session)
end

function skynet.tracecall(tag, addr, typename, msg, sz)
	-- 外部提供的 trace id 进行一次调用的全链路跟踪
	c.trace(tag, "tracecall begin")
	c.send(addr, skynet.PTYPE_TRACE, 0, tag)
	local p = proto[typename]
	local session = assert(auxsend(addr, p.id , msg, sz), "call to invalid address")
	local msg, sz = yield_call(addr, session)
	c.trace(tag, "tracecall end")
	return msg, sz
end

function skynet.ret(msg, sz)
	-- 对上一次 call 发回响应。若 session==0（来自 send），仅丢弃数据。
	msg = msg or ""
	local tag = session_coroutine_tracetag[running_thread]
	if tag then c.trace(tag, "response") end
	local co_session = session_coroutine_id[running_thread]
	if co_session == nil then
		error "No session"
	end
	session_coroutine_id[running_thread] = nil
	if co_session == 0 then
		if sz ~= nil then
			c.trash(msg, sz)
		end
		return false	-- send don't need ret
	end
	local co_address = session_coroutine_address[running_thread]
	local ret = c.send(co_address, skynet.PTYPE_RESPONSE, co_session, msg, sz)
	if ret then
		return true
	elseif ret == false then
		-- If the package is too large, returns false. so we should report error back
		c.send(co_address, skynet.PTYPE_ERROR, co_session, "")
	end
	return false
end

function skynet.context()
	-- 返回当前协程对应的上下文：session 与对端地址
	local co_session = session_coroutine_id[running_thread]
	local co_address = session_coroutine_address[running_thread]
	return co_session, co_address
end

function skynet.ignoreret()
	-- We use session for other uses
	-- 忽略后续的 ret：释放当前协程与 session 的绑定（可用于错误场景等）
	session_coroutine_id[running_thread] = nil
end

function skynet.response(pack)
	-- 生成一次性的响应闭包：
	--  - 调用返回的闭包可发送 RESPONSE/ERROR，返回 true/false 表示是否发送成功
	--  - 若调用 ok=="TEST" 则仅探测闭包是否仍可用（是否未被发送过/未被清理）
	pack = pack or skynet.pack

	local co_session = assert(session_coroutine_id[running_thread], "no session")
	session_coroutine_id[running_thread] = nil
	local co_address = session_coroutine_address[running_thread]
	if co_session == 0 then
		--  do not response when session == 0 (send)
		return function() end
	end
	local function response(ok, ...)
		if ok == "TEST" then
			return unresponse[response] ~= nil
		end
		if not pack then
			error "Can't response more than once"
		end

		local ret
		if unresponse[response] then
			if ok then
				ret = c.send(co_address, skynet.PTYPE_RESPONSE, co_session, pack(...))
				if ret == false then
					-- If the package is too large, returns false. so we should report error back
					c.send(co_address, skynet.PTYPE_ERROR, co_session, "")
				end
			else
				ret = c.send(co_address, skynet.PTYPE_ERROR, co_session, "")
			end
			unresponse[response] = nil
			ret = ret ~= nil
		else
			ret = false
		end
		pack = nil
		return ret
	end
	unresponse[response] = co_address

	return response
end

function skynet.retpack(...)
	return skynet.ret(skynet.pack(...))
end

function skynet.wakeup(token)
	-- 若 token 对应的 sleep 仍在等待，将其入队唤醒
	if sleep_session[token] then
		tinsert(wakeup_queue, token)
		return true
	end
end

function skynet.dispatch(typename, func)
	-- 注册/查询指定 typename 协议的分发函数（p.dispatch）
	local p = proto[typename]
	if func then
		local ret = p.dispatch
		p.dispatch = func
		return ret
	else
		return p and p.dispatch
	end
end

-- 默认未知请求处理：打印报错（通常意味着协议未注册或未设置 dispatch）
local function unknown_request(session, address, msg, sz, prototype)
	skynet.error(string.format("Unknown request (%s): %s", prototype, c.tostring(msg,sz)))
	error(string.format("Unknown session : %d from %x", session, address))
end

function skynet.dispatch_unknown_request(unknown)
	-- 自定义未知请求处理（用于兜底日志或统计）
	local prev = unknown_request
	unknown_request = unknown
	return prev
end

-- 默认未知响应处理：打印报错（通常是错误的会话管理导致）
local function unknown_response(session, address, msg, sz)
	skynet.error(string.format("Response message : %s" , c.tostring(msg,sz)))
	error(string.format("Unknown session : %d from %x", session, address))
end

function skynet.dispatch_unknown_response(unknown)
	-- 自定义未知响应处理（通常视为逻辑错误）
	local prev = unknown_response
	unknown_response = unknown
	return prev
end

function skynet.fork(func,...)
	local n = select("#", ...)
	local co
	if n == 0 then
		co = co_create(func)
	else
		local args = { ... }
		co = co_create(function() func(table.unpack(args,1,n)) end)
	end
	local t = fork_queue.t + 1
	fork_queue.t = t
	fork_queue[t] = co
	return co
end

local trace_source = {}

local function raw_dispatch_message(prototype, msg, sz, session, source)
	-- skynet.PTYPE_RESPONSE = 1, read skynet.h
	if prototype == 1 then
		local co = session_id_coroutine[session]
		if co == "BREAK" then
			session_id_coroutine[session] = nil
		elseif co == nil then
			unknown_response(session, source, msg, sz)
		else
			local tag = session_coroutine_tracetag[co]
			if tag then c.trace(tag, "resume") end
			session_id_coroutine[session] = nil
			suspend(co, coroutine_resume(co, true, msg, sz, session))
		end
	else
		local p = proto[prototype]    -- 找到与消息类型对应的解析协议
		if p == nil then
			if prototype == skynet.PTYPE_TRACE then
				-- trace next request
				trace_source[source] = c.tostring(msg,sz)
			elseif session ~= 0 then
				c.send(source, skynet.PTYPE_ERROR, session, "")
			else
				unknown_request(session, source, msg, sz, prototype)
			end
			return
		end

		local f = p.dispatch  -- 获取消息处理函数，可以视为该类协议的消息回调函数
		if f then
			local co = co_create(f)   -- 如果协程池内有空闲的协程，则直接返回，否则创建一个新的协程，该协程用于执行该类协议的消息处理函数dispatch
			session_coroutine_id[co] = session
			session_coroutine_address[co] = source
			local traceflag = p.trace
			if traceflag == false then
				-- force off
				trace_source[source] = nil
				session_coroutine_tracetag[co] = false
			else
				local tag = trace_source[source]
				if tag then
					trace_source[source] = nil
					c.trace(tag, "request")
					session_coroutine_tracetag[co] = tag
				elseif traceflag then
					-- set running_thread for trace
					running_thread = co
					skynet.trace()
				end
			end
			suspend(co, coroutine_resume(co, session,source, p.unpack(msg,sz)))  -- 启动并执行协程，将结果返回给suspend
		else
			trace_source[source] = nil
			if session ~= 0 then
				c.send(source, skynet.PTYPE_ERROR, session, "")
			else
				unknown_request(session, source, msg, sz, proto[prototype].name)
			end
		end
	end
end

function skynet.dispatch_message(...)
	-- 1. 调用 raw_dispatch_message 处理消息
	local succ, err = pcall(raw_dispatch_message,...)
	while true do
		if fork_queue.h > fork_queue.t then
			-- queue is empty
			fork_queue.h = 1
			fork_queue.t = 0
			break
		end
		-- pop queue
		local h = fork_queue.h
		local co = fork_queue[h]
		fork_queue[h] = nil
		fork_queue.h = h + 1

		local fork_succ, fork_err = pcall(suspend,co,coroutine_resume(co))
		if not fork_succ then
			if succ then
				succ = false
				err = tostring(fork_err)
			else
				err = tostring(err) .. "\n" .. tostring(fork_err)
			end
		end
	end
	assert(succ, tostring(err))
end

function skynet.newservice(name, ...)
	return skynet.call(".launcher", "lua" , "LAUNCH", "snlua", name, ...)
end

function skynet.uniqueservice(global, ...)
	if global == true then
		return assert(skynet.call(".service", "lua", "GLAUNCH", ...))
	else
		return assert(skynet.call(".service", "lua", "LAUNCH", global, ...))
	end
end

function skynet.queryservice(global, ...)
	if global == true then
		return assert(skynet.call(".service", "lua", "GQUERY", ...))
	else
		return assert(skynet.call(".service", "lua", "QUERY", global, ...))
	end
end

function skynet.address(addr)
	if type(addr) == "number" then
		return string.format(":%08x",addr)
	else
		return tostring(addr)
	end
end

function skynet.harbor(addr)
	return c.harbor(addr)
end

skynet.error = c.error
skynet.tracelog = c.trace

-- true: force on
-- false: force off
-- nil: optional (use skynet.trace() to trace one message)
function skynet.traceproto(prototype, flag)
	-- 设置某个协议的 trace 策略：true 强开、false 强关、nil 可选（需调用 skynet.trace()）
	local p = assert(proto[prototype])
	p.trace = flag
end

----- register protocol
do
	local REG = skynet.register_protocol

	REG {
		name = "lua",
		id = skynet.PTYPE_LUA,
		pack = skynet.pack,
		unpack = skynet.unpack,
	}

	REG {
		name = "response",
		id = skynet.PTYPE_RESPONSE,
	}

	REG {
		name = "error",
		id = skynet.PTYPE_ERROR,
		unpack = function(...) return ... end,
		dispatch = _error_dispatch,
	}
end

skynet.init = skynet_require.init
-- skynet.pcall is deprecated, use pcall directly
skynet.pcall = pcall

function skynet.init_service(start)
	local function main()
		skynet_require.init_all()
		start()
	end
	local ok, err = xpcall(main, traceback)
	if not ok then
		skynet.error("init service failed: " .. tostring(err))
		skynet.send(".launcher","lua", "ERROR")
		skynet.exit()
	else
		skynet.send(".launcher","lua", "LAUNCHOK")
	end
end

function skynet.start(start_func)
	-- 步骤1: 设置消息分发回调（C 层将以此 Lua 函数作为统一入口）
	c.callback(skynet.dispatch_message)
	-- 步骤2: 创建一个 0 延迟的定时器来执行初始化（避免阻塞消息循环）
	init_thread = skynet.timeout(0, function()
		skynet.init_service(start_func)
		init_thread = nil
	end)
end

function skynet.endless()
	-- 检查当前服务是否进入无消息可处理但仍保持运行的状态
	return (c.intcommand("STAT", "endless") == 1)
end

function skynet.mqlen()
	-- 当前服务消息队列长度
	return c.intcommand("STAT", "mqlen")
end

function skynet.stat(what)
	-- 读取内部统计项（如 cpu、time 等，见 C 实现）
	return c.intcommand("STAT", what)
end

local function task_traceback(co)
	if co == "BREAK" then
		return co
	elseif timeout_traceback and timeout_traceback[co] then
		return timeout_traceback[co]
	else
		return traceback(co)
	end
end

function skynet.task(ret)
	-- 任务/协程观测工具：
	--  - 无参返回当前挂起的协程数量
	--  - "init" 返回初始化线程的 traceback
	--  - table 填充 { "co session: x" = traceback }
	--  - number 以 session 定位协程栈
	--  - thread 以协程定位 session
	if ret == nil then
		local t = 0
		for _,co in pairs(session_id_coroutine) do
			if co ~= "BREAK" then
				t = t + 1
			end
		end
		return t
	end
	if ret == "init" then
		if init_thread then
			return traceback(init_thread)
		else
			return
		end
	end
	local tt = type(ret)
	if tt == "table" then
		for session,co in pairs(session_id_coroutine) do
			local key = string.format("%s session: %d", tostring(co), session)
			ret[key] = task_traceback(co)
		end
		return
	elseif tt == "number" then
		local co = session_id_coroutine[ret]
		if co then
			return task_traceback(co)
		else
			return "No session"
		end
	elseif tt == "thread" then
		for session, co in pairs(session_id_coroutine) do
			if co == ret then
				return session
			end
		end
		return
	end
end

function skynet.uniqtask()
	-- 归并相同堆栈的协程，输出相同调用栈的会话分布与数量
	local stacks = {}
	for session, co in pairs(session_id_coroutine) do
		local stack = task_traceback(co)
		local info = stacks[stack] or {count = 0, sessions = {}}
		info.count = info.count + 1
		if info.count < 10 then
			info.sessions[#info.sessions+1] = session
		end
		stacks[stack] = info
	end
	local ret = {}
	for stack, info in pairs(stacks) do
		local count = info.count
		local sessions = table.concat(info.sessions, ",")
		if count > 10 then
			sessions = sessions .. "..."
		end
		local head_line = string.format("%d\tsessions:[%s]\n", count, sessions)
		ret[head_line] = stack
	end
	return ret
end

function skynet.term(service)
	-- 向本服务注入“错误分发”，模拟 service 宕机，触发本地清理流程（用于测试）
	return _error_dispatch(0, service)
end

function skynet.memlimit(bytes)
	-- 设置 Lua 内存上限（仅能设置一次）
	debug.getregistry().memlimit = bytes
	skynet.memlimit = nil	-- set only once
end

-- Inject internal debug framework
local debug = require "skynet.debug"
-- 将内部调试工具注入当前框架，实现外部调试命令（如查看任务栈）
debug.init(skynet, {
	dispatch = skynet.dispatch_message,
	suspend = suspend,
	resume = coroutine_resume,
})

return skynet
