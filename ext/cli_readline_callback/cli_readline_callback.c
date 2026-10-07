#include <ruby.h>
#include <ruby/thread.h>
#include <readline/readline.h>
#include <readline/history.h>
#include <unistd.h>
#include <poll.h>
#include <fcntl.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

/* One process-global GNU session. Ruby references stay in module ivars.
 * The getc and line callbacks never touch Ruby. The completion callback is
 * the only Ruby consumer: it runs only inside a without-GVL native_read
 * round and reacquires the GVL per the documented rb_thread_call_with_gvl
 * rules, wrapping every Ruby call in rb_protect. */
static int active, installed, eof_seen, in_native_read, in_event_hook;
static int cancel_pipe[2] = {-1, -1};
static int wake_pipe[2] = {-1, -1};
static char *line, *prompt_copy;
static FILE *old_input, *old_output;
static int old_signals, old_winch;
static rl_getc_func_t *old_getc;
static rl_completion_func_t *old_completion;
static int old_completion_over;
static ID owner_id, completion_id, event_id, call_id;

struct completion_call {
    VALUE proc;       /* completion callback, module ivar, GC-marked */
    VALUE event_proc; /* owner event callback, module ivar, GC-marked */
    VALUE exception;  /* Qnil or the first captured exception (writer-observed:
                         rb_protect returned Qnil with a nonzero state on this
                         Ruby, so capture uses rb_rescue2 instead) */
    const char *text; /* GNU-provided prefix, valid during the callback */
    char **matches;   /* C-owned registry handed to GNU after success */
    int count;        /* candidate count handed to GNU */
};

/* One read round's context, on the read_body C stack (conservatively
 * scanned); the completion callback and the event consumption both run
 * only inside the without-GVL native_read extent and reach it here. */
static struct completion_call *read_context;

/* Idle consumption cadence: the session's own wait loop runs the owner
 * callback at most about every 100ms while GNU awaits input, matching the
 * documented public event-hook cadence. */
#define EVENT_CADENCE_MS 100

static void owner_check(VALUE self, int require_active)
{
    VALUE owner = rb_ivar_get(self, owner_id);
    if (active && owner != rb_thread_current())
        rb_raise(rb_eThreadError, "callback session belongs to another thread");
    if (require_active && !active)
        rb_raise(rb_eRuntimeError, "no active callback session");
}

static void record_line(char *text)
{
    /* GNU transfers malloc ownership. No Ruby hooks are installed. */
    line = text;
    eof_seen = text == NULL;
}

static void run_event_hook(void);

static int cancellable_getc(FILE *stream)
{
    struct pollfd descriptors[3] = {{fileno(stream), POLLIN, 0},
                                   {cancel_pipe[0], POLLIN, 0},
                                   {wake_pipe[0], POLLIN, 0}};
    unsigned char byte;
    for (;;) {
        int result = poll(descriptors, 3, EVENT_CADENCE_MS);
        if (result < 0 && errno == EINTR) continue;
        if (result < 0 || descriptors[1].revents) return EOF;
        if (descriptors[2].revents) {

            /* Producer wake is signaling only: drain one byte and let the
             * owner consume its queued events here, during the GNU await
             * (including a partial escape sequence). Never a READERR, EOF
             * or synthetic input. */
            ssize_t drained = read(descriptors[2].fd, &byte, 1);
            if (drained == 1) {
                run_event_hook();
                continue;
            }
            if (drained < 0 && errno == EINTR) continue;
            return EOF;
        }
        if (result == 0) {
            /* Idle cadence: the owner consumes pending events while GNU
             * awaits keyboard input. */
            run_event_hook();
            continue;
        }
        if (descriptors[0].revents) {
            ssize_t count = read(descriptors[0].fd, &byte, 1);
            if (count == 1) return byte;
            if (count < 0 && errno == EINTR) continue;
            return EOF;
        }
    }
}

static void unblock_read(void *unused)
{
    char byte = 1;
    (void)unused;
    /* Nonblocking write is async-signal-safe; a full pipe is already awake. */
    ssize_t result = write(cancel_pipe[1], &byte, 1);
    (void)result;
}

/* C-owned match strings: allocated under the GVL, then handed to GNU which
 * frees them with free(). The registry carries insertion slot 0 plus the
 * full list so partial builds remain fully freeable via the terminator. */
