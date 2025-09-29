# Skynet C-Lua桥接层 - Lua C扩展模块 (Lua C Extensions)

## 模块概述

Lua C 扩展模块是 Skynet 框架中连接 C 层和 Lua 层的关键组件。这些扩展为 Lua 提供了高性能的底层功能访问，包括核心 API、网络操作、序列化、加密等功能。通过精心设计的 C 接口，实现了高效的数据交换和功能调用。

### 模块定位
- **层次**：C-Lua 桥接层
- **作用**：为 Lua 层提供高性能的底层功能
- **特点**：零拷贝设计、内存池管理、高效序列化

## 核心扩展模块

### 1. Skynet 核心 API (lua-skynet.c)

#### 1.1 功能概述

lua-skynet 模块是 Lua 层访问 Skynet 核心功能的主要接口，提供了消息发送、服务管理、回调设置等核心能力。

#### 1.2 消息发送机制

```c
// 发送消息的核心函数
static int send_message(lua_State *L, int source, int idx_type) {
    struct skynet_context * context = lua_touserdata(L, lua_upvalueindex(1));
    uint32_t dest = (uint32_t)lua_tointeger(L, 1);
    const char * dest_string = NULL;
    
    // 支持数字地址和字符串地址
    if (dest == 0) {
        if (lua_type(L,1) == LUA_TNUMBER) {
            return luaL_error(L, "Invalid service address 0");
        }
        dest_string = get_dest_string(L, 1);  // 如 ".launcher"
    }
    
    int type = luaL_checkinteger(L, idx_type+0);
    int session = 0;
    
    // 自动分配 session
    if (lua_isnil(L,idx_type+1)) {
        type |= PTYPE_TAG_ALLOCSESSION;
    } else {
        session = luaL_checkinteger(L,idx_type+1);
    }
    
    // 处理不同类型的消息
    int mtype = lua_type(L,idx_type+2);
    switch (mtype) {
    case LUA_TSTRING: {
        // 字符串消息
        size_t len = 0;
        void * msg = (void *)lua_tolstring(L,idx_type+2,&len);
        if (dest_string) {
            session = skynet_sendname(context, source, dest_string, 
                                    type, session, msg, len);
        } else {
            session = skynet_send(context, source, dest, 
                                type, session, msg, len);
        }
        break;
    }
    case LUA_TLIGHTUSERDATA: {
        // 轻量用户数据（零拷贝）
        void * msg = lua_touserdata(L,idx_type+2);
        int size = luaL_checkinteger(L,idx_type+3);
        type |= PTYPE_TAG_DONTCOPY;  // 标记不拷贝
        // 发送消息...
        break;
    }
    }
    
    lua_pushinteger(L, session);
    return 1;
}
```

#### 1.3 回调机制实现

```c
// 回调上下文
struct callback_context {
    lua_State *L;  // Lua 协程状态
};

// 消息回调处理
static int _cb(struct skynet_context * context, void * ud, 
               int type, int session, uint32_t source, 
               const void * msg, size_t sz) {
    struct callback_context *cb_ctx = (struct callback_context *)ud;
    lua_State *L = cb_ctx->L;
    
    // 压入回调函数
    lua_pushvalue(L, 2);
    
    // 压入参数
    lua_pushinteger(L, type);        // 消息类型
    lua_pushlightuserdata(L, (void *)msg);  // 消息内容
    lua_pushinteger(L, sz);          // 消息大小
    lua_pushinteger(L, session);     // 会话 ID
    lua_pushinteger(L, source);      // 源服务
    
    // 调用 Lua 函数
    int r = lua_pcall(L, 5, 0, 1);  // 1 是 traceback 函数索引
    
    if (r != LUA_OK) {
        // 错误处理
        const char * self = skynet_command(context, "REG", NULL);
        skynet_error(context, "lua call [%x to %s : %d] error : %s", 
                    source, self, session, lua_tostring(L,-1));
    }
    
    return 0;
}

// 设置回调
static int lcallback(lua_State *L) {
    struct skynet_context * context = lua_touserdata(L, lua_upvalueindex(1));
    int forward = lua_toboolean(L, 2);
    
    luaL_checktype(L, 1, LUA_TFUNCTION);
    
    // 创建回调上下文
    struct callback_context * cb_ctx = lua_newuserdatauv(L, sizeof(*cb_ctx), 2);
    cb_ctx->L = lua_newthread(L);  // 创建新协程
    
    // 设置 traceback
    lua_pushcfunction(cb_ctx->L, traceback);
    lua_setiuservalue(L, -2, 1);
    
    // 移动回调函数到新协程
    lua_xmove(L, cb_ctx->L, 1);
    
    // 注册回调
    skynet_callback(context, cb_ctx, forward ? forward_cb : _cb);
    
    return 0;
}
```

