-- 说明：
--  cmemory 打印进程内 Lua/C 内存信息后退出：
--   - memory.dumpinfo(): 输出各服务内存统计
--   - memory.info(): 返回以服务地址为键的当前内存字节数
--   - total/block：总占用与块数
local skynet = require "skynet"
local memory = require "skynet.memory"

memory.dumpinfo()
--memory.dump()
local info = memory.info()
for k,v in pairs(info) do
	print(string.format(":%08x %gK",k,v/1024))
end

print("Total memory:", memory.total())
print("Total block:", memory.block())

skynet.start(function() skynet.exit() end)
