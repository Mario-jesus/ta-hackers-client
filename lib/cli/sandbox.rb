# frozen_string_literal: true

require 'json'
require 'cli/colorterm'

# Safe structured results shared by CLI commands and the batch runner.
# Only public display values (own name) and booleans/counts are stored;
# account ids, sessions and credentials must never be written here except
# the internal own_id used for private sender matching.
CLI_RESULTS = {}

module Sandbox

  ##
  # Config
  class Config < Hash
    CONFIG_EXT = '.conf'
    JSON_EXT = '.json'

    attr_accessor :file

    def initialize(file)
      super
      @file = file
    end

    def load
      data = JSON.parse(File.read(@file))
      return unless data.instance_of?(Hash)

      merge!(data)
    end

    def save
      File.write(@file, JSON.pretty_generate(self))
    end

    ##
    # Resolves a user-supplied config value to an existing file path.
    # Explicit paths (containing a separator or a .conf/.json suffix,
    # including absolute and ~ paths) are used as-is; bare names fall back
    # to the named configs directory. Returns nil when the file is missing.
    def self.resolve_path(value, configs_dir)
      value = value.to_s
      return nil if value.empty?

      if value.include?(File::SEPARATOR) ||
         value.end_with?(CONFIG_EXT, JSON_EXT)
        path = File.expand_path(value)
        return File.file?(path) ? path : nil
      end

      named = File.join(configs_dir, "#{value}#{CONFIG_EXT}")
      File.file?(named) ? named : nil
    end
  end

  ##
  # Logger
  class Logger
    attr_accessor :log_cterm, :error_cterm, :info_cterm,
                  :log_prefix_cterm, :error_prefix_cterm, :info_prefix_cterm,
                  :log_prefix, :error_prefix, :info_prefix
    attr_reader :error_count, :last_error

    def initialize(shell)
      @shell = shell
      @log_cterm = ColorTerm.white
      @error_cterm = ColorTerm.white
      @info_cterm = ColorTerm.white
      @log_prefix_cterm = ColorTerm.white
      @error_prefix_cterm = ColorTerm.white
      @info_prefix_cterm = ColorTerm.white
      @log_prefix = String.new
      @error_prefix = String.new
      @info_prefix = String.new
      @error_count = 0
      @last_error = nil
    end

    def log(message)
      @shell.puts(@log_prefix_cterm.get(@log_prefix) + @log_cterm.get(message.to_s))
    end

    def error(message)
      @error_count += 1
      @last_error = message.to_s
      @shell.puts(@error_prefix_cterm.get(@error_prefix) + @error_cterm.get(message.to_s))
    end

    def info(message)
      @shell.puts(@info_prefix_cterm.get(@info_prefix) + @info_cterm.get(message.to_s))
    end
  end

  ##
  # Parent class for scripts
  class Script
    ##
    # Creates new script:
    #   game    = Game
    #   shell   = Shell
    #   logger  = Logger
    #   args    = Arguments
    def initialize(game, shell, logger, args)
      @game = game
      @shell = shell
      @logger = logger
      @args = args
    end

    ##
    # Script entry point
    def main; end

    ##
    # Executes after the script finished
    def finish; end
  end
end