#### 1.4 服务命令接口

```c
// 执行命令
static int lcommand(lua_State *L) {
    struct skynet_context * context = lua_touserdata(L, lua_upvalueindex(1));
    const char * cmd = luaL_checkstring(L, 1);
    const char * parm = NULL;
    
    if (lua_gettop(L) == 2) {
        parm = luaL_checkstring(L, 2);
    }
    
    const char * result = skynet_command(context, cmd, parm);
    if (result) {
        lua_pushstring(L, result);
        return 1;
    }
    return 0;
}

// 地址解析命令
static int laddresscommand(lua_State *L) {
    struct skynet_context * context = lua_touserdata(L, lua_upvalueindex(1));
    const char * result = skynet_command(context, cmd, parm);
    
    // 解析 ":01000010" 格式的地址
    if (result && result[0] == ':') {
        uint32_t addr = 0;
        for (int i=1; result[i]; i++) {
            int c = result[i];
            if (c>='0' && c<='9') {
                c = c - '0';
            } else if (c>='a' && c<='f') {
                c = c - 'a' + 10;
            } else if (c>='A' && c<='F') {
                c = c - 'A' + 10;
            }
            addr = addr * 16 + c;
        }
        lua_pushinteger(L, addr);
        return 1;
    }
    return 0;
}
```

### 2. Socket 缓冲区管理 (lua-socket.c)

#### 2.1 缓冲区数据结构

```c
// 缓冲区节点
struct buffer_node {
    char * msg;                 // 消息数据
    int sz;                    // 数据大小
    struct buffer_node *next;  // 下一个节点
};

// Socket 缓冲区
struct socket_buffer {
    int size;                   // 总大小
    int offset;                // 当前偏移
    struct buffer_node *head;  // 头节点
    struct buffer_node *tail;  // 尾节点
};
```

#### 2.2 内存池管理

```c
// 创建内存池
static int lnewpool(lua_State *L, int sz) {
    struct buffer_node * pool = lua_newuserdatauv(L, 
                                    sizeof(struct buffer_node) * sz, 0);
    
    // 初始化节点链表
    for (int i=0; i<sz; i++) {
        pool[i].msg = NULL;
        pool[i].sz = 0;
        pool[i].next = &pool[i+1];
    }
    pool[sz-1].next = NULL;
    
    // 设置元表和 GC
    if (luaL_newmetatable(L, "buffer_pool")) {
        lua_pushcfunction(L, lfreepool);
        lua_setfield(L, -2, "__gc");
    }
    lua_setmetatable(L, -2);
    
    return 1;
}

// 内存池动态扩展策略
static int lpushbuffer(lua_State *L) {
    struct socket_buffer *sb = lua_touserdata(L, 1);
    char * msg = lua_touserdata(L, 3);
    int sz = luaL_checkinteger(L, 4);
    
    // 获取空闲节点
    lua_rawgeti(L, 2, 1);  // pool[1] 是空闲节点链表头
    struct buffer_node * free_node = lua_touserdata(L, -1);
    lua_pop(L, 1);
    
    if (free_node == NULL) {
        // 需要扩展内存池
        int tsz = lua_rawlen(L, 2);
        if (tsz == 0) tsz++;
        
        // 指数增长策略：8, 16, 32, ... 最大 4096
        int size = 8;
        if (tsz <= LARGE_PAGE_NODE-3) {
            size <<= tsz;
        } else {
            size <<= LARGE_PAGE_NODE-3;  // 4096
        }
        
        lnewpool(L, size);
        free_node = lua_touserdata(L, -1);
        lua_rawseti(L, 2, tsz+1);  // 存入 pool 表
        
        if (tsz > POOL_SIZE_WARNING) {
            skynet_error(NULL, "Too many socket pool (%d)", tsz);
        }
    }
    
    // 使用节点
    free_node->msg = msg;
    free_node->sz = sz;
    
    // 加入缓冲区链表
    if (sb->head == NULL) {
        sb->head = sb->tail = free_node;
    } else {
        sb->tail->next = free_node;
        sb->tail = free_node;
    }
    
    return 1;
}
```

