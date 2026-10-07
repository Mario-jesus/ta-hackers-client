# frozen_string_literal: true
require 'mkmf'
abort 'GNU Readline headers unavailable' unless have_header('readline/readline.h')
abort 'GNU Readline callback library unavailable' unless have_library('readline', 'rl_callback_handler_install')
abort 'GNU Readline completion hook unavailable' unless have_var('rl_attempted_completion_function', 'readline/readline.h')
abort 'GNU Readline completion append suppression unavailable' unless have_var('rl_completion_suppress_append', 'readline/readline.h')
abort 'GNU Readline history additions unavailable' unless have_func('add_history')
abort 'GNU Readline history initialization unavailable' unless have_func('using_history')
abort 'GNU Readline terminal resize unavailable' unless have_func('rl_resize_terminal')
$CFLAGS << ' -Wall -Wextra -Werror=implicit-function-declaration'
create_makefile('cli_readline_callback')
