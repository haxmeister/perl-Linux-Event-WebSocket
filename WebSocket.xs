#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <stdint.h>
#include <string.h>

#define BQWS_SINGLE_THREAD 1
#define BQWS_DEBUG 0
#define bqws_mutex int
#define bqws_mutex_init(m) ((void)(m))
#define bqws_mutex_free(m) ((void)(m))
#define bqws_mutex_lock(m) ((void)(m))
#define bqws_mutex_unlock(m) ((void)(m))
#define bqws_assert_locked(m) ((void)(m))
#include "vendor/bq_websocket/bq_websocket.c"

typedef struct {
    bqws_socket *ws;
} lews_bq;

static lews_bq *
lews_bq_from_sv(SV *self)
{
    lews_bq *state;

    if (!SvROK(self)) {
        croak("invalid Linux::Event::WebSocket::_BQ object");
    }

    state = INT2PTR(lews_bq *, SvIV((SV *)SvRV(self)));
    if (state == NULL || state->ws == NULL) {
        croak("invalid Linux::Event::WebSocket::_BQ state");
    }
    return state;
}

static SV *
lews_bq_flush(lews_bq *state)
{
    SV *out = newSVpvn("", 0);
    uint8_t buffer[65536];

    for (;;) {
        size_t n = bqws_write_to(state->ws, buffer, sizeof(buffer));
        if (n > 0) {
            sv_catpvn(out, (const char *)buffer, n);
        }
        if (n < sizeof(buffer)) {
            break;
        }
    }

    return out;
}


static SV *
lews_bq_payload_sv(IV opcode, const char *data, size_t size)
{
    const U8 *bytes = (const U8 *)(data == NULL ? "" : data);
    SV *payload = newSVpvn((const char *)bytes, size);

    if (opcode == 1) {
        const U8 *first_variant = NULL;

        if (!is_utf8_invariant_string_loc(bytes, (STRLEN)size, &first_variant)) {
            if (!is_utf8_string_flags(
                    bytes,
                    (STRLEN)size,
                    UTF8_DISALLOW_ILLEGAL_C9_INTERCHANGE
                )) {
                SvREFCNT_dec(payload);
                return NULL;
            }
            SvUTF8_on(payload);
        }
    }

    return payload;
}

static SV *
lews_bq_call_invalid_utf8(SV *target, SV *connection)
{
    SV *error = NULL;
    dSP;

    ENTER;
    SAVETMPS;

    PUSHMARK(SP);
    EXTEND(SP, 2);
    PUSHs(target);
    PUSHs(connection);
    PUTBACK;

    call_method("_bq_invalid_utf8", G_DISCARD | G_EVAL);
    SPAGAIN;

    if (SvTRUE(ERRSV)) {
        error = newSVsv(ERRSV);
        sv_setsv(ERRSV, &PL_sv_undef);
    }

    PUTBACK;
    FREETMPS;
    LEAVE;

    return error;
}

static SV *
lews_bq_call_event(
    SV *target,
    SV *connection,
    IV opcode,
    const char *data,
    size_t size
)
{
    SV *error = NULL;
    dSP;

    ENTER;
    SAVETMPS;

    PUSHMARK(SP);
    EXTEND(SP, 4);
    PUSHs(target);
    PUSHs(connection);
    {
        SV *payload = lews_bq_payload_sv(opcode, data, size);
        if (payload == NULL) {
            FREETMPS;
            LEAVE;
            return lews_bq_call_invalid_utf8(target, connection);
        }
        PUSHs(sv_2mortal(newSViv(opcode)));
        PUSHs(sv_2mortal(payload));
    }
    PUTBACK;

    call_method("_bq_event", G_DISCARD | G_EVAL);
    SPAGAIN;

    if (SvTRUE(ERRSV)) {
        error = newSVsv(ERRSV);
        sv_setsv(ERRSV, &PL_sv_undef);
    }

    PUTBACK;
    FREETMPS;
    LEAVE;

    return error;
}

MODULE = Linux::Event::WebSocket    PACKAGE = Linux::Event::WebSocket::_BQ

PROTOTYPES: DISABLE

SV *
new(class, endpoint_type, max_message_size)
    const char *class
    const char *endpoint_type
    UV max_message_size
PREINIT:
    lews_bq *state;
    bqws_opts opts;
CODE:
    Newxz(state, 1, lews_bq);
    Zero(&opts, 1, bqws_opts);

    opts.skip_handshake = true;
    opts.recv_control_messages = true;
    opts.ping_interval = SIZE_MAX;
    opts.connect_timeout = SIZE_MAX;
    opts.close_timeout = SIZE_MAX;
    opts.ping_response_timeout = SIZE_MAX;
    opts.limits.max_memory_used = SIZE_MAX;
    opts.limits.max_recv_msg_size = (size_t)(max_message_size < 125 ? 125 : max_message_size);
    opts.limits.max_recv_queue_messages = SIZE_MAX;
    opts.limits.max_recv_queue_size = SIZE_MAX;
    opts.limits.max_partial_message_parts = SIZE_MAX;

    if (strEQ(endpoint_type, "client")) {
        state->ws = bqws_new_client(&opts, NULL);
    } else if (strEQ(endpoint_type, "server")) {
        state->ws = bqws_new_server(&opts, NULL);
    } else {
        Safefree(state);
        croak("endpoint_type must be client or server");
    }

    if (state->ws == NULL) {
        Safefree(state);
        croak("bq_websocket context initialization failed");
    }

    RETVAL = newSV(0);
    sv_setref_pv(RETVAL, class, (void *)state);
