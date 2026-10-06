# frozen_string_literal: true
require 'mkmf'
abort 'GNU Readline headers unavailable' unless have_header('readline/readline.h')
abort 'GNU Readline callback library unavailable' unless have_library('readline', 'rl_callback_handler_install')
$CFLAGS << ' -Wall -Wextra -Werror=implicit-function-declaration'
create_makefile('cli_readline_callback')