#### 2.3 高效数据读取

```c
// 弹出指定大小的数据
static void pop_lstring(lua_State *L, struct socket_buffer *sb, 
                        int sz, int skip) {
    struct buffer_node * current = sb->head;
    
    // 优化：数据在单个节点内
    if (sz < current->sz - sb->offset) {
        lua_pushlstring(L, current->msg + sb->offset, sz-skip);
        sb->offset += sz;
        return;
    }
    
    // 优化：正好消耗完一个节点
    if (sz == current->sz - sb->offset) {
        lua_pushlstring(L, current->msg + sb->offset, sz-skip);
        return_free_node(L, 2, sb);
        return;
    }
    
    // 跨节点读取
    luaL_Buffer b;
    luaL_buffinitsize(L, &b, sz);
    
    for (;;) {
        int bytes = current->sz - sb->offset;
        if (bytes >= sz) {
            if (sz > skip) {
                luaL_addlstring(&b, current->msg + sb->offset, sz - skip);
            }
            sb->offset += sz;
            if (bytes == sz) {
                return_free_node(L, 2, sb);
            }
            break;
        }
        
        // 消耗整个节点
        if (bytes > skip) {
            luaL_addlstring(&b, current->msg + sb->offset + skip, 
                          bytes - skip);
            skip = 0;
        } else {
            skip -= bytes;
        }
        
        return_free_node(L, 2, sb);
        sz -= bytes;
        current = sb->head;
        assert(current);
    }
    
    luaL_pushresult(&b);
}
```

### 3. 序列化模块 (lua-seri.c)

#### 3.1 序列化协议设计

```c
// 类型定义
#define TYPE_NIL 0
#define TYPE_BOOLEAN 1
#define TYPE_NUMBER 2
#define TYPE_USERDATA 3
#define TYPE_SHORT_STRING 4
#define TYPE_LONG_STRING 5
#define TYPE_TABLE 6

// 数字子类型
#define TYPE_NUMBER_ZERO 0   // 0
#define TYPE_NUMBER_BYTE 1   // int8
#define TYPE_NUMBER_WORD 2   // int16
#define TYPE_NUMBER_DWORD 4  // int32
#define TYPE_NUMBER_QWORD 6  // int64
#define TYPE_NUMBER_REAL 8   // double

// 组合类型和值
#define COMBINE_TYPE(t,v) ((t) | (v) << 3)
```

#### 3.2 写入块管理

```c
// 写入块结构
struct write_block {
    struct block * head;     // 块链表头
    struct block * current;  // 当前块
    int len;                 // 总长度
    int ptr;                 // 当前位置
};

// 块结构
struct block {
    struct block * next;
    char buffer[BLOCK_SIZE];  // 128 字节
};

// 高效写入
inline static void wb_push(struct write_block *b, const void *buf, int sz) {
    const char * buffer = buf;
    
    if (b->ptr == BLOCK_SIZE) {
        // 分配新块
        b->current = b->current->next = blk_alloc();
        b->ptr = 0;
    }
    
    if (b->ptr <= BLOCK_SIZE - sz) {
        // 单块写入
        memcpy(b->current->buffer + b->ptr, buffer, sz);
        b->ptr += sz;
        b->len += sz;
    } else {
        // 跨块写入
        int copy = BLOCK_SIZE - b->ptr;
        memcpy(b->current->buffer + b->ptr, buffer, copy);
        buffer += copy;
        b->len += copy;
        sz -= copy;
        // 继续到下一块
        goto _again;
    }
}
```