static void cfree_string_array(char **matches)
{
    if (!matches) return;
    for (char **entry = matches; *entry; entry++) free(*entry);
    free(matches);
}

static VALUE completion_protect(VALUE data)
{
    struct completion_call *call = (struct completion_call *)data;
    VALUE prefix, full, list, first;
    long count, i, common;
    char **registry;
    const char *base;

    prefix = rb_str_new_cstr(call->text);
    full = rb_str_new(rl_line_buffer, rl_end);
    if (!NIL_P(call->proc))
        list = rb_funcall(call->proc, call_id, 2, prefix, full);
    else
        return Qnil;
    if (NIL_P(list)) return Qnil; /* no fallback: over already set by the hook */
    Check_Type(list, T_ARRAY);
    count = RARRAY_LEN(list);
    if (count == 0) return Qnil;
    for (i = 0; i < count; i++) {
        VALUE entry = rb_ary_entry(list, i);
        if (!RB_TYPE_P(entry, T_STRING))
            rb_raise(rb_eTypeError, "completion entries must be Strings");
        if (memchr(RSTRING_PTR(entry), '\0', (size_t)RSTRING_LEN(entry)))
            rb_raise(rb_eArgError, "completion entry contains NUL");
    }
    /* Longest common prefix of every candidate, byte-compared then backed
     * off to a UTF-8 boundary so a multibyte character is never split. The
     * GNU manual convention puts this maximal common substring in slot 0
     * and the full candidate list behind it. */
    first = rb_ary_entry(list, 0);
    base = RSTRING_PTR(first);
    common = RSTRING_LEN(first);
    for (i = 1; i < count && common > 0; i++) {
        VALUE entry = rb_ary_entry(list, i);
        const char *other = RSTRING_PTR(entry);
        long limit = common < RSTRING_LEN(entry) ? common : RSTRING_LEN(entry);
        long k = 0;
        while (k < limit && base[k] == other[k]) k++;
        if (k < common) common = k;
    }
    /* Back off only an INCOMPLETE trailing sequence: when the common prefix
     * is shorter than the first candidate and the byte right after it is a
     * continuation byte, the prefix splits a codepoint — walk back to the
     * lead and drop the lead too. When the common prefix covers the whole
     * first candidate, or ends exactly at a codepoint boundary, nothing is
     * dropped and complete codepoints survive. */
    if (common > 0 && common < RSTRING_LEN(first)) {
        unsigned char next = (unsigned char)base[common];
        if ((next & 0xC0) == 0x80) {
            long boundary = common;
            while (boundary > 0 && ((unsigned char)base[boundary - 1] & 0xC0) == 0x80) boundary--;
            if (boundary > 0) boundary--; /* drop the lead byte too */
            common = boundary;
        }
    }
    /* Layout: with one candidate the registry holds only the unique match
     * (GNU then counts exactly one match). With several candidates slot 0
     * carries the maximal common substring per the GNU manual convention
     * and the full list follows; both layouts keep the terminator last so
     * partial builds stay freeable. */
    registry = calloc((size_t)(count == 1 ? 2 : count + 2), sizeof(char *));
    if (!registry) rb_memerror();
    call->matches = registry; /* partial-safe: freed by the rescue path */
    registry[0] = malloc((size_t)common + 1);
    if (!registry[0]) rb_memerror();
    memcpy(registry[0], base, (size_t)common);
    registry[0][common] = '\0';
    if (count > 1) {
        for (i = 0; i < count; i++) {
            VALUE entry = rb_ary_entry(list, i);
            long length = RSTRING_LEN(entry);
            char *copy = malloc((size_t)length + 1);
            if (!copy) rb_memerror();
            memcpy(copy, RSTRING_PTR(entry), (size_t)length);
            copy[length] = '\0';
            registry[i + 1] = copy;
        }
        registry[count + 1] = NULL;
    }
    call->count = (int)count;
    return Qnil;
}

static VALUE completion_rescue(VALUE data, VALUE exception)
{
    struct completion_call *call = (struct completion_call *)data;

    /* rb_protect is not used for capture here: on Ruby 3.3 it clears the
     * error info before this callback could read it (observed state=6 with
     * a Qnil return and a Qnil rb_errinfo()). rb_rescue2 with rb_eException
     * is the documented equivalent that hands the exact exception object to
     * the rescue argument without unwinding further C frames. */
    cfree_string_array(call->matches);
    call->matches = NULL;
    call->count = 0;
    call->exception = exception;
    return Qnil;
}

