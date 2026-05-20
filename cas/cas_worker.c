// SPDX-License-Identifier: GPL-2.0-only
// Copyright (c) 2026 Intel Corporation.
/*
 * Same workload as test_llc_agg, but the thread count is taken from the
 * command line so one binary serves both the multi-threaded and the
 * multi-process tests, and it runs until killed.
 *
 * Usage: cas_worker [nthreads]
 */
#define _GNU_SOURCE
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define ARRAY_SIZE (1024 * 1024)  /* 4MB shared - fits in LLC */
static int shared_array[ARRAY_SIZE];
static long nthreads;

static void *worker(void *arg)
{
	long id = (long)arg;
	long chunk = ARRAY_SIZE / nthreads;

	while (1) {
		for (long i = id * chunk; i < (id + 1) * chunk; i++)
			shared_array[i]++;
	}
	return NULL;
}

int main(int argc, char **argv)
{
	pthread_t tid;

	nthreads = argc > 1 ? atol(argv[1]) : 4;
	if (nthreads < 1 || nthreads > ARRAY_SIZE) {
		fprintf(stderr, "invalid thread count\n");
		return 1;
	}

	for (long i = 0; i < nthreads; i++) {
		if (pthread_create(&tid, NULL, worker, (void *)i)) {
			perror("pthread_create");
			return 1;
		}
	}

	while (1)
		pause();
	return 0;
}