#### 3.3 整数压缩编码

```c
// 整数序列化（变长编码）
static inline void wb_integer(struct write_block *wb, lua_Integer v) {
    int type = TYPE_NUMBER;
    
    if (v == 0) {
        // 0 只需要 1 字节
        uint8_t n = COMBINE_TYPE(type, TYPE_NUMBER_ZERO);
        wb_push(wb, &n, 1);
    } else if (v >= -128 && v <= 127) {
        // int8: 2 字节
        uint8_t n = COMBINE_TYPE(type, TYPE_NUMBER_BYTE);
        wb_push(wb, &n, 1);
        uint8_t byte = (uint8_t)v;
        wb_push(wb, &byte, 1);
    } else if (v >= -32768 && v <= 32767) {
        // int16: 3 字节
        uint8_t n = COMBINE_TYPE(type, TYPE_NUMBER_WORD);
        wb_push(wb, &n, 1);
        uint16_t word = (uint16_t)v;
        wb_push(wb, &word, 2);
    } else if (v >= -2147483648LL && v <= 2147483647LL) {
        // int32: 5 字节
        uint8_t n = COMBINE_TYPE(type, TYPE_NUMBER_DWORD);
        wb_push(wb, &n, 1);
        uint32_t dword = (uint32_t)v;
        wb_push(wb, &dword, 4);
    } else {
        // int64: 9 字节
        uint8_t n = COMBINE_TYPE(type, TYPE_NUMBER_QWORD);
        wb_push(wb, &n, 1);
        uint64_t qword = (uint64_t)v;
        wb_push(wb, &qword, 8);
    }
}
```

#### 3.4 表序列化

```c
// 递归序列化表
static void pack_table(lua_State *L, struct write_block *wb, int index, int depth) {
    if (depth > MAX_DEPTH) {
        luaL_error(L, "serialize table depth > %d", MAX_DEPTH);
    }
    
    // 检查循环引用
    if (luaL_getmetafield(L, index, "__pairs") != LUA_TNIL) {
        // 支持自定义迭代器
    }
    
    // 数组部分
    lua_pushnil(L);
    while (lua_next(L, index) != 0) {
        if (lua_type(L, -2) == LUA_TNUMBER) {
            // 序列化数组元素
            pack_one(L, wb, -1, depth);
        }
        lua_pop(L, 1);
    }
    
    // 哈希部分
    lua_pushnil(L);
    while (lua_next(L, index) != 0) {
        if (lua_type(L, -2) != LUA_TNUMBER) {
            // 序列化键
            pack_one(L, wb, -2, depth);
            // 序列化值
            pack_one(L, wb, -1, depth);
        }
        lua_pop(L, 1);
    }
    
    // 表结束标记
    wb_nil(wb);
}
```

### 4. 网络包处理 (lua-netpack.c)

#### 4.1 包头处理

```c
// 解析包头（大端序）
static int ltostring(lua_State *L) {
    void * ptr = lua_touserdata(L, 1);
    int size = luaL_checkinteger(L, 2);
    
    if (ptr == NULL) {
        lua_pushliteral(L, "");
        return 1;
    }
    
    if (size <= 0) {
        return luaL_error(L, "Invalid size %d", size);
    }
    
    // 读取 2 字节包头
    uint8_t * buffer = ptr;
    int len = buffer[0] << 8 | buffer[1];
    
    if (len > size - 2) {
        return luaL_error(L, "Invalid package size %d", len);
    }
    
    // 返回包体
    lua_pushlstring(L, (const char *)buffer + 2, len);
    
    // 返回剩余数据大小
    lua_pushinteger(L, size - len - 2);
    
    return 2;
}

// 打包数据
static int lpack(lua_State *L) {
    size_t len;
    const char * ptr = luaL_checklstring(L, 1, &len);
    
    if (len >= 0x10000) {
        return luaL_error(L, "Package too large");
    }
    
    uint8_t * buffer = skynet_malloc(len + 2);
    
    // 写入包头（大端序）
    buffer[0] = (len >> 8) & 0xff;
    buffer[1] = len & 0xff;
    
    // 写入包体
    memcpy(buffer + 2, ptr, len);
    
    lua_pushlightuserdata(L, buffer);
    lua_pushinteger(L, len + 2);
    
    return 2;
}
```

