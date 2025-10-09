#include "skynet.h"
#include "skynet_server.h"     // 服务上下文管理
#include "skynet_imp.h"
#include "skynet_mq.h"         // 消息队列
#include "skynet_handle.h"     // 句柄管理
#include "skynet_module.h"     // 模块加载
#include "skynet_timer.h"      // 定时器系统
#include "skynet_monitor.h"    // 监控器
#include "skynet_socket.h"     // 网络系统
#include "skynet_daemon.h"     // 守护进程
#include "skynet_harbor.h"     // 集群支持

#include <pthread.h>          // POSIX 线程
#include <unistd.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>

struct monitor {
	int count;                      // 工作线程数量
	struct skynet_monitor ** m;     // 每个工作线程的监控器数组
	pthread_cond_t cond;           // 条件变量（工作线程同步）	 (保护 sleep 和 quit 变量)
	pthread_mutex_t mutex;         // 互斥锁					(用于工作线程休眠/唤醒)
	int sleep;                     // 休眠的工作线程数			(原子性由 mutex 保护)
	int quit;                      // 退出标志（0=运行，1=退出） (原子性由 mutex 保护)
};

struct worker_parm {
	struct monitor *m;   // 指向全局监控器
	int id;             // 工作线程 ID (0 到 count-1)
	int weight;         // 调度权重 (-1 到 3)
};

static volatile int SIG = 0;

static void
handle_hup(int signal) {
	if (signal == SIGHUP) {
		SIG = 1;  // 设置标志，由定时器线程处理（支持日志文件轮转，不中断服务）
	}
}

// 检查是否应该退出
#define CHECK_ABORT if (skynet_context_total()==0) break;

static void
create_thread(pthread_t *thread, void *(*start_routine) (void *), void *arg) {
	if (pthread_create(thread,NULL, start_routine, arg)) {
		fprintf(stderr, "Create thread failed");
		exit(1);  // 致命错误，直接退出
	}
}

static void
wakeup(struct monitor *m, int busy) {
	if (m->sleep >= m->count - busy) {
        // 如果休眠线程数 >= 空闲线程数，唤醒一个
		// signal sleep worker, "spurious wakeup" is harmless
		pthread_cond_signal(&m->cond);
	}
}

static void *
thread_socket(void *p) {
	struct monitor * m = p;
	skynet_initthread(THREAD_SOCKET);
	for (;;) {
		int r = skynet_socket_poll();  // 核心：轮询网络事件
		if (r==0)
			break;  // socket 系统退出
		if (r<0) {
			CHECK_ABORT
			continue;  // 没有事件，继续轮询
		}
		wakeup(m,0);  // 有网络事件时唤醒工作线程
	}
	return NULL;
}

static void
free_monitor(struct monitor *m) {
	int i;
	int n = m->count;
	for (i=0;i<n;i++) {
		skynet_monitor_delete(m->m[i]);
	}
	pthread_mutex_destroy(&m->mutex);
	pthread_cond_destroy(&m->cond);
	skynet_free(m->m);
	skynet_free(m);
}

static void *
thread_monitor(void *p) {
	struct monitor * m = p;
	int i;
	int n = m->count;
	skynet_initthread(THREAD_MONITOR);
	for (;;) {
		CHECK_ABORT  // 检查是否应该退出
		// 检查所有工作线程
		for (i=0;i<n;i++) {
			skynet_monitor_check(m->m[i]);
		}
		// 休眠5秒（分5次，每次1秒，以便更快响应退出）
		for (i=0;i<5;i++) {
			CHECK_ABORT
			sleep(1);
		}
	}

	return NULL;
}

static void
signal_hup() {
	// make log file reopen

	struct skynet_message smsg;
	smsg.source = 0;
	smsg.session = 0;
	smsg.data = NULL;
	smsg.sz = (size_t)PTYPE_SYSTEM << MESSAGE_TYPE_SHIFT;
	uint32_t logger = skynet_handle_findname("logger");
	if (logger) {
		skynet_context_push(logger, &smsg);
	}
}

static void *
thread_timer(void *p) {
	struct monitor * m = p;
	skynet_initthread(THREAD_TIMER);
	for (;;) {
		skynet_updatetime();        // 更新系统时间
		skynet_socket_updatetime(); // 更新网络时间
		CHECK_ABORT
		wakeup(m,m->count-1);       // 唤醒休眠的工作线程
		usleep(2500);               // 休眠 2.5 毫秒
		if (SIG) {                  // 处理 SIGHUP 信号
			signal_hup();  // 通知日志服务重新打开文件
			SIG = 0;
		}
	}
	// 定时器线程触发退出
	// wakeup socket thread
	skynet_socket_exit();  // 关闭网络线程
	// wakeup all worker thread
	pthread_mutex_lock(&m->mutex);
	m->quit = 1;  // 设置退出标志
	pthread_cond_broadcast(&m->cond);  // 唤醒所有工作线程
	pthread_mutex_unlock(&m->mutex);
	return NULL;
}

