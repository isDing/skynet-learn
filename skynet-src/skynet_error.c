// 说明（C 层日志入口）：
//  - 提供 skynet_error，用于将格式化文本投递到名为 "logger" 的服务（PTYPE_TEXT）。
//  - 特殊处理 "%*s"：来自 Lua VM 的 lerror 以长度+字符串传递，避免二次格式化。
//  - 首次调用会缓存 logger 句柄；如未找到 logger，直接返回（静默丢弃）。
#include "skynet.h"
#include "skynet_handle.h"
#include "skynet_imp.h"
#include "skynet_mq.h"
#include "skynet_server.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

// 小缓冲：普通格式化先写临时栈缓冲，越界再由 vsnprintf 重新分配
#define LOG_MESSAGE_SIZE 256

static int
log_try_vasprintf(char **strp, const char *fmt, va_list ap) {
	if (strcmp(fmt, "%*s") == 0) {
        // 特殊处理 Lua 错误消息：按长度原样复制
		// for `lerror` in lua-skynet.c
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

void
skynet_error(struct skynet_context * context, const char *msg, ...) {
	static uint32_t logger = 0;
	if (logger == 0) {
		// 查找 logger 服务（由 skynet_start 在早期命名）
		logger = skynet_handle_findname("logger");
	}
	if (logger == 0) {
		return;  // logger 服务未启动（早期错误或配置禁用 logger）
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

	if (data == NULL) { // unlikely：未能通过短缓冲分配数据
		data = skynet_malloc(len + 1);
		va_start(ap, msg);
		len = vsnprintf(data, len + 1, msg, ap);
		va_end(ap);
		if (len < 0) {
			skynet_free(data);
			perror("vsnprintf error :");
			return;
		}
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
	// 投递到 logger 服务，由其统一输出
	skynet_context_push(logger, &smsg);
}
