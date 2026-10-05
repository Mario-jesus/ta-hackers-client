# frozen_string_literal: true

require 'json'
require 'shellwords'

module Sandbox
  ##
  # Batch command runner for the -e/--execute entrypoint mode.
  #
  # Each command line is pre-validated against the shell registry (the SDK
  # shell only prints "Unrecognized command" and returns nil, so batch mode
  # cannot infer status from the exec return value). A command fails the run
  # when it is unknown, has missing mandatory arguments, is malformed, raises,
  # or reports a logger error. The first failure stops all remaining commands.
  #
  # Space-separated context forms (`chat say 999 Test`) are routed through the
  # registry the same way the interactive shell would dispatch them, without
  # re-tokenizing argument values.
  class Batch
    Result = Struct.new(:command, :ok, :error, keyword_init: true)

    attr_reader :results

    def initialize(shell, logger, json: false)
      @shell = shell
      @logger = logger
      @json = json
      @results = []
    end

    ##
    # Executes the commands in order. Returns true when every command
    # succeeded; stops at the first failure otherwise.
    def run(commands)
      commands.each do |line|
        outcome = execute(line)
        @results << Result.new(command: line, ok: outcome[:ok], error: outcome[:error])

        next if outcome[:ok]

        break
      end

      ok = @results.all?(&:ok) && chat_publication_confirmed?
      emit_summary(ok) if @json
      ok
    end

    private

    def execute(line)
      tokens = split_tokens(line)
      return failure('Malformed command quoting', static: true) if tokens.nil?

      return { ok: true } if tokens.empty?

      resolved = resolve(tokens)
      return failure(resolved[:error]) if resolved[:error]

      if resolved.key?(:navigate)
        @shell.path = resolved[:navigate]
        return { ok: true }
      end

      command = resolved[:command]
      mandatory = command.params.count { |_, required| required }
      return failure('Missing arguments') if resolved[:tokens].length - 1 < mandatory

      errors_before = @logger.error_count
      command.exec(resolved[:tokens])
      return failure(@logger.last_error || 'Command failed') if @logger.error_count > errors_before

      { ok: true }
    rescue Hackers::RequestError => e
      failure(sanitize_request_error(e))
    rescue StandardError => e
      # Unknown untrusted exception messages may quote URLs/args/config
      # fragments: report the class only.
      failure(e.class.to_s)
    end

    def split_tokens(line)
      line.to_s.shellsplit
    rescue ArgumentError
      # Never echo the raw line: it may quote private arguments.
      nil
    end

    ##
    # Mapped request errors carry a bounded type and a static or whitelisted
    # description; the HTTP status is safe diagnostic evidence.
    def sanitize_request_error(error)
      message = error.to_s
      message += " (HTTP #{error.http_status})" unless error.http_status.nil?
      message
    end

    ##
    # Mirrors the SDK shell dispatch: walks context navigation from the
    # current path, then matches the final token against the current
    # context's commands and the root's global commands.
    def resolve(tokens)
      words = tokens.dup
      first = words.shift
      consumed = [first]
      parts = first.split('/')
      path = first.start_with?('/') ? [] : @shell.path.clone

      parts[0..-2].each do |part|
        if part == '..'
          path.pop
        elsif !part.empty?
          path << part.to_sym
        end
      end

      last = parts.last
      args = words

      loop do
        if last == '..'
          path.pop
          last = nil
        end

        break if last.nil? || last.empty?

        current = @shell.root.context(*path)
        return { error: "Unrecognized command: #{consumed.join(' ')}" } if current.nil?

        context = current.contexts.detect { |c| c.name.to_s == last }
        if context && !args.empty?
          path << context.name
          consumed << last
          last = args.shift
          next
        end

        break
      end

      return { navigate: path } if last.nil? || last.empty?

      current = @shell.root.context(*path)
      return { error: "Unrecognized command: #{consumed.join(' ')}" } if current.nil?

      # A bare context name enters the context, exactly like the interactive
      # shell does; the path persists for the following batch commands.
      context = current.contexts.detect { |c| c.name.to_s == last }
      if context && args.empty?
        path << context.name
        return { navigate: path }
      end

      command = current.commands.detect { |c| c.match?(last) } ||
                @shell.root.commands.detect { |c| c.global? && c.match?(last) }
      return { error: "Unrecognized command: #{consumed.join(' ')}" } if command.nil?

      { command: command, tokens: [last, *args] }
    end

    def failure(error, static: false)
      static # unused marker: kept for call-site clarity of static vs dynamic messages
      @logger.error(error)
      { ok: false, error: error }
    end

    ##
    # Emits a safe structured summary: own display name and booleans/counts
    # only. Account ids, sessions, tokens and credentials are never included.
    def chat_publication_confirmed?
      CLI_RESULTS[:chat_publication_status] != 'unconfirmed'
    end

    def emit_summary(ok)
      summary = {
        ok: ok,
        commands: @results.map do |result|
          entry = { command: result.command, ok: result.ok }
          entry[:error] = result.error unless result.error.nil?
          entry
        end,
        own_name: CLI_RESULTS[:own_name],
        own_message_seen: CLI_RESULTS[:own_message_seen] == true,
        chat_message_count: CLI_RESULTS[:chat_last_read_count] || 0,
        chat_publication_status: CLI_RESULTS[:chat_publication_status]
      }

      @shell.puts(JSON.generate(summary))
    end
  end
end
