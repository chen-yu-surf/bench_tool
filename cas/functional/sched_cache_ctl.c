// SPDX-License-Identifier: GPL-2.0-only
// Copyright (c) 2026 Intel Corporation.
/*
 * Command line wrapper around prctl(PR_SCHED_CACHE), so that a shell script
 * can manage the cache group membership of other tasks the way a workload
 * manager would.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>

#ifndef PR_SCHED_CACHE
#define PR_SCHED_CACHE			82
# define PR_SCHED_CACHE_GET		0
# define PR_SCHED_CACHE_CREATE		1
# define PR_SCHED_CACHE_SHARE_FROM	2
# define PR_SCHED_CACHE_DISABLE		3
# define PR_SCHED_CACHE_ENABLE		4
#endif
#ifndef PR_SCHED_CACHE_GET_ENABLED
# define PR_SCHED_CACHE_GET_ENABLED	5
#endif

/* Mirror the kernel's enum pid_type ordering for the pid_type argument. */
static const char * const scopes[] = { "pid", "tgid", "pgid" };

static void usage(const char *prog)
{
	fprintf(stderr,
		"Usage: %s get         <pid>\n"
		"       %s get_enabled <pid>\n"
		"       %s create      <pid> [pid|tgid|pgid]\n"
		"       %s share       <dst-pid> <src-pid> [pid|tgid|pgid]\n"
		"       %s enable      <pid>\n"
		"       %s disable     <pid>\n"
		"<pid> 0 means the calling task. The scope defaults to pid.\n",
		prog, prog, prog, prog, prog, prog);
	exit(2);
}

static unsigned long parse_pid(const char *s, const char *prog)
{
	char *end;
	long v;

	errno = 0;
	v = strtol(s, &end, 10);
	if (errno || *end || v < 0)
		usage(prog);
	return v;
}

static unsigned long parse_scope(const char *s, const char *prog)
{
	unsigned long i;

	if (!s)
		return 0;
	for (i = 0; i < sizeof(scopes) / sizeof(scopes[0]); i++)
		if (!strcmp(s, scopes[i]))
			return i;
	usage(prog);
	return 0;
}

int main(int argc, char **argv)
{
	const char *prog = argv[0], *op;
	unsigned long subop, pid, arg4 = 0, scope = 0;
	uint64_t val = 0;
	int get = 0;

	if (argc < 3)
		usage(prog);

	op = argv[1];
	pid = parse_pid(argv[2], prog);

	if (!strcmp(op, "get") || !strcmp(op, "get_enabled")) {
		if (argc != 3)
			usage(prog);
		subop = op[3] ? PR_SCHED_CACHE_GET_ENABLED : PR_SCHED_CACHE_GET;
		arg4 = (unsigned long)&val;
		get = 1;
	} else if (!strcmp(op, "create")) {
		if (argc > 4)
			usage(prog);
		subop = PR_SCHED_CACHE_CREATE;
		scope = parse_scope(argv[3], prog);
	} else if (!strcmp(op, "share")) {
		if (argc < 4 || argc > 5)
			usage(prog);
		subop = PR_SCHED_CACHE_SHARE_FROM;
		arg4 = parse_pid(argv[3], prog);
		scope = parse_scope(argv[4], prog);
	} else if (!strcmp(op, "enable") || !strcmp(op, "disable")) {
		if (argc != 3)
			usage(prog);
		subop = op[0] == 'e' ? PR_SCHED_CACHE_ENABLE :
				       PR_SCHED_CACHE_DISABLE;
	} else {
		usage(prog);
	}

	if (prctl(PR_SCHED_CACHE, subop, pid, arg4, scope)) {
		fprintf(stderr, "%s %s %lu: %s\n", prog, op, pid, strerror(errno));
		return 1;
	}

	if (get)
		printf("%#llx\n", (unsigned long long)val);
	return 0;
}
