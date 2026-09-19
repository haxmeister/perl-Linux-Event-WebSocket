#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <wslay/wslay.h>
#include <sys/random.h>
#include <errno.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    wslay_event_context_ptr ctx;
    const uint8_t *input;
    size_t input_len;
    size_t input_pos;
    SV *output;
    SV *callback_target;
    SV *callback_error;
    int in_recv;
    int forced_failure_code;
    int client;
} lews_wslay;

static lews_wslay *
lews_wslay_from_sv(SV *self)
{
    if (!SvROK(self)) {
        croak("invalid Linux::Event::WebSocket::_Wslay object");
    }
    return INT2PTR(lews_wslay *, SvIV((SV *)SvRV(self)));
}

static ssize_t
lews_recv_callback(wslay_event_context_ptr ctx, uint8_t *buf, size_t len,
                   int flags, void *user_data)
{
    lews_wslay *state = (lews_wslay *)user_data;
    size_t available;
    size_t take;
    (void)flags;

    if (state->input_pos >= state->input_len) {
        wslay_event_set_error(ctx, WSLAY_ERR_WOULDBLOCK);
        return -1;
    }

    available = state->input_len - state->input_pos;
    take = available < len ? available : len;
    memcpy(buf, state->input + state->input_pos, take);
    state->input_pos += take;
    return (ssize_t)take;
}

static ssize_t
lews_send_callback(wslay_event_context_ptr ctx, const uint8_t *data, size_t len,
                   int flags, void *user_data)
{
    lews_wslay *state = (lews_wslay *)user_data;
    (void)flags;

    if (state->output == NULL) {
        wslay_event_set_error(ctx, WSLAY_ERR_CALLBACK_FAILURE);
        return -1;
    }

    sv_catpvn(state->output, (const char *)data, len);
    return (ssize_t)len;
}

static int
lews_genmask_callback(wslay_event_context_ptr ctx, uint8_t *buf, size_t len,
                      void *user_data)
{
    size_t offset = 0;
    (void)user_data;

    while (offset < len) {
        ssize_t n = getrandom(buf + offset, len - offset, 0);
        if (n > 0) {
            offset += (size_t)n;
            continue;
        }
        if (n < 0 && errno == EINTR) {
            continue;
        }
        wslay_event_set_error(ctx, WSLAY_ERR_CALLBACK_FAILURE);
        return -1;
    }
    return 0;
}

static void
lews_on_frame_recv_start_callback(
    wslay_event_context_ptr ctx,
    const struct wslay_event_on_frame_recv_start_arg *arg,
    void *user_data)
{
    lews_wslay *state = (lews_wslay *)user_data;

    if (arg->opcode == WSLAY_CONNECTION_CLOSE && arg->payload_length == 1) {
        int rc = wslay_event_queue_close(
            ctx,
            WSLAY_CODE_PROTOCOL_ERROR,
            NULL,
            0
        );
        if (rc == 0 || rc == WSLAY_ERR_NO_MORE_MSG) {
            state->forced_failure_code = WSLAY_CODE_PROTOCOL_ERROR;
        }
        wslay_event_shutdown_read(ctx);
    }
}

static SV *
lews_payload_sv(const uint8_t *data, size_t len, int text)
{
    SV *sv;
    size_t i;

    sv = newSVpvn(data == NULL ? "" : (const char *)data, len);
    if (text) {
        for (i = 0; i < len; ++i) {
            if (data[i] & 0x80u) {
                SvUTF8_on(sv);
                break;
            }
        }
    }
    return sv;
}

static SV *
lews_protocol_close(lews_wslay *state, uint16_t status_code)
{
    uint8_t frame[8];
    uint8_t mask[4];
    uint8_t payload[2];
    uint16_t ncode;

    ncode = htons(status_code);
    memcpy(payload, &ncode, 2);
    frame[0] = 0x88u;

    if (!state->client) {
        frame[1] = 2u;
        memcpy(frame + 2, payload, 2);
        return newSVpvn((const char *)frame, 4);
    }

    if (lews_genmask_callback(state->ctx, mask, sizeof(mask), state) != 0) {
        croak("unable to generate WebSocket close mask");
    }

    frame[1] = 0x82u;
    memcpy(frame + 2, mask, 4);
    frame[6] = payload[0] ^ mask[0];
    frame[7] = payload[1] ^ mask[1];
    return newSVpvn((const char *)frame, 8);
}

