#ifndef SKYNET_IMP_H
#define SKYNET_IMP_H

#include <string.h>

struct skynet_config {
	int thread;              // 工作线程数量
	int harbor;              // 集群节点 ID (1-255)
	int profile;             // 是否开启性能分析
	const char * daemon;     // 守护进程 PID 文件路径
	const char * module_path; // C 服务模块搜索路径
	const char * bootstrap;  // 启动命令（通常是 "snlua bootstrap"）
	const char * logger;     // 日志文件路径
	const char * logservice; // 日志服务名称（默认 "logger"）
};

#define THREAD_WORKER 0
#define THREAD_MAIN 1
#define THREAD_SOCKET 2
#define THREAD_TIMER 3
#define THREAD_MONITOR 4

void skynet_start(struct skynet_config * config);

static inline char *
skynet_strndup(const char *str, size_t size) {
	char * ret = skynet_malloc(size+1);
	if (ret == NULL) return NULL;
	memcpy(ret, str, size);
	ret[size] = '\0';
	return ret;
}

static inline char *
skynet_strdup(const char *str) {
	size_t sz = strlen(str);
	return skynet_strndup(str, sz);
}

#endif
