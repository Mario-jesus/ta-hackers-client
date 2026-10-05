# frozen_string_literal: true

module Hackers
  ##
  # Chat
  class Chat < Dataset
    include Enumerable

    Room = Struct.new(:id, :last_message)

    def initialize(api)
      @api = api

      @rooms = []
    end

    def each(&block)
      @rooms.each(&block)
    end

    def opened?(room)
      @rooms.any? { |r| r.id == room }
    end

    def open(room)
      return if opened?(room)

      @rooms << Room.new(room, String.new)
    end

    def close(room)
      @rooms.delete_if { |r| r.id == room }
    end

    def read(room)
      return unless opened?(room)

      room = @rooms.detect { |r| r.id == room }
      raw_data = @api.read_chat(room.id, room.last_message)
      validate_response!(raw_data)
      serializer = Serializer::Chat.new(raw_data)
      data = serializer.parse(0)
      parse(data, room)
    end

    def write(room, message)
      return unless opened?(room)

      serializer_message = Serializer::ChatMessage.new
      room = @rooms.detect { |r| r.id == room }
      raw_data = @api.write_chat(
        room.id,
        serializer_message.generate(message),
        room.last_message
      )

      validate_response!(raw_data)
      serializer_chat = Serializer::Chat.new(raw_data)
      data = serializer_chat.parse(0)
      parse(data, room)
    end

    private

    def validate_response!(raw_data)
      raw = raw_data.to_s
      return if raw.empty?

      validate_exception_response!(raw)
      validate_chat_records!(raw)
    end

    def validate_exception_response!(raw)
      return unless raw == EXCEPTION_TYPE || raw.start_with?("#{EXCEPTION_TYPE},", "#{EXCEPTION_TYPE};")

      if raw.start_with?("#{EXCEPTION_TYPE},")
        envelope = Serializer::Exception.new(raw).parse(0, 0)
        if EXCEPTIONS.key?(envelope.data)
          raise EXCEPTIONS[envelope.data].new(envelope.type, envelope.data)
        end
      end

      raise RequestError.new(EXCEPTION_TYPE)
    rescue Serializer::ParserError, EncodingError, ArgumentError
      raise RequestError.new(EXCEPTION_TYPE)
    end

    def validate_chat_records!(raw)
      section = raw.split(Serializer::Base::DELIM_SECTION_NORM, 2).first
      section.split(Serializer::Base::DELIM_RECORD_NORM).each do |record|
        fields = record.split(Serializer::Base::DELIM_FIELD_NORM, -1)
        raise RequestError.new('Chat response malformed') unless fields.length == 7
        raise RequestError.new('Chat response malformed') unless numeric_chat_field?(fields[3])
        raise RequestError.new('Chat response malformed') unless numeric_chat_field?(fields[6])
      end
    end

    def numeric_chat_field?(value)
      value.match?(/\A\d+\z/)
    end

    def parse(data, room)
      messages = []
      data.each do |message|
        room.last_message = message.datetime
        messages << message
      end

      messages
    end
  end
end