static void *completion_gvl_body(void *data)
{
    struct completion_call *call = (struct completion_call *)data;

    call->matches = NULL;
    call->count = 0;
    call->exception = Qnil;
    rb_rescue2(completion_protect, (VALUE)call, completion_rescue, (VALUE)call, rb_eException, (VALUE)0);
    return NULL;
}

static char **ruby_attempted_completion(const char *text, int start, int stop)
{
    struct completion_call *call = read_context;
    (void)start;
    (void)stop;

    /* Guard: the registered hook may run only inside the without-GVL
     * native_read body; every other caller gets no matches. */
    if (!call || !in_native_read) return NULL;
    /* Documented application-completion switches: readline must not append
     * its completion character after our registered match, and with an
     * installed completion callback a nil/empty/unmatched result must never
     * fall back to default filename completion. */
    rl_completion_suppress_append = 1;
    rl_attempted_completion_over = 1;
    call->text = text;
    rb_thread_call_with_gvl(completion_gvl_body, call);
    /* A captured Ruby exception must not unwind GNU C frames; the owner
     * re-raises it under the GVL with full session cleanup. */
    if (call->exception != Qnil) return NULL;
    return call->matches;
}

static VALUE event_protect(VALUE data)
{
    struct completion_call *call = (struct completion_call *)data;

    rb_funcall(call->event_proc, call_id, 0);
    return Qnil;
}

static VALUE event_rescue(VALUE data, VALUE exception)
{
    struct completion_call *call = (struct completion_call *)data;

    /* A raising event callback must not unwind GNU C frames; the first
     * captured exception is stored for the owner, re-raised under the GVL
     * after the native read returns, with full session cleanup. */
    if (NIL_P(call->exception)) call->exception = exception;
    return Qnil;
}

static void *event_gvl_body(void *data)
{
    struct completion_call *call = (struct completion_call *)data;

    rb_rescue2(event_protect, (VALUE)call, event_rescue, (VALUE)call, rb_eException, (VALUE)0);
    return NULL;
}

/* The owner consumes queued producer events here, during the GNU await
 * (including a bare-ESC partial escape). Runs on the owner thread inside
 * the without-GVL native_read extent; never re-enters GNU character
 * reading and never mutates the session. */
static void run_event_hook(void)
{
    struct completion_call *call = read_context;

    if (!in_native_read || !call || in_event_hook) return;
    if (NIL_P(call->event_proc)) return;
    in_event_hook = 1;
    rb_thread_call_with_gvl(event_gvl_body, call);
    in_event_hook = 0;
}

static VALUE cleanup(VALUE self)
{
    if (!active) return Qnil;
    if (installed) rl_callback_handler_remove();
    installed = 0;
    rl_instream = old_input;
    rl_outstream = old_output;
    rl_getc_function = old_getc;
    rl_catch_signals = old_signals;
    rl_catch_sigwinch = old_winch;
    rl_attempted_completion_function = old_completion;
    rl_attempted_completion_over = old_completion_over;
    free(line);
    line = NULL;
    free(prompt_copy);
    prompt_copy = NULL;
    close(cancel_pipe[0]);
    close(cancel_pipe[1]);
    cancel_pipe[0] = cancel_pipe[1] = -1;
    close(wake_pipe[0]);
    close(wake_pipe[1]);
    wake_pipe[0] = wake_pipe[1] = -1;
    active = 0;
    in_native_read = 0;
    in_event_hook = 0;
    rb_ivar_set(self, owner_id, Qnil);
    rb_ivar_set(self, completion_id, Qnil);
    return Qnil;
}

