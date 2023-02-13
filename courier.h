/*
 * “Courier” is the means by which the Perl application can know whether
 * there is a task finished.
 */

#ifndef MDXS_COURIER_H
#define MDXS_COURIER_H

#include <stdbool.h>
#include <unistd.h>

typedef struct courier_t courier_t;

courier_t* courier_create (void);
void courier_destroy (courier_t*);
//void courier_lock (courier_t*);
//void courier_unlock (courier_t*);

void courier_set (courier_t*);
void courier_read (courier_t*);

int courier_read_fd (courier_t*);
bool courier_read_pending (courier_t*);

#endif
