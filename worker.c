#include <assert.h>
#include <stdbool.h>

#include "worker.h"

void worker_lock (worker_in_t *worker_input) {
    assert( -1 != pthread_mutex_lock(&worker_input->mutex) );
}

void worker_unlock (worker_in_t *worker_input) {
    assert( -1 != pthread_mutex_unlock(&worker_input->mutex) );
}

void initialize_worker_input (worker_in_t *worker_input) {
    worker_input->courier = courier_create();

    assert( !pthread_mutex_init(&worker_input->mutex, NULL) );
    assert( !pthread_cond_init(&worker_input->tasks_pending, NULL) );
}

void destroy_worker_input (worker_in_t *worker_input) {
    courier_destroy(worker_input->courier);

    while (1) {
        pthread_cond_broadcast(&worker_input->tasks_pending);
        int err = pthread_cond_destroy(&worker_input->tasks_pending);
        if (!err) break;

        if (err == EBUSY) continue;

        fprintf(stderr, "pthread_cond_destroy: %s (%d)\n", strerror(err), err);
        assert(0);
    }

    while (1) {
        int err = pthread_mutex_destroy(&worker_input->mutex);
        if (!err) break;

        if (err == EBUSY) {

            // Unlock is not idempotent!
            pthread_mutex_unlock(&worker_input->mutex);

            continue;
        }

        fprintf(stderr, "pthread_mutex_destroy: %s (%d)\n", strerror(err), err);

        assert(0);
    }
}

static mdb_task_t* _start_next_task(worker_in_t *worker_input) {
    worker_lock(worker_input);
    // fprintf(stderr, "%p locked\n", pthread_self());

    mdb_task_t* retval = NULL;

    while (!retval) {
// fprintf(stderr, "tasks count: %u\n", worker_input->num_tasks);
        for (unsigned t=0; t<worker_input->num_tasks; t++) {
// printf("%p, task[%u]: %p\n", pthread_self(), t, worker_input->tasks[t]);
            if (worker_input->tasks[t]->state == TASK_CREATED) {
                retval = worker_input->tasks[t];
                retval->state = TASK_STARTED;
                break;
            }
        }

        if (!retval) {
            // fprintf(stderr, "%p awaiting pending task; giving up lock\n", pthread_self());
            if (-1 == pthread_cond_wait(&worker_input->tasks_pending, &worker_input->mutex)) {
                assert(0);
            }
            // fprintf(stderr, "thread %p: tasks pending!!\n", pthread_self());
        }
    }

    worker_unlock(worker_input);
    // fprintf(stderr, "%p unlocked\n", pthread_self());

    return retval;
}

// ----------------------------------------------------------------------
// Task handlers
// ----------------------------------------------------------------------

static task_state_t _handle_command( worker_in_t *input, mdb_task_t* task ) {
    mongoc_client_t* client = input->client;

    mdb_task_command_t* cmd = &task->per_type.command;

    bool ok = mongoc_client_command_simple(
        client,
        cmd->db_name,
        (bson_t*) cmd->request_payload,
        NULL, //task->read_prefs,
        &cmd->reply,
        &cmd->error
    );

   return ( ok ? TASK_SUCCEEDED : TASK_FAILED );
}

static task_state_t _handle_get_read_concern( worker_in_t *input, mdb_task_t* task ) {
    mongoc_client_t* client = input->client;

    task->per_type.read_concern = mongoc_read_concern_copy(
        mongoc_client_get_read_concern(client)
    );

    return TASK_SUCCEEDED;
}

static task_state_t _handle_get_write_concern( worker_in_t *input, mdb_task_t* task ) {
    mongoc_client_t* client = input->client;

    task->per_type.write_concern = mongoc_write_concern_copy(
        mongoc_client_get_write_concern(client)
    );

    return TASK_SUCCEEDED;
}

static task_state_t _handle_set_read_concern( worker_in_t *input, mdb_task_t* task ) {
    mongoc_client_t* client = input->client;

    mongoc_client_set_read_concern(client, task->per_type.read_concern);

    mongoc_read_concern_destroy(task->per_type.read_concern);

    return TASK_SUCCEEDED;
}

static task_state_t _handle_set_write_concern( worker_in_t *input, mdb_task_t* task ) {
    mongoc_client_t* client = input->client;

    mongoc_client_set_write_concern(client, task->per_type.write_concern);

    mongoc_write_concern_destroy(task->per_type.write_concern);

    return TASK_SUCCEEDED;
}

typedef task_state_t (*mdxs_handler_t) (worker_in_t*, mdb_task_t*);

