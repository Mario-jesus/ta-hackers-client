# frozen_string_literal: true

require 'thread'

CHAT_ROOMS = {}
CHAT_LOG_CHAR = "\u2764"
CHAT_LIST_CHAR = "\u2022"
CHAT_TALK_CHAR = "\u2765"

DEFAULT_CHAT_POLL_INTERVAL = 5
MIN_CHAT_POLL_INTERVAL = 1

##
# Sanitizes untrusted incoming chat text for terminal display: strips ANSI
# CSI/OSC escape effects and control bytes (which also prevents multiline
# fake prompts), preserves Unicode and rich-text literals verbatim.
def sanitize_chat_text(text)
  text.to_s.scrub
      .gsub(/\e\[[0-9:;<=>?]*[ -\/]*[@-~]/, '')
      .gsub(/\e\][^\x07]*(?:\x07|\e\\)/, '')
      .gsub(/\e[@-Z\\-_]/, '')
      .gsub(/[\x00-\x1f\x7f]/, ' ')
end

##
# Returns true when outgoing text carries terminal control sequences; such
# messages are rejected instead of being silently mutated.
def control_text?(text)
  text.match?(/\e/) || text.match?(/[\x00-\x1f\x7f]/)
end

##
# Positive bounded chat poll interval: server setting when usable, a
# reasonable default when unset or invalid, and a positive floor otherwise.
def chat_poll_interval
  raw = GAME.app_settings.loaded? ? GAME.app_settings.get('chat_refresh_interval') : nil
  value = raw.to_f
  return DEFAULT_CHAT_POLL_INTERVAL if value <= 0

  value = value.round
  return MIN_CHAT_POLL_INTERVAL if value < MIN_CHAT_POLL_INTERVAL

  value
end

##
# Records safe batch evidence from structured chat message fields only.
# Messages are never interpreted as commands or batch status.
def batch_note_chat_messages(messages)
  CLI_RESULTS[:chat_last_read_count] = messages.length
  own_id = CLI_RESULTS[:own_id]
  sent = CLI_RESULTS[:sent_messages] || []
  return update_chat_publication_status if own_id.nil?

  observed = CLI_RESULTS[:observed_chat_message_identities] ||= {}
  messages.each do |message|
    next unless message.id == own_id

    identity = batch_chat_message_identity(message)
    unless observed.key?(identity)
      pending = sent.detect do |outgoing|
        !outgoing[:confirmed] && outgoing[:room] == message.country && outgoing[:message] == message.message
      end
      pending[:confirmed] = true unless pending.nil?
    end
    observed[identity] = true
  end

  update_chat_publication_status
end

##
# Conservative per-message identity for confirmation reuse detection. The
# native chat schema does not expose a stable message id, so identical own-id,
# datetime, room and exact text is treated as the same observed echo.
def batch_chat_message_identity(message)
  [message.id, message.datetime, message.country, message.message]
end

##
# Records an attempted outgoing chat message without treating the HTTP 200 or
# send response itself as proof of publication. A later own-id/exact-text echo
# confirms at most one still-pending send.
def batch_record_chat_send(room, text)
  CLI_RESULTS[:next_send_id] = CLI_RESULTS.fetch(:next_send_id, 0) + 1
  send = { id: CLI_RESULTS[:next_send_id], room: room, message: text, confirmed: false }
  (CLI_RESULTS[:sent_messages] ||= []) << send
  update_chat_publication_status
  send
end

def update_chat_publication_status
  sent = CLI_RESULTS[:sent_messages] || []
  if sent.empty?
    CLI_RESULTS.delete(:chat_publication_status)
    CLI_RESULTS[:own_message_seen] = false
  elsif sent.all? { |outgoing| outgoing[:confirmed] }
    CLI_RESULTS[:chat_publication_status] = 'confirmed'
    CLI_RESULTS[:own_message_seen] = true
  else
    CLI_RESULTS[:chat_publication_status] = 'unconfirmed'
    CLI_RESULTS[:own_message_seen] = false
  end
