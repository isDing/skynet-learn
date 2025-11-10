-- 说明：
--  service_cell 是被 service_provider 启动的“单元服务容器”：
--   - 接收 init(code, ...) 指令，按传入字节码加载并执行
--   - 在 init 执行期捕获 skynet.start 注册的启动函数并调用
--   - 提供默认的 lua 协议分发（未注册 dispatch 会报错）
local skynet = require "skynet"

local service_name = (...)
local init = {}

function init.init(code, ...)
	local start_func
	skynet.start = function(f)
		start_func = f
	end
	skynet.dispatch("lua", function() error("No dispatch function")	end)
	local mainfunc = assert(load(code, service_name))
	assert(skynet.pcall(mainfunc,...))
	if start_func then
		start_func()
	end
	skynet.ret()
end

skynet.start(function()
	skynet.dispatch("lua", function(_,_,cmd,...)
		init[cmd](...)
	end)
end)