OUTPUT:
    RETVAL

void
feed(self, callback_target, connection, bytes)
    SV *self
    SV *callback_target
    SV *connection
    SV *bytes
PREINIT:
    lews_bq *state;
    STRLEN len;
    const char *data;
    size_t used;
    bqws_msg *msg;
    bqws_error error;
    SV *callback_error;
PPCODE:
    state = lews_bq_from_sv(self);
    data = SvPVbyte(bytes, len);
    used = 0;
    while (used < (size_t)len) {
        size_t n = bqws_read_from_one_message(
            state->ws,
            data + used,
            (size_t)len - used
        );

        if (n > 0) {
            used += n;
        }

        while ((msg = bqws_recv(state->ws)) != NULL) {
            callback_error = NULL;

            switch (msg->type) {
            case BQWS_MSG_TEXT:
                callback_error = lews_bq_call_event(
                    callback_target, connection, 1, msg->data, msg->size
                );
                break;
            case BQWS_MSG_BINARY:
                callback_error = lews_bq_call_event(
                    callback_target, connection, 2, msg->data, msg->size
                );
                break;
            case BQWS_MSG_CONTROL_CLOSE:
                callback_error = lews_bq_call_event(
                    callback_target, connection, 8, msg->data, msg->size
                );
                break;
            case BQWS_MSG_CONTROL_PING:
            case BQWS_MSG_CONTROL_PONG:
                break;
            default:
                bqws_free_msg(msg);
                croak("unexpected bq_websocket message type %d", (int)msg->type);
            }

            bqws_free_msg(msg);

            if (callback_error != NULL) {
                croak_sv(callback_error);
            }
        }

        if (bqws_get_error(state->ws) != BQWS_OK
            || bqws_get_state(state->ws) >= BQWS_STATE_CLOSING
            || n == 0) {
            break;
        }
    }

    error = bqws_get_error(state->ws);
    if (used != (size_t)len && error == BQWS_OK
        && bqws_get_state(state->ws) < BQWS_STATE_CLOSING) {
        croak("bq_websocket consumed only %lu of %lu input bytes",
            (unsigned long)used, (unsigned long)len);
    }

    EXTEND(SP, 2);
    PUSHs(sv_2mortal(newSViv((IV)error)));
    PUSHs(sv_2mortal(newSVpv(bqws_error_str(error), 0)));
    XSRETURN(2);

SV *
flush(self)
    SV *self
PREINIT:
    lews_bq *state;
CODE:
    state = lews_bq_from_sv(self);
    RETVAL = lews_bq_flush(state);
OUTPUT:
    RETVAL

void
queue_message(self, opcode, bytes)
    SV *self
    IV opcode
    SV *bytes
PREINIT:
    lews_bq *state;
    STRLEN len;
    const char *data;
CODE:
    state = lews_bq_from_sv(self);
    if (opcode == 1) {
        if (SvUTF8(bytes)) {
            data = SvPVutf8(bytes, len);
        } else {
            data = SvPVbyte(bytes, len);
        }

        if (!is_utf8_string_flags(
                (const U8 *)data,
                len,
                UTF8_DISALLOW_ILLEGAL_C9_INTERCHANGE
            )) {
            croak("send_text(): payload contains invalid UTF-8");
        }

        bqws_send(state->ws, BQWS_MSG_TEXT, data, (size_t)len);
    } else if (opcode == 2) {
        data = SvPVbyte(bytes, len);
        bqws_send(state->ws, BQWS_MSG_BINARY, data, (size_t)len);
    } else if (opcode == 9) {
        data = SvPVbyte(bytes, len);
        bqws_send_ping(state->ws, data, (size_t)len);
    } else {
        croak("unsupported bq_websocket opcode %ld", (long)opcode);
    }

    if (bqws_get_error(state->ws) != BQWS_OK) {
        croak("bq_websocket send failed: %s",
            bqws_error_str(bqws_get_error(state->ws)));
    }

void
queue_close(self, status_code, reason)
    SV *self
    UV status_code
    SV *reason
PREINIT:
    lews_bq *state;
    STRLEN len;
    const char *data;
CODE:
    state = lews_bq_from_sv(self);
    data = SvPVbyte(reason, len);
    bqws_close(
        state->ws,
        (bqws_close_reason)status_code,
        data,
        (size_t)len
    );

void
DESTROY(self)
    SV *self
PREINIT:
    lews_bq *state;
CODE:
    if (SvROK(self)) {
        state = INT2PTR(lews_bq *, SvIV((SV *)SvRV(self)));
        if (state != NULL) {
            if (state->ws != NULL) {
                bqws_free_socket(state->ws);
                state->ws = NULL;
            }
            Safefree(state);
            sv_setiv((SV *)SvRV(self), 0);
        }
    }