end

def chat_read(shell, room)
  loop do
    begin
      messages = GAME.chat.read(room)
    rescue Hackers::RequestError => e
      LOGGER.error("Chat read (#{e})")
      break
    else
      # The room disappeared from the local bookkeeping: stop instead of
      # spinning or crashing the poll thread.
      break if messages.nil?

      chat_log(shell, room, messages)
    end

    sleep(chat_poll_interval)
  end

  CHAT_ROOMS.delete(room)
  GAME.chat.close(room) if GAME.chat.opened?(room)
end

def chat_log(shell, room, messages)
  messages.each do |message|
    level = GAME.experience_list.loaded? ? GAME.experience_list.level(message.experience) : '?'
    shell.puts(
      ::Kernel.format(
        '%s [%s:%s] %s %s %s',
        ColorTerm.brown.bold(CHAT_LOG_CHAR),
        ColorTerm.blue(GAME.countries_list.name(room)),
        ColorTerm.blue(room),
        ColorTerm.red(level),
        ColorTerm.magenta.bold(sanitize_chat_text(message.name)),
        ColorTerm.brown(sanitize_chat_text(message.message))
      )
    )
  end
end

##
# Opens a room for a one-shot operation when it is not already opened by a
# poll thread, yielding whether the caller must close it afterwards.
def chat_open_for_oneshot(room)
  return false if GAME.chat.opened?(room)

  GAME.chat.open(room)
  true
end

## Commands

# open
CONTEXT_CHAT_OPEN = CONTEXT_CHAT.add_command(
  :open,
  description: 'Open room',
  params: ['<room>']
) do |tokens, shell|
  unless GAME.connected? || GAME.app_settings.loaded?
    shell.puts(NOT_CONNECTED)
    next
  end

  room = tokens[1].to_i
  if CHAT_ROOMS.key?(room)
    shell.puts("Room #{room} already opened")
    next
  end

  GAME.chat.open(room)
  CHAT_ROOMS[room] = Thread.new { chat_read(shell, room) }
end