static mdxs_handler_t mdxs_handlers[] = {
    [TASK_TYPE_SHUTDOWN] = NULL,
    [TASK_TYPE_COMMAND] = _handle_command,
    [TASK_TYPE_GET_READ_CONCERN] = _handle_get_read_concern,
    [TASK_TYPE_GET_WRITE_CONCERN] = _handle_get_write_concern,
    [TASK_TYPE_SET_READ_CONCERN] = _handle_set_read_concern,
    [TASK_TYPE_SET_WRITE_CONCERN] = _handle_set_write_concern,
};

static void _execute_task( worker_in_t *input, mdb_task_t* task ) {
    mdxs_handler_t handler = mdxs_handlers[task->type];
    assert(handler);
    task->state = handler(input, task);

    worker_lock(input);
    courier_set(input->courier);
    worker_unlock(input);
}

// ----------------------------------------------------------------------

mdb_task_t** get_finished_tasks( worker_in_t* worker_input, unsigned *finished_count ) {
    worker_lock(worker_input);

    mdb_task_t** retval = NULL;

    if (courier_read_pending(worker_input->courier)) {

// fprintf(stderr, "read is pending\n");
        mdb_task_t* finished[worker_input->num_tasks];
        *finished_count = 0;

// fprintf(stderr, "tasks count: %u\n", worker_input->num_tasks);
        for (unsigned i=0; i<worker_input->num_tasks; i++) {
// fprintf(stderr, "task[%u] state: %d\n", i, worker_input->tasks[i]->state);
            if (!TASK_FINISHED(worker_input->tasks[i]->state)) continue;

            finished[*finished_count] = worker_input->tasks[i];
            (*finished_count)++;
        }
// fprintf(stderr, "finished count: %u\n", *finished_count);

        if (*finished_count) {
            retval = calloc(*finished_count, sizeof(mdb_task_t*));
            memcpy(retval, finished, *finished_count * sizeof(mdb_task_t*));

            unsigned new_queue_size =  worker_input->num_tasks - *finished_count;
            mdb_task_t** new_queue = calloc(new_queue_size, sizeof(mdb_task_t*));
            mdb_task_t** nqp = new_queue;

            for (unsigned i=0; i<worker_input->num_tasks; i++) {
                if (TASK_FINISHED(worker_input->tasks[i]->state)) continue;

                *nqp = worker_input->tasks[i];
                nqp++;
            }

            free(worker_input->tasks);
            worker_input->tasks = new_queue;
            worker_input->num_tasks = new_queue_size;

            courier_read(worker_input->courier);
        }
        else {
            fprintf(stderr, "huh?? read pending but no finished tasks?\n");
        }
    }

// for (unsigned i=0; i<worker_input->num_tasks; i++) {
// fprintf(stderr, "tasks after get-finished: task[%u]=%p\n", i, worker_input->tasks[i]);
// }

    worker_unlock(worker_input);

    return retval;
}

void push_task( worker_in_t* worker_input, const mdb_task_t* new_task_orig ) {
    mdb_task_t* new_task = calloc(1, sizeof(mdb_task_t));
    memcpy(new_task, new_task_orig, sizeof(mdb_task_t));

    worker_lock(worker_input);

    mdb_task_t** new_queue = calloc(
        1 + worker_input->num_tasks,
        sizeof(mdb_task_t*)
    );
    new_queue[worker_input->num_tasks] = new_task;

    if (worker_input->num_tasks) {
// for (unsigned i=0; i<worker_input->num_tasks; i++) {
// fprintf(stderr, "before memcpy: task[%u]=%p\n", i, worker_input->tasks[i]);
// }
        memcpy(
            new_queue,
            worker_input->tasks,
            worker_input->num_tasks * sizeof(mdb_task_t*)
        );

        free(worker_input->tasks);
    }

    worker_input->tasks = new_queue;
    worker_input->num_tasks++;

// for (unsigned i=0; i<worker_input->num_tasks; i++) {
// fprintf(stderr, "tasks after push: task[%u]=%p\n", i, worker_input->tasks[i]);
// }

    worker_unlock(worker_input);

    pthread_cond_signal(&worker_input->tasks_pending);
// fprintf(stderr, "pushing task - signaled\n");
}

void* worker_body (void* data) {
    //fprintf(stderr, "in thread %ld\n", (intptr_t) pthread_self());
    worker_in_t *input = data;

    mdb_task_t* task;

    bool sent_shutdown = false;

    while (!sent_shutdown) {
        task = _start_next_task(input);

        switch (task->type) {
            case TASK_TYPE_SHUTDOWN:
                sent_shutdown = true;
                break;

            default:
                _execute_task(input, task);
        }
    }

    return NULL;
}
