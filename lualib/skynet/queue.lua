-- 说明：
--  本模块提供协程级的串行化执行队列（临界区），用于避免并发访问共享资源。
--  用法：
--    local q = skynet.queue()
--    q(function()  -- 进入临界区
--      -- 临界区代码
--    end)
--  特点：
--    - 相同队列下的多个调用严格顺序执行
--    - 支持嵌套（ref 计数）
local skynet = require "skynet"
local coroutine = coroutine
local xpcall = xpcall
local traceback = debug.traceback
local table = table

function skynet.queue()
	-- 当前正在执行的协程（持有临界区的“锁”）
	local current_thread
	local ref = 0
	local thread_queue = {}

	local function xpcall_ret(ok, ...)
		ref = ref - 1
		if ref == 0 then
			current_thread = table.remove(thread_queue,1)
			if current_thread then
				skynet.wakeup(current_thread)
			end
		end
		assert(ok, (...))
		return ...
	end

	return function(f, ...)
		-- 若已有协程持有“锁”，则将当前协程排队并等待唤醒
		local thread = coroutine.running()
		if current_thread and current_thread ~= thread then
			table.insert(thread_queue, thread)
			skynet.wait()
			assert(ref == 0)	-- current_thread == thread
		end
		current_thread = thread

		-- 进入临界区（支持嵌套），异常由 xpcall_ret 统一处理
		ref = ref + 1
		return xpcall_ret(xpcall(f, traceback, ...))
	end
end

return skynet.queue
