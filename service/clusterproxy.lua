-- 说明：
--  clusterproxy 作为远端服务的本地“代理”：
--   - 将本地收到的 lua/snax 请求统一转为 system 协议，交由 clusterd 的 sender 转发
--   - forward_map 映射响应协议，避免释放 response 数据
--   - 通过 skynet.forward_type 注入映射关系
local skynet = require "skynet"
local cluster = require "skynet.cluster"
require "skynet.manager"	-- inject skynet.forward_type

local node, address = ...

skynet.register_protocol {
	name = "system",
	id = skynet.PTYPE_SYSTEM,
	unpack = function (...) return ... end,
}

local forward_map = {
	[skynet.PTYPE_SNAX] = skynet.PTYPE_SYSTEM,
	[skynet.PTYPE_LUA] = skynet.PTYPE_SYSTEM,
	[skynet.PTYPE_RESPONSE] = skynet.PTYPE_RESPONSE,	-- don't free response message
}

skynet.forward_type( forward_map ,function()
	local clusterd = skynet.uniqueservice("clusterd")
	local n = tonumber(address)
	if n then
		address = n
	end
	local sender = skynet.call(clusterd, "lua", "sender", node)
	skynet.dispatch("system", function (session, source, msg, sz)
		if session == 0 then
			skynet.send(sender, "lua", "push", address, msg, sz)
		else
			skynet.ret(skynet.rawcall(sender, "lua", skynet.pack("req", address, msg, sz)))
		end
	end)
end)