static void
lews_on_msg_recv_callback(wslay_event_context_ptr ctx,
                          const struct wslay_event_on_msg_recv_arg *arg,
                          void *user_data)
{
    lews_wslay *state = (lews_wslay *)user_data;
    const uint8_t *payload = arg->msg;
    size_t payload_len = arg->msg_length;
    dSP;

    if (state->callback_target == NULL || state->forced_failure_code) {
        return;
    }
    if (arg->opcode != WSLAY_TEXT_FRAME &&
        arg->opcode != WSLAY_BINARY_FRAME &&
        arg->opcode != WSLAY_CONNECTION_CLOSE) {
        return;
    }

    if (arg->opcode == WSLAY_CONNECTION_CLOSE && payload_len >= 2) {
        payload += 2;
        payload_len -= 2;
    }

    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    EXTEND(SP, 4);
    PUSHs(sv_2mortal(newSVsv(state->callback_target)));
    PUSHs(sv_2mortal(newSViv((IV)arg->opcode)));
    PUSHs(sv_2mortal(lews_payload_sv(
        payload,
        payload_len,
        arg->opcode == WSLAY_TEXT_FRAME ||
        arg->opcode == WSLAY_CONNECTION_CLOSE
    )));
    PUSHs(sv_2mortal(newSViv((IV)arg->status_code)));
    PUTBACK;

    call_method("_wslay_event", G_DISCARD | G_EVAL);
    SPAGAIN;

    if (SvTRUE(ERRSV)) {
        if (state->callback_error != NULL) {
            SvREFCNT_dec(state->callback_error);
        }
        state->callback_error = newSVsv(ERRSV);
        sv_setsv(ERRSV, &PL_sv_undef);
        wslay_event_shutdown_read(ctx);
    }

    PUTBACK;
    FREETMPS;
    LEAVE;
}

static SV *
lews_flush(lews_wslay *state)
{
    SV *output = newSVpvn("", 0);
    int rc;

    if (state->in_recv || !wslay_event_want_write(state->ctx)) {
        return output;
    }

    state->output = output;
    rc = wslay_event_send(state->ctx);
    state->output = NULL;

    if (rc < 0) {
        SvREFCNT_dec(output);
        croak("wslay_event_send failed with code %d", rc);
    }

    return output;
}

MODULE = Linux::Event::WebSocket    PACKAGE = Linux::Event::WebSocket::_Wslay

PROTOTYPES: DISABLE

SV *
new(class, endpoint_type, max_message_size)
    const char *class
    const char *endpoint_type
    UV max_message_size
PREINIT:
    lews_wslay *state;
    struct wslay_event_callbacks callbacks;
    int rc;
CODE:
    Newxz(state, 1, lews_wslay);
    Zero(&callbacks, 1, struct wslay_event_callbacks);
    callbacks.recv_callback = lews_recv_callback;
    callbacks.send_callback = lews_send_callback;
    callbacks.on_frame_recv_start_callback =
        lews_on_frame_recv_start_callback;
    callbacks.on_msg_recv_callback = lews_on_msg_recv_callback;

    if (strEQ(endpoint_type, "client")) {
        state->client = 1;
        callbacks.genmask_callback = lews_genmask_callback;
        rc = wslay_event_context_client_init(&state->ctx, &callbacks, state);
    } else if (strEQ(endpoint_type, "server")) {
        rc = wslay_event_context_server_init(&state->ctx, &callbacks, state);
    } else {
        Safefree(state);
        croak("endpoint_type must be client or server");
    }

    if (rc < 0) {
        Safefree(state);
        croak("wslay context initialization failed with code %d", rc);
    }

    wslay_event_config_set_max_recv_msg_length(state->ctx,
        (uint64_t)max_message_size);
    RETVAL = newSV(0);
    sv_setref_pv(RETVAL, class, (void *)state);
OUTPUT:
    RETVAL

void
feed(self, callback_target, bytes)
    SV *self
    SV *callback_target
    SV *bytes
PREINIT:
    lews_wslay *state;
    STRLEN len;
    const char *data;
    int rc;
    int failure_code = 0;
    SV *output;
    SV *callback_error;
