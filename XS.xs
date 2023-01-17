#include "easyxs/easyxs.h"

#include <unistd.h>
#include <pthread.h>
#include <stdbool.h>

#include <mongoc/mongoc.h>
#include <bson/bson.h>

#include "courier.h"

#define PERL_NS "MongoDB::XS"

// Initially there were multiple threads per MongoDB::XS, but that
// runs afoul of the need for cursors to be handled by the same
// session throughout. So, each MongoDB::XS gets exactly one thread
// and exactly one mongoc_client_t; applications that want to parallelize
// can just create multiple MongoDB::XS instances.
//
#define THREADS_PER_MDXS 1

typedef enum {
    TASK_CREATED,
    TASK_STARTED,
    TASK_SUCCEEDED,
    TASK_FAILED,
} task_state_t;

typedef enum {
    TASK_TYPE_COMMAND = 1,
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

    courier_t*                courier;
} worker_in_t;

typedef struct {
    pid_t                   pid;
    mongoc_uri_t*           uri;
    const char*             uri_str;
    mongoc_client_pool_t*   pool;
    worker_in_t             worker_input;
    pthread_t*              threads;
    unsigned                num_threads;
} mdxs_t;

typedef struct {
#ifdef MULTIPLICITY
    tTHX aTHX;
#endif
    SV* sv;
} mdxs_bson_realloc_ctx_t;

static bool did_init = false;

// ----------------------------------------------------------------------
// Task handlers
// ----------------------------------------------------------------------

static void _handle_command( mongoc_client_t* client, mdb_task_t* task ) {
    bool ok = mongoc_client_command_simple(
        client,
        task->db_name,
        (bson_t*) task->request_payload,
        NULL, //task->read_prefs,
        &task->reply,
        &task->error
    );

    task->state = ok ? TASK_SUCCEEDED : TASK_FAILED;
}

typedef void (*mdxs_handler_t) (mongoc_client_t*, mdb_task_t*);

static mdxs_handler_t mdxs_handlers[] = {
    [TASK_TYPE_COMMAND] = _handle_command,
};

static void execute_task( mongoc_client_t* client, mdb_task_t* task ) {
    mdxs_handlers[task->type](client, task);
}

// ----------------------------------------------------------------------

static inline void _init_mdb_if_needed(pTHX) {
    if (!did_init) {
        SV* version = get_sv(PERL_NS "::VERSION", 0);
        const char* version_str = version ? SvPVbyte_nolen(version) : NULL;
        mongoc_init();

        mongoc_handshake_data_append( PERL_NS, version_str, NULL );

        did_init = true;
    }
}

static void* bson_realloc_sv (void* mem, size_t num_bytes, void* ctx) {
    mdxs_bson_realloc_ctx_t* perl_ctx = ctx;

#ifdef MULTIPLICITY
    tTHX aTHX = perl_ctx->aTHX;
#endif

    SvGROW(perl_ctx->sv, 1 + num_bytes);

    return SvPVX(perl_ctx->sv);
}

static SV* bson2sv (pTHX_ bson_t* bsondoc) {
    uint8_t *buf = NULL;
    size_t buflen = 0;
    bson_t *doc;

    SV* retval = newSVpvs("");
    mdxs_bson_realloc_ctx_t ctx = {
#ifdef MULTIPLICITY
        .aTHX = aTHX,
#endif
        .sv = retval,
    };

    bson_writer_t* writer = bson_writer_new(&buf, &buflen, 0, bson_realloc_sv, &ctx);
    bson_writer_begin(writer, &doc);
    bson_concat(doc, bsondoc);
    SvCUR_set(retval, bson_writer_get_length(writer));
    bson_writer_end(writer);

    return retval;
}

static SV* _error2sv (pTHX_ bson_error_t *error) {
    SV* args[] = {
        newSVuv(error->domain),
        newSVuv(error->code),
        newSVpv(error->message, 0),
        NULL,
    };

    return exs_call_method_scalar(
        newSVpvs(PERL_NS "::Error"),
        "new",
        args
    );
}

void _initialize_worker_input( worker_in_t *worker_input, mongoc_client_pool_t* pool ) {
    worker_input->courier = courier_create();

    pthread_mutex_init(&worker_input->mutex, NULL);  // TODO: check
    pthread_cond_init(&worker_input->tasks_pending, NULL);  // TODO: check

    worker_input->pool = pool;
}

// https://stackoverflow.com/a/525841

static void _lock_worker(worker_in_t *worker_input) {
    if (-1 == pthread_mutex_lock(&worker_input->mutex)) {
        assert(0); // TODO: Should be in a separate object file.
    }
}