static VALUE install(VALUE self, VALUE prompt)
{
    const char *text;
    owner_check(self, 0);
    if (active) rb_raise(rb_eRuntimeError, "callback session already active");
    Check_Type(prompt, T_STRING);
    text = StringValueCStr(prompt);
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO))
        rb_raise(rb_eRuntimeError, "callback session requires stdin/stdout TTY");
    if (strcmp(rl_library_version, "8.3") != 0)
        rb_raise(rb_eRuntimeError, "prototype requires GNU Readline 8.3");
    prompt_copy = strdup(text);
    if (!prompt_copy) rb_memerror();
    if (pipe(cancel_pipe) < 0) {
        int saved = errno;
        free(prompt_copy); prompt_copy = NULL;
        errno = saved;
        rb_sys_fail("callback cancellation pipe");
    }
    if (fcntl(cancel_pipe[1], F_SETFL, O_NONBLOCK) < 0) {
        int saved = errno;
        close(cancel_pipe[0]); close(cancel_pipe[1]);
        cancel_pipe[0] = cancel_pipe[1] = -1;
        free(prompt_copy); prompt_copy = NULL;
        errno = saved;
        rb_sys_fail("callback cancellation flags");
    }
    if (pipe(wake_pipe) < 0) {
        int saved = errno;
        close(cancel_pipe[0]); close(cancel_pipe[1]);
        cancel_pipe[0] = cancel_pipe[1] = -1;
        free(prompt_copy); prompt_copy = NULL;
        errno = saved;
        rb_sys_fail("callback wake pipe");
    }
    if (fcntl(wake_pipe[1], F_SETFL, O_NONBLOCK) < 0) {
        int saved = errno;
        close(wake_pipe[0]); close(wake_pipe[1]);
        wake_pipe[0] = wake_pipe[1] = -1;
        close(cancel_pipe[0]); close(cancel_pipe[1]);
        cancel_pipe[0] = cancel_pipe[1] = -1;
        free(prompt_copy); prompt_copy = NULL;
        errno = saved;
        rb_sys_fail("callback wake flags");
    }
    old_input = rl_instream;
    old_output = rl_outstream;
    old_getc = rl_getc_function;
    old_signals = rl_catch_signals;
    old_winch = rl_catch_sigwinch;
    old_completion = rl_attempted_completion_function;
    old_completion_over = rl_attempted_completion_over;
    rb_ivar_set(self, owner_id, rb_thread_current());
    active = 1;
    eof_seen = 0;
    rl_instream = stdin;
    rl_outstream = stdout;
    rl_catch_signals = 0;
    rl_catch_sigwinch = 0;
    rl_getc_function = cancellable_getc;

    if (!NIL_P(rb_ivar_get(self, completion_id))) {
        rl_attempted_completion_function = ruby_attempted_completion;
    } else {
        /* Without an installed callback GNU's documented default completion
         * applies; the over variable is left untouched. */
        rl_attempted_completion_function = NULL;
    }
    using_history();
    rl_callback_handler_install(prompt_copy, record_line);
    installed = 1;
    return Qnil;
}

static void *native_read(void *unused)
{
    (void)unused;
    rl_callback_read_char();
    return NULL;
}

static VALUE read_body(VALUE self)
{
    struct completion_call call;

    if (in_event_hook)
        rb_raise(rb_eRuntimeError, "read_char must not re-enter the event hook");
    call.proc = rb_ivar_get(self, completion_id);
    call.event_proc = rb_ivar_get(self, event_id);
    call.exception = Qnil;
    call.text = NULL;
    call.matches = NULL;
    call.count = 0;
    read_context = &call;
    in_native_read = 1;
    rb_thread_call_without_gvl(native_read, NULL, unblock_read, NULL);
    in_native_read = 0;
    read_context = NULL;
    if (call.exception != Qnil)
        rb_exc_raise(call.exception); /* unwinds into read_rescue: cleanup runs */
    if (eof_seen) {
        cleanup(self);
        return ID2SYM(rb_intern("eof"));
    }
    if (line) {
        VALUE result = rb_str_new_cstr(line);
        free(line);
        line = NULL;
        return result;
    }
    return ID2SYM(rb_intern("pending"));
}

static VALUE read_rescue(VALUE self, VALUE exception)
{
    cleanup(self);
    rb_exc_raise(exception);
    return Qnil;
}

static VALUE read_char(VALUE self)
{
    owner_check(self, 1);
    return rb_rescue2(read_body, self, read_rescue, self, rb_eException, (VALUE)0);
}

static VALUE remove_session(VALUE self)
{
    if (in_event_hook)
        rb_raise(rb_eRuntimeError, "remove must not run inside the event hook");
    owner_check(self, 1);
    return cleanup(self);
}

static VALUE buffer(VALUE self)
{
    owner_check(self, 1);
    return rb_str_new(rl_line_buffer, rl_end);
}

