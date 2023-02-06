#include "easyxs/easyxs.h"

#include <unistd.h>
#include <pthread.h>
#include <stdbool.h>

#include <mongoc/mongoc.h>
#include <bson/bson.h>

#include "courier.h"
#include "worker.h"

#define PERL_NS "MongoDB::XS"

// Initially there were multiple threads per MongoDB::XS, but that
// runs afoul of the need for cursors to be handled by the same
// session throughout. So, each MongoDB::XS gets exactly one thread
// and exactly one mongoc_client_t; applications that want to parallelize
// can just create multiple MongoDB::XS instances.
//
#define THREADS_PER_MDXS 1

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

static bson_t* str2bson_or_croak(pTHX_ const char* bson, size_t len) {
    bson_t* parsed = bson_new_from_data(
        (const uint8_t*) bson, len
    );
    //printf("bson p: %p\n", command);
    if (!parsed) croak("Invalid BSON given!");

    return parsed;
}

static void _destroy_tasks(mdb_task_t** tasks, unsigned count) {
    // TODO
    for (unsigned t=0; t<count; t++) {
        Safefree(tasks[t]->db_name);
    }
}

// ----------------------------------------------------------------------

MODULE = MongoDB::XS            PACKAGE = MongoDB::XS

PROTOTYPES: DISABLE

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
            mongoc_uri_destroy(uri);
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

        initialize_worker_input( &mdxs->worker_input );

        mdxs->worker_input.pool = pool;

        for (unsigned t=0; t<mdxs->num_threads; t++) {
            pthread_create(&mdxs->threads[t], NULL, worker_body, &mdxs->worker_input);
        }

    OUTPUT:
        RETVAL

void
DESTROY(SV* self_sv)
    CODE:
        mdxs_t* mdxs = exs_structref_ptr(self_sv);

        if (PL_dirty && (getpid() == mdxs->pid)) {
            warn("%" SVf ": DESTROY during global destruction; memory leak likely!", self_sv);
        }

        for (unsigned t=0; t<mdxs->num_threads; t++) {
            mdb_task_t* task = calloc(1, sizeof(mdb_task_t));
            *task = (mdb_task_t) {
                .type = TASK_TYPE_SHUTDOWN,
            };

            push_task(&mdxs->worker_input, task);
        }

        for (unsigned t=0; t<mdxs->num_threads; t++) {
            void *ret;
            pthread_join(mdxs->threads[t], &ret);
        }

        mongoc_client_pool_destroy(mdxs->pool);
        mongoc_uri_destroy(mdxs->uri);

        destroy_worker_input( &mdxs->worker_input );

        Safefree(mdxs->threads);
        Safefree(mdxs->uri_str);

void
process (SV* self_sv)
    CODE:
        mdxs_t* mdxs = exs_structref_ptr(self_sv);
        unsigned count = 0;
        mdb_task_t **tasks = get_finished_tasks(&mdxs->worker_input, &count);
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

        push_task(&mdxs->worker_input, task);

int
fd(SV* self_sv)
    CODE:
        mdxs_t* mdxs = exs_structref_ptr(self_sv);
        RETVAL = courier_read_fd(mdxs->worker_input.courier);
    OUTPUT:
        RETVAL

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
