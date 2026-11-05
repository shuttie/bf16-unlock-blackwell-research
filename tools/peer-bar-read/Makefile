CC ?= gcc
CFLAGS ?= -O2 -Wall
CUDA_INC ?= /usr/local/cuda/include
CUDA_LIB ?= /usr/lib/x86_64-linux-gnu

peer_read: peer_read.c
	$(CC) $(CFLAGS) -I$(CUDA_INC) -o $@ $< -L$(CUDA_LIB) -lcuda -lm

clean:
	rm -f peer_read

.PHONY: clean
