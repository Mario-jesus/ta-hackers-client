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
    @cells = Array.new(rows) { ' ' * columns }
    @row = @column = 0
    @pending = +''
    @wrap = false
    @unknown = []
  end

  def feed(bytes)
    @pending << bytes
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
        case byte
        when "\r" then @column = 0; @wrap = false
        when "\n" then down; @wrap = false
        when "\b" then @column = [@column - 1, 0].max; @wrap = false
        when "\a" # bell does not change cells
        else
          raise "non-ASCII display byte #{byte.inspect}" unless byte.ord.between?(32, 126)

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

  def lines
    @cells.map(&:rstrip)
  end

  def down
    @row += 1
    return if @row < @rows

    @cells.shift
    @cells << ' ' * @columns
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

      @cells = Array.new(@rows) { ' ' * @columns }
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
    expect(CliReadlineCallback).to respond_to(:install, :session, :read_char, :emit_message, :remove, :buffer, :point)
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
    before = STDIN.console_mode
    # IO::ConsoleMode#== compares raw struct bytes and is unstable between two
    # consecutive snapshots (padding), so restore checks compare the semantic
    # termios state instead: the full stty -g encoding plus every exposed field.
    before_stty = `stty -g`
    mode_fields = ->(m) { m.methods.grep(/^c_/).sort.map { |n| [n, m.public_send(n)] }.to_h }
    before_fields = mode_fields.call(before)
    restored_tty = -> { `stty -g` == before_stty && mode_fields.call(STDIN.console_mode) == before_fields }
    if mode == 'contracts'
      %i[read_char buffer point remove].each { |name| rejects(RuntimeError) { api.public_send(name) } }
      rejects(TypeError) { api.install(123) }
      rejects(ArgumentError) { api.install("bad\0prompt") }
      prompt = +'p> '
      api.session(prompt) do
        prompt.replace('changed')
        rejects(RuntimeError) { api.install('again') }
        rejects(TypeError) { api.emit_message(nil) }
        rejects(ArgumentError) { api.emit_message("bad\0text") }
        %i[version buffer point read_char remove].each do |name|
          Thread.new { rejects(ThreadError) { api.public_send(name) } }.value
        end
        Thread.new { rejects(ThreadError) { api.install('foreign') } }.value
        Thread.new { rejects(ThreadError) { api.emit_message('foreign') } }.value
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
      api.session('p> ') do
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
            when 'quit' then break
            else raise "bad fixture command #{command.inspect}"
            end
          elsif readable.include?(STDIN)
            result = api.read_char
            event(events, line: result) if result.is_a?(String)
            if result == :eof
              event(events, eof: true)
              break
            end
          end
        end
      end
    rescue Interrupt
      event(events, interrupt: true)
    end
    event(events, restored: restored_tty.call)
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
  end
end