static void *
thread_worker(void *p) {
	struct worker_parm *wp = p;
	int id = wp->id;
	int weight = wp->weight;  // 调度权重
	struct monitor *m = wp->m;
	struct skynet_monitor *sm = m->m[id];
	skynet_initthread(THREAD_WORKER);
	struct message_queue * q = NULL;
	while (!m->quit) {
		// 分发消息，weight 决定每次处理的消息数量
		q = skynet_context_message_dispatch(sm, q, weight);
		if (q == NULL) {  // 没有消息可处理
			if (pthread_mutex_lock(&m->mutex) == 0) {
				++ m->sleep;  // 增加休眠计数
				// "spurious wakeup" is harmless,
				// because skynet_context_message_dispatch() can be call at any time.
				if (!m->quit)
					pthread_cond_wait(&m->cond, &m->mutex);  // 原子性休眠, 等待唤醒
				-- m->sleep;  // 被唤醒，减少休眠计数
				if (pthread_mutex_unlock(&m->mutex)) {
					fprintf(stderr, "unlock mutex error");
					exit(1);
				}
			}
		}
	}
	return NULL;
}

static void
start(int thread) {
	pthread_t pid[thread+3];  // 工作线程 + 3个系统线程

    // 1. 初始化监控器结构
	struct monitor *m = skynet_malloc(sizeof(*m));
	memset(m, 0, sizeof(*m));
	m->count = thread;
	m->sleep = 0;

	m->m = skynet_malloc(thread * sizeof(struct skynet_monitor *));
	int i;
    // 2. 为每个工作线程创建监控器
	for (i=0;i<thread;i++) {
		m->m[i] = skynet_monitor_new();
	}
    // 3. 初始化同步原语
	if (pthread_mutex_init(&m->mutex, NULL)) {
		fprintf(stderr, "Init mutex error");
		exit(1);
	}
	if (pthread_cond_init(&m->cond, NULL)) {
		fprintf(stderr, "Init cond error");
		exit(1);
	}

    // 4. 创建系统线程
	create_thread(&pid[0], thread_monitor, m);
	create_thread(&pid[1], thread_timer, m);
	create_thread(&pid[2], thread_socket, m);

	static int weight[] = {   // 前4个线程：每次处理1条消息
		-1, -1, -1, -1, 0, 0, 0, 0,  // 5-8线程：每次处理直到队列空
		1, 1, 1, 1, 1, 1, 1, 1,   // 9-16线程：处理1/2消息
		2, 2, 2, 2, 2, 2, 2, 2,   // 17-24线程：处理1/4消息
		3, 3, 3, 3, 3, 3, 3, 3, };   // 25-32线程：处理1/8消息
    // 5. 创建工作线程
	struct worker_parm wp[thread];
	for (i=0;i<thread;i++) {
		wp[i].m = m;
		wp[i].id = i;
		if (i < sizeof(weight)/sizeof(weight[0])) {
			wp[i].weight= weight[i];
		} else {
			wp[i].weight = 0;
		}
		create_thread(&pid[i+3], thread_worker, &wp[i]);
	}

    // 6. 等待所有线程结束
	for (i=0;i<thread+3;i++) {
		pthread_join(pid[i], NULL); 
	}

    // 7. 释放资源
	free_monitor(m);
}

static void
bootstrap(struct skynet_context * logger, const char * cmdline) {
	int sz = strlen(cmdline);
	char name[sz+1];
	char args[sz+1];
	int arg_pos;
	sscanf(cmdline, "%s", name);  
	arg_pos = strlen(name);
	if (arg_pos < sz) {
		while(cmdline[arg_pos] == ' ') {
			arg_pos++;
		}
		strncpy(args, cmdline + arg_pos, sz);
	} else {
		args[0] = '\0';
	}
	struct skynet_context *ctx = skynet_context_new(name, args);
	if (ctx == NULL) {
		// Bootstrap 服务启动失败
		skynet_error(NULL, "Bootstrap error : %s\n", cmdline);
		skynet_context_dispatchall(logger);
		exit(1);
	}
}

void 
skynet_start(struct skynet_config * config) {
	// register SIGHUP for log file reopen
	// 1. 注册信号处理器
	struct sigaction sa;
	sa.sa_handler = &handle_hup;
	sa.sa_flags = SA_RESTART;
	sigfillset(&sa.sa_mask);
	sigaction(SIGHUP, &sa, NULL);  // 用于日志文件重新打开

    // 2. 守护进程模式（可选）
	if (config->daemon) {
		if (daemon_init(config->daemon)) {
			exit(1);
		}
	}
    // 3. 初始化各子系统（顺序很重要）
	skynet_harbor_init(config->harbor);    		// 集群配置（必须最先）
	skynet_handle_init(config->harbor);			// 句柄池（依赖 harbor）
	skynet_mq_init();							// 消息队列系统
	skynet_module_init(config->module_path);	// C 服务模块加载器
	skynet_timer_init();     					// 定时器系统
	skynet_socket_init();    					// 网络子系统
	skynet_profile_enable(config->profile); 	// 性能分析（可选）

    // 4. 创建日志服务
	struct skynet_context *ctx = skynet_context_new(config->logservice, config->logger);
	if (ctx == NULL) {
		// 日志服务启动失败
		fprintf(stderr, "Can't launch %s service\n", config->logservice);
		exit(1);
	}

	skynet_handle_namehandle(skynet_context_handle(ctx), "logger");

    // 5. 启动 bootstrap 服务
	bootstrap(ctx, config->bootstrap);

    // 6. 创建并启动所有线程
	start(config->thread);

    // 7. 清理资源
	// harbor_exit may call socket send, so it should exit before socket_free
	skynet_harbor_exit();
	skynet_socket_free();
	if (config->daemon) {
		daemon_exit(config->daemon);
	}
}
