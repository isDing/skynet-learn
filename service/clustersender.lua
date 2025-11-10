-- 说明：
--  clustersender 负责与远端节点保持 socketchannel 连接：
--   - 接收 clusterd 的 changenode 指令切换连接/关闭
--   - 承担 req/push 的序列化与发送，并处理 trace
local skynet = require "skynet"
local sc = require "skynet.socketchannel"
local socket = require "skynet.socket"
local cluster = require "skynet.cluster.core"

local channel
local session = 1
local node, nodename, init_host, init_port = ...

local command = {}

-- 序列化并发送请求：支持 trace id 透传
local function send_request(addr, msg, sz)
	-- msg is a local pointer, cluster.packrequest will free it
	local current_session = session
	local request, new_session, padding = cluster.packrequest(addr, session, msg, sz)
	session = new_session

	local tracetag = skynet.tracetag()
	if tracetag then
		if tracetag:sub(1,1) ~= "(" then
			-- add nodename
			local newtag = string.format("(%s-%s-%d)%s", nodename, node, session, tracetag)
			skynet.tracelog(tracetag, string.format("session %s", newtag))
			tracetag = newtag
		end
		skynet.tracelog(tracetag, string.format("cluster %s", node))
		channel:request(cluster.packtrace(tracetag))
	end
	return channel:request(request, current_session, padding)
end

function command.req(...)
    -- 处理有响应的请求
	local ok, msg = pcall(send_request, ...)
	if ok then
		if type(msg) == "table" then
			skynet.ret(cluster.concat(msg))
		else
			skynet.ret(msg)
		end
	else
		skynet.error(msg)
		skynet.response()(false)
	end
end

function command.push(addr, msg, sz)
    -- 无响应 push（可能为多段请求）
	local request, new_session, padding = cluster.packpush(addr, session, msg, sz)
	if padding then	-- is multi push
		session = new_session
	end

	channel:request(request, nil, padding)
end

-- socketchannel 的 response 解析函数
local function read_response(sock)
	local sz = socket.header(sock:read(2))
	local msg = sock:read(sz)
	return cluster.unpackresponse(msg)	-- session, ok, data, padding
end

-- 切换/关闭连接：host=nil/false 表示关闭
function command.changenode(host, port)
	if not host then
		skynet.error(string.format("Close cluster sender %s:%d", channel.__host, channel.__port))
		channel:close()
	else
		channel:changehost(host, tonumber(port))
		channel:connect(true)
	end
	skynet.ret(skynet.pack(nil))
end

skynet.start(function()
	channel = sc.channel {
			host = init_host,
			port = tonumber(init_port),
			response = read_response,
			nodelay = true,
		}
	skynet.dispatch("lua", function(session , source, cmd, ...)
		local f = assert(command[cmd])
		f(...)
	end)
end)
