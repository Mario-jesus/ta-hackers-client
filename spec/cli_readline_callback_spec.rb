# frozen_string_literal: true

require 'pty'
require 'io/console'
require 'json'
require 'timeout'
require 'rbconfig'

# Current-screen interpreter, not a transcript matcher. Unknown ANSI is fatal.
class CallbackScreen
  attr_reader :row, :column, :unknown

  def initialize(rows = 12, columns = 24)
    @rows, @columns = rows, columns
    @cells = Array.new(rows) { (' ' * columns).force_encoding(Encoding::UTF_8) }
    @row = @column = 0
    @pending = +''
    @wrap = false
    @unknown = []
  end

  def feed(bytes)
    # The model consumes raw terminal bytes, so UTF-8 string inputs are
    # normalized to their byte sequence before slicing.
    @pending << bytes.b
    until @pending.empty?
      if @pending.start_with?("\e[")
        match = /\A\e\[([0-9;?]*)([ -\/]*)([@-~])/.match(@pending)
        break unless match

        @pending = @pending.byteslice(match[0].bytesize..)
        csi(match[1], match[3])
      elsif @pending.start_with?("\e")
        break if @pending.bytesize < 2

        raise "unsupported escape #{@pending.byteslice(0, 2).inspect}"
      else
        byte = @pending.slice!(0)
        byte = consume_utf8(byte) if byte.ord > 0x7F
        case byte
        when "\r" then @column = 0; @wrap = false
        when "\n" then down; @wrap = false
        when "\b" then @column = [@column - 1, 0].max; @wrap = false
        when "\a" # bell does not change cells
        else
          fatal_unless_displayable = byte.ascii_only? ? byte.ord.between?(32, 126) : TESTED_UTF8.include?(byte)
          raise "non-ASCII display byte #{byte.inspect}" unless fatal_unless_displayable

          if @wrap
            @column = 0
            down
            @wrap = false
          end
          @cells[@row][@column] = byte
          if @column == @columns - 1
            @wrap = true
          else
            @column += 1
          end
        end
      end
    end
  end

  # Only glyphs actually exercised by the PTY fixtures are accepted with
  # display width 1; no general width table is invented, and anything else
  # stays fatal.
  TESTED_UTF8 = ['▸', 'á'].freeze

  def consume_utf8(lead)
    code = lead.ord
    raise "invalid UTF-8 lead #{lead.inspect}" unless [0b11000000, 0b11100000].any? { |mask| (code & mask) == mask }

    size = code >= 0b11100000 ? 3 : 2
    raise "truncated UTF-8 sequence #{lead.inspect}" if @pending.bytesize < size - 1

    char = (lead + @pending.byteslice(0, size - 1)).force_encoding(Encoding::UTF_8)
    raise "invalid UTF-8 sequence #{char.inspect}" unless char.valid_encoding?
    raise "untested non-ASCII glyph #{char.inspect}" unless TESTED_UTF8.include?(char)

    @pending = @pending.byteslice(size - 1..)
    char
  end

  def lines
    @cells.map(&:rstrip)
  end

  def down
    @row += 1
    return if @row < @rows

    @cells.shift
    @cells << (' ' * @columns).force_encoding(Encoding::UTF_8)
    @row = @rows - 1
  end

  def csi(parameters, code)
    args = parameters.split(';').map(&:to_i)
    count = args.fetch(0, 0)
    count = 1 if count.zero?
    @wrap = false
    case code
    when 'A' then @row = [@row - count, 0].max
    when 'B' then @row = [@row + count, @rows - 1].min
    when 'C' then @column = [@column + count, @columns - 1].min
    when 'D' then @column = [@column - count, 0].max
    when 'G' then @column = count - 1
    when 'H', 'f'
      @row = count - 1
      @column = [args.fetch(1, 1), 1].max - 1
    when 'K'
      mode = args.fetch(0, 0)
      case mode
      when 0 then @cells[@row][@column..] = ' ' * (@columns - @column)
      when 1 then @cells[@row][0..@column] = ' ' * (@column + 1)
      when 2 then @cells[@row] = ' ' * @columns
      else raise "unsupported erase mode #{mode}"
      end
    when '@' # ICH: insert count blanks at the cursor, shifting the tail right
      width = @columns - @column
      blanks = [count, width].min
      tail = @cells[@row][@column..]
      @cells[@row][@column..] = (' ' * blanks) + tail[0, width - blanks]
    when 'P' # DCH: delete count characters at the cursor, shifting the tail left
      width = @columns - @column
      dropped = [count, width].min
      tail = @cells[@row][@column..]
      @cells[@row][@column..] = tail[dropped, width] + ' ' * dropped
    when 'X' # ECH: erase count characters from the cursor without shifting
      width = @columns - @column
      erased = [count, width].min
      tail = @cells[@row][@column..]
      @cells[@row][@column..] = (' ' * erased) + (tail[erased..] || '')
    when 'J'
      raise 'only full-screen erase supported' unless parameters == '2'

      @cells = Array.new(@rows) { (' ' * @columns).force_encoding(Encoding::UTF_8) }
    when 'm' # ASCII fixture has no color-dependent cells
    when 'h', 'l'
      raise "unsupported terminal mode #{parameters}" unless parameters == '?2004'
    else
      @unknown << [parameters, code]
      raise "unsupported CSI #{parameters}#{code}"
    end
  end
end

RSpec.describe 'Standalone GNU Readline callback prototype' do
  native = File.expand_path('../.bundle/native-readline-callback/cli_readline_callback', __dir__)

  it 'provides the isolated native callback API' do
    load_error = nil
    begin
      require native
    rescue LoadError => error
      load_error = error
    end
    expect(load_error).to be_nil, 'build the standalone callback prototype first'
    expect(CliReadlineCallback.version).to eq('8.3')
    expect(CliReadlineCallback).to respond_to(
      :install, :session, :read_char, :emit_message, :remove, :buffer, :point,
      :wake, :event=, :completion=, :add_history, :resize
    )
  end

  child = <<~'RUBY'
    require 'json'
    require 'io/console'
    require ARGV.fetch(0)
    control = IO.for_fd(3)
    events = IO.for_fd(4)
    events.sync = true
    STDOUT.sync = true
    api = CliReadlineCallback
    def event(io, payload)
      io.puts(JSON.generate(payload))
    end
    def rejects(klass)
      begin
        yield
      rescue klass
        return true
      end
      raise "expected #{klass}"
    end
    control.gets # Parent sets real geometry before any Readline initialization.
    mode = ARGV.fetch(1)
    prompt = 'p> '
    completions = []
    # Inactive-session rejections on the owner thread, then a permitted
    # inactive setter round trip before any per-mode setup.
    rejects(RuntimeError) { api.wake }
    rejects(RuntimeError) { api.add_history('inactive') }
    rejects(RuntimeError) { api.resize }
    api.completion = proc { [] }
    api.completion = nil
    api.event = proc { [] }
    api.event = nil
    if mode == 'utf8'
      prompt = "\001\e[32m\002▸ \001\e[0m\002"
    end
    if mode == 'complete'
      api.completion = -> (prefix, full) do
        completions << [prefix, full]
        Thread.new { GC.start; GC.compact }.join
        ['hello']
      end
    end
    if mode == 'hook'
      owner_thread = Thread.current
      pending_message = false
      api.event = -> do
        next unless pending_message

        pending_message = false
        Thread.new { GC.start; GC.compact }.join
        api.emit_message('incoming')
        event(events, hook: {'thread' => Thread.current == owner_thread ? 'owner' : 'foreign',
                             'wall_ms' => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - $wake_written_at) * 1000).round})
      end
    end
    before = STDIN.console_mode
    # IO::ConsoleMode#== compares raw struct bytes and is unstable between two
    # consecutive snapshots (padding), so restore checks compare the semantic
    # termios state instead: the full stty -g encoding plus every exposed field.
    before_stty = `stty -g`
    mode_fields = ->(m) { m.methods.grep(/^c_/).sort.map { |n| [n, m.public_send(n)] }.to_h }
    before_fields = mode_fields.call(before)
    restored_tty = -> { `stty -g` == before_stty && mode_fields.call(STDIN.console_mode) == before_fields }
    if mode == 'contracts'
      %i[read_char buffer point remove wake resize].each { |name| rejects(RuntimeError) { api.public_send(name) } }
      rejects(RuntimeError) { api.add_history('inactive') }
      rejects(TypeError) { api.install(123) }
      rejects(ArgumentError) { api.install("bad\0prompt") }
      prompt = +'p> '
      api.session(prompt) do
        prompt.replace('changed')
        rejects(RuntimeError) { api.install('again') }
        rejects(TypeError) { api.emit_message(nil) }
        rejects(ArgumentError) { api.emit_message("bad\0text") }
        rejects(TypeError) { api.completion = 123 }
        rejects(TypeError) { api.event = 123 }
        rejects(TypeError) { api.add_history(123) }
        api.add_history('via add')
        api.add_history('via add')
        api.add_history('')
        api.completion = nil
        api.resize
        %i[version buffer point read_char remove].each do |name|
          Thread.new { rejects(ThreadError) { api.public_send(name) } }.value
        end
        Thread.new { rejects(ThreadError) { api.install('foreign') } }.value
        Thread.new { rejects(ThreadError) { api.emit_message('foreign') } }.value
        Thread.new { rejects(ThreadError) { api.completion = proc { [] } } }.value
        Thread.new { rejects(ThreadError) { api.event = proc { [] } } }.value
        Thread.new { rejects(ThreadError) { api.add_history('foreign') } }.value
        Thread.new { rejects(ThreadError) { api.resize } }.value
        20.times { GC.start; GC.compact }
        copy = api.buffer
        copy.replace('foreign')
        raise 'buffer alias' unless api.buffer == '' && api.point == 0
        event(events, contracts: true)
      end
      begin
        api.session('p> ') { raise 'fixture exception' }
      rescue RuntimeError => error
        raise unless error.message == 'fixture exception'
      end
      event(events, restored: restored_tty.call)
      exit
    end
    STDOUT.write("\e[2J\e[H")
    begin
      api.session(prompt) do
        event(events, ready: api.version)
        loop do
          readable = IO.select([control, STDIN], nil, nil, 5)&.first
          raise 'fixture input timeout' unless readable
          if readable.include?(control)
            command = control.gets&.strip
            case command
            when 'snapshot'
              event(events, buffer: api.buffer, point: api.point)
            when 'frame'
              event(events, frame: 'starting')
              # Exceed the PTY output capacity: the parent queues ! after observing
              # the first output bytes, while emit_message still owns the frame.
              api.emit_message(("padding\n" * 20_000) + 'incoming')
              event(events, frame: 'done', buffer: api.buffer, point: api.point)
            when 'interrupt'
              event(events, blocking: true)
              api.read_char # SIGINT must cancel a native blocking read.
            when 'wake-hook'
              event(events, waking: true)
              producer = Thread.new do
                sleep 0.05
                pending_message = true
                $wake_written_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
                api.wake
              end
              result = api.read_char
              producer.join
              event(events, state: result.to_s)
            when 'hook-raise'
              # The proc reports the raise from inside the hook BEFORE raising,
              # so the parent completes the line only after the hook provably
              # ran; otherwise the completion key beats the idle cadence.
              api.event = -> do
                event(events, hook_raised: true)
                raise 'hook boom'
              end
              event(events, raising_hook: true)
              producer = Thread.new do
                sleep 0.05
                api.wake
              end
              begin
                result = api.read_char
                producer.join
                event(events, state: result.to_s)
              rescue StandardError => error
                event(events, exception: error.message)
                break
              end
            when 'add-history'
              api.add_history('via add')
              event(events, added: true)
            when 'add-duplicate-history'
              api.add_history('via add')
              event(events, added_dup: true)
            when 'add-blank-history'
              api.add_history('')
              event(events, added_blank: true)
            when 'complete-args'
              event(events, completion_args: completions.pop)
            when 'set-raising-completion'
              api.completion = -> (prefix, full) { raise 'completion boom' }
              event(events, raising_completion: true)
            when 'set-multi-completion'
              api.completion = -> (prefix, full) do
                completions << [prefix, full]
                %w[help hello]
              end
              event(events, multi_completion: true)
            when 'set-nil-completion'
              api.completion = -> (prefix, full) do
                completions << [prefix, full]
                nil
              end
              event(events, nil_completion: true)
            when 'set-empty-completion'
              api.completion = -> (prefix, full) do
                completions << [prefix, full]
                []
              end
              event(events, empty_completion: true)
            when 'set-malformed-completion'
              api.completion = -> (prefix, full) { ['hello', 123] }
              event(events, malformed_completion: true)
            when 'set-utf8-completion'
              api.completion = -> (prefix, full) do
                completions << [prefix, full]
                ['holaá', 'holaó']
              end
              event(events, utf8_completion: true)
            when 'resize'
              api.resize
              event(events, resized: true)
            when 'quit' then break
            else raise "bad fixture command #{command.inspect}"
            end
          elsif readable.include?(STDIN)
            begin
              result = api.read_char
            rescue StandardError => error
              raise unless mode == 'complete'

              event(events, exception: error.message)
              break
            end
            if result == :eof
              event(events, eof: true)
              break
            elsif result.is_a?(String)
              event(events, line: result)
            else
              event(events, state: result.to_s)
            end
          end
        end
      end
    rescue Interrupt
      event(events, interrupt: true)
    end
    event(events, restored: restored_tty.call)
    if mode == 'complete' || mode == 'hook'
      begin
        api.buffer
        raise 'expected inactive buffer check to fail'
      rescue RuntimeError
        event(events, inactive_checks: true)
      end
    end
  RUBY

  # Child communication is on private fixture pipes, never mixed into the screen.
  define_method(:with_callback_pty) do |mode, &block|
    control_r, control_w = IO.pipe
    events_r, events_w = IO.pipe
    pid = nil
    PTY.spawn({'INPUTRC' => '/dev/null', 'TERM' => 'xterm'}, RbConfig.ruby,
              '-e', child, native, mode, 3 => control_r, 4 => events_w) do |output, input, child_pid|
      pid = child_pid
      control_r.close
      events_w.close
      output.winsize = [12, 24]
      control_w.puts('start')
      screen = CallbackScreen.new
      Timeout.timeout(15) { block.call(output, input, control_w, events_r, screen, pid) }
      _, status = Process.wait2(pid)
      pid = nil
      expect(status.success?).to be(true)
    end
  ensure
    if pid
      Process.kill('TERM', pid) rescue Errno::ESRCH
      Process.wait(pid) rescue Errno::ECHILD
    end
    [control_r, control_w, events_r, events_w].compact.each { |io| io.close unless io.closed? }
  end

  define_method(:event_until) do |events, key|
    loop do
      event = JSON.parse(events.gets || raise('child closed event pipe'))
      return event if event.key?(key)
    end
  end

  define_method(:drain_screen) do |output, screen|
    while IO.select([output], nil, nil, 0.03)
      screen.feed(output.read_nonblock(16_384))
    end
  rescue IO::WaitReadable
    nil
  end

  define_method(:stabilize) do |control, events, expected|
    snapshot = nil
    100.times do
      sleep 0.005
      control.puts('snapshot')
      snapshot = event_until(events, 'buffer')
      break if snapshot == expected
    end
    snapshot
  end

  it 'rejects invalid state/types/owners and preserves copied storage through GC and exceptions' do
    with_callback_pty('contracts') do |_output, _input, _control, events, _screen, _pid|
      expect(event_until(events, 'contracts')['contracts']).to be(true)
      expect(event_until(events, 'restored')['restored']).to be(true)
    end
  end

  it 'restores the real TTY after EOF' do
    with_callback_pty('edit') do |_output, input, _control, events, _screen, _pid|
      event_until(events, 'ready')
      input.write("\u0004")
      expect(event_until(events, 'eof')['eof']).to be(true)
      expect(event_until(events, 'restored')['restored']).to be(true)
    end
  end

  it 'cancels a blocking native read on SIGINT and restores the TTY' do
    with_callback_pty('edit') do |_output, _input, control, events, _screen, pid|
      event_until(events, 'ready')
      control.puts('interrupt')
      event_until(events, 'blocking')
      sleep 0.05
      Process.kill('INT', pid)
      expect(event_until(events, 'interrupt')['interrupt']).to be(true)
      expect(event_until(events, 'restored')['restored']).to be(true)
    end
  end

  it 'preserves wrapped visible input/cursor and defers a key queued during the output frame' do
    with_callback_pty('edit') do |output, input, control, events, screen, _pid|
      expect(event_until(events, 'ready')['ready']).to eq('8.3')
      text = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWX'
      input.write(text + ("\e[D" * 25))
      # Snapshot only after GNU has consumed every native key, not by assigning point.
      snapshot = nil
      100.times do
        sleep 0.005
        control.puts('snapshot')
        snapshot = event_until(events, 'buffer')
        break if snapshot == {'buffer' => text, 'point' => 25}
      end
      expect(snapshot).to eq('buffer' => text, 'point' => 25)
      drain_screen(output, screen)
      expect(screen.lines.first(3)).to eq([('p> ' + text)[0, 24], ('p> ' + text)[24, 24], ('p> ' + text)[48..]])
      expect([screen.row, screen.column]).to eq([1, 4])
      control.puts('frame')
      event_until(events, 'frame')
      # Do not drain the entire frame yet: it cannot complete while the output
      # capacity is exceeded. Queue input after actual frame output is observed.
      IO.select([output])
      screen.feed(output.readpartial(4096))
      input.write('!')
      done = nil
      until done
        ready = IO.select([output, events], nil, nil, 5)&.first || raise('frame timeout')
        screen.feed(output.read_nonblock(16_384)) if ready.include?(output)
        if ready.include?(events)
          candidate = JSON.parse(events.gets)
          done = candidate if candidate['frame'] == 'done'
        end
      end
      expect(done).to include('buffer' => text, 'point' => 25)
      # The root may now consume the queued key. Verify the new logical state.
      control.puts('snapshot')
      snapshot = event_until(events, 'buffer')
      unless snapshot['point'] == 26
        sleep 0.02
        control.puts('snapshot')
        snapshot = event_until(events, 'buffer')
      end
      expected = 'abcdefghijklmnopqrstuvwxy!zABCDEFGHIJKLMNOPQRSTUVWX'
      expect(snapshot).to eq('buffer' => expected, 'point' => 26)
      drain_screen(output, screen)
      prompt = 'p> ' + expected
      expect(screen.lines.last(4)).to eq(['incoming', prompt[0, 24], prompt[24, 24], prompt[48..]])
      expect([screen.row, screen.column]).to eq([10, 5])
      expect(screen.unknown).to be_empty
      input.write("\r")
      expect(event_until(events, 'line')['line']).to eq(expected)
      control.puts('quit')
      expect(event_until(events, 'restored')['restored']).to be(true)
    end
  end

  # The old READERR wake contract (expecting a :wake return) failed
  # deterministically in GNU 8.3 and is kept as historical evidence in the
  # tracker/docs; this example pins the new owner-consumption contract.
  it 'consumes a producer event during the bare-ESC wait through the owner hook and keeps the wrapped editor state' do
    with_callback_pty('hook') do |output, input, control, events, screen, _pid|
      event_until(events, 'ready')
      text = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWX'
      input.write(text + ("\e[D" * 25))
      expect(stabilize(control, events, 'buffer' => text, 'point' => 25)).to eq('buffer' => text, 'point' => 25)
      # A bare ESC leaves GNU waiting inside the incomplete escape sequence;
      # the producer must still reach the owner there, without EOF.
      input.write("\e")
      expect(event_until(events, 'state')['state']).to eq('pending')
      control.puts('wake-hook')
      expect(event_until(events, 'waking')['waking']).to be(true)
      drawn = event_until(events, 'hook')
      expect(drawn.dig('hook', 'thread')).to eq('owner')
      expect(drawn.dig('hook', 'wall_ms')).to be < 1000
      # Completing the escape continues editing; nothing was lost.
      input.write('[D')
      expect(stabilize(control, events, 'buffer' => text, 'point' => 24)).to eq('buffer' => text, 'point' => 24)
      # Backpressured frame with a collision-free key queued during it: the
      # key must stay unprocessed until the owner completes the redraw.
      control.puts('frame')
      event_until(events, 'frame')
      IO.select([output])
      screen.feed(output.readpartial(4096))
      input.write('!')
      done = nil
      until done
        ready = IO.select([output, events], nil, nil, 5)&.first || raise('frame timeout')
        screen.feed(output.read_nonblock(16_384)) if ready.include?(output)
        if ready.include?(events)
          candidate = JSON.parse(events.gets)
          done = candidate if candidate['frame'] == 'done'
        end
      end
      expect(done).to include('buffer' => text, 'point' => 24)
      control.puts('snapshot')
      snapshot = event_until(events, 'buffer')
      unless snapshot['point'] == 25
        sleep 0.02
        control.puts('snapshot')
        snapshot = event_until(events, 'buffer')
      end
      expected = text[0, 24] + '!' + text[24..]
      expect(snapshot).to eq('buffer' => expected, 'point' => 25)
      drain_screen(output, screen)
      prompt = 'p> ' + expected
      expect(screen.lines.last(4)).to eq(['incoming', prompt[0, 24], prompt[24, 24], prompt[48..]])
      expect([screen.row, screen.column]).to eq([10, 4])
      expect(screen.unknown).to be_empty
      input.write("\r")
      expect(event_until(events, 'line')['line']).to eq(expected)
      # A raising hook aborts the round with cleanup: the owner sees the
      # original exception and the session is inactive afterwards.
      control.puts('hook-raise')
      expect(event_until(events, 'raising_hook')['raising_hook']).to be(true)
      # Causal: the hook must provably have run (and been captured) before
      # the line is completed; the completion key never beats the cadence.
      expect(event_until(events, 'hook_raised')['hook_raised']).to be(true)
      input.write("\r")
      expect(event_until(events, 'exception')['exception']).to eq('hook boom')
      expect(event_until(events, 'restored')['restored']).to be(true)
      expect(event_until(events, 'inactive_checks')['inactive_checks']).to be(true)
    end
  end

  it 'completes the maximal common prefix for ambiguous candidates and submits it' do
    with_callback_pty('complete') do |output, input, control, events, screen, _pid|
      event_until(events, 'ready')
      control.puts('set-multi-completion')
      expect(event_until(events, 'multi_completion')['multi_completion']).to be(true)
      input.write('he')
      expect(stabilize(control, events, 'buffer' => 'he', 'point' => 2)).to eq('buffer' => 'he', 'point' => 2)
      input.write("\t")
      expect(stabilize(control, events, 'buffer' => 'hel', 'point' => 3)).to eq('buffer' => 'hel', 'point' => 3)
      control.puts('complete-args')
      expect(event_until(events, 'completion_args')['completion_args']).to eq(['he', 'he'])
      drain_screen(output, screen)
      expect(screen.lines.first).to eq('p> hel')
      expect(screen.unknown).to be_empty
      input.write("\r")
      expect(event_until(events, 'line')['line']).to eq('hel')
      control.puts('quit')
      expect(event_until(events, 'restored')['restored']).to be(true)
    end
  end

  it 'never falls back to filenames with an installed callback returning nil or empty' do
    with_callback_pty('complete') do |output, input, control, events, screen, _pid|
      event_until(events, 'ready')
      control.puts('set-nil-completion')
      expect(event_until(events, 'nil_completion')['nil_completion']).to be(true)
      input.write('Gemf')
      expect(stabilize(control, events, 'buffer' => 'Gemf', 'point' => 4)).to eq('buffer' => 'Gemf', 'point' => 4)
      input.write("\t")
      # An installed callback returning nil means no command matches and no
      # filename fallback: the buffer must stay exactly as typed.
      expect(stabilize(control, events, 'buffer' => 'Gemf', 'point' => 4)).to eq('buffer' => 'Gemf', 'point' => 4)
      drain_screen(output, screen)
      expect(screen.lines.first).to eq('p> Gemf')
      input.write("\r")
      expect(event_until(events, 'line')['line']).to eq('Gemf')
      control.puts('set-empty-completion')
      expect(event_until(events, 'empty_completion')['empty_completion']).to be(true)
      input.write('Gem')
      expect(stabilize(control, events, 'buffer' => 'Gem', 'point' => 3)).to eq('buffer' => 'Gem', 'point' => 3)
      input.write("\t")
      expect(stabilize(control, events, 'buffer' => 'Gem', 'point' => 3)).to eq('buffer' => 'Gem', 'point' => 3)
      input.write("\r")
      expect(event_until(events, 'line')['line']).to eq('Gem')
      control.puts('quit')
      expect(event_until(events, 'restored')['restored']).to be(true)
    end
  end

  it 'rejects a malformed partial completion list with cleanup and reopens' do
    with_callback_pty('complete') do |output, input, control, events, screen, _pid|
      event_until(events, 'ready')
      control.puts('set-malformed-completion')
      expect(event_until(events, 'malformed_completion')['malformed_completion']).to be(true)
      input.write('h')
      expect(stabilize(control, events, 'buffer' => 'h', 'point' => 1)).to eq('buffer' => 'h', 'point' => 1)
      input.write("\t")
      expect(event_until(events, 'exception')['exception']).to eq('completion entries must be Strings')
      expect(event_until(events, 'restored')['restored']).to be(true)
      expect(event_until(events, 'inactive_checks')['inactive_checks']).to be(true)
    end
  end

  it 'keeps the UTF-8 boundary in the ambiguous common prefix' do
    with_callback_pty('complete') do |output, input, control, events, screen, _pid|
      event_until(events, 'ready')
      control.puts('set-utf8-completion')
      expect(event_until(events, 'utf8_completion')['utf8_completion']).to be(true)
      input.write('hola')
      expect(stabilize(control, events, 'buffer' => 'hola', 'point' => 4)).to eq('buffer' => 'hola', 'point' => 4)
      input.write("\t")
      # Candidates ['holaá','holaó'] share the byte prefix 'hola\xC3' but the
      # common prefix must back off to the character boundary 'hola'.
      expect(stabilize(control, events, 'buffer' => 'hola', 'point' => 4)).to eq('buffer' => 'hola', 'point' => 4)
      drain_screen(output, screen)
      expect(screen.lines.first).to eq('p> hola')
      expect(screen.unknown).to be_empty
      input.write("\r")
      expect(event_until(events, 'line')['line']).to eq('hola')
      control.puts('quit')
      expect(event_until(events, 'restored')['restored']).to be(true)
    end
  end

  it 'keeps GNU default filename completion without an installed callback' do
    with_callback_pty('edit') do |_output, input, control, events, _screen, _pid|
      event_until(events, 'ready')
      input.write('Gemf')
      expect(stabilize(control, events, 'buffer' => 'Gemf', 'point' => 4)).to eq('buffer' => 'Gemf', 'point' => 4)
      input.write("\t")
      # No proc installed: the documented default applies (Gemfile and
      # Gemfile.lock share the common prefix Gemfile).
      expect(stabilize(control, events, 'buffer' => 'Gemfile', 'point' => 7)).to eq('buffer' => 'Gemfile', 'point' => 7)
      input.write("\r")
      expect(event_until(events, 'line')['line']).to eq('Gemfile')
      control.puts('quit')
      expect(event_until(events, 'restored')['restored']).to be(true)
    end
  end

  it 'completes through the owner callback with prefix/full buffer under GC and cleans up on its exception' do
    with_callback_pty('complete') do |output, input, control, events, screen, _pid|
      event_until(events, 'ready')
      input.write('he')
      expect(stabilize(control, events, 'buffer' => 'he', 'point' => 2)).to eq('buffer' => 'he', 'point' => 2)
      input.write("\t")
      expect(stabilize(control, events, 'buffer' => 'hello', 'point' => 5)).to eq('buffer' => 'hello', 'point' => 5)
      control.puts('complete-args')
      expect(event_until(events, 'completion_args')['completion_args']).to eq(['he', 'he'])
      drain_screen(output, screen)
      expect(screen.lines.first).to eq('p> hello')
      expect([screen.row, screen.column]).to eq([0, 8])
      expect(screen.unknown).to be_empty
      input.write("\r")
      expect(event_until(events, 'line')['line']).to eq('hello')
      # A raising completion callback aborts the round with cleanup: the owner
      # sees the original exception, and the session is inactive afterwards.
      control.puts('set-raising-completion')
      expect(event_until(events, 'raising_completion')['raising_completion']).to be(true)
      input.write('x')
      expect(stabilize(control, events, 'buffer' => 'x', 'point' => 1)).to eq('buffer' => 'x', 'point' => 1)
      input.write("\t")
      expect(event_until(events, 'exception')['exception']).to eq('completion boom')
      expect(event_until(events, 'restored')['restored']).to be(true)
      expect(event_until(events, 'inactive_checks')['inactive_checks']).to be(true)
    end
  end

  it 'adds history with blanks and immediate duplicates and navigates the live owner buffer' do
    with_callback_pty('edit') do |output, input, control, events, screen, _pid|
      event_until(events, 'ready')
      control.puts('add-history')
      expect(event_until(events, 'added')['added']).to be(true)
      input.write("\e[A")
      expect(stabilize(control, events, 'buffer' => 'via add', 'point' => 7)).to eq('buffer' => 'via add', 'point' => 7)
      drain_screen(output, screen)
      expect(screen.lines.first).to eq('p> via add')
      input.write("\e[B")
      expect(stabilize(control, events, 'buffer' => '', 'point' => 0)).to eq('buffer' => '', 'point' => 0)
      # The native layer must accept immediate duplicates and blanks without
      # policy; the duplicate is stored verbatim before the blank entry.
      control.puts('add-duplicate-history')
      expect(event_until(events, 'added_dup')['added_dup']).to be(true)
      control.puts('add-blank-history')
      expect(event_until(events, 'added_blank')['added_blank']).to be(true)
      # Newest entry first: the blank must be recallable as the empty buffer,
      # then the immediate duplicate is recalled above it.
      input.write("\e[A")
      expect(event_until(events, 'state')['state']).to eq('pending')
      expect(stabilize(control, events, 'buffer' => '', 'point' => 0)).to eq('buffer' => '', 'point' => 0)
      input.write("\e[A")
      expect(event_until(events, 'state')['state']).to eq('pending')
      expect(stabilize(control, events, 'buffer' => 'via add', 'point' => 7)).to eq('buffer' => 'via add', 'point' => 7)
      input.write("\e[B")
      expect(event_until(events, 'state')['state']).to eq('pending')
      expect(stabilize(control, events, 'buffer' => '', 'point' => 0)).to eq('buffer' => '', 'point' => 0)
      input.write("\e[B")
      expect(event_until(events, 'state')['state']).to eq('pending')
      expect(stabilize(control, events, 'buffer' => '', 'point' => 0)).to eq('buffer' => '', 'point' => 0)
      # Editing is intact after navigation; no EOF occurred during the round.
      input.write('!')
      expect(stabilize(control, events, 'buffer' => '!', 'point' => 1)).to eq('buffer' => '!', 'point' => 1)
      input.write("\r")
      expect(event_until(events, 'line')['line']).to eq('!')
      control.puts('quit')
      expect(event_until(events, 'restored')['restored']).to be(true)
    end
  end

  it 'redisplays the live prompt/input across a real PTY winsize change through public resize' do
    with_callback_pty('edit') do |output, input, control, events, screen, _pid|
      event_until(events, 'ready')
      text = 'abcdefghijklmnopqrstuvwxyz'
      input.write(text)
      expect(stabilize(control, events, 'buffer' => text, 'point' => 26)).to eq('buffer' => text, 'point' => 26)
      screen = CallbackScreen.new
      drain_screen(output, screen)
      expect(screen.lines.first(2)).to eq([('p> ' + text)[0, 24], ('p> ' + text)[24..]])
      expect([screen.row, screen.column]).to eq([1, 5])
      # Real winsize change; the session keeps GNU's own SIGWINCH handling
      # disabled, so the redraw is driven by the owner's public resize only.
      output.winsize = [12, 40]
      control.puts('resize')
      expect(event_until(events, 'resized')['resized']).to be(true)
      resized = CallbackScreen.new(12, 40)
      drain_screen(output, resized)
      expect(resized.lines.first).to eq('p> ' + text)
      expect([resized.row, resized.column]).to eq([0, 29])
      expect(resized.unknown).to be_empty
      input.write("\r")
      expect(event_until(events, 'line')['line']).to eq(text)
      control.puts('quit')
      expect(event_until(events, 'restored')['restored']).to be(true)
    end
  end

  it 'proves UTF-8 and color prompt columns through public ignore markers end to end' do
    with_callback_pty('utf8') do |output, input, control, events, screen, _pid|
      event_until(events, 'ready')
      input.write('holá')
      # rl_point counts bytes, so the typed accented byte sequence has point 5
      # while the display cursor advances by one visible column per glyph.
      expect(stabilize(control, events, 'buffer' => 'holá', 'point' => 5)).to eq('buffer' => 'holá', 'point' => 5)
      drain_screen(output, screen)
      expect(screen.lines.first).to eq('▸ holá')
      expect([screen.row, screen.column]).to eq([0, 6])
      expect(screen.unknown).to be_empty
      input.write("\r")
      expect(event_until(events, 'line')['line']).to eq('holá')
      control.puts('quit')
      expect(event_until(events, 'restored')['restored']).to be(true)
    end
  end

  describe 'CallbackScreen CSI model' do
    let(:screen) { CallbackScreen.new }

    it 'keeps the untouched tail on ECH' do
      screen.feed("\e[2J\e[Habcdefghijkl\e[5G\e[2X")
      expect(screen.lines.first).to eq('abcd  ghijkl')
      expect([screen.row, screen.column]).to eq([0, 4])
      expect(screen.unknown).to be_empty
    end

    it 'clips ECH at the right margin without touching earlier columns' do
      screen.feed("\e[2J\e[Habcdef\e[5G\e[99X")
      expect(screen.lines.first).to eq('abcd')
      expect([screen.row, screen.column]).to eq([0, 4])
      expect(screen.unknown).to be_empty
    end

    it 'keeps the untouched tail on ICH' do
      screen.feed("\e[2J\e[Habcdef\e[5G\e[2@")
      expect(screen.lines.first).to eq('abcd  ef')
      expect(screen.unknown).to be_empty
    end

    it 'deletes only the count on DCH preserving the remaining tail' do
      screen.feed("\e[2J\e[Habcdefghijkl\e[5G\e[2P")
      expect(screen.lines.first).to eq('abcdghijkl')
      expect([screen.row, screen.column]).to eq([0, 4])
      expect(screen.unknown).to be_empty
    end

    it 'keeps row width unchanged and unknown ANSI fatal across all three' do
      screen.feed("\e[2J\e[Habcdefghijkl\e[5G\e[2X\e[2@\e[2P")
      expect(screen.lines.first.length).to eq(12)
      expect(screen.unknown).to be_empty
    end

  it 'rejects unknown CSI as fatal' do
    expect { screen.feed("\e[9z") }.to raise_error(RuntimeError, /unsupported CSI/)
  end

  it 'renders the tested UTF-8 glyphs at one display column each' do
    screen.feed("\e[2J\e[H▸ á\b")
    expect(screen.lines.first).to eq('▸ á')
    expect([screen.row, screen.column]).to eq([0, 2])
    expect(screen.unknown).to be_empty
  end

  it 'keeps untested non-ASCII glyphs and invalid UTF-8 fatal' do
    cases = [["\u0416", /untested non-ASCII glyph/],
             ["\xC3", /truncated UTF-8 sequence/],
             ["\x80", /invalid UTF-8 lead/]].freeze
    cases.each do |input, pattern|
      fresh = CallbackScreen.new
      expect { fresh.feed("\e[2J\e[H#{input}") }.to raise_error(RuntimeError, pattern)
    end
  end
end
end