### 5. 集群通信支持 (lua-cluster.c)

#### 5.1 集群数据打包

```c
// 打包请求
static int lpackrequest(lua_State *L) {
    int sz = 0;
    
    // 计算总大小
    int n = lua_gettop(L);
    for (int i = 1; i <= n; i++) {
        size_t len;
        luaL_checklstring(L, i, &len);
        sz += len + 4;  // 4 字节长度前缀
    }
    
    uint8_t * data = skynet_malloc(sz);
    uint8_t * ptr = data;
    
    // 打包每个参数
    for (int i = 1; i <= n; i++) {
        size_t len;
        const char * str = lua_tolstring(L, i, &len);
        
        // 写入长度（小端序）
        ptr[0] = len & 0xff;
        ptr[1] = (len >> 8) & 0xff;
        ptr[2] = (len >> 16) & 0xff;
        ptr[3] = (len >> 24) & 0xff;
        ptr += 4;
        
        // 写入数据
        memcpy(ptr, str, len);
        ptr += len;
    }
    
    lua_pushlightuserdata(L, data);
    lua_pushinteger(L, sz);
    
    return 2;
}

// 解包响应
static int lunpackresponse(lua_State *L) {
    const uint8_t * data = lua_touserdata(L, 1);
    int sz = luaL_checkinteger(L, 2);
    
    int n = 0;
    while (sz > 0) {
        if (sz < 4) {
            return luaL_error(L, "Invalid cluster response");
        }
        
        // 读取长度
        int len = data[0] | data[1] << 8 | data[2] << 16 | data[3] << 24;
        data += 4;
        sz -= 4;
        
        if (sz < len) {
            return luaL_error(L, "Invalid cluster response size");
        }
        
        // 压入数据
        lua_pushlstring(L, (const char *)data, len);
        data += len;
        sz -= len;
        n++;
    }
    
    return n;
}
```

### 6. 加密模块 (lua-crypt.c)

#### 6.1 哈希函数

```c
// SHA1 实现
static int lsha1(lua_State *L) {
    size_t sz;
    const uint8_t * buffer = (const uint8_t *)luaL_checklstring(L, 1, &sz);
    
    SHA1_CTX ctx;
    uint8_t digest[SHA1_DIGEST_SIZE];
    
    SHA1Init(&ctx);
    SHA1Update(&ctx, buffer, sz);
    SHA1Final(digest, &ctx);
    
    lua_pushlstring(L, (const char *)digest, SHA1_DIGEST_SIZE);
    
    return 1;
}

// HMAC-SHA1
static int lhmac_sha1(lua_State *L) {
    size_t key_sz, text_sz;
    const uint8_t * key = (const uint8_t *)luaL_checklstring(L, 1, &key_sz);
    const uint8_t * text = (const uint8_t *)luaL_checklstring(L, 2, &text_sz);
    
    uint8_t digest[SHA1_DIGEST_SIZE];
    hmac_sha1(key, key_sz, text, text_sz, digest);
    
    lua_pushlstring(L, (const char *)digest, SHA1_DIGEST_SIZE);
    
    return 1;
}
```

#### 6.2 DH 密钥交换