CONTEXT_CHAT_OPEN.completion do |line|
  countries = GAME.countries_list.select { |c| c.id.to_s =~ /^#{Regexp.escape(line)}/ }
  countries.map { |c| c.id.to_s }
end

# close
CONTEXT_CHAT_CLOSE = CONTEXT_CHAT.add_command(
  :close,
  description: 'Close room',
  params: ['<room>']
) do |tokens, shell|
  room = tokens[1].to_i
  unless CHAT_ROOMS.key?(room)
    shell.puts('No such opened room')
    next
  end

  CHAT_ROOMS[room].kill
  CHAT_ROOMS.delete(room)
  GAME.chat.close(room)
end

CONTEXT_CHAT_CLOSE.completion do |line|
  CHAT_ROOMS.keys.map(&:to_s).grep(/^#{Regexp.escape(line)}/)
end

# list
CONTEXT_CHAT.add_command(
  :list,
  description: 'List opened rooms'
) do |tokens, shell|
  if CHAT_ROOMS.empty?
    shell.puts('No opened rooms')
    next
  end

  shell.puts "Opened rooms:"
  CHAT_ROOMS.each_key do |k|
    shell.puts(
      ::Kernel.format(
        ' %s %-4d (%s)',
        ColorTerm.brown.bold(CHAT_LIST_CHAR),
        k,
        GAME.countries_list.name(k)
      )
    )
  end
end

# read (one-shot)
CONTEXT_CHAT_READ = CONTEXT_CHAT.add_command(
  :read,
  description: 'Read room messages once without polling',
  params: ['<room>']
) do |tokens, shell|
  unless GAME.session_active?
    LOGGER.error(NOT_CONNECTED)
    next
  end

  unless tokens[1] =~ /\A\d+\z/
    LOGGER.error('Invalid room')
    next
  end

  room = tokens[1].to_i
  opened_here = chat_open_for_oneshot(room)

  messages = GAME.chat.read(room)
  chat_log(shell, room, messages)
  LOGGER.log("Chat read: #{messages.length} message(s)")

  GAME.chat.close(room) if opened_here
  batch_note_chat_messages(messages)
rescue Hackers::RequestError => e
  LOGGER.error("Chat read (#{e})")
  GAME.chat.close(room) if opened_here
end

# say
CONTEXT_CHAT_SAY = CONTEXT_CHAT.add_command(
  :say,
  description: 'Say to the room',
  params: ['<room>', '<text>']
) do |tokens, shell|
  unless GAME.session_active?
    LOGGER.error(NOT_CONNECTED)
    next
  end

  unless tokens[1] =~ /\A\d+\z/
    LOGGER.error('Invalid room')
    next
  end

  text = tokens[2..].join(' ')
  if control_text?(text)
    LOGGER.error('Message contains terminal control characters')
    next
  end

  room = tokens[1].to_i
  opened_here = chat_open_for_oneshot(room)

  messages = GAME.chat.write(room, text)
  chat_log(shell, room, messages)

  GAME.chat.close(room) if opened_here
  batch_record_chat_send(room, text)
  batch_note_chat_messages(messages)
rescue Hackers::RequestError => e
  LOGGER.error("Chat write (#{e})")
  GAME.chat.close(room) if opened_here
end

CONTEXT_CHAT_SAY.completion do |line|
  CHAT_ROOMS.keys.map(&:to_s).grep(/^#{Regexp.escape(line)}/)
end

# talk
CONTEXT_CHAT_TALK = CONTEXT_CHAT.add_command(
  :talk,
  description: 'Talk in the room',
  params: ['<room>']
) do |tokens, shell|
  room = tokens[1].to_i
  unless CHAT_ROOMS.key?(room)
    shell.puts('No such opened room')
    next
  end

  shell.puts('Enter ! or press ^D to quit')
  loop do
    prompt = "#{GAME.countries_list.name(room)}:#{room} #{ColorTerm.brown.bold(CHAT_TALK_CHAR)} "
    message = shell.readline(prompt, true)
    if message.nil?
      shell.puts
      break
    end

    message.strip!
    next if message.empty?

    break if message == '!'

    if control_text?(message)
      LOGGER.error('Message contains terminal control characters')
      next
    end

    messages = GAME.chat.write(room, message)
    chat_log(shell, room, messages)
  rescue Hackers::RequestError => e
    LOGGER.error("Chat write (#{e})")
  end
end

CONTEXT_CHAT_TALK.completion do |line|
  CHAT_ROOMS.keys.map(&:to_s).grep(/^#{Regexp.escape(line)}/)
end

# users
CONTEXT_CHAT_USERS = CONTEXT_CHAT.add_command(
  :users,
  description: 'Show users list in the room',
  params: ['<room>']
) do |tokens, shell|
  unless GAME.connected? || GAME.app_settings.loaded?
    shell.puts(NOT_CONNECTED)
    next
  end

  room = tokens[1].to_i

  chat = Hackers::Chat.new(GAME.api)
  chat.open(room)
  messages = chat.read(room)
  chat.close(room)
  if messages.empty?
    shell.puts("No users in room #{room}")
    next
  end

  messages.uniq! { |m| m.id }
  shell.puts(
    format(
      'Users in room %d (%s)',
      room,
      GAME.countries_list.name(room)
    )
  )

  messages.each do |message|
    shell.puts(
      format(
        ' %-30s .. %d',
        message.name,
        message.id
      )
    )
  end
rescue Hackers::RequestError => e
  LOGGER.error("Chat read (#{e})")
end

CONTEXT_CHAT_USERS.completion do |line|
  countries = GAME.countries_list.select { |c| c.id.to_s =~ /^#{Regexp.escape(line)}/ }
  countries.map { |c| c.id.to_s }
end
