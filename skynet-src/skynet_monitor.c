#include "skynet.h"

#include "skynet_monitor.h"
#include "skynet_server.h"
#include "skynet.h"
#include "atomic.h"

#include <stdlib.h>
#include <string.h>

struct skynet_monitor {
	ATOM_INT version;    // 原子版本号（消息处理计数）
	int check_version;   // 上次检查的版本号  // 使用原子操作，无需锁
	uint32_t source;     // 当前处理消息的来源服务 handle
	uint32_t destination; // 当前处理消息的目标服务 handle
};

struct skynet_monitor * 
skynet_monitor_new() {
	struct skynet_monitor * ret = skynet_malloc(sizeof(*ret));
	memset(ret, 0, sizeof(*ret));
	return ret;
}

void 
skynet_monitor_delete(struct skynet_monitor *sm) {
	skynet_free(sm);
}

void 
skynet_monitor_trigger(struct skynet_monitor *sm, uint32_t source, uint32_t destination) {
	sm->source = source;
	sm->destination = destination;
	ATOM_FINC(&sm->version);
}

void 
skynet_monitor_check(struct skynet_monitor *sm) {
	if (sm->version == sm->check_version) {
    	// 版本号未变，可能死循环
		if (sm->destination) {
            // 标记服务为 endless 状态
			skynet_context_endless(sm->destination);
            // 记录错误日志
			skynet_error(NULL, "error: A message from [ :%08x ] to [ :%08x ] maybe in an endless loop (version = %d)", sm->source , sm->destination, sm->version);
		}
	} else {
		sm->check_version = sm->version;
	}
}