```c
// DH 密钥交换
static int ldhexchange(lua_State *L) {
    size_t sz;
    const uint8_t * secret = (const uint8_t *)luaL_checklstring(L, 1, &sz);
    
    if (sz != 32) {
        luaL_error(L, "Invalid dh secret size %d", (int)sz);
    }
    
    uint8_t public_key[32];
    
    // 生成公钥
    curve25519_donna(public_key, secret, basepoint);
    
    lua_pushlstring(L, (const char *)public_key, 32);
    
    return 1;
}

// 计算共享密钥
static int ldhsecret(lua_State *L) {
    size_t sz1, sz2;
    const uint8_t * private_key = (const uint8_t *)luaL_checklstring(L, 1, &sz1);
    const uint8_t * public_key = (const uint8_t *)luaL_checklstring(L, 2, &sz2);
    
    if (sz1 != 32 || sz2 != 32) {
        luaL_error(L, "Invalid key size");
    }
    
    uint8_t shared_secret[32];
    
    // 计算共享密钥
    curve25519_donna(shared_secret, private_key, public_key);
    
    lua_pushlstring(L, (const char *)shared_secret, 32);
    
    return 1;
}
```

### 7. 共享数据模块 (lua-sharedata.c / lua-sharetable.c)

#### 7.1 共享数据设计

```c
// 共享数据结构
struct sharedata {
    int ref;           // 引用计数
    void * data;       // 数据指针
    size_t sz;         // 数据大小
};

// 创建共享数据
static int lnew(lua_State *L) {
    size_t sz;
    void * data = get_data(L, 1, &sz);
    
    struct sharedata * sd = lua_newuserdata(L, sizeof(*sd));
    sd->ref = 1;
    sd->data = skynet_malloc(sz);
    sd->sz = sz;
    
    memcpy(sd->data, data, sz);
    
    // 设置元表
    luaL_getmetatable(L, "sharedata");
    lua_setmetatable(L, -2);
    
    return 1;
}

// 增加引用
static int laddref(lua_State *L) {
    struct sharedata * sd = luaL_checkudata(L, 1, "sharedata");
    __sync_add_and_fetch(&sd->ref, 1);
    return 0;
}

// 减少引用
static int lrelease(lua_State *L) {
    struct sharedata * sd = luaL_checkudata(L, 1, "sharedata");
    if (__sync_sub_and_fetch(&sd->ref, 1) == 0) {
        skynet_free(sd->data);
        sd->data = NULL;
    }
    return 0;
}
```

### 8. 调试通道 (lua-debugchannel.c)

#### 8.1 调试通道实现

```c
// 调试通道结构
struct debug_channel {
    struct skynet_context * ctx;
    int fd;  // socket fd
};

// 创建调试通道
static int lcreate(lua_State *L) {
    struct skynet_context * ctx = lua_touserdata(L, lua_upvalueindex(1));
    const char * addr = luaL_checkstring(L, 1);
    int port = luaL_checkinteger(L, 2);
    
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        lua_pushnil(L);
        return 1;
    }
    
    // 连接调试服务器
    struct sockaddr_in server;
    server.sin_family = AF_INET;
    server.sin_port = htons(port);
    inet_pton(AF_INET, addr, &server.sin_addr);
    
    if (connect(fd, (struct sockaddr *)&server, sizeof(server)) < 0) {
        close(fd);
        lua_pushnil(L);
        return 1;
    }
    
    struct debug_channel * dc = lua_newuserdata(L, sizeof(*dc));
    dc->ctx = ctx;
    dc->fd = fd;
    
    return 1;
}
```

## 内存管理策略

### 1. 零拷贝设计

```c
// 消息发送时的零拷贝
case LUA_TLIGHTUSERDATA: {
    void * msg = lua_touserdata(L, idx_type+2);
    int size = luaL_checkinteger(L, idx_type+3);
    
    // PTYPE_TAG_DONTCOPY 标记避免拷贝
    session = skynet_send(context, source, dest, 
                         type | PTYPE_TAG_DONTCOPY, 
                         session, msg, size);
    break;
}
```

### 2. 内存池复用

```c
// Socket 缓冲区内存池
struct buffer_pool {
    struct buffer_node * free_list;  // 空闲链表
    int allocated;                   // 已分配数量
    int size;                        // 池大小
};

// 指数增长策略
if (tsz <= LARGE_PAGE_NODE-3) {
    size <<= tsz;  // 8, 16, 32, 64, ...
} else {
    size = 1 << (LARGE_PAGE_NODE-3);  // 最大 4096
}
```

### 3. 引用计数管理

