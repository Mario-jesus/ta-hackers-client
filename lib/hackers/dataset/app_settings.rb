# frozen_string_literal: true

module Hackers
  ##
  # Application settings
  class AppSettings < Dataset
    include Enumerable

    attr_reader :datetime

    def initialize(*)
      super

      @settings = {}
      @languages = {}
    end

    def load
      @raw_data = nil
      @settings = {}
      @languages = {}
      @datetime = nil

      raw_data = @api.app_settings
      settings, languages, datetime = parse(raw_data)
      @settings = settings
      @languages = languages
      @datetime = datetime
      @raw_data = raw_data
    end

    def each(&block)
      @settings.keys.each(&block)
    end

    def get(key)
      @settings[key]
    end

    def languages
      @languages.keys
    end

    def language(name)
      @languages[name]
    end

    private

    def parse(raw_data)
      records = Serializer.parseData(raw_data)[0]
      unless records.is_a?(Array) && records.length >= 12
        raise Serializer::ParserError, 'AppSettings requires eleven settings and a timestamp'
      end

      settings = {}
      languages = {}
      records.take(11).each_with_index do |record, index|
        validate_setting(record, 1, 2, index)
        settings[record[1]] = setting_value(record[2])
      end

      datetime = records[11][0]
      unless datetime.is_a?(String) && !datetime.empty?
        raise Serializer::ParserError, 'AppSettings requires a nonempty timestamp'
      end

      (records[12] || []).each do |language|
        code, value = language.split(':', 2)
        unless code && !code.empty? && value && value.match?(/\A[+-]?\d+\z/)
          raise Serializer::ParserError, 'AppSettings language requires a code and numeric ID'
        end
        languages[code] = value.to_i
      end

      (records[13..] || []).each_with_index do |record, index|
        validate_setting(record, 0, 1, index + 13)
        settings[record[0]] = setting_value(record[1])
      end

      [settings, languages, datetime]
    end

    def validate_setting(record, key_index, value_index, index)
      key = record[key_index]
      value = record[value_index]
      return if key.is_a?(String) && !key.empty? && value.is_a?(String)

      raise Serializer::ParserError, "Invalid AppSettings key/value record #{index}"
    end

    def setting_value(value)
      value =~ /^\d+$/ ? value.to_i : value
    end
  end
end
