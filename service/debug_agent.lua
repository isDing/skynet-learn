-- 说明：
--  debug_agent 是 debug_console 与目标服务之间的“调试通道代理”：
--   - start(address, fd)：在目标服务上触发 REMOTEDEBUG，建立双向通道
--   - cmd(cmdline)：向目标服务写入调试命令
--   - ping()：探活
--  创建完成后本服务立即退出（通道由目标服务持有）。
local skynet = require "skynet"
local debugchannel = require "skynet.debugchannel"

local CMD = {}

local channel

function CMD.start(address, fd)
	assert(channel == nil, "start more than once")
	skynet.error(string.format("Attach to :%08x", address))
	local handle
	channel, handle = debugchannel.create()
	local ok, err = pcall(skynet.call, address, "debug", "REMOTEDEBUG", fd, handle)
	if not ok then
		skynet.ret(skynet.pack(false, "Debugger attach failed"))
	else
		-- todo hook
		skynet.ret(skynet.pack(true))
	end
	skynet.exit()
end

function CMD.cmd(cmdline)
	channel:write(cmdline)
end

function CMD.ping()
	skynet.ret()
end

skynet.start(function()
	skynet.dispatch("lua", function(_,_,cmd,...)
		local f = CMD[cmd]
		f(...)
	end)
end)
