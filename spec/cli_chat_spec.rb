# frozen_string_literal: true

require 'stringio'
require 'timeout'

require 'cli/colorterm'
require 'sandbox'
require 'cli/sandbox'
require 'hackers'

# Offline unit tests for the chat CLI surface (task C1).
#
# The chat context file is loaded against a synthetic shell/game/logger
# scaffold. Transport is stubbed with synthetic serialized payloads; no real
# network and no real config files are touched.
SHELL_OUTPUT = StringIO.new
SHELL = Sandbox::Shell.new(StringIO.new, SHELL_OUTPUT)
GAME = Hackers::Game.new({})
LOGGER = Sandbox::Logger.new(SHELL)
NOT_CONNECTED = 'Not connected'
CONTEXT_CHAT = SHELL.add_context(:chat, description: 'Internal chat')

require 'cli/context/chat'

RSpec.describe 'CLI chat context' do
  CHAT_PAYLOAD = '1000,Alice,hello,55,60,3,999;1001,TestHero,Test,777,60,3,999'.freeze
  HOSTILE_PAYLOAD =
    "1000,Evil,Unrecognized command: rm -rf,55,60,3,999;" \
    "1001,Evil2,\e[31m✘ fake failure\e[0m,66,60,3,999".freeze

  before do
    SHELL_OUTPUT.truncate(0)
    SHELL_OUTPUT.rewind
    CHAT_ROOMS.clear
    GAME.chat.instance_variable_set(:@rooms, [])
    CLI_RESULTS.clear
    allow(GAME.api.client).to receive(:request_raw).and_return(CHAT_PAYLOAD)
  end

  def chat_command(name)
    CONTEXT_CHAT.commands.detect { |c| c.match?(name) }
  end

  def run_chat(name, *tokens)
    command = chat_command(name)
    command.exec([name.to_s, *tokens])
    SHELL_OUTPUT.string
  end

  describe 'chat text sanitization' do
    it 'strips ANSI color and cursor effects from untrusted text' do
      text = sanitize_chat_text("\e[31mred\e[0m\e[2J\e[1;10Hclean")

      expect(text).to eq('redclean')
    end

    it 'strips OSC sequences and bare escape bytes' do
      text = sanitize_chat_text("\e]0;title\aafter\eXraw")

      expect(text).to eq('afterraw')
    end

    it 'collapses control bytes so messages cannot fake prompts or lines' do
      text = sanitize_chat_text("one\r\n\u2764 two\tthree\x00four\x7f")

      expect(text).to eq("one  \u2764 two three four ")
      expect(text).not_to include("\n")
    end

    it 'preserves Unicode and game rich-text literals verbatim' do
      text = sanitize_chat_text('[ff0000]βℓąȼЌhąţhąȼЌ€я ✓ 漢字')

      expect(text).to eq('[ff0000]βℓąȼЌhąţhąȼЌ€я ✓ 漢字')
    end

    it 'scrubs invalid byte sequences instead of raising' do
      text = sanitize_chat_text("bad \xFF byte".dup.force_encoding(Encoding::UTF_8))

      expect(text).to be_valid_encoding
    end
  end

  describe 'chat rendering without app metadata' do
    before do
      allow(GAME.api).to receive(:sid).and_return('SIDTEST123')
      allow(GAME.api).to receive(:sid?).and_return(true)
    end

    it 'shows an unknown level when the experience list is not loaded' do
      expect(GAME.experience_list.loaded?).to be(false)

      run_chat(:read, '999')

      expect(SHELL_OUTPUT.string).to include('?')
      expect(SHELL_OUTPUT.string).to include('Alice')
    end

    it 'sanitizes untrusted names and message text in the log line' do
      allow(GAME.api.client).to receive(:request_raw).and_return(HOSTILE_PAYLOAD)

      run_chat(:read, '999')

      # Hostile escape effects are stripped; our own level coloring remains.
      expect(SHELL_OUTPUT.string).not_to include("\e[31m✘")
      expect(SHELL_OUTPUT.string).not_to include("\e[2J")
      expect(SHELL_OUTPUT.string).to include('Unrecognized command: rm -rf')
      expect(SHELL_OUTPUT.string).to include('✘ fake failure')
    end
  end

  describe 'polling cadence' do
    it 'falls back to the 5s default when app settings are not loaded' do
      expect(GAME.app_settings.loaded?).to be(false)

      expect(chat_poll_interval).to eq(5)
    end

    it 'falls back to the default for nil, zero and negative intervals' do
      allow(GAME.app_settings).to receive(:loaded?).and_return(true)
      allow(GAME.app_settings).to receive(:get).with('chat_refresh_interval').and_return(nil)
      expect(chat_poll_interval).to eq(5)

      allow(GAME.app_settings).to receive(:get).with('chat_refresh_interval').and_return(0)
      expect(chat_poll_interval).to eq(5)

      allow(GAME.app_settings).to receive(:get).with('chat_refresh_interval').and_return(-3)
      expect(chat_poll_interval).to eq(5)
    end

    it 'applies the positive floor to sub-second server values' do
      allow(GAME.app_settings).to receive(:loaded?).and_return(true)
      allow(GAME.app_settings).to receive(:get).with('chat_refresh_interval').and_return(0.2)

      expect(chat_poll_interval).to eq(1)
    end

    it 'keeps positive server values' do
      allow(GAME.app_settings).to receive(:loaded?).and_return(true)
      allow(GAME.app_settings).to receive(:get).with('chat_refresh_interval').and_return(7)

      expect(chat_poll_interval).to eq(7)
    end
  end

  describe 'one-shot chat read' do
    before do
      allow(GAME.api).to receive(:sid).and_return('SIDTEST123')
      allow(GAME.api).to receive(:sid?).and_return(true)
    end

    it 'fails safely without a session' do
      allow(GAME.api).to receive(:sid?).and_return(false)

      run_chat(:read, '999')

      expect(GAME.chat).not_to be_opened(999)
      expect(SHELL_OUTPUT.string).to include(NOT_CONNECTED)
    end

    it 'reads with one RPC and closes a room it opened itself' do
      run_chat(:read, '999')

      expect(GAME.chat).not_to be_opened(999)
      expect(CHAT_ROOMS).to be_empty
      expect(SHELL_OUTPUT.string).to include('Alice')
      expect(SHELL_OUTPUT.string).to include('TestHero')
    end

    it 'does not close a room opened by a poll thread' do
      GAME.chat.open(999)
      CHAT_ROOMS[999] = Thread.new { sleep }

      run_chat(:read, '999')

      expect(GAME.chat).to be_opened(999)
      expect(CHAT_ROOMS.keys).to eq([999])
    ensure
      CHAT_ROOMS.each_value(&:kill)
    end
  end

  describe 'threadless chat say' do
    before do
      allow(GAME.api).to receive(:sid).and_return('SIDTEST123')
      allow(GAME.api).to receive(:sid?).and_return(true)
      CLI_RESULTS[:own_id] = 777
    end

    it 'opens, writes one RPC and closes the room it opened' do
      run_chat(:say, '999', 'Test')

      expect(GAME.chat).not_to be_opened(999)
      expect(CHAT_ROOMS).to be_empty
      expect(SHELL_OUTPUT.string).to include('TestHero')
      expect(CLI_RESULTS[:sent_messages].map { |send| send[:message] }).to eq(['Test'])
      expect(CLI_RESULTS[:own_message_seen]).to be(true)
      expect(CLI_RESULTS[:chat_publication_status]).to eq('confirmed')
    end

    it 'does not let one owned echo confirm multiple distinct outgoing sends' do
      CLI_RESULTS[:sent_messages] = [
        { id: 1, room: 999, message: 'First', confirmed: false },
        { id: 2, room: 999, message: 'Second', confirmed: false }
      ]
      messages = [Hackers::Serializer::Chat::Data.new('1001', 'TestHero', 'First', 777, 60, 3, 999)]

      batch_note_chat_messages(messages, room: 999)

      expect(CLI_RESULTS[:sent_messages].map { |send| send[:confirmed] }).to eq([true, false])
      expect(CLI_RESULTS[:own_message_seen]).to be(false)
      expect(CLI_RESULTS[:chat_publication_status]).to eq('unconfirmed')
    end

    it 'does not reuse the same owned echo identity for repeated identical sends' do
      CLI_RESULTS[:sent_messages] = [
        { id: 1, room: 999, message: 'Same', confirmed: false },
        { id: 2, room: 999, message: 'Same', confirmed: false }
      ]
      messages = [Hackers::Serializer::Chat::Data.new('1001', 'TestHero', 'Same', 777, 60, 3, 999)]

      batch_note_chat_messages(messages, room: 999)
      changed_metadata = [Hackers::Serializer::Chat::Data.new('1001', 'Renamed', 'Same', 777, 70, 4, 4)]
      batch_note_chat_messages(changed_metadata, room: 999)

      expect(CLI_RESULTS[:sent_messages].map { |send| send[:confirmed] }).to eq([true, false])
      expect(CLI_RESULTS[:chat_publication_status]).to eq('unconfirmed')
    end

    it 'does not let an owned echo observed before sending confirm a future send' do
      stale_echo = [Hackers::Serializer::Chat::Data.new('1001', 'TestHero', 'Same', 777, 60, 3, 999)]

      batch_note_chat_messages(stale_echo, room: 999)
      CLI_RESULTS[:sent_messages] = [
        { id: 1, room: 999, message: 'Same', confirmed: false }
      ]
      batch_note_chat_messages(stale_echo, room: 999)

      expect(CLI_RESULTS[:sent_messages].map { |send| send[:confirmed] }).to eq([false])
      expect(CLI_RESULTS[:chat_publication_status]).to eq('unconfirmed')
    end

    it 'allows two identical sends to be confirmed by distinct echo datetimes' do
      CLI_RESULTS[:sent_messages] = [
        { id: 1, room: 999, message: 'Same', confirmed: false },
        { id: 2, room: 999, message: 'Same', confirmed: false }
      ]
      messages = [
        Hackers::Serializer::Chat::Data.new('1001', 'TestHero', 'Same', 777, 60, 3, 999),
        Hackers::Serializer::Chat::Data.new('1002', 'TestHero', 'Same', 777, 60, 3, 999)
      ]

      batch_note_chat_messages(messages, room: 999)

      expect(CLI_RESULTS[:sent_messages].map { |send| send[:confirmed] }).to eq([true, true])
      expect(CLI_RESULTS[:chat_publication_status]).to eq('confirmed')
    end

    it 'keeps repeated echo matching separated by room' do
      CLI_RESULTS[:sent_messages] = [
        { id: 1, room: 999, message: 'Same', confirmed: false },
        { id: 2, room: 1000, message: 'Same', confirmed: false }
      ]
      messages = [
        Hackers::Serializer::Chat::Data.new('1001', 'TestHero', 'Same', 777, 60, 3, 999),
        Hackers::Serializer::Chat::Data.new('1001', 'TestHero', 'Same', 777, 60, 3, 1000)
      ]

      batch_note_chat_messages([messages.first], room: 999)
      batch_note_chat_messages([messages.first], room: 1000)

      expect(CLI_RESULTS[:sent_messages].map { |send| send[:confirmed] }).to eq([true, true])
      expect(CLI_RESULTS[:chat_publication_status]).to eq('confirmed')
    end

    it 'rejects wrong caller room, owner and text despite matching country' do
      CLI_RESULTS[:sent_messages] = [{ id: 1, room: 999, message: 'Same', confirmed: false }]
      echo = Hackers::Serializer::Chat::Data.new('1001', 'TestHero', 'Same', 777, 60, 3, 999)
      batch_note_chat_messages([echo], room: 1000)
      batch_note_chat_messages([Hackers::Serializer::Chat::Data.new('1002', 'Other', 'Same', 778, 60, 3, 999)], room: 999)
      batch_note_chat_messages([Hackers::Serializer::Chat::Data.new('1003', 'TestHero', 'Other', 777, 60, 3, 999)], room: 999)

      expect(CLI_RESULTS[:sent_messages].first[:confirmed]).to be(false)
      expect(CLI_RESULTS[:chat_last_read_count]).to eq(1)
    end

    it 'does not close an existing poll room' do
      GAME.chat.open(999)
      CHAT_ROOMS[999] = Thread.new { sleep }

      run_chat(:say, '999', 'Test')

      expect(GAME.chat).to be_opened(999)
      expect(CLI_RESULTS[:own_message_seen]).to be(true)
    ensure
      CHAT_ROOMS.each_value(&:kill)
    end

    it 'rejects outgoing terminal control sequences without an RPC' do
      run_chat(:say, '999', "bad\e[31mtext")

      expect(GAME.chat).not_to be_opened(999)
      expect(SHELL_OUTPUT.string).to include('terminal control')
      expect(CLI_RESULTS[:sent_messages] || []).to be_empty
    end
  end

  describe 'poller ownership and teardown' do
    before do
      allow(GAME).to receive(:connected?).and_return(true)
      @workers = []
    end

    after do
      @workers.each do |worker|
        worker.kill if worker.alive?
        worker.join(2) rescue StandardError
      end
    end

    def await_worker(worker)
      expect(worker.join(2)).to equal(worker)
      worker.value
    end

    def owned_worker(shell = SHELL)
      gate = Queue.new
      worker = Thread.new do
        Thread.current.report_on_exception = false
        gate.pop
        chat_read(shell, 999)
      end
      @workers << worker
      GAME.chat.open(999)
      CHAT_ROOMS[999] = worker
      gate << true
      worker
    end

    it 'cleans up and propagates an unexpected output failure without reporting its body' do
      output = double('failing output')
      message = Hackers::Serializer::Chat::Data.new('1000', 'Synthetic', 'hello', 55, 60, 3, 999)
      allow(GAME.chat).to receive(:read).with(999).and_return([message])
      allow(output).to receive(:puts).and_raise(NoMethodError, 'PRIVATE synthetic body')
      worker = owned_worker(output)

      expect { await_worker(worker) }.to raise_error(NoMethodError, /PRIVATE synthetic body/)
      expect(CHAT_ROOMS).not_to have_key(999)
      expect(GAME.chat).not_to be_opened(999)
      expect(SHELL_OUTPUT.string).not_to include('PRIVATE synthetic body')
    end

    it 'cleans up even when request-error reporting fails' do
      allow(GAME.chat).to receive(:read).and_raise(Hackers::RequestError.new('HTTP', 'PRIVATE'))
      allow(LOGGER).to receive(:error).and_raise(IOError, 'output unavailable')
      worker = owned_worker

      expect { await_worker(worker) }.to raise_error(IOError)
      expect(CHAT_ROOMS).not_to have_key(999)
      expect(GAME.chat).not_to be_opened(999)
    end

    it 'does not print a request-error response body' do
      allow(GAME.chat).to receive(:read).and_raise(Hackers::RequestError.new('HTTP', 'PRIVATE'))
      await_worker(owned_worker)

      expect(SHELL_OUTPUT.string).not_to include('PRIVATE')
      expect(SHELL_OUTPUT.string).to include('Hackers::RequestError')
    end

    it 'publishes ownership before an immediately terminating worker executes' do
      original_new = Thread.method(:new)
      # Force the worker to reach its first blocking point or completion before
      # Thread.new returns. A registered start barrier must block it before read.
      allow(Thread).to receive(:new) do |&block|
        worker = original_new.call(&block)
        @workers << worker
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
        until !worker.alive? || worker.status == 'sleep'
          raise 'worker did not reach start boundary' if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          Thread.pass
        end
        worker
      end
      owners = Queue.new
      allow(GAME.chat).to receive(:read) do
        owners << CHAT_ROOMS[999]
        nil
      end

      run_chat(:open, '999')
      @workers.last.join(2)
      expect(@workers.last).not_to be_alive
      observed = owners.pop

      expect(observed).to equal(@workers.last)
      expect(CHAT_ROOMS).not_to have_key(999)
      expect(GAME.chat).not_to be_opened(999)
    end

    it 'retains unexpected worker errors without automatic raw thread reports' do
      allow(GAME.chat).to receive(:read).and_raise(IOError, 'PRIVATE worker body')
      expect(LOGGER).to receive(:error).with('Chat poller (IOError)') do
        expect(CHAT_ROOMS).not_to have_key(999)
        expect(GAME.chat).not_to be_opened(999)
        raise NoMethodError, 'reporting unavailable'
      end
      original_new = Thread.method(:new)
      allow(Thread).to receive(:new) do |&block|
        original_new.call(&block).tap { |created| @workers << created }
      end
      run_chat(:open, '999')
      worker = @workers.last
      expect { await_worker(worker) }.to raise_error(IOError, 'PRIVATE worker body')
      expect(worker.report_on_exception).to be(false)
    end

    it 'renders a successful poll before kill cleans up its ownership' do
      output = double('output')
      rendered = Queue.new
      message = Hackers::Serializer::Chat::Data.new('1000', 'Synthetic', 'hello', 55, 60, 3, 999)
      allow(GAME.chat).to receive(:read).and_return([message])
      allow(output).to receive(:puts) { |line| rendered << line }
      worker = owned_worker(output)

      expect(Timeout.timeout(2) { rendered.pop }).to include('Synthetic', 'hello')
      worker.kill
      expect(worker.join(2)).to equal(worker)
      expect(CHAT_ROOMS).not_to have_key(999)
      expect(GAME.chat).not_to be_opened(999)
    end

    it 'cleans up a killed blocked reader and permits reopening' do
      read = Queue.new
      hold = Queue.new
      allow(GAME.chat).to receive(:read) { read << true; hold.pop }
      worker = owned_worker
      Timeout.timeout(2) { read.pop }
      worker.kill
      worker.join(2)

      expect(CHAT_ROOMS).not_to have_key(999)
      expect(GAME.chat).not_to be_opened(999)
      allow(GAME.chat).to receive(:read).and_return(nil)
      run_chat(:open, '999')
      reopened = CHAT_ROOMS[999]
      @workers << reopened if reopened
      await_worker(reopened) unless reopened.nil?
      expect(CHAT_ROOMS).not_to have_key(999)
      expect(GAME.chat).not_to be_opened(999)
    end

    it 'does not let a delayed old ensure close or delete a reopened room' do
      reached = Queue.new
      release = Queue.new
      finishing = Queue.new
      finish = Queue.new
      # Delay unwinding inside read so the poller's ensure runs only after
      # explicit close has removed its slot and a new owner has reopened it.
      allow(GAME.chat).to receive(:read) do
        begin
          reached << true
          release.pop
        ensure
          finishing << true
          finish.pop
        end
      end
      old = owned_worker
      Timeout.timeout(2) { reached.pop }
      # Defer kill to model a reader already completing a normal nil response.
      allow(old).to receive(:kill).and_return(old)
      run_chat(:close, '999')
      release << nil
      Timeout.timeout(2) { finishing.pop }
      allow(GAME.chat).to receive(:read) { reached << true; release.pop }
      run_chat(:open, '999')
      newer = CHAT_ROOMS.fetch(999)
      @workers << newer
      Timeout.timeout(2) { reached.pop }
      finish << true
      old.join(2)

      expect(CHAT_ROOMS[999]).to equal(newer)
      expect(GAME.chat).to be_opened(999)
      expect(newer).to be_alive
      run_chat(:close, '999')
    end
  end

  describe 'poll thread error handling' do
    it 'stops polling and cleans up after a request error instead of looping' do
      allow(GAME.api).to receive(:sid).and_return('SIDTEST123')
      allow(GAME.api).to receive(:sid?).and_return(true)
      allow(GAME.api.client).to receive(:request_raw)
        .and_raise(Hackers::RequestError.new('HTTP', 'boom'))

      GAME.chat.open(999)
      gate = Queue.new
      thread = Thread.new { gate.pop; chat_read(SHELL, 999) }
      CHAT_ROOMS[999] = thread
      gate << true
      thread.join(5)

      expect(thread.alive?).to be(false)
      expect(GAME.chat).not_to be_opened(999)
      expect(CHAT_ROOMS).to be_empty
    end

    describe 'bounded transient read recovery' do
      before do
        allow(GAME.app_settings).to receive(:loaded?).and_return(true)
        allow(GAME.app_settings).to receive(:get).with('chat_refresh_interval').and_return(1)
      end

      # Same shape as the poller helpers above, scoped to this nested group.
      def recovery_worker(output)
        gate = Queue.new
        worker = Thread.new do
          Thread.current.report_on_exception = false
          gate.pop
          chat_read(output, 999)
        end
        (@recovery_workers ||= []) << worker
        GAME.chat.open(999)
        CHAT_ROOMS[999] = worker
        gate << true
        worker
      end

      def await_recovery_worker(worker, cap = 12)
        expect(worker.join(cap)).to equal(worker)
        worker
      end

      after do
        (@recovery_workers || []).each do |worker|
          worker.kill if worker.alive?
          worker.join(8)
        end
      end

      it 'recovers a first transient transport failure, keeping the room and the cursor' do
        error_base = LOGGER.error_count
        # Method-level guards beyond the transport key-shape lens: recovery must
        # rely on the existing session only — no re-authentication, no resend.
        expect(GAME).to receive(:auth).never
        expect(GAME).to receive(:auth_minimal).never
        expect(GAME.chat).to receive(:write).never
        expect(GAME.api).to receive(:write_chat).never
        requests = []
        # Real dataset bookkeeping is exercised: only the transport is replaced,
        # so any room recreation or cursor reset is observable here.
        allow(GAME.api.client).to receive(:request_raw) do |params, *|
          requests << params.dup
          if requests.length == 1
            raise Hackers::RequestError.new('Net::ReadTimeout', 'synthetic timeout')
          else
            CHAT_PAYLOAD
          end
        end
        rendered = Queue.new
        output = double('output')
        allow(output).to receive(:puts) { |line| rendered << line }
        worker = recovery_worker(output)

        post_recovery_line = Timeout.timeout(8) { rendered.pop }
        expect(post_recovery_line).to include('TestHero')
        # One more cadence read proves the cursor moved only via the successful
        # parse; the same room entry advanced it ('' through the failing and
        # retry reads, '1000' after), so neither cursor reset nor room
        # recreation occurred.
        Timeout.timeout(8) { nil until requests.length >= 3 }
        worker.kill
        expect(worker.join(8)).to equal(worker)

        expect(requests.map(&:keys).uniq)
          .to eq([%w[chat_display room last_message app_version session_id cmd_id]])
        expect(requests[0]['last_message']).to be_empty
        expect(requests[1]['last_message']).to be_empty
        expect(requests[2]['last_message']).to eq('1000')
        expect(SHELL_OUTPUT.string).to include('Chat read retry (1/3) (Hackers::RequestError)')
        expect(SHELL_OUTPUT.string.scan(/Chat read retry \(\d\/3\)/).length).to eq(1)
        expect(LOGGER.error_count).to eq(error_base)
      end

      it 'stops with an exhausted retry budget after exactly four read attempts' do
        error_base = LOGGER.error_count
        allow(GAME.chat).to receive(:read).with(999) do
          raise Hackers::RequestError.new('Net::ReadTimeout', 'synthetic timeout')
        end
        worker = recovery_worker(SHELL)

        await_recovery_worker(worker)
        expect(GAME.chat).to have_received(:read).with(999).exactly(4).times
        expect(SHELL_OUTPUT.string.scan(/Chat read retry/).length).to eq(3)
        expect(SHELL_OUTPUT.string).to include('Chat read failed after 3 retries (Hackers::RequestError)')
        expect(SHELL_OUTPUT.string).not_to include('Chat read retry (4/')
        expect(LOGGER.error_count).to eq(error_base + 1)
        expect(CHAT_ROOMS).not_to have_key(999)
        expect(GAME.chat).not_to be_opened(999)
      end

      it 'resets the retry budget after a valid empty read' do
        error_base = LOGGER.error_count
        calls = 0
        allow(GAME.chat).to receive(:read).with(999) do
          calls += 1
          case calls
          when 1 then raise Hackers::RequestError.new('Errno::ECONNRESET', 'synthetic reset')
          when 2 then []
          else raise Hackers::RequestError.new('Net::OpenTimeout', 'synthetic timeout')
          end
        end
        worker = recovery_worker(SHELL)

        await_recovery_worker(worker, 15)
        expect(GAME.chat).to have_received(:read).with(999).exactly(6).times
        expect(SHELL_OUTPUT.string.scan(/Chat read retry/).length).to eq(4)
        expect(SHELL_OUTPUT.string).to include('Chat read failed after 3 retries (Hackers::RequestError)')
        expect(LOGGER.error_count).to eq(error_base + 1)
        expect(CHAT_ROOMS).not_to have_key(999)
        expect(GAME.chat).not_to be_opened(999)
      end

      [
        Hackers::RequestError.new('HTTP', 'synthetic body', http_status: 500),
        Hackers::RequestError.new('Exception', nil),
        Hackers::RequestError.new('Chat response malformed', nil),
        Hackers::RequestError.new('OpenSSL::SSL::SSLError', 'synthetic ssl')
      ].each do |error|
        it "stops immediately on a non-retryable #{error.type} failure" do
          allow(GAME.chat).to receive(:read).with(999).and_raise(error)
          await_recovery_worker(recovery_worker(SHELL), 12)

          expect(GAME.chat).to have_received(:read).with(999).exactly(1).times
          expect(SHELL_OUTPUT.string).not_to include('Chat read retry')
          expect(SHELL_OUTPUT.string).to include('Chat read (Hackers::RequestError)')
          expect(CHAT_ROOMS).not_to have_key(999)
          expect(GAME.chat).not_to be_opened(999)
        end
      end

      it 'interrupts a waiting recovery when the room is closed' do
        rendered = Queue.new
        output = double('output')
        allow(output).to receive(:puts) { |line| rendered << line }
        calls = 0
        message = Hackers::Serializer::Chat::Data.new('1000', 'Synthetic', 'hello', 55, 60, 3, 999)
        allow(GAME.chat).to receive(:read).with(999) do
          calls += 1
          case calls
          when 1 then raise Hackers::RequestError.new('Net::ReadTimeout', 'synthetic timeout')
          when 2 then [message]
          else nil
          end
        end
        worker = recovery_worker(output)

        rendered_line = Timeout.timeout(8) { rendered.pop }
        run_chat(:close, '999')
        expect(worker.join(8)).to equal(worker)
        expect(CHAT_ROOMS).not_to have_key(999)
        expect(GAME.chat).not_to be_opened(999)
        expect(SHELL_OUTPUT.string).to include('Chat read retry (1/3) (Hackers::RequestError)')
        expect(rendered_line).to include('Synthetic')
      end

      it 'keeps sibling room polling isolated from a recovery teardown' do
        message = Hackers::Serializer::Chat::Data.new('1000', 'Synthetic', 'hello', 55, 60, 3, 777)
        allow(GAME.chat).to receive(:read).and_return([message])
        allow(GAME.chat).to receive(:read).with(999)
          .and_raise(Hackers::RequestError.new('EOFError', 'synthetic eof'))
        worker_a = recovery_worker(SHELL)
        expect(GAME.chat).to be_opened(999)
        rendered_b = Queue.new
        output_b = double('output')
        allow(output_b).to receive(:puts) { |line| rendered_b << line }
        gate_b = Queue.new
        worker_b = Thread.new do
          Thread.current.report_on_exception = false
          gate_b.pop
          chat_read(output_b, 777)
        end
        (@recovery_workers ||= []) << worker_b
        GAME.chat.open(777)
        CHAT_ROOMS[777] = worker_b
        gate_b << true
        Timeout.timeout(8) { rendered_b.pop }

        run_chat(:close, '999')
        expect(worker_a.join(12)).to equal(worker_a)
        expect(CHAT_ROOMS[777]).to equal(worker_b)
        expect(GAME.chat).to be_opened(777)
        run_chat(:close, '777')
        expect(worker_b.join(8)).to equal(worker_b)
        expect(CHAT_ROOMS).to be_empty
        expect(GAME.chat).not_to be_opened(777)
      end

      it 'recovers without any authentication or send side effects' do
        # Planned row (v), explicit method-level spies (never-throws semantics):
        # the retry→success path must reuse the existing session, never call
        # auth/auth_minimal and never touch the write path.
        expect(GAME).to receive(:auth).never
        expect(GAME).to receive(:auth_minimal).never
        expect(GAME.chat).to receive(:write).never
        expect(GAME.api).to receive(:write_chat).never
        requests = []
        allow(GAME.api.client).to receive(:request_raw) do |params, *|
          requests << params.dup
          raise Hackers::RequestError.new('Net::WriteTimeout', 'synthetic timeout') if requests.length == 1

          CHAT_PAYLOAD
        end
        rendered = Queue.new
        output = double('output')
        allow(output).to receive(:puts) { |line| rendered << line }
        worker = recovery_worker(output)

        # The retry actually executes before the asserted success render and
        # the transport call count is 2+ (1 failed attempt then retried reads).
        expect(Timeout.timeout(8) { rendered.pop }).to include('TestHero')
        expect(requests.length).to be >= 2
        # Recorded transport keys identify chat reads only.
        expect(requests[0, 2].map(&:keys).uniq)
          .to eq([%w[chat_display room last_message app_version session_id cmd_id]])
        expect(requests[0]['last_message']).to be_empty
        expect(requests[1]['last_message']).to be_empty
        worker.kill
        expect(worker.join(8)).to equal(worker)
      end

      it 'classifies all ten allowlisted transport types as retryable and status-bearing errors as terminal' do
        CHAT_READ_TRANSIENT_ERROR_TYPES.each do |type|
          expect(transient_chat_read_error?(Hackers::RequestError.new(type, 'probe'))).to be(true)
        end
        # Positive HTTP status is never retriable, regardless of body.
        expect(transient_chat_read_error?(Hackers::RequestError.new('HTTP', 'probe', http_status: 500))).to be(false)
        # Session/auth, TLS and malformed-payload shapes stop the poller.
        expect(transient_chat_read_error?(Hackers::RequestError.new('Exception', nil))).to be(false)
        expect(transient_chat_read_error?(Hackers::RequestError.new('OpenSSL::SSL::SSLError', 'probe'))).to be(false)
        expect(transient_chat_read_error?(Hackers::RequestError.new('Chat response malformed', nil))).to be(false)
      end
    end
  end
end
