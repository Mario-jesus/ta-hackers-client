# frozen_string_literal: true

# Shared current-screen interpreter for real-PTY editor specs. Extracted
# verbatim from spec/cli_readline_callback_spec.rb (T0b1/T0b2a closed unit);
# the native spec and the interactive-shell adapter spec require this helper
# so both gates run the exact same screen semantics.
#
# Current-screen interpreter, not a transcript matcher. Unknown ANSI is fatal.
class CallbackScreen
  attr_reader :row, :column, :unknown

  def initialize(rows = 12, columns = 24, streaming: false)
    @rows, @columns = rows, columns
    @streaming = streaming
    @unfinished = nil
    @cells = Array.new(rows) { (' ' * columns).force_encoding(Encoding::UTF_8) }
    @row = @column = 0
    @pending = +''
    @wrap = false
    @unknown = []
  end

  def feed(bytes)
    # The model consumes raw terminal bytes, so UTF-8 string inputs are
    # normalized to their byte sequence before slicing.
    #
    # Streaming mode (SDK PTY readers only): restore the carried unfinished
    # VALID UTF-8 prefix ahead of the new bytes — no double consumption,
    # no reordering. The default strict feed never defers anything.
    if @streaming && @unfinished
      @pending = @unfinished + @pending
      @unfinished = nil
    end
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
        if byte.ord > 0x7F
          if @streaming
            size = utf8_sequence_size(byte)
            if @pending.bytesize < size - 1
              # Incomplete at an intermediate read: carry the validated
              # lead until the next chunk completes the codepoint; no
              # cell/cursor advance happens yet. Never fatal here.
              @unfinished = byte
              break
            end
          end
          byte = consume_utf8(byte)
        end
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
  # stays fatal. Each added glyph is an SDK-rendered character exercised by a
  # concrete fixture: '▸' prompt (bin + native spec), 'á' typed/completed
  # text, '❥' talk prompt, '❤' chat log lines, '✔' logger log prefix,
  # '✿' script logger prefix, '❯' script-local logger prefixes.
  TESTED_UTF8 = ['▸', 'á', '❥', '❤', '✔', '✿', '❯'].freeze

  # Streaming-mode lead validation, used ONLY to decide whether the
  # current chunk can already carry the whole sequence: the exact same
  # lead acceptance as the strict consume_utf8 mask (2/3-byte leads;
  # 4-byte leads and anything else stay on the error path — no
  # fullwidth/grapheme claims), so no glyph whitelist is extended and the
  # strict behavior is untouched.
  def utf8_sequence_size(lead)
    code = lead.ord
    raise "invalid UTF-8 lead #{lead.inspect}" unless [0b11000000, 0b11100000].any? { |mask| (code & mask) == mask }

    code >= 0b11100000 ? 3 : 2
  end

  ##
  # Stream-end validation for streaming receivers only — never called per
  # chunk or mid-frame, only at the stable declared end of a verification
  # (after the full quiet drain, with the child idle). A still-carried
  # UTF-8 prefix or an unfinished escape/CSI sequence at stream end is
  # FATAL here; the same incompleteness is legal at an intermediate read.
  # The strict default defers nothing, so its callers never need this.
  def finish!
    raise "unfinished UTF-8 prefix #{@unfinished.inspect} at stream end" if @streaming && @unfinished

    raise "unfinished escape sequence #{@pending.inspect} at stream end" unless @pending.empty?

    self
  end

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
    # SGR is a pure attribute change: it must not clear the terminal's
    # deferred auto-wrap state (extended for colored adapter fixtures; the
    # verbatim baseline never combined SGR with a margin-position cursor).
    @wrap = false unless code == 'm'
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
      # Extended for the adapter gate: the SDK shell's Interrupt path emits
      # "\e[0G\e[J" (erase from cursor to the end of the screen). Mode 0 is
      # the documented default; mode 2 stays the full-screen erase.
      mode = parameters.empty? ? 0 : parameters.to_i
      case mode
      when 0
        @cells[@row][@column..] = ' ' * (@columns - @column)
        ((@row + 1)...@rows).each do |row|
          @cells[row] = (' ' * @columns).force_encoding(Encoding::UTF_8)
        end
      when 2
        @cells = Array.new(@rows) { (' ' * @columns).force_encoding(Encoding::UTF_8) }
      else raise "unsupported erase mode #{mode}"
      end
    when 'm' # ASCII fixture has no color-dependent cells
    when 'h', 'l'
      raise "unsupported terminal mode #{parameters}" unless parameters == '?2004'
    else
      @unknown << [parameters, code]
      raise "unsupported CSI #{parameters}#{code}"
    end
  end
end
