-- 说明：
--  http.sockethelper 为 httpc/httpd 提供底层读写工具：
--   - readfunc/writefunc：包装 fd 的读写，失败抛出统一 socket_error
--   - connect(host,port,timeout)：支持可选超时的连接（超时后 shutdown）
--   - close/shutdown：关闭或半关闭 fd
--  流程概览：
--   connect(host, port, timeout)
--    1) 若设置 timeout：fork 异步 socket.open；当前协程 sleep(timeout)
--    2) 若超时且还未连上：标记 drop_fd=true，待异步返回时立即关闭该 fd（避免泄漏）
--    3) 若在超时前连上：wakeup 当前协程；后续按协议使用 readfunc/writefunc
--   readfunc(fd, pre?)
--    - 支持预读 pre：优先消费预读缓存，再按需补齐底层读取（用于 HTTP 已读取片段的复用）
--   socket_error
--    - 统一错误对象，可携带上下文信息；上层可通过捕获该对象进行连接生命周期控制
local socket = require "skynet.socket"
local skynet = require "skynet"

local coroutine = coroutine
local error = error
local tostring = tostring

local readbytes = socket.read
local writebytes = socket.write

local sockethelper = {}
local socket_error = setmetatable({} , { 
	__tostring = function(self)
		local info = self.err_info
		self.err_info = nil
		return info or "[Socket Error]"
	end,

	__call = function (self, info)
		self.err_info = "[Socket Error] : " .. tostring(info)
		return self
	end
})

sockethelper.socket_error = socket_error

-- 预读封装：优先消费 prebuffer，再按需补齐读取
local function preread(fd, str)
	return function (sz)
		if str then
			if sz == #str or sz == nil then
				local ret = str
				str = nil
				return ret
			else
				if sz < #str then
					local ret = str:sub(1,sz)
					str = str:sub(sz + 1)
					return ret
				else
					sz = sz - #str
					local ret = readbytes(fd, sz)
					if ret then
						return str .. ret
					else
						error(socket_error("read failed fd = " .. fd))
					end
				end
			end
		else
			local ret = readbytes(fd, sz)
			if ret then
				return ret
			else
				error(socket_error("read failed fd = " .. fd))
			end
		end
	end
end

function sockethelper.readfunc(fd, pre)
	if pre then
		return preread(fd, pre)
	end
	return function (sz)
		local ret = readbytes(fd, sz)
		if ret then
			return ret
		else
			-- 统一错误对象，便于上层捕获与处理
			error(socket_error("read failed fd = " .. fd))
		end
	end
end

sockethelper.readall = socket.readall

function sockethelper.writefunc(fd)
	return function(content)
		local ok = writebytes(fd, content)
		if not ok then
			error(socket_error("write failed fd = " .. fd))
		end
	end
end

function sockethelper.connect(host, port, timeout)
	local fd, err
	local is_time_out = false
	if timeout then
		-- 带超时的连接：fork 异步 connect，并在超时后半关闭（避免 fd 悬挂）
		is_time_out = true
		local drop_fd
		local co = coroutine.running()
		-- asynchronous connect 1) 异步连接
		skynet.fork(function()
			fd, err = socket.open(host, port)
			if drop_fd then
				-- sockethelper.connect already return, and raise socket_error 已经超时返回：立即关闭刚建立的 fd，交由上层重试
				socket.close(fd)
			else
				-- socket.open before sleep, wakeup. 未超时：唤醒等待的协程
				is_time_out = false
				skynet.wakeup(co)
			end
		end)
		-- 2) 等待 timeout 个 tick（1 tick = 10ms）
		skynet.sleep(timeout)
		if not fd then
			-- not connect yet 仍未连接：标记 drop_fd，稍后异步连接成功需立刻关闭
			drop_fd = true
		end
	else
		is_time_out = false
		-- block connect
		fd = socket.open(host, port)
	end
	if fd then
		return fd
	end
	-- 连接失败：统一化错误信息，包含 host/port/timeout/err/is_time_out
	error(socket_error("connect failed host = " .. host .. ' port = '.. port .. ' timeout = ' .. tostring(timeout) .. ' err = ' .. tostring(err) .. ' is_time_out = '.. tostring(is_time_out)))
end

function sockethelper.close(fd)
	socket.close(fd)
end

function sockethelper.shutdown(fd)
	socket.shutdown(fd)
end

return sockethelper
