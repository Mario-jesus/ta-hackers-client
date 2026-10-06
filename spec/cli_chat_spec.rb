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

      batch_note_chat_messages(messages)

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

      batch_note_chat_messages(messages)
      batch_note_chat_messages(messages)

      expect(CLI_RESULTS[:sent_messages].map { |send| send[:confirmed] }).to eq([true, false])
      expect(CLI_RESULTS[:chat_publication_status]).to eq('unconfirmed')
    end

    it 'does not let an owned echo observed before sending confirm a future send' do
      stale_echo = [Hackers::Serializer::Chat::Data.new('1001', 'TestHero', 'Same', 777, 60, 3, 999)]

      batch_note_chat_messages(stale_echo)
      CLI_RESULTS[:sent_messages] = [
        { id: 1, room: 999, message: 'Same', confirmed: false }
      ]
      batch_note_chat_messages(stale_echo)

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

      batch_note_chat_messages(messages)

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

      batch_note_chat_messages(messages)

      expect(CLI_RESULTS[:sent_messages].map { |send| send[:confirmed] }).to eq([true, true])
      expect(CLI_RESULTS[:chat_publication_status]).to eq('confirmed')
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
  end
end