static void _unlock_worker(worker_in_t *worker_input) {
    if (-1 == pthread_mutex_unlock(&worker_input->mutex)) {
        assert(0); // TODO: Should be in a separate object file.
    }
}

static void _destroy_tasks(mdb_task_t** tasks, unsigned count) {
    // TODO
    for (unsigned t=0; t<count; t++) {
        Safefree(tasks[t]->db_name);
    }
}

static mdb_task_t** _get_finished_tasks( worker_in_t* worker_input, unsigned *finished_count ) {
    _lock_worker(worker_input);

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

    _unlock_worker(worker_input);

    return retval;
}

static void _push_task( worker_in_t* worker_input, mdb_task_t* new_task ) {
    _lock_worker(worker_input);

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

    _unlock_worker(worker_input);

    pthread_cond_signal(&worker_input->tasks_pending);
// fprintf(stderr, "pushing task - signaled\n");
}

static mdb_task_t* _start_next_task(worker_in_t *worker_input) {
    _lock_worker(worker_input);
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

    _unlock_worker(worker_input);
    // fprintf(stderr, "%p unlocked\n", pthread_self());

    return retval;
}

static void* worker (void* data) {
    //fprintf(stderr, "in thread %ld\n", (intptr_t) pthread_self());
    worker_in_t *input = data;

    mongoc_client_t *client;

    mdb_task_t* task;

    while ( (task = _start_next_task(input)) ) {
    //fprintf(stderr, "%p starts task %p (pool=%p)\n", pthread_self(), task, input->pool);
        client = mongoc_client_pool_pop(input->pool);

        // fprintf(stderr, "Client URI: %s\n", mongoc_uri_get_string( mongoc_client_get_uri(client)));
        // fprintf(stderr, "req p: %p\n", task->command);
        // fprintf(stderr, "Request: %s\n",  bson_as_json(task->command, NULL));

        execute_task(client, task);

        //if (!ok) _set_error(task, &error);
        // printf("OK: %d\n", ok);
        // printf("ERROR: %s\n", task->error.message);
        // printf("REPLY: %s\n", bson_as_json(&task->reply, NULL));

        mongoc_client_pool_push(input->pool, client);
        // fprintf(stderr, "%p ends task\n", pthread_self());

        _lock_worker(input);
        courier_set(input->courier);
        _unlock_worker(input);
    }

    return NULL;
}

static bson_t* str2bson_or_croak(pTHX_ const char* bson, size_t len) {
    bson_t* parsed = bson_new_from_data(
        (const uint8_t*) bson, len
    );
    //printf("bson p: %p\n", command);
    if (!parsed) croak("Invalid BSON given!");

    return parsed;
}

// ----------------------------------------------------------------------

MODULE = MongoDB::XS            PACKAGE = MongoDB::XS

SV*
new(const char* classname, SV* uri_sv)
    CODE:
        _init_mdb_if_needed(aTHX);

        const char* uri_str = savepv( exs_SvPVbyte_nolen(uri_sv) );
        bson_error_t error;
        mongoc_uri_t *uri = mongoc_uri_new_with_error(uri_str, &error);
        if (!uri) {
            Safefree(uri_str);
            croak_sv(_error2sv(aTHX_ &error));
        }

        // This, unfortunately, blocks. Ideally it’d move to the worker.
        mongoc_client_pool_t *pool = mongoc_client_pool_new_with_error(uri, &error);
        if (!pool) {
            Safefree(uri_str);
            croak_sv(_error2sv(aTHX_ &error));
        }

        unsigned threads_count = THREADS_PER_MDXS;   // TODO

        mongoc_client_pool_max_size( pool, threads_count );
        mongoc_client_pool_set_error_api(pool, MONGOC_ERROR_API_VERSION_2);

        RETVAL = exs_new_structref( mdxs_t, classname );

        mdxs_t* mdxs = exs_structref_ptr(RETVAL);
        *mdxs = (mdxs_t) {
            .pid = getpid(),
            .uri = uri,
            .uri_str = uri_str,
            .pool = pool,
            .num_threads = threads_count,
        };

        Newx(mdxs->threads, mdxs->num_threads, pthread_t);

        _initialize_worker_input( &mdxs->worker_input, pool );

        for (unsigned t=0; t<mdxs->num_threads; t++) {
            pthread_create(&mdxs->threads[t], NULL, worker, &mdxs->worker_input);
        }

    OUTPUT:
        RETVAL

