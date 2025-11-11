// 说明（系统级 C 服务：logger）
//
// 用途：
//  - 接收全局日志（PTYPE_TEXT）并输出到 stdout 或指定文件
//  - 支持通过 PTYPE_SYSTEM 触发“重新打开日志文件”（典型于 SIGHUP 日志轮转）
//
// 启动方式：
//  - 由 C 层在引导阶段创建（参见 skynet_start.c -> skynet_context_new(logservice, logger)）
//  - 被命名为 "logger"，供 skynet_error 等接口查找并投递日志
//  - 配置文件：logger = "/path/to/skynet.log"（若为 NULL/未配置，则输出到 stdout）
//
// 消息说明：
//  - PTYPE_TEXT ：写入一行日志（可带时间戳与来源 handle）
//  - PTYPE_SYSTEM ：收到后若设置了文件路径，则通过 freopen 以追加模式重新打开文件
//
// 关键点：
//  - timestring() 基于 skynet 启动时间与当前厘秒合成“日期.厘秒”时间戳
//  - logger_cb() 为回调入口，根据消息类型分类处理

#include "skynet.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

struct logger {
	FILE * handle;              // 当前写入目标（文件或 stdout）
	char * filename;            // 当写入文件时保存路径
	uint32_t starttime;         // skynet 启动时间（秒），与 now/100 相加得到当前绝对时间
	int close;                  // 是否需要在释放时关闭句柄
};

struct logger *
logger_create(void) {
	struct logger * inst = skynet_malloc(sizeof(*inst));
	inst->handle = NULL;
	inst->close = 0;
	inst->filename = NULL;

	return inst;
}

void
logger_release(struct logger * inst) {
	if (inst->close) {
		fclose(inst->handle);
	}
	skynet_free(inst->filename);
	skynet_free(inst);
}

#define SIZETIMEFMT	250

static int
timestring(struct logger *inst, char tmp[SIZETIMEFMT]) {
	// 将当前厘秒时间换算为绝对时间（秒），并格式化为可读字符串
	uint64_t now = skynet_now();          // 当前时间（厘秒）
	time_t ti = now/100 + inst->starttime; // 折算到绝对秒
	struct tm info;
	(void)localtime_r(&ti,&info);
	strftime(tmp, SIZETIMEFMT, "%d/%m/%y %H:%M:%S", &info);
	return now % 100;  // 返回厘秒小数部分（0-99），用于拼接成 xx.xx 的形式
}

static int
logger_cb(struct skynet_context * context, void *ud, int type, int session, uint32_t source, const void * msg, size_t sz) {
	struct logger * inst = ud;
	// 根据消息类型进行处理：
	switch (type) {
	case PTYPE_SYSTEM:
        // 系统消息：触发日志轮转。若指定了文件名，则重新以追加模式打开
		if (inst->filename) {
			inst->handle = freopen(inst->filename, "a", inst->handle);
		}
		break;
	case PTYPE_TEXT:
		// 文本日志：按格式输出（可选时间戳 + 源服务地址 + 文本 + 换行）
		if (inst->filename) {
			char tmp[SIZETIMEFMT];
			int csec = timestring(ud, tmp);
			fprintf(inst->handle, "%s.%02d ", tmp, csec);
		}
		fprintf(inst->handle, "[:%08x] ", source);
		fwrite(msg, sz , 1, inst->handle);
		fprintf(inst->handle, "\n");
		fflush(inst->handle);
		break;
	}

	return 0;
}

int
logger_init(struct logger * inst, struct skynet_context *ctx, const char * parm) {
	const char * r = skynet_command(ctx, "STARTTIME", NULL);
	inst->starttime = strtoul(r, NULL, 10);
	// 若配置中提供了日志文件路径（parm），则以追加模式写入文件；否则输出到 stdout
	if (parm) {
		inst->handle = fopen(parm,"a");
		if (inst->handle == NULL) {
			return 1;
		}
		inst->filename = skynet_malloc(strlen(parm)+1);
		strcpy(inst->filename, parm);
		inst->close = 1;
	} else {
		inst->handle = stdout;
	}
	if (inst->handle) {
		// 注册回调：接收来自各服务的日志消息
		skynet_callback(ctx, inst, logger_cb);
		return 0;
	}
	return 1;
}
