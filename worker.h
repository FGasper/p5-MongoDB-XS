#ifndef MDXS_WORKER_H
#define MDXS_WORKER_H

#include <pthread.h>
#include <mongoc/mongoc.h>
#include <bson/bson.h>

#include "courier.h"

typedef enum {
    TASK_CREATED,
    TASK_STARTED,
    TASK_SUCCEEDED,
    TASK_FAILED,
} task_state_t;

typedef enum {
    TASK_TYPE_COMMAND = 1,
    TASK_TYPE_SHUTDOWN,
} mdb_task_type_t;

#define TASK_FINISHED(x) (x > TASK_STARTED)

typedef struct {
    const char*                 db_name;
    void*                *request_payload;
    //const mongoc_read_prefs_t*  read_prefs;
    bson_t                reply;
    bson_error_t          error;
    task_state_t      state;
    mdb_task_type_t  type;
    void*           opaque;
} mdb_task_t;

typedef struct {
    pthread_mutex_t         mutex;
    pthread_cond_t          tasks_pending;
    mongoc_client_pool_t*   pool;
    mdb_task_t**            tasks;
    unsigned                num_tasks;

    courier_t*              courier;
} worker_in_t;

void worker_lock (worker_in_t*);
void worker_unlock (worker_in_t*);
void initialize_worker_input (worker_in_t*);
void destroy_worker_input (worker_in_t*);

mdb_task_t** get_finished_tasks( worker_in_t*, unsigned* );

void push_task( worker_in_t*, mdb_task_t* );

void* worker_body (void*);

#endif
