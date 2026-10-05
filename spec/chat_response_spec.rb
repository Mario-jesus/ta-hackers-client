# frozen_string_literal: true

require 'hackers'

RSpec.describe Hackers::Chat do
  class ChatResponseSpecApi
    attr_accessor :read_payload, :write_payload

    def initialize(read_payload: '', write_payload: '')
      @read_payload = read_payload
      @write_payload = write_payload
    end

    def read_chat(_room, _last_message)
      read_payload
    end

    def write_chat(_room, _message, _last_message)
      write_payload
    end
  end

  subject(:chat) { described_class.new(api) }

  let(:api) { ChatResponseSpecApi.new(read_payload: read_payload, write_payload: write_payload) }
  let(:read_payload) { '' }
  let(:write_payload) { '' }

  before { chat.open(999) }

  it 'keeps a valid empty chat response as an empty message list' do
    expect(chat.read(999)).to eq([])
  end

  it 'rejects known comma-delimited exception envelopes before chat parsing' do
    api.read_payload = 'Exception,maximum node level reached'

    expect { chat.read(999) }
      .to raise_error(Hackers::MaximumNodeLevelError, 'Exception: maximum node level reached')
  end

  it 'rejects semicolon-delimited helper exception fixtures safely without echoing the body' do
    api.read_payload = 'Exception;server secret detail'

    expect { chat.read(999) }
      .to raise_error(Hackers::RequestError, 'Exception')
  end

  it 'rejects malformed nonempty records instead of treating them as empty chat' do
    api.read_payload = 'not,a,complete,chat,row'

    expect { chat.read(999) }
      .to raise_error(Hackers::RequestError, 'Chat response malformed')
  end

  it 'preserves valid chat record parsing and escaped delimiter normalization' do
    api.read_payload = "1000,Alice,hello\x01world,55,60,3,999"

    messages = chat.read(999)

    expect(messages.length).to eq(1)
    expect(messages.first.datetime).to eq('1000')
    expect(messages.first.message).to eq('hello,world')
    expect(messages.first.id).to eq(55)
  end

  it 'rejects chat records with nonnumeric sender ids' do
    api.read_payload = '1000,Alice,hello,notid,60,3,999'

    expect { chat.read(999) }
      .to raise_error(Hackers::RequestError, 'Chat response malformed')
  end

  it 'rejects chat records with nonnumeric room ids' do
    api.read_payload = '1000,Alice,hello,55,60,3,notroom'

    expect { chat.read(999) }
      .to raise_error(Hackers::RequestError, 'Chat response malformed')
  end

  it 'validates write responses before parsing them as chat' do
    api.write_payload = 'Exception,too many builders requested'

    expect { chat.write(999, 'Test') }
      .to raise_error(Hackers::TooManyBuilders, 'Exception: too many builders requested')
  end
end
