#ifndef SKYNET_HARBOR_H
#define SKYNET_HARBOR_H

#include <stdint.h>
#include <stdlib.h>

// Harbor ID编码规则
// 32位句柄 = [8位Harbor ID][24位本地ID]
//
// 示例：
// 0x01000001 = Harbor 1, Service 1
// 0x02000100 = Harbor 2, Service 256
// 0x00000001 = 单节点模式, Service 1

#define GLOBALNAME_LENGTH 16
#define REMOTE_MAX 256

struct remote_name {
	char name[GLOBALNAME_LENGTH];
	uint32_t handle;
};

struct remote_message {
	struct remote_name destination;
	const void * message;
	size_t sz;
	int type;
};

void skynet_harbor_send(struct remote_message *rmsg, uint32_t source, int session);
int skynet_harbor_message_isremote(uint32_t handle);
void skynet_harbor_init(int harbor);
void skynet_harbor_start(void * ctx);
void skynet_harbor_exit();

#endif
