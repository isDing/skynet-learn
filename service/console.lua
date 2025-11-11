-- 说明：
--  console 服务从标准输入读取命令：
--   - `snax <name> [args...]` 启动 snax 服务
--   - 其他非空行按 `skynet.newservice` 启动
--  用于简单启动脚本/手动测试，不适合作为生产控制入口（无鉴权、无权限控制）。
--  注意：读取自 stdin 的实现依赖 socket.stdin() 提供的伪 fd，适合 "./skynet examples/config" 场景快速验证。
local skynet = require "skynet"
local snax   = require "skynet.snax"
local socket = require "skynet.socket"

local function split_cmdline(cmdline)
	local split = {}
	for i in string.gmatch(cmdline, "%S+") do
		table.insert(split,i)
	end
	return split
end

local function console_main_loop()
	local stdin = socket.stdin()
	while true do
		local cmdline = socket.readline(stdin, "\n")
		-- 按空白拆分命令行，支持简单的空格分隔参数
		local split = split_cmdline(cmdline)
		local command = split[1]
		if command == "snax" then
			pcall(snax.newservice, select(2, table.unpack(split)))
		elseif cmdline ~= "" then
			pcall(skynet.newservice, cmdline)
		end
	end
end

skynet.start(function()
	skynet.fork(console_main_loop)
end)