```c
// 共享数据引用计数
struct sharedata {
    int ref;  // 原子引用计数
    void * data;
    size_t sz;
};

// 原子操作
__sync_add_and_fetch(&sd->ref, 1);  // 增加引用
__sync_sub_and_fetch(&sd->ref, 1);  // 减少引用
```

## 错误处理

### 1. Lua 错误传播

```c
// 带追踪的错误处理
static int traceback(lua_State *L) {
    const char *msg = lua_tostring(L, 1);
    if (msg)
        luaL_traceback(L, L, msg, 1);
    else
        lua_pushliteral(L, "(no error message)");
    return 1;
}

// 安全调用
int r = lua_pcall(L, 5, 0, trace);
if (r != LUA_OK) {
    skynet_error(context, "lua error : %s", lua_tostring(L, -1));
}
```

### 2. 参数验证

```c
// 类型检查
luaL_checktype(L, 1, LUA_TFUNCTION);
luaL_checkudata(L, 1, "sharedata");

// 范围检查
if (len >= 0x10000) {
    return luaL_error(L, "Package too large");
}

// 空指针检查
if (ptr == NULL) {
    lua_pushliteral(L, "");
    return 1;
}
```

## 性能优化

### 1. 批量操作

```c
// 批量读取优化
if (sz <= current->sz - sb->offset) {
    // 单节点读取，避免拷贝
    lua_pushlstring(L, current->msg + sb->offset, sz);
    sb->offset += sz;
    return;
}
```

### 2. 缓存局部性

```c
// 块大小优化
#define BLOCK_SIZE 128  // 适合 CPU 缓存行

// 连续内存分配
struct buffer_node * pool = lua_newuserdatauv(L, 
                            sizeof(struct buffer_node) * sz, 0);
```

### 3. 分支预测优化

```c
// likely/unlikely 宏优化
if (likely(r == LUA_OK)) {
    return 0;
}

// 热路径优化
if (sb->head == NULL) {
    assert(sb->tail == NULL);  // 冷路径断言
    sb->head = sb->tail = free_node;
} else {
    sb->tail->next = free_node;  // 热路径
    sb->tail = free_node;
}
```

## 架构图

### C-Lua 扩展架构

```
┌─────────────────────────────────────────────┐
│              Lua Service Layer               │
├─────────────────────────────────────────────┤
│            Lua C Extension API               │
│  ┌──────────┬──────────┬──────────┐        │
│  │ skynet   │ socket   │  seri    │        │
│  ├──────────┼──────────┼──────────┤        │
│  │ netpack  │ cluster  │  crypt   │        │
│  ├──────────┼──────────┼──────────┤        │
│  │sharedata │ mongo    │  debug   │        │
│  └──────────┴──────────┴──────────┘        │
├─────────────────────────────────────────────┤
│          Lua API Bridge Layer                │
│    (lua_push*, lua_to*, luaL_check*)        │
├─────────────────────────────────────────────┤
│           Skynet Core C API                  │
│  (skynet_send, skynet_command, ...)         │
└─────────────────────────────────────────────┘
```

### 消息流转路径

```
Lua Service A                    Lua Service B
     │                                │
     ├──lua-skynet.send()            │
     │                                │
     ↓                                │
C Extension Layer                     │
     │                                │
     ├──skynet_send()                │
     │                                │
     ↓                                │
Message Queue                         │
     │                                │
     └────────────────────────────────┤
                                      │
                                      ↓
                                 Callback
                                      │
                                      ├──lua_pcall()
                                      │
                                      ↓
                                 Lua Handler
```

## 总结

Lua C 扩展模块是 Skynet 高性能的关键组件，通过精心设计的接口和优化策略，实现了：

1. **高效通信**：零拷贝消息传递，内存池管理
2. **数据处理**：高性能序列化，网络包处理
3. **安全性**：加密支持，错误处理
4. **扩展性**：模块化设计，易于扩展

这些扩展模块充分利用了 C 语言的性能优势，同时保持了 Lua 的易用性，为上层应用提供了强大而灵活的基础设施。通过合理的内存管理、缓存优化和并发控制，确保了整个系统的高性能和稳定性。