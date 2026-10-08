# frozen_string_literal: true

require 'shellwords'

module Sandbox
  ##
  # InteractiveShell — T0b2b public-SDK adapter.
  #
  # Subclasses the installed SDK Sandbox::Shell and replaces only the
  # Readline-blocking readline/puts/print paths with the proved GNU Readline
  # callback module (CliReadlineCallback), using public APIs exclusively: no
  # SDK private ivars or methods are read or written, no global
  # monkeypatching, no aliases, no stdout redirection, and no active-buffer
  # rewrites. SDK run/exec/stop/confirm behavior is preserved through super.
  #
  # Output contract:
  # - While the callback editor is active, every thread's shell output is
  #   queued (producer threads only enqueue and wake; they never touch the
  #   terminal) and the owner renders it through the native emit_message
  #   clear-line/new-line/redisplay path.
  # - print fragments (no trailing newline) accumulate as the trailing
  #   fragment and merge with the following puts/newline payload; the
  #   pending fragment is flushed raw at the editor boundary/run end
  #   without loss and without a silently added newline. Complete producer
  #   payloads (logger/chat lines) render on their own timing, while an
  #   active partial print stream buffers until line framing arrives.
  class InteractiveShell < Shell
    ##
    # Typed fail-closed selection error: the native callback artifact is
    # missing, or its ABI/API no longer matches this adapter.
    class UnavailableError < StandardError; end

    NATIVE_ARTIFACT = File.expand_path(
      ENV.fetch('SANDBOX_NATIVE_CALLBACK', '../../.bundle/native-readline-callback/cli_readline_callback'),
      __dir__
    ).freeze
    SUPPORTED_GNU_VERSION = '8.3'
    NATIVE_API_METHODS = %i[
      install session read_char emit_message remove buffer point
      version wake event= completion= add_history resize
    ].freeze
    SGR_SEQUENCE = /\e\[[0-9;:<=>?]*m/.freeze

    class << self
      ##
      # Interactive selection requires the actual stdin/stdout identities:
      # file IO in a synthetic library never selects the native editor.
      def interactive_tty?
        $stdin.tty? && $stdout.tty?
      end

      ##
      # Entrypoint selection: the plain SDK shell for batch/nonTTY, the
      # adapter only on an interactive TTY pair (fail-closed loading).
      def selected_shell_class
        return Shell unless interactive_tty?

        load_native
        InteractiveShell
      end

      ##
      # Loads the existing built artifact lazily and verifies the exact
      # supported ABI/API; raises UnavailableError instead of ever falling
      # back to the known-broken Reline path or auto-building.
      def load_native(path: NATIVE_ARTIFACT)
        begin
          require path
        rescue LoadError => error
          raise UnavailableError, <<~TEXT
            The interactive shell requires the native GNU Readline callback editor, but it could not be loaded: #{error.message}
            Build the existing artifact inside this repository (see docs/cli-interactive-chat.md):
              source ~/.local/share/ta-hackers-toolchain/env-ruby33.sh
              export BUNDLE_APP_CONFIG="$PWD/.bundle" BUNDLE_PATH="$PWD/.bundle/native-readline"
              ~/.local/bin/mise exec ruby@3.3.12 -- ruby scripts/build_cli_readline_callback.rb
          TEXT
        end
        verify_native(CliReadlineCallback)
      end

      ##
      # Exact supported surface check against the loaded native module.
      def verify_native(native)
        unless native.version == SUPPORTED_GNU_VERSION
          raise UnavailableError,
                "The native callback editor reports GNU Readline #{native.version}; " \
                "this adapter supports #{SUPPORTED_GNU_VERSION} exactly."
        end

        missing = NATIVE_API_METHODS.reject { |name| native.respond_to?(name) }
        return native if missing.empty?

        raise UnavailableError,
              "The native callback editor is missing supported APIs (#{missing.join(', ')}); " \
              'rebuild with scripts/build_cli_readline_callback.rb.'
      end
    end

    def initialize(input = $stdin, output = $stdout, native: nil, **options)
      super(input, output, **options)

      @native = native
      @lock = Mutex.new
      @queue = Queue.new
      @editor_active = false
      @editor_installed = false
      @pending_fragment = nil
      @last_history_entry = nil
      @last_winsize = sample_winsize
    end

    ##
    # Runs the shell through the inherited SDK loop with a final no-loss
    # output flush. Terminal resizes are detected by a periodic winsize
    # sampler inside the owner event cadence (the Ruby WINCH trap variant
    # was observed to abort the native blocking read via the thread unblock
    # path on this runtime).
    def run
      super
    ensure
      @lock.synchronize { flush_inactive_output! }
    end

    ##
    # One interactive read: the native callback session covers exactly the
    # read (like the SDK's Readline.readline), with per-read completion and
    # event hooks and a full boundary flush afterwards.
    def readline(prompt, history)
      native = native_module
      activate_editor!
      result = nil
      native.session(wrap_prompt(prompt)) do
        install_editor!
        native.completion = completion_deriver
        native.event = owner_event_consumer
        loop do
          raw = native.read_char
          if raw.instance_of?(String)
            result = normalize_terminal_utf8(raw)
            record_history(result) if history
            break
          end

          break if raw == :eof

          consume_pending_events
        end
      end
      result
    ensure
      deactivate_editor!(native) if native
    end

    ##
    # SDK public print: raw bytes, no framing. While the editor is active the
    # bytes queue and their trailing fragment merges per the framing rules.
    def print(data)
      deliver(data.nil? ? '' : data.to_s)
    end

    ##
    # SDK public puts with exact Ruby IO puts semantics, routed like print.
    def puts(data = '')
      deliver(puts_payload(data))
    end

    private

    def native_module
      @native ||= self.class.load_native
    end

    def sample_winsize
      @input.winsize
    rescue StandardError
      nil
    end

    def activate_editor!
      @lock.synchronize do
        @editor_active = true
      end
    end

    def install_editor!
      @lock.synchronize do
        @editor_installed = true
      end
    end

    ##
    # Atomic deactivation: producers resume direct serialized output at the
    # boundary, queued bytes and the pending fragment flush without loss,
    # and the persisted native event closure is released (public setter).
    def deactivate_editor!(native)
      @lock.synchronize do
        @editor_active = false
        @editor_installed = false
        flush_inactive_output!
      end
      native.event = nil
    end

    def flush_inactive_output!
      until @queue.empty?
        begin
          bytes = @queue.pop(true)
        rescue ThreadError
          break
        end

        @output.write(bytes)
      end

      return if @pending_fragment.nil?

      @output.write(@pending_fragment)
      @pending_fragment = nil
    end

    def deliver(bytes)
      wake_installed = false
      @lock.synchronize do
        if @editor_active
          @queue << bytes
          wake_installed = @editor_installed
        else
          @output.write(bytes)
        end
      end
      wake_editor! if wake_installed
    end

    def wake_editor!
      native_module.wake
    rescue RuntimeError
      # The session ended between the routing decision and the wake. The
      # queued bytes drain at the boundary; the producer never surfaces raw
      # post-run session metadata.
      nil
    end

    ##
    # Owner-side consumption (event hook during the native await and after
    # every pending read round): render queued bytes, then compare the
    # current terminal winsize with the sampled baseline and resize once
    # when it changed. Never re-enters native reads.
    def owner_event_consumer
      proc { consume_pending_events }
    end

    def consume_pending_events
      drain_active_queue!
      refresh_winsize!
    end

    def drain_active_queue!
      native = native_module
      until @queue.empty?
        begin
          bytes = @queue.pop(true)
        rescue ThreadError
          break
        end

        render_active_bytes(bytes)
      end
    end

    def render_active_bytes(bytes)
      native = native_module
      stream = (@pending_fragment || +'') + bytes
      *complete, trailing = stream.split("\n", -1)
      complete.each { |line| native.emit_message(line) }
      @pending_fragment = trailing && !trailing.empty? ? trailing : nil
    end

    ##
    # Periodic winsize sampler: the owner hook runs at the documented
    # nominal 100ms cadence while the native read blocks, so a real PTY
    # resize reaches rl_resize_terminal within that cadence without any
    # Ruby trap or terminal output outside the owner.
    def refresh_winsize!
      current = sample_winsize
      return if current.nil? || current == @last_winsize

      @last_winsize = current
      native_module.resize
    end

    ##
    # GNU prompt display safety: wrap the prompt's ANSI SGR sequences with
    # the documented public ignore markers so column math ignores them.
    def wrap_prompt(prompt)
      prompt.gsub(SGR_SEQUENCE) { "\001#{Regexp.last_match(0)}\002" }
    end

    ##
    # The native editor hands back byte strings: normalize to UTF-8 and
    # refuse invalid bytes loudly (never quietly changed or passed on).
    def normalize_terminal_utf8(value)
      text = value.to_s.b.force_encoding(Encoding::UTF_8)
      return text if text.valid_encoding?

      raise ShellError, 'terminal input is not valid UTF-8'
    end

    ##
    # Native history add honoring the history argument; blanks and immediate
    # duplicates skip, matching the SDK readline pop policy. GNU keeps its
    # own per-process history copy.
    def record_history(line)
      return if line.strip.empty?
      return if line == @last_history_entry

      native_module.add_history(line)
      @last_history_entry = line
    end

    ##
    # Public-SDK completion derivation (no SDK private proc/ivars): tokens
    # come from the full buffer via Shellwords.shellsplit, the command proc
    # receives the documented public Command#completion_proc signature
    # (word, tokens, shell, context, command), and the result is filtered
    # against the completing word. Native match entries must be strings, so
    # names convert via to_s.
    def completion_deriver
      proc do |prefix, full|
        word = normalize_terminal_utf8(prefix)
        line = normalize_terminal_utf8(full)
        tokens = Shellwords.shellsplit(line)
        tokens.first&.downcase!

        context = root.context(*path)
        commands = []
        commands += context.contexts
        commands += context.commands
        commands += root.commands.select(&:global?) unless path.empty?

        command = commands.detect { |c| c.instance_of?(Command) && c.match?(tokens.first) }
        list = commands.map(&:name)
        list = command.completion_proc&.call(word, tokens, self, context, command) unless command.nil?
        list&.grep(/^#{Regexp.escape(word)}/)&.map(&:to_s)
      rescue ArgumentError => e
        raise ShellError, e.message
      end
    end

    ##
    # Exact Ruby IO#puts byte semantics: array elements each get a line, nil
    # becomes a bare newline, strings get one trailing newline only when
    # missing.
    def puts_payload(data)
      entries = data.instance_of?(Array) ? data : [data]
      return "\n" if entries.empty?

      entries.map do |entry|
        text = entry.nil? ? '' : entry.to_s
        text.end_with?("\n") ? text : text + "\n"
      end.join
    end
  end
end