void
process (SV* self_sv)
    CODE:
        mdxs_t* mdxs = exs_structref_ptr(self_sv);
        unsigned count = 0;
        mdb_task_t **tasks = _get_finished_tasks(&mdxs->worker_input, &count);
        // printf("received response(s): %u\n", count);
        for (unsigned c=0; c<count; c++) {
            SV* reply_sv;
            SV* coderef = tasks[c]->opaque;

            if (tasks[c]->state == TASK_SUCCEEDED) {
                // printf("REPLY: %s\n", bson_as_json(&tasks[c]->reply, NULL));

                reply_sv = bson2sv(aTHX_ &tasks[c]->reply);
            }
            else {
                reply_sv = _error2sv(aTHX_ &tasks[c]->error);
            }

            SV* args[] = {
                reply_sv,
                NULL,
            };
            SV* err = NULL;

            exs_call_sv_void_trapped( coderef, args, &err );
            SvREFCNT_dec(coderef);

            if (err) {
                warn_sv(err);
                SvREFCNT_dec(err);
            }
        }

        _destroy_tasks(tasks, count);

# SV*
# get_collection(SV* self_sv, const char* dbname, const char* collname)
#     CODE:
#         mdxs_t* mdxs = exs_structref_ptr(self_sv);
#     OUTPUT:
#         RETVAL

void
run_command(SV* self_sv, SV* dbname_sv, SV* bson_sv, SV* cb)
    CODE:
        mdxs_t* mdxs = exs_structref_ptr(self_sv);

        STRLEN bsonlen;
        const char* bson = SvPVbyte(bson_sv, bsonlen);

        const char* dbname = exs_SvPVbyte_nolen(dbname_sv);

        // TODO: validate the BSON

        bson_t* command = str2bson_or_croak(aTHX_ bson, bsonlen);

        //printf("BSON parsed (%p): %s\n", command, bson_as_json(command, NULL));

        mdb_task_t* task = calloc(1, sizeof(mdb_task_t));
        *task = (mdb_task_t) {
            .db_name = savepv(dbname),
            .request_payload = (void*) command,
            .state = TASK_CREATED,
            .reply = BSON_INITIALIZER,
            .type = TASK_TYPE_COMMAND,
            .opaque = SvREFCNT_inc(cb),
        };
        //fprintf(stderr, "new task = %p\n", task);

        _push_task(&mdxs->worker_input, task);

int
fd(SV* self_sv)
    CODE:
        mdxs_t* mdxs = exs_structref_ptr(self_sv);
        RETVAL = courier_read_fd(mdxs->worker_input.courier);
    OUTPUT:
        RETVAL

void
DESTROY(SV* self_sv)
    CODE:
        mdxs_t* mdxs = exs_structref_ptr(self_sv);

        if (PL_dirty && (getpid() == mdxs->pid)) {
            warn("%" SVf ": DESTROY during global destruction; memory leak likely!", self_sv);
        }

        mongoc_client_pool_destroy(mdxs->pool);
        mongoc_uri_destroy(mdxs->uri);

        courier_destroy(mdxs->worker_input.courier);

        for (unsigned t=0; t<mdxs->num_threads; t++) {
            pthread_cancel(mdxs->threads[t]);    // TODO: check
        }

        Safefree(mdxs->threads);
        Safefree(mdxs->uri_str);

        pthread_mutex_destroy(&mdxs->worker_input.mutex);  // TODO: check

char*
mongoc_version_string()
    CODE:
        RETVAL = MONGOC_VERSION_S;
    OUTPUT:
        RETVAL

SV*
bson2cejson(SV* bson_sv)
    ALIAS:
        bson2rejson = 1
    CODE:
        STRLEN len;
        const char* bson = SvPVbyte(bson_sv, len);

        bson_t* bson_obj = str2bson_or_croak(aTHX_ bson, len);

        char *json;
        size_t jsonlen;
        if (ix) {
            json = bson_as_relaxed_extended_json(bson_obj, &jsonlen);
        }
        else {
            json = bson_as_canonical_extended_json(bson_obj, &jsonlen);
        }

        RETVAL = newSVpvn(json, jsonlen);

        bson_free(json);
        bson_destroy(bson_obj);

    OUTPUT:
        RETVAL

SV*
ejson2bson (SV* json_sv)
    CODE:
        STRLEN len;
        const char* json = SvPVbyte(json_sv, len);

        bson_error_t error;

        bson_t* bson = bson_new_from_json ((const uint8_t *)json, (ssize_t) len, &error);
        if (!bson) croak_sv(_error2sv(aTHX_ &error));

        RETVAL = bson2sv(aTHX_ bson);
        bson_destroy(bson);
    OUTPUT:
        RETVAL

void
_xs_cleanup()
    CODE:
        if (did_init) mongoc_cleanup();
