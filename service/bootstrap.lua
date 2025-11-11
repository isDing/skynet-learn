local service = require "skynet.service"
local skynet = require "skynet.manager"	-- import skynet.launch, ...

skynet.start(function()
	local standalone = skynet.getenv "standalone"

	local launcher = assert(skynet.launch("snlua","launcher"))
	skynet.name(".launcher", launcher)

	-- harbor 模式：
	--  - harbor=0 ：单机模式（cdummy 作为 .cslave），不需要 master/address
	--  - harbor>0：分布式模式；若 standalone=true，同步启动 cmaster；始终启动 cslave
	local harbor_id = tonumber(skynet.getenv "harbor" or 0)
	if harbor_id == 0 then
		assert(standalone ==  nil)
		standalone = true
		skynet.setenv("standalone", "true")

		-- 单节点（harbor=0）：启动 cdummy 并命名 .cslave
		local ok, slave = pcall(skynet.newservice, "cdummy")
		if not ok then
			skynet.abort()
		end
		skynet.name(".cslave", slave)

	else
		-- 分布式（harbor>0）：按需启动 cmaster（standalone=true 时），启动 cslave 并命名 .cslave
		if standalone then
			if not pcall(skynet.newservice,"cmaster") then
				skynet.abort()
			end
		end

		local ok, slave = pcall(skynet.newservice, "cslave")
		if not ok then
			skynet.abort()
		end
		skynet.name(".cslave", slave)
	end

	if standalone then
		local datacenter = skynet.newservice "datacenterd"
		skynet.name("DATACENTER", datacenter)
	end
	skynet.newservice "service_mgr"

	-- 可选：开启 ltls_holder（用于共享 TLS 环境）
	local enablessl = skynet.getenv "enablessl"
	if enablessl == "true" then
		service.new("ltls_holder", function ()
			local c = require "ltls.init.c"
			c.constructor()
		end)
	end

	pcall(skynet.newservice,skynet.getenv "start" or "main")
	skynet.exit()
end)
