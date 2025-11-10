-- 说明：
--  skynet.debug 提供一组内置调试命令（通过 PTYPE_DEBUG 协议），
--  支持内存查看/GC、任务/消息队列统计、杀协程、注入代码、远程调试、trace 开关等。
--  调试命令由外部通过 skynet.call(..., "debug", cmd, ...) 触发。
local table = table
local extern_dbgcmd = {}

-- 初始化调试协议：注册 "debug" 协议并注入调度/挂起/恢复接口
local function init(skynet, export)
	local internal_info_func

	-- 注册一个信息采集函数，供 INFO 命令回调
	function skynet.info_func(func)
		internal_info_func = func
	end

	local dbgcmd

	-- 延迟初始化调试命令（首次收到 debug 消息时构建）
	local function init_dbgcmd()
		dbgcmd = {}

		-- 返回当前 Lua VM 占用内存（KB）
		function dbgcmd.MEM()
			local kb = collectgarbage "count"
			skynet.ret(skynet.pack(kb))
		end

		local gcing = false
		-- 触发一次 GC 并打印花费
		function dbgcmd.GC()
			if gcing then
				return
			end
			gcing = true
			local before = collectgarbage "count"
			local before_time = skynet.now()
			collectgarbage "collect"
			-- skip subsequent GC message
			skynet.yield()
			local after = collectgarbage "count"
			local after_time = skynet.now()
			skynet.error(string.format("GC %.2f Kb -> %.2f Kb, cost %.2f sec", before, after, (after_time - before_time) / 100))
			gcing = false
		end

		-- 返回任务数、消息队列长度、CPU 占用、消息数等统计信息
		function dbgcmd.STAT()
			local stat = {}
			stat.task = skynet.task()
			stat.mqlen = skynet.stat "mqlen"
			stat.cpu = skynet.stat "cpu"
			stat.message = skynet.stat "message"
			skynet.ret(skynet.pack(stat))
		end

		-- 按 thread 名称（tostring(co) 片段）或协程句柄杀死协程
		function dbgcmd.KILLTASK(threadname)
			local co = skynet.killthread(threadname)
			if co then
				skynet.error(string.format("Kill %s", co))
				skynet.ret()
			else
				skynet.error(string.format("Kill %s : Not found", threadname))
				skynet.ret(skynet.pack "Not found")
			end
		end

		-- TASK：
		--  - 无参返回任务概览（表）
		--  - 指定 session 返回对应任务栈
		function dbgcmd.TASK(session)
			if session then
				skynet.ret(skynet.pack(skynet.task(session)))
			else
				local task = {}
				skynet.task(task)
				skynet.ret(skynet.pack(task))
			end
		end

		-- 返回按照堆栈归并后的任务统计
		function dbgcmd.UNIQTASK()
			skynet.ret(skynet.pack(skynet.uniqtask()))
		end

		-- 调用前面通过 skynet.info_func 注册的回调，返回自定义服务信息
		function dbgcmd.INFO(...)
			if internal_info_func then
				skynet.ret(skynet.pack(internal_info_func(...)))
			else
				skynet.ret(skynet.pack(nil))
			end
		end

		-- 退出当前服务
		function dbgcmd.EXIT()
			skynet.exit()
		end

		-- 在目标服务上下文中注入并运行一段 Lua 代码（文件）
		function dbgcmd.RUN(source, filename, ...)
			local inject = require "skynet.inject"
			local args = table.pack(...)
			local ok, output = inject(skynet, source, filename, args, export.dispatch, skynet.register_protocol)
			collectgarbage "collect"
			skynet.ret(skynet.pack(ok, table.concat(output, "\n")))
		end

		-- 向本服务注入“错误分发”（见 skynet.term），用于模拟被监控服务宕机场景
		function dbgcmd.TERM(service)
			skynet.term(service)
		end

		-- 启动远程调试（参见 lualib/skynet/remotedebug.lua）
		function dbgcmd.REMOTEDEBUG(...)
			local remotedebug = require "skynet.remotedebug"
			remotedebug.start(export, ...)
		end

		-- 检查协议是否已注册分发函数
		function dbgcmd.SUPPORT(pname)
			return skynet.ret(skynet.pack(skynet.dispatch(pname) ~= nil))
		end

		-- 心跳
		function dbgcmd.PING()
			return skynet.ret()
		end

		-- 建立持久链接：仅获取响应但不返回（仍保持 session 占用）
		function dbgcmd.LINK()
			skynet.response()	-- get response , but not return. raise error when exit
		end

		-- 控制协议的 trace：proto 缺省为 "lua"；flag=true/false/nil
		function dbgcmd.TRACELOG(proto, flag)
			if type(proto) ~= "string" then
				flag = proto
				proto = "lua"
			end
			skynet.error(string.format("Turn trace log %s for %s", flag, proto))
			skynet.traceproto(proto, flag)
			skynet.ret()
		end

		return dbgcmd
	end -- function init_dbgcmd

	-- debug 协议的分发函数：按 cmd 分派
	local function _debug_dispatch(session, address, cmd, ...)
		dbgcmd = dbgcmd or init_dbgcmd() -- lazy init dbgcmd
		local f = dbgcmd[cmd] or extern_dbgcmd[cmd]
		assert(f, cmd)
		f(...)
	end

	-- 注册 debug 协议
	skynet.register_protocol {
		name = "debug",
		id = assert(skynet.PTYPE_DEBUG),
		pack = assert(skynet.pack),
		unpack = assert(skynet.unpack),
		dispatch = _debug_dispatch,
	}
end

-- 注册自定义的调试命令（可被其他模块扩展）
local function reg_debugcmd(name, fn)
	extern_dbgcmd[name] = fn
end

return {
	init = init,
	reg_debugcmd = reg_debugcmd,
}
