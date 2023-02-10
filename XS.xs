#include "easyxs/easyxs.h"

#include <unistd.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>

#include <mongoc/mongoc.h>
#include <bson/bson.h>

#include "courier.h"
#include "worker.h"

#define PERL_NS "MongoDB::XS"

#define USE_LONG_TIMEOUT (sizeof(IV) >= 8)

// Initially there were multiple threads per MongoDB::XS, but that
// runs afoul of the need for cursors to be handled by the same
// session throughout. So, each MongoDB::XS gets exactly one thread
// and exactly one mongoc_client_t; applications that want to parallelize
// can just create multiple MongoDB::XS instances.
//
// We leave this in--and the client-pool logic--just in case it’s ever
// useful to restore.
//
#define THREADS_PER_MDXS 1

typedef struct {
    pid_t                   pid;
    mongoc_uri_t*           uri;
    const char*             uri_str;
    mongoc_client_t*   client;
    worker_in_t             worker_input;
    pthread_t               threads[THREADS_PER_MDXS];
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
    for (unsigned t=0; t<count; t++) {
        Safefree(tasks[t]->db_name);
    }
}

// ----------------------------------------------------------------------

static HV* _write_concern_to_hv(pTHX_ const mongoc_write_concern_t *wc) {
    HV* rethash = newHV();

    const char* wtag = mongoc_write_concern_get_wtag(wc);
    int32_t w32 = mongoc_write_concern_get_w(wc);

    hv_stores(rethash, "w",
        (w32 == MONGOC_WRITE_CONCERN_W_DEFAULT) ? &PL_sv_undef
        : wtag ? newSVpv(wtag, 0)
        : newSViv(w32)
    );

    hv_stores(rethash, "j",
        mongoc_write_concern_journal_is_set(wc)
            ? boolSV( mongoc_write_concern_get_journal(wc) )
            : &PL_sv_undef
    );

    hv_stores( rethash, "wtimeout",
        newSViv(
            USE_LONG_TIMEOUT
                ? mongoc_write_concern_get_wtimeout_int64(wc)
                : mongoc_write_concern_get_wtimeout(wc)
        )
    );

    return rethash;
}

static bool _sv_can_be_int (pTHX_ SV* specimen) {

    // We already ruled out undef, so if it’s not POK then it’s
    // some sort of number.
    if (!SvPOK(specimen)) return true;

    STRLEN len;
    const char* str = SvPVbyte(specimen, len);

    if (str[0] == '-') str++;
    return (strspn(str, "0123456789") == len);
}

// This ignores Perl undef values.
static mongoc_write_concern_t* _hv_to_write_concern(pTHX_ HV* hv) {
    int64_t timeout64;
    int32_t timeout32;
    bool timeout_set = false;

    bool journal = false;
    bool journal_set = false;
    char* wtag = NULL;
    int32_t w;
    bool w_set = false;

    SV** timeout_sv = hv_fetchs(hv, "wtimeout", 0);
    if (timeout_sv && *timeout_sv && SvOK(*timeout_sv)) {
        if (USE_LONG_TIMEOUT) {
            timeout64 = exs_SvIV(*timeout_sv);
        }
        else {
            timeout32 = exs_SvIV(*timeout_sv);
        }

        timeout_set = true;
    }

    SV** journal_sv = hv_fetchs(hv, "j", 0);
    if (journal_sv && *journal_sv && SvOK(*journal_sv)) {
        journal = SvTRUE(*journal_sv);
        journal_set = true;
    }

    SV** w_sv = hv_fetchs(hv, "w", 0);
    if (w_sv && *w_sv && SvOK(*w_sv)) {
        if (_sv_can_be_int(aTHX_ *w_sv)) {
            IV iv = SvIV(*w_sv);
            if (iv > INT32_MAX || iv < INT32_MIN) {
                croak("Unreasonable “w”: %" IVdf, SvIV(*w_sv));
            }

            w = (int32_t) iv;
            w_set = true;
        }
        else {
            wtag = exs_SvPVbyte_nolen(*w_sv);
        }
    }

    mongoc_write_concern_t* wc = mongoc_write_concern_new();

    if (journal_set) {
        mongoc_write_concern_set_journal(wc, journal);
    }

    if (timeout_set) {
        if (USE_LONG_TIMEOUT) {
            mongoc_write_concern_set_wtimeout_int64(wc, timeout64);
        }
        else {
            mongoc_write_concern_set_wtimeout(wc, timeout32);
        }
    }

    if (wtag) {
        mongoc_write_concern_set_wtag(wc, wtag);
    }
    else if (w_set) {
        mongoc_write_concern_set_w(wc, w);
    }

    return wc;
}

// ----------------------------------------------------------------------

