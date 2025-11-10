-- 说明：
--  dbg 是一个一次性的小工具服务：
--   - 将命令参数转发给 .launcher（例如 LIST/MEM/STAT 等）
--   - 将结果打印到标准输出并退出
local skynet = require "skynet"

local cmd = { ... }

local function format_table(t)
	local index = {}
	for k in pairs(t) do
		table.insert(index, k)
	end
	table.sort(index)
	local result = {}
	for _,v in ipairs(index) do
		table.insert(result, string.format("%s:%s",v,tostring(t[v])))
	end
	return table.concat(result,"\t")
end

local function dump_line(key, value)
	if type(value) == "table" then
		print(key, format_table(value))
	else
		print(key,tostring(value))
	end
end

local function dump_list(list)
	local index = {}
	for k in pairs(list) do
		table.insert(index, k)
	end
	table.sort(index)
	for _,v in ipairs(index) do
		dump_line(v, list[v])
	end
end

skynet.start(function()
	local list = skynet.call(".launcher","lua", table.unpack(cmd))
	if list then
		dump_list(list)
	end
	skynet.exit()
end)
