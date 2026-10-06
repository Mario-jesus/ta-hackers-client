#include <ruby.h>
#include <ruby/thread.h>
#include <readline/readline.h>
#include <unistd.h>
#include <poll.h>
#include <fcntl.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

/* One process-global GNU session. Ruby references stay in module ivars.
 * The native callback and getc function never access Ruby or Ruby VALUEs. */
static int active, installed, eof_seen;
static int cancel_pipe[2] = {-1, -1};
static char *line, *prompt_copy;
static FILE *old_input, *old_output;
static int old_signals, old_winch;
static rl_getc_func_t *old_getc;
static ID owner_id;

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

static int cancellable_getc(FILE *stream)
{
    struct pollfd descriptors[2] = {{fileno(stream), POLLIN, 0},
                                  {cancel_pipe[0], POLLIN, 0}};
    unsigned char byte;
    for (;;) {
        int result = poll(descriptors, 2, -1);
        if (result < 0 && errno == EINTR) continue;
        if (result < 0 || descriptors[1].revents) return EOF;
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
    free(line);
    line = NULL;
    free(prompt_copy);
    prompt_copy = NULL;
    close(cancel_pipe[0]);
    close(cancel_pipe[1]);
    cancel_pipe[0] = cancel_pipe[1] = -1;
    active = 0;
    rb_ivar_set(self, owner_id, Qnil);
    return Qnil;
}

static VALUE install(VALUE self, VALUE prompt)
{
    owner_check(self, 0);
    if (active) rb_raise(rb_eRuntimeError, "callback session already active");
    Check_Type(prompt, T_STRING);
    const char *text = StringValueCStr(prompt);
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO))
        rb_raise(rb_eRuntimeError, "callback session requires stdin/stdout TTY");
    if (strcmp(rl_library_version, "8.3") != 0)
        rb_raise(rb_eRuntimeError, "prototype requires GNU Readline 8.3");
    prompt_copy = strdup(text);
    if (!prompt_copy) rb_memerror();
    if (pipe(cancel_pipe) < 0) {
        free(prompt_copy);
        prompt_copy = NULL;
        rb_sys_fail("callback cancellation pipe");
    }
    if (fcntl(cancel_pipe[1], F_SETFL, O_NONBLOCK) < 0) {
        int saved = errno;
        close(cancel_pipe[0]); close(cancel_pipe[1]);
        free(prompt_copy); prompt_copy = NULL;
        errno = saved;
        rb_sys_fail("callback cancellation flags");
    }
    old_input = rl_instream;
    old_output = rl_outstream;
    old_getc = rl_getc_function;
    old_signals = rl_catch_signals;
    old_winch = rl_catch_sigwinch;
    rb_ivar_set(self, owner_id, rb_thread_current());
    active = 1;
    eof_seen = 0;
    rl_instream = stdin;
    rl_outstream = stdout;
    rl_catch_signals = 0;
    rl_catch_sigwinch = 0;
    rl_getc_function = cancellable_getc;
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
    rb_thread_call_without_gvl(native_read, NULL, unblock_read, NULL);
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
    rb_define_singleton_method(module, "version", version, 0);
    rb_define_singleton_method(module, "install", install, 1);
    rb_define_singleton_method(module, "session", session, 1);
    rb_define_singleton_method(module, "read_char", read_char, 0);
    rb_define_singleton_method(module, "emit_message", emit_message, 1);
    rb_define_singleton_method(module, "remove", remove_session, 0);
    rb_define_singleton_method(module, "buffer", buffer, 0);
    rb_define_singleton_method(module, "point", point, 0);
}