#define _CREATE_PERL_CONST(constname) \
    newCONSTSUB( gv_stashpv(PERL_NS, 0), #constname, newSViv(constname) )

// ----------------------------------------------------------------------

MODULE = MongoDB::XS            PACKAGE = MongoDB::XS

PROTOTYPES: DISABLE

BOOT:
    newCONSTSUB( gv_stashpv(PERL_NS, 0), "READ_CONCERN_LOCAL", newSVpvs(MONGOC_READ_CONCERN_LEVEL_LOCAL));
    newCONSTSUB( gv_stashpv(PERL_NS, 0), "READ_CONCERN_MAJORITY", newSVpvs(MONGOC_READ_CONCERN_LEVEL_MAJORITY));
    newCONSTSUB( gv_stashpv(PERL_NS, 0), "READ_CONCERN_LINEARIZABLE", newSVpvs(MONGOC_READ_CONCERN_LEVEL_LINEARIZABLE));
    newCONSTSUB( gv_stashpv(PERL_NS, 0), "READ_CONCERN_AVAILABLE", newSVpvs(MONGOC_READ_CONCERN_LEVEL_AVAILABLE));
    newCONSTSUB( gv_stashpv(PERL_NS, 0), "READ_CONCERN_SNAPSHOT", newSVpvs(MONGOC_READ_CONCERN_LEVEL_SNAPSHOT));

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
        mongoc_client_t *client = mongoc_client_new_from_uri_with_error(uri, &error);
        if (!client) {
            mongoc_uri_destroy(uri);
            Safefree(uri_str);
            croak_sv(_error2sv(aTHX_ &error));
        }

        mongoc_client_set_error_api(client, MONGOC_ERROR_API_VERSION_2);

        RETVAL = exs_new_structref( mdxs_t, classname );

        mdxs_t* mdxs = exs_structref_ptr(RETVAL);
        *mdxs = (mdxs_t) {
            .pid = getpid(),
            .uri = uri,
            .uri_str = uri_str,
            .client = client,
        };

        initialize_worker_input( &mdxs->worker_input );

        mdxs->worker_input.client = client;

        for (unsigned t=0; t<THREADS_PER_MDXS; t++) {
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

        for (unsigned t=0; t<THREADS_PER_MDXS; t++) {
            mdb_task_t* task = calloc(1, sizeof(mdb_task_t));
            *task = (mdb_task_t) {
                .type = TASK_TYPE_SHUTDOWN,
            };

            push_task(&mdxs->worker_input, task);
        }

        for (unsigned t=0; t<THREADS_PER_MDXS; t++) {
            void *ret;
            int err;
            if ( (err = pthread_cancel(mdxs->threads[t])) ) {
                warn("pthread_cancel(): %d (%s)\n", err, strerror(err));
            }
            pthread_join(mdxs->threads[t], &ret);
        }

        mongoc_client_destroy(mdxs->client);
        mongoc_uri_destroy(mdxs->uri);

        destroy_worker_input( &mdxs->worker_input );

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

        // TODO: validate the BSON?

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

SV*
get_read_concern (SV* self_sv)
    CODE:
        mdxs_t* mdxs = exs_structref_ptr(self_sv);
        worker_lock(&mdxs->worker_input);
        const mongoc_read_concern_t *rc = mongoc_client_get_read_concern(mdxs->client);
        const char* level = mongoc_read_concern_get_level(rc);
        RETVAL = level ? newSVpv(level, 0) : &PL_sv_undef;
        worker_unlock(&mdxs->worker_input);
    OUTPUT:
        RETVAL

SV*
get_write_concern (SV* self_sv)
    CODE:
        mdxs_t* mdxs = exs_structref_ptr(self_sv);
        worker_lock(&mdxs->worker_input);
        const mongoc_write_concern_t *wc = mongoc_client_get_write_concern(mdxs->client);
        HV* rethash = _write_concern_to_hv(aTHX_ wc);

        worker_unlock(&mdxs->worker_input);

        RETVAL = newRV_noinc((SV*) rethash);
    OUTPUT:
        RETVAL

SV*
set_read_concern (SV* self_sv, SV* level_sv)
    CODE:
        mdxs_t* mdxs = exs_structref_ptr(self_sv);

        const char* level = exs_SvPVbyte_nolen(level_sv);

        mongoc_read_concern_t *rc = mongoc_read_concern_new();
        if (!mongoc_read_concern_set_level(rc, level)) {
            mongoc_read_concern_destroy(rc);
            croak("Failed to initialize read concern struct!");
        }

        worker_lock(&mdxs->worker_input);
        mongoc_client_set_read_concern(mdxs->client, rc);
        worker_unlock(&mdxs->worker_input);

        mongoc_read_concern_destroy(rc);

        RETVAL = SvREFCNT_inc(self_sv);
    OUTPUT:
        RETVAL

SV*
set_write_concern (SV* self_sv, SV* wc_svhv)
    CODE:
        mdxs_t* mdxs = exs_structref_ptr(self_sv);

        HV* wc_hv = NULL;

        if (SvROK(wc_svhv)) {
            wc_hv = (HV*) SvRV(wc_svhv);
        }

        if (!wc_hv || (SvTYPE((SV*) wc_hv) != SVt_PVHV)) {
            croak("Write concern must be a hashref, not %" SVf, wc_svhv);
        }

        mongoc_write_concern_t *wc = _hv_to_write_concern(aTHX_ wc_hv);

        mongoc_client_set_write_concern(mdxs->client, wc);

        mongoc_write_concern_destroy(wc);

        RETVAL = SvREFCNT_inc(self_sv);

    OUTPUT:
        RETVAL

# ----------------------------------------------------------------------

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
