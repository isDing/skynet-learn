# Skynet 监控系统和系统支持工具详解

## 目录

- [第一部分：监控系统架构](#第一部分监控系统架构)
- [第二部分：日志系统](#第二部分日志系统)  
- [第三部分：环境变量系统](#第三部分环境变量系统)
- [第四部分：错误处理系统](#第四部分错误处理系统)
- [第五部分：守护进程支持](#第五部分守护进程支持)
- [第六部分：系统集成与协作](#第六部分系统集成与协作)

---

## 第一部分：监控系统架构

### 1.1 监控系统概述

Skynet的监控系统(`skynet_monitor.c`)实现了一个轻量级但高效的死锁检测机制。该系统通过独立的监控线程定期检查工作线程的消息处理状态，及时发现和报告可能的死锁情况。

#### 核心设计理念

```
┌─────────────────────────────────────────────────┐
│                  监控系统架构                      │
├─────────────────────────────────────────────────┤
│                                                   │
│   监控线程 (thread_monitor)                        │
│      ↓ 每5秒检查一次                               │
│   ┌─────────────────────────┐                    │
│   │  监控器数组 (m->m[])      │                    │
│   └─────────────────────────┘                    │
│      ↓                                            │
│   ┌─────────────────────────┐                    │
│   │  版本号比较              │                    │
│   │  (version == check_ver)  │                    │
│   └─────────────────────────┘                    │
│      ↓ 如果相等                                    │
│   ┌─────────────────────────┐                    │
│   │  死锁警告                │                    │
│   │  标记endless状态         │                    │
│   └─────────────────────────┘                    │
│                                                   │
└─────────────────────────────────────────────────┘
```

### 1.2 核心数据结构

#### skynet_monitor 结构体

```c
struct skynet_monitor {
    ATOM_INT version;        // 原子版本号（消息处理计数器）
    int check_version;       // 上次检查时的版本号
    uint32_t source;         // 当前处理消息的来源服务ID
    uint32_t destination;    // 当前处理消息的目标服务ID
};
```

**字段说明：**
- `version`：原子整数，每处理一条消息后自增，表示工作线程的活跃度
- `check_version`：监控线程上次检查时记录的版本号
- `source/destination`：记录当前正在处理的消息路由信息，用于死锁诊断

#### monitor 结构体（skynet_start.c）

```c
struct monitor {
    int count;                      // 工作线程总数
    struct skynet_monitor ** m;     // 监控器数组，每个工作线程一个
    pthread_cond_t cond;           // 条件变量，用于唤醒休眠的工作线程
    pthread_mutex_t mutex;         // 互斥锁，保护sleep计数
    int sleep;                     // 当前休眠的工作线程数
    int quit;                      // 系统退出标志
};
```

### 1.3 关键函数分析

#### 1.3.1 创建监控器

```c
struct skynet_monitor * 
skynet_monitor_new() {
    struct skynet_monitor * ret = skynet_malloc(sizeof(*ret));
    memset(ret, 0, sizeof(*ret));
    return ret;
}
```

初始化一个新的监控器实例，所有字段清零。每个工作线程启动时都会创建一个对应的监控器。

#### 1.3.2 触发检查点

```c
void 
skynet_monitor_trigger(struct skynet_monitor *sm, uint32_t source, uint32_t destination) {
    sm->source = source;
    sm->destination = destination;
    ATOM_FINC(&sm->version);  // 原子自增版本号
}
```

**调用时机：**
- 消息处理前：记录消息路由信息（source和destination）
- 消息处理后：清空路由信息（传入0,0）

**工作流程：**

```
消息调度循环 (skynet_context_message_dispatch)
    ↓
弹出消息 (skynet_mq_pop)
    ↓
触发监控器 (skynet_monitor_trigger(sm, msg.source, handle))
    ↓
处理消息 (dispatch_message)
    ↓
清除监控器 (skynet_monitor_trigger(sm, 0, 0))
```

#### 1.3.3 检查死锁

```c
void 
skynet_monitor_check(struct skynet_monitor *sm) {
    if (sm->version == sm->check_version) {
        // 版本号未变化，可能死锁
        if (sm->destination) {
            skynet_context_endless(sm->destination);
            skynet_error(NULL, "error: A message from [ :%08x ] to [ :%08x ] maybe in an endless loop (version = %d)", 
                        sm->source, sm->destination, sm->version);
        }
    } else {
        // 版本号有变化，更新检查版本
        sm->check_version = sm->version;
    }
}
```

**死锁判定逻辑：**
1. 如果当前版本号等于上次检查的版本号，说明5秒内没有处理新消息
2. 如果destination不为0，说明有消息正在处理中
3. 标记目标服务为endless状态，输出死锁警告

### 1.4 死锁检测原理

#### 1.4.1 监控线程工作流程

```c
static void *
thread_monitor(void *p) {
    struct monitor * m = p;
    int i;
    int n = m->count;
    skynet_initthread(THREAD_MONITOR);
    
    for (;;) {
        CHECK_ABORT  // 检查是否需要退出
        
        // 检查所有工作线程的监控器
        for (i=0; i<n; i++) {
            skynet_monitor_check(m->m[i]);
        }
        
        // 休眠5秒（分5次，每次1秒，便于响应退出）
        for (i=0; i<5; i++) {
            CHECK_ABORT
            sleep(1);
        }
    }
    
    return NULL;
}
```

#### 1.4.2 死锁检测时序图

```
时间轴 →
─────────────────────────────────────────────────────────────────
T0: 工作线程处理消息A
    monitor_trigger() → version=1
    
T1: 消息A处理完成
    monitor_trigger(0,0) → version=2
    
T2: 工作线程处理消息B
    monitor_trigger() → version=3
    
T5: 监控线程第一次检查
    version(3) != check_version(0)
    更新: check_version=3
    
T7: 消息B仍在处理（可能死锁）
    version仍为3
    
T10: 监控线程第二次检查
     version(3) == check_version(3)
     触发死锁警告！
─────────────────────────────────────────────────────────────────
```

#### 1.4.3 死锁检测的关键特性

1. **非侵入式**：不影响正常消息处理性能
2. **低开销**：仅使用原子操作和定期检查
3. **准确性**：5秒阈值避免误报（正常的长时间处理）
4. **诊断信息**：记录死锁消息的源和目标服务

---

## 第二部分：日志系统

### 2.1 日志架构

Skynet的日志系统提供了灵活的日志记录和管理功能，支持服务级别的独立日志文件和日志轮转。

#### 日志系统组件关系

```
┌──────────────────────────────────────────┐
│            日志系统架构                    │
├──────────────────────────────────────────┤
│                                          │
│   skynet_error()                         │
│       ↓                                  │
│   查找logger服务                          │
│       ↓                                  │
│   构建日志消息                            │
│       ↓                                  │
│   发送到logger服务                        │
│       ↓                                  │
│   logger服务处理                          │
│       ↓                                  │
│   ┌─────────────┬──────────────┐        │
│   │  控制台输出  │   文件输出    │        │
│   └─────────────┴──────────────┘        │
│                                          │
└──────────────────────────────────────────┘
```

### 2.2 核心实现

#### 2.2.1 打开日志文件

```c
FILE * 
skynet_log_open(struct skynet_context * ctx, uint32_t handle) {
    const char * logpath = skynet_getenv("logpath");
    if (logpath == NULL)
        return NULL;
        
    size_t sz = strlen(logpath);
    char tmp[sz + 16];
    sprintf(tmp, "%s/%08x.log", logpath, handle);  // 格式：路径/服务句柄.log
    
    FILE *f = fopen(tmp, "ab");  // 追加二进制模式
    if (f) {
        uint32_t starttime = skynet_starttime();
        uint64_t currenttime = skynet_now();
        time_t ti = starttime + currenttime/100;
        skynet_error(ctx, "Open log file %s", tmp);
        fprintf(f, "open time: %u %s", (uint32_t)currenttime, ctime(&ti));
        fflush(f);
    } else {
        skynet_error(ctx, "Open log file %s fail", tmp);
    }
    return f;
}
```

**特点：**
- 每个服务可以有独立的日志文件
- 文件名基于服务句柄，确保唯一性
- 记录日志文件打开时间

#### 2.2.2 日志输出

```c
void 
skynet_log_output(FILE *f, uint32_t source, int type, int session, void * buffer, size_t sz) {
    if (type == PTYPE_SOCKET) {
        log_socket(f, buffer, sz);  // 特殊处理socket消息
    } else {
        uint32_t ti = (uint32_t)skynet_now();
        fprintf(f, ":%08x %d %d %u ", source, type, session, ti);
        log_blob(f, buffer, sz);    // 十六进制输出二进制数据
        fprintf(f,"\n");
        fflush(f);
    }
}
```

**日志格式：**
```
:源服务ID 消息类型 会话ID 时间戳 消息内容(十六进制)
```

#### 2.2.3 Socket消息日志

```c
static void
log_socket(FILE * f, struct skynet_socket_message * message, size_t sz) {
    fprintf(f, "[socket] %d %d %d ", message->type, message->id, message->ud);
    
    if (message->buffer == NULL) {
        // 内联数据
        const char *buffer = (const char *)(message + 1);
        sz -= sizeof(*message);
        const char * eol = memchr(buffer, '\0', sz);
        if (eol) {
            sz = eol - buffer;
        }
        fprintf(f, "[%*s]", (int)sz, (const char *)buffer);
    } else {
        // 外部缓冲区
        sz = message->ud;
        log_blob(f, message->buffer, sz);
    }
    fprintf(f, "\n");
    fflush(f);
}
```

### 2.3 日志轮转机制

#### SIGHUP信号处理

```c
static void
signal_hup() {
    struct skynet_message smsg;
    smsg.source = 0;
    smsg.session = 0;
    smsg.data = NULL;
    smsg.sz = (size_t)PTYPE_SYSTEM << MESSAGE_TYPE_SHIFT;
    
    uint32_t logger = skynet_handle_findname("logger");
    if (logger) {
        skynet_context_push(logger, &smsg);  // 发送系统消息给logger服务
    }
}
```

**日志轮转流程：**

1. 系统接收SIGHUP信号
2. timer线程检测到SIG标志
3. 发送PTYPE_SYSTEM消息给logger服务
4. logger服务重新打开日志文件
5. 实现日志轮转而不中断服务

---

## 第三部分：环境变量系统

### 3.1 设计目的

Skynet的环境变量系统提供了一个线程安全的全局配置存储机制，使得各个服务和模块可以共享配置信息。

### 3.2 实现机制

#### 3.2.1 核心数据结构

```c
struct skynet_env {
    struct spinlock lock;   // 自旋锁保护
    lua_State *L;          // Lua状态机存储环境变量
};

static struct skynet_env *E = NULL;  // 全局单例
```

**设计特点：**
- 使用Lua表作为存储后端（自动管理内存）
- 自旋锁保证线程安全
- 全局单例模式

#### 3.2.2 环境变量设置

```c
void 
skynet_setenv(const char *key, const char *value) {
    SPIN_LOCK(E)
    
    lua_State *L = E->L;
    lua_getglobal(L, key);
    assert(lua_isnil(L, -1));  // 确保不重复设置
    lua_pop(L,1);
    lua_pushstring(L,value);
    lua_setglobal(L,key);
    
    SPIN_UNLOCK(E)
}
```

**注意事项：**
- 环境变量只能设置一次（assert检查）
- 用于存储不变的配置信息
- 字符串由Lua管理，自动垃圾回收

#### 3.2.3 环境变量获取

```c
const char * 
skynet_getenv(const char *key) {
    SPIN_LOCK(E)
    
    lua_State *L = E->L;
    lua_getglobal(L, key);
    const char * result = lua_tostring(L, -1);
    lua_pop(L, 1);
    
    SPIN_UNLOCK(E)
    
    return result;
}
```

**使用场景：**
- 获取配置路径（logpath、bootstrap等）
- 获取线程数量配置
- 获取网络配置信息

### 3.3 常用环境变量

| 环境变量 | 说明 | 示例值 |
|---------|------|--------|
| thread | 工作线程数量 | "8" |
| harbor | 节点ID | "1" |
| bootstrap | 启动服务 | "snlua bootstrap" |
| logpath | 日志目录 | "./logs" |
| logger | 日志文件路径（传给日志服务的参数，留空表示标准输出） | "./logs/skynet.log" |
| logservice | 日志服务模块（默认使用内置C服务） | "logger" |

---

## 第四部分：错误处理系统

### 4.1 错误输出机制

Skynet的错误处理系统通过logger服务集中管理所有错误输出。

#### 4.1.1 错误消息发送

```c
void
skynet_error(struct skynet_context * context, const char *msg, ...) {
    static uint32_t logger = 0;
    
    // 查找logger服务
    if (logger == 0) {
        logger = skynet_handle_findname("logger");
    }
    if (logger == 0) {
        return;  // logger服务未启动
    }
    
    // 格式化错误消息
    char *data = NULL;
    va_list ap;
    va_start(ap, msg);
    int len = log_try_vasprintf(&data, msg, ap);
    va_end(ap);
    
    if (len < 0) {
        perror("vasprintf error :");
        return;
    }
    
    // 构建消息
    struct skynet_message smsg;
    if (context == NULL) {
        smsg.source = 0;
    } else {
        smsg.source = skynet_context_handle(context);
    }
    smsg.session = 0;
    smsg.data = data;
    smsg.sz = len | ((size_t)PTYPE_TEXT << MESSAGE_TYPE_SHIFT);
    
    // 发送到logger服务
    skynet_context_push(logger, &smsg);
}
```

### 4.2 与日志系统集成

#### 错误处理流程

```
服务调用skynet_error()
        ↓
查找logger服务句柄
        ↓
格式化错误消息
        ↓
构建PTYPE_TEXT消息
        ↓
发送到logger服务队列
        ↓
logger服务处理消息
        ↓
输出到控制台/文件
```

### 4.3 格式化输出

#### 特殊格式处理

```c
static int
log_try_vasprintf(char **strp, const char *fmt, va_list ap) {
    if (strcmp(fmt, "%*s") == 0) {
        // 特殊处理Lua错误消息
        const int len = va_arg(ap, int);
        const char *tmp = va_arg(ap, const char*);
        *strp = skynet_strndup(tmp, len);
        return *strp != NULL ? len : -1;
    }
    
    // 常规格式化
    char tmp[LOG_MESSAGE_SIZE];
    int len = vsnprintf(tmp, LOG_MESSAGE_SIZE, fmt, ap);
    if (len >= 0 && len < LOG_MESSAGE_SIZE) {
        *strp = skynet_strndup(tmp, len);
        if (*strp == NULL) return -1;
    }
    return len;
}
```

---

## 第五部分：守护进程支持

### 5.1 守护进程创建

Skynet支持以守护进程方式运行，提供了完整的进程管理功能。

#### 5.1.1 初始化流程

```c
int
daemon_init(const char *pidfile) {
    // 1. 检查是否已有实例在运行
    int pid = check_pid(pidfile);
    if (pid) {
        fprintf(stderr, "Skynet is already running, pid = %d.\n", pid);
        return 1;
    }
    
    // 2. 创建守护进程
#ifdef __APPLE__
    fprintf(stderr, "'daemon' is deprecated: first deprecated in OS X 10.5 , use launchd instead.\n");
#else
    if (daemon(1,1)) {  // 保留当前目录，保留标准IO
        fprintf(stderr, "Can't daemonize.\n");
        return 1;
    }
#endif
    
    // 3. 写入PID文件
    pid = write_pid(pidfile);
    if (pid == 0) {
        return 1;
    }
    
    // 4. 重定向标准IO
    if (redirect_fds()) {
        return 1;
    }
    
    return 0;
}
```

### 5.2 进程ID文件管理

#### 5.2.1 检查已有进程

```c
static int
check_pid(const char *pidfile) {
    int pid = 0;
    FILE *f = fopen(pidfile,"r");
    if (f == NULL)
        return 0;
        
    int n = fscanf(f,"%d", &pid);
    fclose(f);
    
    if (n !=1 || pid == 0 || pid == getpid()) {
        return 0;
    }
    
    // 检查进程是否存在
    if (kill(pid, 0) && errno == ESRCH)
        return 0;
        
    return pid;
}
```

#### 5.2.2 写入PID文件（带文件锁）

```c
static int
write_pid(const char *pidfile) {
    FILE *f;
    int pid = 0;
    int fd = open(pidfile, O_RDWR|O_CREAT, 0644);
    if (fd == -1) {
        fprintf(stderr, "Can't create pidfile [%s].\n", pidfile);
        return 0;
    }
    
    f = fdopen(fd, "w+");
    if (f == NULL) {
        fprintf(stderr, "Can't open pidfile [%s].\n", pidfile);
        return 0;
    }
    
    // 获取排他锁
    if (flock(fd, LOCK_EX|LOCK_NB) == -1) {
        int n = fscanf(f, "%d", &pid);
        fclose(f);
        if (n != 1) {
            fprintf(stderr, "Can't lock and read pidfile.\n");
        } else {
            fprintf(stderr, "Can't lock pidfile, lock is held by pid %d.\n", pid);
        }
        return 0;
    }
    
    // 写入当前进程ID
    pid = getpid();
    if (!fprintf(f,"%d\n", pid)) {
        fprintf(stderr, "Can't write pid.\n");
        close(fd);
        return 0;
    }
    fflush(f);
    
    return pid;
}
```

### 5.3 标准IO重定向

```c
static int
redirect_fds() {
    int nfd = open("/dev/null", O_RDWR);
    if (nfd == -1) {
        perror("Unable to open /dev/null: ");
        return -1;
    }
    
    // 重定向标准输入
    if (dup2(nfd, 0) < 0) {
        perror("Unable to dup2 stdin(0): ");
        return -1;
    }
    
    // 重定向标准输出
    if (dup2(nfd, 1) < 0) {
        perror("Unable to dup2 stdout(1): ");
        return -1;
    }
    
    // 重定向标准错误
    if (dup2(nfd, 2) < 0) {
        perror("Unable to dup2 stderr(2): ");
        return -1;
    }
    
    close(nfd);
    return 0;
}
```

---

## 第六部分：系统集成与协作

### 6.1 模块协作关系图

```
┌────────────────────────────────────────────────────────────┐
│                     Skynet系统支持模块协作                   │
├────────────────────────────────────────────────────────────┤
│                                                            │
│  ┌──────────────┐        ┌──────────────┐                │
│  │   启动流程    │        │  环境变量系统  │                │
│  │ daemon_init  │───────▶│ skynet_env   │                │
│  └──────────────┘        └──────────────┘                │
│         │                        │                        │
│         ▼                        ▼                        │
│  ┌──────────────┐        ┌──────────────┐                │
│  │   主线程      │        │   配置加载    │                │
│  │ skynet_start │        │  config.lua  │                │
│  └──────────────┘        └──────────────┘                │
│         │                                                 │
│         ├────────────────┬────────────────┐              │
│         ▼                ▼                ▼              │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐    │
│  │  监控线程     │ │   工作线程    │ │   定时器线程  │    │
│  │thread_monitor│ │thread_worker │ │thread_timer  │    │
│  └──────────────┘ └──────────────┘ └──────────────┘    │
│         │                │                │              │
│         ▼                ▼                ▼              │
│  ┌──────────────────────────────────────────────┐       │
│  │              错误处理系统                      │       │
│  │              skynet_error                    │       │
│  └──────────────────────────────────────────────┘       │
│                           │                              │
│                           ▼                              │
│  ┌──────────────────────────────────────────────┐       │
│  │               日志系统                        │       │
│  │          logger服务 + skynet_log             │       │
│  └──────────────────────────────────────────────┘       │
│                                                          │
└────────────────────────────────────────────────────────────┘
```

### 6.2 启动顺序和依赖关系

#### 6.2.1 系统启动顺序

1. **守护进程初始化**（如果配置了daemon）
   - 检查PID文件
   - 创建守护进程
   - 重定向标准IO

2. **环境变量系统初始化**
   ```c
   skynet_env_init();  // 创建Lua状态机
   ```

3. **加载配置并设置环境变量**
   - 解析配置文件
   - 调用skynet_setenv设置各项配置

4. **启动系统线程**
   ```c
   // skynet_start.c中的start函数
   create_thread(&pid[0], thread_monitor, m);  // 监控线程
   create_thread(&pid[1], thread_timer, m);    // 定时器线程
   create_thread(&pid[2], thread_socket, m);   // 网络线程
   // ... 创建工作线程
   ```

5. **日志服务就绪**
   - `skynet_start` 在创建线程之前调用 `skynet_context_new(logservice, logger)` 启动日志服务
   - bootstrap 继续加载其余系统服务

### 6.3 运行时协作机制

#### 6.3.1 死锁检测协作

```
工作线程处理消息
    ↓
调用skynet_monitor_trigger记录状态
    ↓
处理消息（可能阻塞）
    ↓
监控线程定期检查（每5秒）
    ↓
发现版本号未变化
    ↓
调用skynet_error输出警告
    ↓
logger服务记录日志
```

#### 6.3.2 日志轮转协作

```
外部发送SIGHUP信号
    ↓
信号处理函数设置SIG标志
    ↓
timer线程检测到SIG标志
    ↓
发送PTYPE_SYSTEM消息给logger
    ↓
logger服务重新打开日志文件
```

### 6.4 错误处理和容错机制

#### 6.4.1 监控系统容错

1. **版本号溢出处理**
   - 使用原子操作保证一致性
   - 32位整数足够大，实际不会溢出

2. **服务已销毁处理**
   ```c
   struct skynet_context * ctx = skynet_handle_grab(handle);
   if (ctx == NULL) {
       return;  // 服务已不存在，忽略
   }
   ```

3. **监控器内存管理**
   - 每个工作线程独立的监控器
   - 系统退出时统一释放

#### 6.4.2 日志系统容错

1. **Logger服务未启动**
   ```c
   if (logger == 0) {
       logger = skynet_handle_findname("logger");
   }
   if (logger == 0) {
       return;  // logger未启动，丢弃日志
   }
   ```

2. **日志文件打开失败**
   - 输出错误信息到stderr
   - 返回NULL，调用者需处理

3. **内存分配失败**
   - 使用固定大小缓冲区作为备选
   - perror输出错误信息

### 6.5 性能优化设计

#### 6.5.1 监控系统优化

1. **原子操作**
   - 无锁设计，避免性能损耗
   - 仅在消息处理边界触发

2. **批量检查**
   - 每5秒检查一次所有线程
   - 减少系统调用开销

3. **惰性查找**
   - logger句柄缓存
   - 避免重复查找

#### 6.5.2 日志系统优化

1. **异步日志**
   - 通过消息队列异步处理
   - 不阻塞服务执行

2. **批量刷新**
   - fflush在每条日志后调用
   - 平衡性能和可靠性

3. **二进制日志**
   - 支持二进制格式
   - 减少格式化开销

### 6.6 典型使用场景

#### 6.6.1 死锁调试

当系统出现死锁时，监控系统会输出：
```
error: A message from [ :00000001 ] to [ :00000002 ] maybe in an endless loop (version = 123)
```

调试步骤：
1. 查看源服务(00000001)和目标服务(00000002)
2. 检查对应服务的消息处理函数
3. 查找可能的死循环或阻塞调用

#### 6.6.2 日志分析

日志格式示例：
```
:00000001 1 0 1234567 48656c6c6f
[socket] 1 5 1024 [GET /index.html HTTP/1.1]
```

分析要点：
- 消息来源和类型
- 时间戳用于性能分析
- Socket消息的详细信息

#### 6.6.3 环境变量配置

```lua
-- 配置文件示例
thread = 8
harbor = 1
bootstrap = "snlua bootstrap"
logger = "./logs/skynet.log"    -- 传给日志服务的文件路径，nil 表示输出到 stdout
logservice = "logger"           -- 使用内置 C 日志服务
logpath = "./logs"
```

## 总结

Skynet的监控系统和系统支持工具构成了一个完整的运行时支撑体系：

1. **监控系统**提供了轻量级的死锁检测机制，通过版本号比较实现无锁监控
2. **日志系统**实现了灵活的日志管理，支持服务级别的日志和日志轮转
3. **环境变量系统**提供了线程安全的全局配置存储
4. **错误处理系统**统一了错误输出机制，与日志系统无缝集成
5. **守护进程支持**使得Skynet可以作为系统服务运行

这些模块相互协作，为Skynet提供了稳定可靠的运行环境，同时保持了高性能和低开销的特点。通过合理的模块化设计和清晰的接口定义，这些系统支持工具既保证了功能的完整性，又维持了代码的简洁性和可维护性。
