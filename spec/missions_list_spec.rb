# frozen_string_literal: true

require 'hackers'

RSpec.describe Hackers::MissionsList do
  let(:api) { double('API') }
  subject(:missions) { described_class.new(api) }

  def row(id = '7')
    Array.new(29) { |i| i.to_s }.tap do |fields|
      fields[0] = id
      fields[1] = 'giver'
      fields[2] = "name\x03text"
      fields[3] = 'info'
      fields[4] = "01\x01-2"
      fields[9] = "003\x014"
      fields[17] = "done\x02text"
      fields[19] = "news\x03text"
      fields[21] = "top\x01text"
      fields[22] = "nodes\x02text"
    end
  end

  def packet(rows)
    rows.map { |fields| fields.join(Hackers::Serializer::DELIM_FIELD) }
        .join(Hackers::Serializer::DELIM_RECORD)
  end

  def load_rows(rows)
    allow(api).to receive(:missions_list).and_return(packet(rows))
    missions.load
  end

  def expect_empty
    expect(missions).not_to be_loaded
    expect(missions.raw_data).to be_nil
    expect(missions.to_a).to eq([])
    expect(missions.get(7)).to be_nil
    expect(missions.exist?(7)).to be(false)
  end

  it 'preserves every full legacy field conversion, order and return shape' do
    raw = packet([row])
    expect(api).to receive(:missions_list).once.and_return(raw)
    result = missions.load
    expect(missions).to be_loaded
    expect(missions.raw_data).to eq(raw)
    expect(result).to eq(Hackers::Serializer.parseData(raw)[0])
    expect(missions.get(7).to_a).to eq([
      7, 'giver', 'name@text', 'info', %w[01 -2], 5, 6, 7,
      %w[003 4], 12, 13, 14, 'done;text', 'news@text',
      'top,text', 'nodes;text', 24, 25, '28'
    ])
    expect(missions.exist?(7)).to be(true)
  end

  it 'preserves empty numeric and normalized fields with omitted nullable group' do
    fields = Array.new(28, '')
    fields[0] = '7'
    load_rows([fields])
    expect(missions.get(7).to_a).to eq([
      7, nil, '', nil, [], 0, 0, 0, [], 0, 0, 0, '', '', '', '', 0, 0, nil
    ])
    fields[27] = 'unused' # Keep interior blanks representable by the serializer.
    load_rows([fields])
    expect(missions.get(7).giver_name).to eq('')
    expect(missions.get(7).message_info).to eq('')
    expect(missions.get(7).group).to be_nil
    expect(missions.get(7).goals).to eq([])
    expect(missions.get(7).reward_money).to eq(0)
  end

  it 'accepts an ID-only record with legacy optional defaults' do
    load_rows([['7']])
    expect(missions.get(7).to_a).to eq([
      7, nil, '', nil, [], 0, 0, 0, [], 0, 0, 0, '', '', '', '', 0, 0, nil
    ])
  end

  it 'preserves signed, zero and leading-zero IDs and duplicate lookup order' do
    load_rows(%w[0 -2 +3 007 7].map { |id| row(id) })
    expect(missions.map(&:id)).to eq([0, -2, 3, 7, 7])
    expect(missions.get(7)).to equal(missions.to_a[3])
  end

  it 'replaces old rows on successful reload' do
    load_rows([row])
    load_rows([row('8')])
    expect(missions.map(&:id)).to eq([8])
    expect(missions.get(7)).to be_nil
    expect(missions).to be_loaded
  end

  it 'accepts an actual present empty first section and ignores secondary metadata' do
    raw = Hackers::Serializer::DELIM_SECTION + 'ignored'
    expect(Hackers::Serializer.parseData(raw)[0]).to eq([])
    load_rows([row])
    allow(api).to receive(:missions_list).and_return(raw)
    expect(missions.load).to eq([])
    expect(missions).to be_loaded
    expect(missions.to_a).to eq([])
  end

  [nil, '', ',private-marker', 'abc,private-marker', '1x,private-marker',
   ' 1,private-marker', '+,private-marker', "1\n,private-marker",
   "7;bad,private-marker"].each do |raw|
    it "rejects malformed packet #{raw.inspect} on initial load and reload" do
      [false, true].each do |reload|
        load_rows([row]) if reload
        allow(api).to receive(:missions_list).and_return(raw)
        expect { missions.load }.to raise_error(Hackers::Serializer::ParserError) { |error|
          expect(error.message).not_to include('private-marker', 'bad', 'abc')
        }
        expect_empty
      end
    end
  end

  [nil, '7', ['7'], [[7]], [[]]].each do |section|
    it "rejects invalid parsed section/record shape #{section.inspect}" do
      allow(api).to receive(:missions_list).and_return('synthetic')
      allow(Hackers::Serializer).to receive(:parseData).with('synthetic').and_return([section])
      expect { missions.load }.to raise_error(Hackers::Serializer::ParserError)
      expect_empty
    end
  end

  it 'propagates the exact API exception on initial load and reload' do
    error = IOError.new('offline failure')
    [false, true].each do |reload|
      load_rows([row]) if reload
      allow(api).to receive(:missions_list).and_raise(error)
      expect { missions.load }.to raise_error { |raised| expect(raised).to equal(error) }
      expect_empty
    end
  end
end
