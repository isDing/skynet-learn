# Skynet网络层架构文档

## 目录

1. [网络层整体架构](#网络层整体架构)
2. [核心数据结构详解](#核心数据结构详解)
3. [网络线程工作机制](#网络线程工作机制)
4. [IO多路复用实现](#io多路复用实现)
5. [消息传递机制](#消息传递机制)
6. [Socket ID管理机制](#socket-id管理机制)
7. [内存管理优化](#内存管理优化)
8. [并发安全设计](#并发安全设计)
9. [性能优化策略](#性能优化策略)
10. [典型应用场景](#典型应用场景)
11. [配置和调优](#配置和调优)
12. [源码文件说明](#源码文件说明)

---

## 网络层整体架构

Skynet采用单线程IO多路复用模型，实现了高效的网络通信架构。整个网络层采用三层架构设计：

### 架构层次

```
┌─────────────────────────────────────────────────────────────┐
│                     上层消息分发层                           │
│  skynet_socket.c - 向上层服务提供网络接口                    │
│  将底层网络事件转换为skynet消息并分发给对应服务               │
└─────────────────────────────────────────────────────────────┘
                              ↑↓
┌─────────────────────────────────────────────────────────────┐
│                     中间socket管理层                         │
│  socket_server.c - socket状态管理、缓冲区管理                │
│  控制命令处理、socket生命周期管理                           │
└─────────────────────────────────────────────────────────────┘
                              ↑↓
┌─────────────────────────────────────────────────────────────┐
│                     底层IO多路复用层                         │
│  socket_epoll.h / socket_kqueue.h - 事件驱动                │
│  非阻塞IO、事件循环、系统调用封装                           │
└─────────────────────────────────────────────────────────────┘
```

### 核心设计原则

- **单线程IO多路复用**：避免多线程竞争，简化并发控制
- **事件驱动架构**：基于epoll/kqueue的高效事件处理
- **异步非阻塞**：所有网络操作都是非阻塞的
- **消息传递隔离**：通过管道隔离网络线程和主线程
- **状态机管理**：严格的socket状态转换控制

---

## 核心数据结构详解

### socket_server结构

```c
struct socket_server {
    volatile uint64_t time;        // 当前时间戳
    int reserve_fd;                // 预留fd，用于EMFILE错误处理  
    int recvctrl_fd;              // 控制管道读端
    int sendctrl_fd;              // 控制管道写端
    int checkctrl;                // 是否检查控制命令
    poll_fd event_fd;             // epoll/kqueue文件描述符
    ATOM_INT alloc_id;            // 原子变量：ID分配器
    int event_n;                  // 事件数量
    int event_index;              // 当前事件索引
    struct socket_object_interface soi; // 对象接口回调
    struct event ev[MAX_EVENT];   // 事件数组(64个)
    struct socket slot[MAX_SOCKET]; // socket池(65536个槽位)
    char buffer[MAX_INFO];        // 信息缓冲区
    uint8_t udpbuffer[MAX_UDP_PACKAGE]; // UDP数据包缓冲区
    fd_set rfds;                  // select用的文件描述符集合
};
```

**关键特性：**
- **65536个socket槽位**：通过`MAX_SOCKET (1<<MAX_SOCKET_P)`定义，支持大量并发连接
- **事件缓冲区**：`MAX_EVENT=64`，批量处理网络事件提升性能
- **控制管道机制**：`recvctrl_fd/sendctrl_fd`实现线程间通信
- **原子ID分配器**：`ATOM_INT alloc_id`保证ID分配的线程安全

### socket结构

```c
struct socket {
    uintptr_t opaque;              // 拥有此socket的服务句柄
    struct wb_list high;           // 高优先级写缓冲区链表
    struct wb_list low;            // 低优先级写缓冲区链表
    int64_t wb_size;               // 写缓冲区总大小
    struct socket_stat stat;       // 统计信息(读写字节数和时间)
    ATOM_ULONG sending;            // 原子变量：正在发送的引用计数
    int fd;                        // 系统文件描述符
    int id;                        // skynet内部socket ID
    ATOM_INT type;                 // 原子变量：socket状态类型
    uint8_t protocol;              // 协议类型(TCP/UDP/UDPv6)
    bool reading;                  // 是否启用读事件
    bool writing;                  // 是否启用写事件
    bool closing;                  // 是否正在关闭
    ATOM_INT udpconnecting;        // UDP连接计数
    int64_t warn_size;             // 警告阈值大小
    union {
        int size;                  // TCP读缓冲区大小
        uint8_t udp_address[UDP_ADDRESS_SIZE]; // UDP地址
    } p;
    struct spinlock dw_lock;       // 直写锁
    int dw_offset;                 // 直写偏移量
    const void * dw_buffer;        // 直写缓冲区
    size_t dw_size;                // 直写大小
};
```

### Socket状态机

```
INVALID(0) → RESERVE(1) → PLISTEN(2) → LISTEN(3)
                       ↘                ↙
                         PACCEPT(8) → CONNECTED(5)
                                         ↓
                              HALFCLOSE_READ/WRITE(6/7)
                                         ↓
                                    INVALID(0)
```

**状态转换说明：**
- `INVALID`：无效状态，初始状态
- `RESERVE`：已预留ID但未初始化
- `PLISTEN`：准备监听状态
- `LISTEN`：正在监听连接
- `PACCEPT`：准备接受连接
- `CONNECTED`：已连接状态
- `HALFCLOSE_READ/WRITE`：半关闭状态

---

## 网络线程工作机制

### 主循环：thread_socket

网络线程的核心是`thread_socket`函数，它运行在独立的线程中：

```c
// 网络线程主循环伪代码
void thread_socket(void *p) {
    struct socket_server *ss = (struct socket_server *)p;
    
    while (!ss->closing) {
        // 1. 处理控制命令
        if (has_cmd()) {
            ctrl_cmd(ss);
        }
        
        // 2. 处理网络事件
        socket_server_poll(ss, &result, &more);
        
        // 3. 转发消息到主线程
        forward_message(&result);
    }
}
```

### socket_server_poll事件处理流程

```c
int socket_server_poll(struct socket_server *ss, 
                      struct socket_message *result, 
                      int *more) {
    // 1. 检查是否有控制命令
    if (ss->checkctrl) {
        if (has_cmd(ss)) {
            return ctrl_cmd(ss, result);
        }
    }
    
    // 2. 检查是否有缓存事件
    if (ss->event_index < ss->event_n) {
        struct event *e = &ss->ev[ss->event_index++];
        struct socket *s = e->s;
        return report_event(ss, s, e, result, more);
    }
    
    // 3. 等待新的网络事件
    ss->event_n = sp_wait(ss->event_fd, ss->ev, MAX_EVENT);
    ss->event_index = 0;
    
    if (ss->event_n > 0) {
        // 处理第一个事件
        struct event *e = &ss->ev[ss->event_index++];
        struct socket *s = e->s;
        return report_event(ss, s, e, result, more);
    }
    
    return -1; // 无事件
}
```

### 控制命令处理(ctrl_cmd)

控制命令通过管道从主线程发送到网络线程：

```c
// 控制命令类型
#define 'O' // OPEN - 连接
#define 'L' // LISTEN - 监听
#define 'K' // CLOSE - 关闭
#define 'S' // SEND - 发送数据
#define 'B' // BIND - 绑定fd
#define 'T' // START - 开始接收
#define 'P' // PAUSE - 暂停接收
#define 'R' // RESUME - 恢复接收
#define 'D' // UDP
#define 'C' // UDP连接
```

---

## IO多路复用实现

### Linux epoll实现

```c
// socket_epoll.h 核心函数

// 创建epoll实例
static int sp_create() {
    return epoll_create(1024);
}

// 添加socket到epoll
static int sp_add(int efd, int sock, void *ud) {
    struct epoll_event ev;
    ev.events = EPOLLIN;
    ev.data.ptr = ud;
    return epoll_ctl(efd, EPOLL_CTL_ADD, sock, &ev);
}

// 修改socket事件
static int sp_enable(int efd, int sock, void *ud, 
                    bool read_enable, bool write_enable) {
    struct epoll_event ev;
    ev.events = (read_enable ? EPOLLIN : 0) | 
                (write_enable ? EPOLLOUT : 0);
    ev.data.ptr = ud;
    return epoll_ctl(efd, EPOLL_CTL_MOD, sock, &ev);
}

// 等待事件
static int sp_wait(int efd, struct event *e, int max) {
    struct epoll_event ev[max];
    int n = epoll_wait(efd, ev, max, -1);
    
    for (int i = 0; i < n; i++) {
        e[i].s = ev[i].data.ptr;
        unsigned flag = ev[i].events;
        e[i].write = (flag & EPOLLOUT) != 0;
        e[i].read = (flag & EPOLLIN) != 0;
        e[i].error = (flag & EPOLLERR) != 0;
        e[i].eof = (flag & EPOLLHUP) != 0;
    }
    
    return n;
}
```

### BSD kqueue实现

kqueue在BSD系统上提供类似epoll的功能，但API略有不同：

```c
// socket_kqueue.h 主要差异
static int sp_create() {
    return kqueue();
}

static int sp_wait(int kfd, struct event *e, int max) {
    struct kevent ev[max];
    int n = kevent(kfd, NULL, 0, ev, max, NULL);
    
    for (int i = 0; i < n; i++) {
        struct socket *s = (struct socket *)ev[i].udata;
        e[i].s = s;
        e[i].write = (ev[i].filter == EVFILT_WRITE);
        e[i].read = (ev[i].filter == EVFILT_READ);
        // 处理错误和EOF...
    }
    
    return n;
}
```

### 事件类型处理

```c
struct event {
    void * s;      // socket指针
    bool read;     // 可读事件
    bool write;    // 可写事件
    bool error;    // 错误事件
    bool eof;      // 连接关闭事件
};
```

**事件处理优先级：**
1. **错误事件**：立即处理，通常导致连接关闭
2. **EOF事件**：对端关闭连接，进入半关闭状态
3. **读事件**：有数据可读，调用接收处理
4. **写事件**：发送缓冲区可写，继续发送数据

---

## 消息传递机制

### 接收数据流程

```
网络数据 → epoll_wait → socket_server_poll → forward_message_tcp 
         → skynet_socket_poll → forward_message → skynet_context_push 
         → 服务消息队列
```

**详细流程：**

1. **网络层接收**：
```c
// socket_server.c
static int forward_message_tcp(struct socket_server *ss, 
                              struct socket *s, 
                              struct socket_message *result) {
    int sz = recv(s->fd, ss->buffer, sizeof(ss->buffer), 0);
    if (sz > 0) {
        result->opaque = s->opaque;
        result->id = s->id;
        result->ud = sz;
        result->data = ss->buffer;
        return SOCKET_DATA;
    }
    // 处理错误情况...
}
```

2. **消息转发**：
```c
// skynet_socket.c
static void forward_message(int type, bool padding, 
                           struct socket_message * result) {
    struct skynet_socket_message *sm;
    sm = (struct skynet_socket_message *)skynet_malloc(sz);
    sm->type = type;
    sm->id = result->id;
    sm->ud = result->ud;
    sm->buffer = result->data;
    
    struct skynet_message message;
    message.source = 0;
    message.session = 0;
    message.data = sm;
    message.sz = sz | ((size_t)PTYPE_SOCKET << MESSAGE_TYPE_SHIFT);
    
    skynet_context_push((uint32_t)result->opaque, &message);
}
```

### 发送数据流程

```
服务socket.write → skynet_socket_send → 控制管道 
                 → ctrl_cmd → 写缓冲区 → EPOLLOUT → send_buffer
```

**详细流程：**

1. **上层接口**：
```c
// skynet_socket.c
int skynet_socket_send(struct skynet_context *ctx, int id, 
                      void *buffer, int sz) {
    struct socket_sendbuffer tmp;
    tmp.id = id;
    tmp.buffer = buffer;
    tmp.type = SOCKET_BUFFER_MEMORY;
    tmp.sz = sz;
    return skynet_socket_sendbuffer(ctx, &tmp);
}
```

2. **控制命令发送**：
```c
// 通过管道发送控制命令
static void send_request(struct socket_server *ss, 
                        struct request_package *request, 
                        char type, int len) {
    request->header[6] = (uint8_t)type;
    request->header[7] = (uint8_t)len;
    // 原子操作写入管道
    for (;;) {
        ssize_t n = write(ss->sendctrl_fd, &request->header[6], len+2);
        if (n < 0) {
            if (errno != EINTR) {
                continue;
            }
        }
        return;
    }
}
```

3. **网络层发送**：
```c
// socket_server.c
static int send_buffer(struct socket_server *ss, 
                      struct socket *s, 
                      struct wb_list *list, 
                      struct socket_stat *stat) {
    while (list->head) {
        struct write_buffer * tmp = list->head;
        ssize_t sz = write(s->fd, tmp->ptr, tmp->sz);
        
        if (sz > 0) {
            stat->write += sz;
            tmp->ptr += sz;
            tmp->sz -= sz;
            if (tmp->sz == 0) {
                // 完整发送，移除缓冲区
                list->head = tmp->next;
                FREE_WB(tmp);
            }
        } else {
            // EAGAIN或错误处理
            return -1;
        }
    }
    return 0;
}
```

---

## Socket ID管理机制

### ID分配算法

```c
#define HASH_ID(id) (((unsigned)id) % MAX_SOCKET)
#define ID_TAG16(id) ((id>>MAX_SOCKET_P) & 0xffff)

// 原子操作分配新ID
static int reserve_id(struct socket_server *ss) {
    int i;
    for (i=0; i<MAX_SOCKET; i++) {
        int id = ATOM_FINC(&(ss->alloc_id)) + 1;
        if (id < 0) {
            id = ATOM_FAND(&(ss->alloc_id), 0x7fffffff) & 0x7fffffff;
        }
        struct socket *s = &ss->slot[HASH_ID(id)];
        int type_invalid = SOCKET_TYPE_INVALID;
        if (ATOM_CAS(&s->type, &type_invalid, SOCKET_TYPE_RESERVE)) {
            s->id = id;
            s->protocol = PROTOCOL_UNKNOWN;
            s->fd = -1;
            return id;
        }
    }
    return -1;
}
```

### ID映射机制

- **哈希映射**：`HASH_ID(id)`将32位ID映射到16位槽位索引
- **版本号机制**：ID高16位作为版本号，避免ID重复使用问题
- **原子分配**：使用原子操作`ATOM_FINC`保证线程安全
- **循环使用**：ID用完后从0开始重新分配

### ID验证

```c
// 验证socket ID是否有效
static struct socket * get_socket(struct socket_server *ss, int id) {
    struct socket *s = &ss->slot[HASH_ID(id)];
    if (s->id == id) {
        return s;
    }
    return NULL;
}
```

---

## 内存管理优化

### 直写模式(Direct Write)

当发送数据量较小时，Skynet尝试直接写入socket，避免缓冲：

```c
// 直写优化
static int send_socket(struct socket_server *ss, 
                      struct request_send * request, 
                      struct socket_message *result, 
                      int priority, 
                      const uint8_t *udp_address) {
    struct socket *s = get_socket(ss, request->id);
    
    // 如果没有待发送数据且socket可写，尝试直写
    if (s->high.head == NULL && s->low.head == NULL && 
        s->dw_buffer == NULL && !s->closing) {
        
        spinlock_lock(&s->dw_lock);
        if (s->dw_buffer == NULL) {
            // 设置直写缓冲区
            s->dw_buffer = request->buffer;
            s->dw_size = request->sz;
            s->dw_offset = 0;
            spinlock_unlock(&s->dw_lock);
            
            // 启用写事件，在下次EPOLLOUT时发送
            sp_enable(ss->event_fd, s->fd, s, true, true);
            return -1;
        }
        spinlock_unlock(&s->dw_lock);
    }
    
    // 添加到写缓冲区
    return append_sendbuffer(ss, s, request, priority);
}
```

### 写缓冲区链表管理

```c
struct wb_list {
    struct write_buffer * head;
    struct write_buffer * tail;
};

struct write_buffer {
    struct write_buffer * next;    // 链表指针
    const void *buffer;           // 数据缓冲区指针
    char *ptr;                    // 当前写位置
    size_t sz;                    // 剩余大小
    bool userobject;              // 是否为用户对象
};
```

**优化策略：**
- **双优先级队列**：`high`和`low`两个优先级的写缓冲区
- **零拷贝**：尽可能避免数据复制，使用指针引用
- **批量发送**：将多个小包合并发送
- **内存池**：重用write_buffer结构减少内存分配

### 用户对象引用机制

```c
struct socket_object_interface {
    const void * (*buffer)(const void *);  // 获取缓冲区指针
    size_t (*size)(const void *);          // 获取数据大小
    void (*free)(void *);                  // 释放对象
};
```

允许用户自定义对象的内存管理，支持复杂的数据结构零拷贝发送。

---

## 并发安全设计

### 管道隔离机制

```c
// 创建控制管道
static int pipe_init(struct socket_server *ss) {
    int fd[2];
    if (pipe(fd)) {
        return 1;
    }
    ss->recvctrl_fd = fd[0];  // 网络线程读端
    ss->sendctrl_fd = fd[1];  // 主线程写端
    sp_nonblocking(ss->recvctrl_fd);
    return 0;
}
```

**隔离原理：**
- 主线程通过`sendctrl_fd`发送控制命令
- 网络线程通过`recvctrl_fd`接收控制命令
- 避免了直接的内存共享和锁竞争

### 原子操作保护

```c
// 原子操作宏定义
#define ATOM_CAS(ptr, oval, nval) __sync_bool_compare_and_swap(ptr, oval, nval)
#define ATOM_FINC(ptr) __sync_fetch_and_add(ptr, 1)
#define ATOM_FDEC(ptr) __sync_fetch_and_sub(ptr, 1)
#define ATOM_FAND(ptr, val) __sync_fetch_and_and(ptr, val)

// 使用示例：socket状态转换
static bool socket_trylock(struct socket *s) {
    int sending = 0;
    return ATOM_CAS(&s->sending, &sending, 1);
}
```

### Spinlock保护写操作

```c
struct spinlock {
    int lock;
};

// 直写操作的并发保护
static void try_direct_write(struct socket *s, 
                            const void *buffer, 
                            size_t sz) {
    spinlock_lock(&s->dw_lock);
    if (s->dw_buffer == NULL) {
        s->dw_buffer = buffer;
        s->dw_size = sz;
        s->dw_offset = 0;
    }
    spinlock_unlock(&s->dw_lock);
}
```

### 无锁化设计原则

1. **单线程网络处理**：网络事件只在一个线程中处理
2. **原子状态机**：socket状态使用原子变量保护
3. **管道通信**：避免共享内存，使用管道传递控制命令
4. **引用计数**：使用原子引用计数管理socket生命周期

---

## 性能优化策略

### 批量事件处理

```c
// 一次最多处理64个事件
#define MAX_EVENT 64

int socket_server_poll(struct socket_server *ss, 
                      struct socket_message *result, 
                      int *more) {
    if (ss->event_index < ss->event_n) {
        // 处理缓存的事件
        *more = (ss->event_index < ss->event_n - 1);
        return process_cached_event(ss, result);
    }
    
    // 批量获取新事件
    ss->event_n = sp_wait(ss->event_fd, ss->ev, MAX_EVENT);
    ss->event_index = 0;
    
    if (ss->event_n > 0) {
        *more = (ss->event_n > 1);
        return process_first_event(ss, result);
    }
    
    return -1;
}
```

### 零拷贝优化

```c
// 零拷贝发送：直接使用用户缓冲区
int socket_server_send(struct socket_server *ss, 
                      struct socket_sendbuffer *buffer) {
    // 不复制数据，直接引用用户缓冲区
    struct write_buffer *wb = MALLOC(sizeof(*wb));
    wb->buffer = buffer->buffer;  // 直接引用
    wb->sz = buffer->sz;
    wb->userobject = (buffer->type == SOCKET_BUFFER_OBJECT);
    
    return append_to_high_queue(ss, buffer->id, wb);
}
```

### 内存池管理

```c
// 预分配socket池
struct socket slot[MAX_SOCKET];  // 65536个socket预分配

// write_buffer复用池
static struct write_buffer *free_wb_list = NULL;

static struct write_buffer * MALLOC_WB() {
    struct write_buffer *wb = free_wb_list;
    if (wb) {
        free_wb_list = wb->next;
    } else {
        wb = MALLOC(sizeof(*wb));
    }
    return wb;
}

static void FREE_WB(struct write_buffer *wb) {
    wb->next = free_wb_list;
    free_wb_list = wb;
}
```

### CPU亲和性设置

```c
// 设置网络线程CPU亲和性（用户可配置）
static void set_cpu_affinity(int cpu_id) {
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(cpu_id, &cpuset);
    pthread_setaffinity_np(pthread_self(), sizeof(cpuset), &cpuset);
}
```

---

## 典型应用场景

### Gate服务监听流程

```lua
-- service/gate.lua 网关服务示例
local skynet = require "skynet"
local socket = require "skynet.socket"

-- 1. 监听端口
local function listen_port(address, port)
    local fd = socket.listen(address, port)
    skynet.error("Listen on " .. address .. ":" .. port)
    
    -- 2. 开始接受连接
    socket.start(fd, function(fd, addr)
        skynet.error("Connected from " .. addr)
        
        -- 3. 为每个连接创建处理协程
        skynet.fork(handle_connection, fd, addr)
    end)
end

-- 连接处理函数
function handle_connection(fd, addr)
    socket.start(fd)
    
    while true do
        -- 4. 接收数据
        local data, err = socket.read(fd)
        if not data then
            break
        end
        
        -- 5. 处理业务逻辑
        process_client_data(fd, data)
    end
    
    socket.close(fd)
end
```

### Agent服务连接处理

```lua
-- 客户端代理服务
local skynet = require "skynet"
local socket = require "skynet.socket"

local CMD = {}

-- 连接到后端服务
function CMD.connect(host, port)
    local fd = socket.open(host, port)
    if fd then
        socket.start(fd)
        return fd
    end
    return nil
end

-- 发送数据
function CMD.send(fd, data)
    return socket.write(fd, data)
end

-- 接收数据
function CMD.recv(fd)
    return socket.read(fd)
end
```

### 数据收发示例代码

```c
// C层面的socket操作示例

// 1. 创建监听socket
int listen_fd = skynet_socket_listen(ctx, "0.0.0.0", 8080, 128);

// 2. 处理连接事件
static int socket_cb(struct skynet_context *ctx, void *ud, 
                    int type, int session, 
                    uint32_t source, const void *msg, size_t sz) {
    struct skynet_socket_message *message = (struct skynet_socket_message *)msg;
    
    switch (message->type) {
    case SKYNET_SOCKET_TYPE_ACCEPT:
        // 新连接
        skynet_socket_start(ctx, message->id);
        break;
        
    case SKYNET_SOCKET_TYPE_DATA:
        // 收到数据
        process_data(message->id, message->buffer, message->ud);
        break;
        
    case SKYNET_SOCKET_TYPE_CLOSE:
        // 连接关闭
        cleanup_connection(message->id);
        break;
    }
    
    return 0;
}

// 3. 发送数据
void send_response(int fd, const char *data, size_t len) {
    skynet_socket_send(ctx, fd, (void*)data, len);
}
```

---

## 配置和调优

### 核心配置参数

```c
// socket_server.c 关键配置
#define MAX_SOCKET_P 16        // socket池大小指数 (2^16 = 65536)
#define MAX_EVENT 64           // 单次处理的最大事件数
#define MIN_READ_BUFFER 64     // 最小读缓冲区大小
#define WARNING_SIZE (1024*1024) // 写缓冲区警告阈值(1MB)
#define MAX_UDP_PACKAGE 65535  // UDP包最大大小
```

### 性能调优建议

1. **MAX_EVENT调整**：
```c
// 高并发场景可适当增大
#define MAX_EVENT 128  // 提升事件处理批量度
```

2. **警告阈值设置**：
```c
// 根据业务场景调整写缓冲区警告大小
#define WARNING_SIZE (2*1024*1024)  // 2MB
```

3. **TCP选项配置**：
```c
// 开启TCP_NODELAY减少延迟
void socket_server_nodelay(struct socket_server *ss, int id) {
    struct socket *s = get_socket(ss, id);
    if (s && s->protocol == PROTOCOL_TCP) {
        int flag = 1;
        setsockopt(s->fd, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));
    }
}
```

4. **系统级优化**：
```bash
# 增大系统连接数限制
echo "* soft nofile 65535" >> /etc/security/limits.conf
echo "* hard nofile 65535" >> /etc/security/limits.conf

# 调整内核网络参数
echo "net.core.somaxconn = 4096" >> /etc/sysctl.conf
echo "net.ipv4.tcp_max_syn_backlog = 4096" >> /etc/sysctl.conf
```

### 监控和诊断

```c
// 获取socket统计信息
struct socket_info * socket_server_info(struct socket_server *ss) {
    // 返回所有socket的统计信息
    // 包括：读写字节数、连接时间、缓冲区大小等
}

// 使用示例
void print_socket_stats() {
    struct socket_info *info = skynet_socket_info();
    while (info) {
        printf("Socket %d: read=%lu write=%lu buffer=%ld\n",
               info->id, info->read, info->write, info->wbuffer);
        info = info->next;
    }
}
```

---

## 源码文件说明

### 核心文件结构

```
skynet-src/
├── socket_server.c       # 核心socket管理实现
├── socket_server.h       # socket_server接口定义  
├── skynet_socket.c       # 上层接口封装
├── skynet_socket.h       # skynet socket API
├── socket_poll.h         # IO多路复用统一接口
├── socket_epoll.h        # Linux epoll实现
├── socket_kqueue.h       # BSD kqueue实现
├── socket_buffer.h       # 发送缓冲区定义
└── socket_info.h         # socket信息结构定义
```

### 文件功能详解

**socket_server.c** (核心实现，约2000+行)：
- socket生命周期管理
- 事件循环和消息处理
- 读写缓冲区管理
- 控制命令处理
- UDP/TCP协议支持

**skynet_socket.c** (上层接口，约500行)：
- 向skynet服务层提供网络API
- 消息格式转换和分发
- 全局socket_server管理
- 错误处理和资源清理

**socket_epoll.h** (Linux平台，约80行)：
- epoll系统调用封装
- 事件类型转换
- 非阻塞IO设置
- 文件描述符管理

**socket_kqueue.h** (BSD平台，约120行)：
- kqueue事件机制
- kevent结构处理
- 跨平台兼容性
- 事件过滤器设置

**socket_poll.h** (统一接口，约35行)：
- 平台检测和头文件包含
- 统一的函数接口定义
- 编译时平台选择
- 事件结构体定义

### 依赖关系

```
服务层 (service/*.lua)
    ↓
lualib层 (lualib/skynet/socket.lua)
    ↓  
skynet_socket.c (消息转换层)
    ↓
socket_server.c (核心管理层)
    ↓
socket_poll.h (平台抽象层)
    ↓
socket_epoll.h / socket_kqueue.h (系统调用层)
```

---

## 总结

Skynet的网络层设计体现了以下核心思想：

1. **简洁性**：单线程IO多路复用避免了复杂的锁机制
2. **高效性**：批量事件处理、零拷贝、直写优化等
3. **可靠性**：严格的状态机管理、原子操作保护
4. **可扩展性**：支持65536个并发连接、双优先级队列
5. **跨平台性**：统一接口下支持epoll和kqueue

这种设计使得Skynet能够在单机上支持大量并发连接，同时保持代码的简洁性和可维护性，是高性能网络编程的优秀实践案例。

网络层的设计直接影响整个框架的性能表现，Skynet通过精心设计的三层架构、高效的事件处理机制和优化的内存管理，为上层业务逻辑提供了强大而稳定的网络通信基础。