static VALUE point(VALUE self)
{
    owner_check(self, 1);
    return INT2NUM(rl_point);
}

static VALUE emit_message(VALUE self, VALUE message)
{
    owner_check(self, 1);
    Check_Type(message, T_STRING);
    const char *text = StringValueCStr(message);
    rl_clear_visible_line();
    fputs(text, stdout);
    fputc('\n', stdout);
    rl_on_new_line();
    rl_redisplay();
    fflush(stdout);
    return Qnil;
}

/* Producer-safe wake: any thread may call it while a session is active; the
 * nonblocking write tolerates a full pipe because a full pipe already means
 * the owner is awake, and each byte is drained exactly once. */
static VALUE wake(VALUE self)
{
    char byte = 1;
    ssize_t result;
    (void)self;
    if (!active) rb_raise(rb_eRuntimeError, "no active callback session");
    result = write(wake_pipe[1], &byte, 1);
    if (result < 0 && errno != EAGAIN && errno != EWOULDBLOCK)
        rb_sys_fail("callback wake pipe");
    return Qnil;
}

/* The setter may store a callback before install; during an active session
 * only the owner thread may swap or clear it. The proc is pinned through the
 * module-level ivar and cleared when the session ends. */
static VALUE set_completion(VALUE self, VALUE callback)
{
    if (active) owner_check(self, 1);
    if (!NIL_P(callback) && !RTEST(rb_obj_is_proc(callback)))
        rb_raise(rb_eTypeError, "completion callback must be a Proc");
    rb_ivar_set(self, completion_id, callback);
    if (active) {
        rl_attempted_completion_function =
            NIL_P(callback) ? NULL : ruby_attempted_completion;
        rl_attempted_completion_over =
            NIL_P(callback) ? old_completion_over : 1;
    }
    return callback;
}

/* Careful: the GNU history function is also named add_history; the Ruby
 * wrapper is deliberately named differently to avoid shadowing it. */
/* Owner event callback setter: inactive store is allowed and read per
 * read round; during an active session only the owner may swap or clear. */
static VALUE set_event(VALUE self, VALUE callback)
{
    if (active) owner_check(self, 1);
    if (!NIL_P(callback) && !RTEST(rb_obj_is_proc(callback)))
        rb_raise(rb_eTypeError, "event callback must be a Proc");
    rb_ivar_set(self, event_id, callback);
    return callback;
}

static VALUE record_history(VALUE self, VALUE text)
{
    owner_check(self, 1);
    Check_Type(text, T_STRING);
    add_history(StringValueCStr(text)); /* GNU keeps its own copy */
    using_history(); /* re-anchor the navigation state at the newest entry */
    return Qnil;
}

static VALUE resize(VALUE self)
{
    owner_check(self, 1);
    rl_resize_terminal();
    rl_redisplay();
    fflush(stdout);
    return Qnil;
}

static VALUE yield_session(VALUE self)
{
    return rb_yield(self);
}

static VALUE session(VALUE self, VALUE prompt)
{
    rb_need_block();
    install(self, prompt);
    return rb_ensure(yield_session, self, cleanup, self);
}

static VALUE version(VALUE self)
{
    owner_check(self, 0);
    return rb_str_new_cstr(rl_library_version);
}

void Init_cli_readline_callback(void)
{
    VALUE module = rb_define_module("CliReadlineCallback");
    owner_id = rb_intern("@owner");
    completion_id = rb_intern("@completion");
    event_id = rb_intern("@event");
    call_id = rb_intern("call");
    rb_define_singleton_method(module, "version", version, 0);
    rb_define_singleton_method(module, "install", install, 1);
    rb_define_singleton_method(module, "session", session, 1);
    rb_define_singleton_method(module, "read_char", read_char, 0);
    rb_define_singleton_method(module, "emit_message", emit_message, 1);
    rb_define_singleton_method(module, "remove", remove_session, 0);
    rb_define_singleton_method(module, "buffer", buffer, 0);
    rb_define_singleton_method(module, "point", point, 0);
    rb_define_singleton_method(module, "wake", wake, 0);
    rb_define_singleton_method(module, "event=", set_event, 1);
    rb_define_singleton_method(module, "completion=", set_completion, 1);
    rb_define_singleton_method(module, "add_history", record_history, 1);
    rb_define_singleton_method(module, "resize", resize, 0);
}
