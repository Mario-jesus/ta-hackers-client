# frozen_string_literal: true

require 'hackers'

RSpec.describe Hackers::Serializer do
  describe '.normalizeData' do
    it 'normalizes escaped delimiters without mutating frozen input' do
      input = "alpha\x01beta\x02gamma\x03delta".freeze

      expect(described_class.normalizeData(input)).to eq('alpha,beta;gamma@delta')
      expect(input).to eq("alpha\x01beta\x02gamma\x03delta")
      expect(input).to be_frozen
    end

    it 'denormalizes delimiters without mutating reused input' do
      input = 'alpha,beta;gamma@delta'

      first = described_class.normalizeData(input, false)
      second = described_class.normalizeData(input, false)

      expect(first).to eq("alpha\x01beta\x02gamma\x03delta")
      expect(second).to eq(first)
      expect(input).to eq('alpha,beta;gamma@delta')
    end

    it 'converts nil to an empty optional text value for safe splitting' do
      normalized = described_class.normalizeData(nil)

      expect(normalized).to eq('')
      expect(normalized.split(',')).to eq([])
    end

    it 'preserves valid Unicode while translating delimiter bytes' do
      input = "βeta\x01emoji✓\x02тест\x03終"

      expect(described_class.normalizeData(input)).to eq('βeta,emoji✓;тест@終')
      expect(described_class.normalizeData('βeta,emoji✓;тест@終', false)).to eq(input)
    end
  end

  describe '.parseData' do
    it 'keeps nil and empty input as the existing valid empty shape' do
      expect(described_class.parseData(nil)).to eq([])
      expect(described_class.parseData('')).to eq([])
    end

    it 'duplicates and scrubs malformed incoming UTF-8 without changing the original bytes or encoding' do
      incoming = "name,hello\xFFworld".b
      original_bytes = incoming.bytes
      original_encoding = incoming.encoding

      parsed = described_class.parseData(incoming)

      expect(parsed).to eq([[['name', "hello\uFFFDworld"]]])
      expect(incoming.bytes).to eq(original_bytes)
      expect(incoming.encoding).to eq(original_encoding)
    end
  end

  describe Hackers::Serializer::Chat do
    it 'scrubs malformed incoming UTF-8 for parser objects without mutating the source string' do
      incoming = "1000,Alice,hello\xFFworld,55,60,3,999".b
      original_bytes = incoming.bytes
      original_encoding = incoming.encoding

      messages = described_class.new(incoming).parse(0)

      expect(messages.first.message).to eq("hello\uFFFDworld")
      expect(incoming.bytes).to eq(original_bytes)
      expect(incoming.encoding).to eq(original_encoding)
    end

    it 'normalizes escaped delimiters from frozen incoming records' do
      incoming = "1000,Alice,hello\x01world,55,60,3,999".freeze

      messages = described_class.new(incoming).parse(0)

      expect(messages.first.message).to eq('hello,world')
      expect(incoming).to eq("1000,Alice,hello\x01world,55,60,3,999")
    end
  end

  describe Hackers::Serializer::ChatMessage do
    it 'denormalizes outgoing delimiters exactly for valid Unicode messages' do
      message = 'βeta,emoji✓;тест@終'

      generated = described_class.new.generate(message)

      expect(generated).to eq("βeta\x01emoji✓\x02тест\x03終")
      expect(message).to eq('βeta,emoji✓;тест@終')
    end

    it 'does not silently scrub invalid outgoing UTF-8' do
      invalid_message = "bad\xFF,message".b.force_encoding('UTF-8')

      expect { described_class.new.generate(invalid_message) }
        .to raise_error(ArgumentError, /invalid byte sequence/)
      expect(invalid_message.bytes).to eq([98, 97, 100, 255, 44, 109, 101, 115, 115, 97, 103, 101])
    end
  end
end
