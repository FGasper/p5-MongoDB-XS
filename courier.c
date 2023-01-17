#include <stdlib.h>
#include <pthread.h>
#include <assert.h>
#include "courier.h"

struct courier_t {
	// Ideally everyone would just have eventfd, but alas.
	int                     fds[2];
	bool                    read_pending;
};

static const char PIPECHAR = 'x';

courier_t* courier_create (void) {
	courier_t *self = calloc(1, sizeof(courier_t));
	assert(!pipe(self->fds));

	// We leave the pipe blocking for now. If that proves problematic
	// it’s easy to switch to nonblocking.

	return self;
}

void courier_destroy (courier_t *self) {
	assert(!close(self->fds[1]));
	assert(!close(self->fds[0]));
	//assert(!pthread_mutex_destroy(&self->mutex));

	free(self);
}

int courier_read_fd (courier_t *self) {
	return self->fds[0];
}

bool courier_read_pending (courier_t *self) {
	return self->read_pending;
}

/*
void courier_lock (courier_t *self) {
	assert(!pthread_mutex_lock(&self->mutex));
}

void courier_unlock (courier_t *self) {
	assert(!pthread_mutex_unlock(&self->mutex));
}
*/

void courier_set (courier_t *self) {
	if (!self->read_pending) {
		self->read_pending = true;
		assert(1 == write(self->fds[1], &PIPECHAR, sizeof(char)));
	}
}

void courier_read (courier_t *self) {
	int got = 0;
	char buf;
	while (got < 1) {
		got = read(self->fds[0], &buf, 1);
		assert(got >= 0);
	}

	assert(buf == PIPECHAR);

	self->read_pending = false;
}
