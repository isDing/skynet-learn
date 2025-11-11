-- 说明：
--  http.tlshelper 为 httpc/websocket 等模块提供 TLS (SSL) I/O 适配：
--   - 将明文 socket 的 read/write/readall 封装为 TLS 会话读写
--   - 提供客户端与服务端握手流程（init_requestfunc / init_responsefunc）
--   - 统一 close 行为，释放底层 TLS 上下文
--  设计要点（KISS/YAGNI）：
--   - 不参与套接字生命周期管理，仅按需读写转换（职责单一）
--   - 只暴露当前用到的 API，不预留多余扩展点
--   - 读路径内部做最小缓冲，避免重复拷贝（DRY/性能）
local socket = require "http.sockethelper"
local c = require "ltls.c"

local tlshelper = {}

-- 客户端握手：
--  1) 设置 SNI（Server Name Indication）
--  2) 调用 tls_ctx:handshake() 生成待发送的 TLS record，写入网络
--  3) 循环：读取服务端 record → 传入 handshake(ds) → 若返回待发数据则继续写入
--  4) 直至 tls_ctx:finished()
function tlshelper.init_requestfunc(fd, tls_ctx)
    local readfunc = socket.readfunc(fd)
    local writefunc = socket.writefunc(fd)
    return function (hostname)
        tls_ctx:set_ext_host_name(hostname)
        local ds1 = tls_ctx:handshake()
        writefunc(ds1)
        while not tls_ctx:finished() do
            local ds2 = readfunc()
            local ds3 = tls_ctx:handshake(ds2)
            if ds3 then
                writefunc(ds3)
            end
        end
    end
end


-- 服务端握手：
--  1) 循环读取客户端 record → handshake(ds)
--  2) 若 handshake 返回待写数据则写出
--  3) 完成后调用 tls_ctx:write() 发送 ChangeCipherSpec/Finished 等尾包
function tlshelper.init_responsefunc(fd, tls_ctx)
    local readfunc = socket.readfunc(fd)
    local writefunc = socket.writefunc(fd)
    return function ()
        while not tls_ctx:finished() do
            local ds1 = readfunc()
            local ds2 = tls_ctx:handshake(ds1)
            if ds2 then
                writefunc(ds2)
            end
        end
        local ds3 = tls_ctx:write()
        writefunc(ds3)
    end
end

-- 关闭 TLS 上下文（与 socket.close 分离，保持单一职责）
function tlshelper.closefunc(tls_ctx)
    return function ()
        tls_ctx:close()
    end
end

-- TLS 读取：
--  - 外层 readfunc 每次从 fd 取一帧密文，交给 tls_ctx:read 解密
--  - 提供带大小（sz）与读尽（nil）的两种模式
--  - 使用 read_buff 临时缓存，满足按需拼接与截断
function tlshelper.readfunc(fd, tls_ctx)
    local function readfunc()
        readfunc = socket.readfunc(fd)
        return ""
    end
    local read_buff = ""
    return function (sz)
        if not sz then
            local s = ""
            if #read_buff == 0 then
                local ds = readfunc()
                s = tls_ctx:read(ds)
            end
            s = read_buff .. s
            read_buff = ""
            return s
        else
            while #read_buff < sz do
                local ds = readfunc()
                local s = tls_ctx:read(ds)
                read_buff = read_buff .. s
            end
            local  s = string.sub(read_buff, 1, sz)
            read_buff = string.sub(read_buff, sz+1, #read_buff)
            return s
        end
    end
end

-- TLS 写：调用 tls_ctx:write 生成密文 record 后写入 fd
function tlshelper.writefunc(fd, tls_ctx)
    local writefunc = socket.writefunc(fd)
    return function (s)
        local ds = tls_ctx:write(s)
        return writefunc(ds)
    end
end

-- 读尽所有数据：先读尽 fd 密文，再一次性解密返回
function tlshelper.readallfunc(fd, tls_ctx)
    return function ()
        local ds = socket.readall(fd)
        local s = tls_ctx:read(ds)
        return s
    end
end

-- 创建 TLS 全局上下文（客户端/服务端共用的 SSL_CTX）
function tlshelper.newctx()
    return c.newctx()
end

-- 创建 TLS 会话（握手状态机）
function tlshelper.newtls(method, ssl_ctx, hostname)
    return c.newtls(method, ssl_ctx, hostname)
end

return tlshelper
