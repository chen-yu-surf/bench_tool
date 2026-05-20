# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026 Intel Corporation.

CC = gcc
CFLAGS = -O2 -W -Wall -pthread

BIN = test_llc_agg cas_worker sched_cache_ctl

all: $(BIN)

test_llc_agg: test_llc_agg.c
	$(CC) $(CFLAGS) -o $@ $<

cas_worker: cas_worker.c
	$(CC) $(CFLAGS) -o $@ $<

sched_cache_ctl: sched_cache_ctl.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	-rm -f $(BIN)

.PHONY: all clean