PPCODE:
    state = lews_wslay_from_sv(self);
    data = SvPVbyte(bytes, len);
    state->input = (const uint8_t *)data;
    state->input_len = (size_t)len;
    state->input_pos = 0;
    state->callback_target = callback_target;
    state->forced_failure_code = 0;
    state->in_recv = 1;

    rc = wslay_event_recv(state->ctx);

    state->in_recv = 0;
    state->callback_target = NULL;
    state->input = NULL;
    state->input_len = 0;
    state->input_pos = 0;

    if (state->callback_error != NULL) {
        callback_error = state->callback_error;
        state->callback_error = NULL;
        croak_sv(callback_error);
    }

    /*
     * wslay_event_recv() maps frame-parser structural failures to
     * WSLAY_ERR_CALLBACK_FAILURE after queueing an empty Close frame.
     * RFC 6455 requires those failures to use 1002.  Replace that
     * library-generated empty Close at the adapter boundary.
     */
    if (rc == WSLAY_ERR_CALLBACK_FAILURE) {
        wslay_event_shutdown_write(state->ctx);
        output = lews_protocol_close(state, WSLAY_CODE_PROTOCOL_ERROR);
        failure_code = WSLAY_CODE_PROTOCOL_ERROR;
    } else {
        if (rc < 0) {
            croak("wslay_event_recv failed with code %d", rc);
        }
        output = lews_flush(state);
    }

    if (failure_code) {
        /* already classified above */
    } else if (state->forced_failure_code) {
        failure_code = state->forced_failure_code;
    } else if (!wslay_event_get_read_enabled(state->ctx) &&
               !wslay_event_get_close_received(state->ctx)) {
        int status_code = (int)wslay_event_get_status_code_sent(state->ctx);
        if (status_code != WSLAY_CODE_ABNORMAL_CLOSURE) {
            failure_code = status_code;
        }
    }

    EXTEND(SP, 2);
    PUSHs(sv_2mortal(output));
    if (failure_code) {
        PUSHs(sv_2mortal(newSViv((IV)failure_code)));
    } else {
        PUSHs(&PL_sv_undef);
    }
    XSRETURN(2);

SV *
flush(self)
    SV *self
PREINIT:
    lews_wslay *state;
CODE:
    state = lews_wslay_from_sv(self);
    RETVAL = lews_flush(state);
OUTPUT:
    RETVAL

void
queue_message(self, opcode, bytes)
    SV *self
    IV opcode
    SV *bytes
PREINIT:
    lews_wslay *state;
    STRLEN len;
    const char *data;
    struct wslay_event_msg msg;
    int rc;
CODE:
    state = lews_wslay_from_sv(self);
    data = SvPVbyte(bytes, len);
    msg.opcode = (uint8_t)opcode;
    msg.msg = (const uint8_t *)data;
    msg.msg_length = (size_t)len;
    rc = wslay_event_queue_msg(state->ctx, &msg);
    if (rc < 0) {
        croak("wslay_event_queue_msg failed with code %d", rc);
    }

void
queue_close(self, status_code, reason)
    SV *self
    UV status_code
    SV *reason
PREINIT:
    lews_wslay *state;
    STRLEN len;
    const char *data;
    int rc;
CODE:
    state = lews_wslay_from_sv(self);
    data = SvPVbyte(reason, len);
    rc = wslay_event_queue_close(state->ctx, (uint16_t)status_code,
        (const uint8_t *)data, (size_t)len);
    if (rc < 0) {
        croak("wslay_event_queue_close failed with code %d", rc);
    }

void
shutdown_read(self)
    SV *self
PREINIT:
    lews_wslay *state;
CODE:
    state = lews_wslay_from_sv(self);
    wslay_event_shutdown_read(state->ctx);

void
DESTROY(self)
    SV *self
PREINIT:
    lews_wslay *state;
CODE:
    state = lews_wslay_from_sv(self);
    if (state != NULL) {
        if (state->ctx != NULL) {
            wslay_event_context_free(state->ctx);
        }
        if (state->callback_error != NULL) {
            SvREFCNT_dec(state->callback_error);
        }
        Safefree(state);
        sv_setiv((SV *)SvRV(self), 0);
    }
