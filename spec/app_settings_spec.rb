# frozen_string_literal: true

require 'hackers'

RSpec.describe Hackers::AppSettings do
  let(:api) { double('API') }
  subject(:settings) { described_class.new(api) }

  def records
    Array.new(11) { |i| [i.to_s, "setting#{i}", i.to_s] } +
      [['opaque timestamp'], ['en:1', 'es:-2'], ['extra', '007']]
  end

  def packet(rows)
    rows.map { |row| row.join(Hackers::Serializer::DELIM_FIELD) }
        .join(Hackers::Serializer::DELIM_RECORD)
  end

  def load_rows(rows)
    allow(api).to receive(:app_settings).and_return(packet(rows))
    settings.load
  end

  def expect_empty
    expect(settings).not_to be_loaded
    expect(settings.to_a).to eq([])
    expect(settings.languages).to eq([])
    expect(settings.get('setting0')).to be_nil
    expect(settings.get('extra')).to be_nil
    expect(settings.language('en')).to be_nil
    expect(settings.datetime).to be_nil
    expect(settings.raw_data).to be_nil
  end

  it 'preserves full-catalog coercion, text, enumeration and one API call' do
    rows = records
    rows[1][2] = '-2'
    rows[2][2] = '3.5'
    rows[3][2] = 'hello world'
    expect(api).to receive(:app_settings).once.and_return(packet(rows))
    settings.load

    expect(settings).to be_loaded
    expect(settings.get('setting0')).to eq(0)
    expect(settings.get('setting1')).to eq('-2')
    expect(settings.get('setting2')).to eq('3.5')
    expect(settings.get('setting3')).to eq('hello world')
    expect(settings.get('extra')).to eq(7)
    expect(settings.to_a).to eq((0..10).map { |i| "setting#{i}" } + ['extra'])
    expect(settings.languages).to eq(%w[en es])
    expect(settings.language('es')).to eq(-2)
    expect(settings.datetime).to eq('opaque timestamp')
  end

  it 'allows omitted optional records and clears stale keys on valid reload' do
    load_rows(records)
    load_rows(records.take(12))
    expect(settings).to be_loaded
    expect(settings.languages).to eq([])
    expect(settings.get('extra')).to be_nil
    expect(settings.datetime).to eq('opaque timestamp')
  end

  it 'allows an empty language placeholder before extensions' do
    rows = records
    rows[12] = []
    load_rows(rows)
    expect(settings.languages).to eq([])
    expect(settings.get('extra')).to eq(7)
  end

  it 'allows representable empty values and ignored extra fields and sections' do
    rows = records
    rows[0] = ['0', 'setting0', '', 'unused']
    rows[13] = ['extra', '', 'unused']
    allow(api).to receive(:app_settings).and_return(packet(rows) + '@ignored')
    settings.load
    expect(settings.get('setting0')).to eq('')
    expect(settings.get('extra')).to eq('')
  end

  malformed = {
    'missing section' => ->(_r) { [] },
    'missing required records' => ->(r) { r.take(10) },
    'missing required key' => ->(r) { r[0] = ['0', '', '1']; r },
    'missing required value' => ->(r) { r[0] = ['0', 'setting0']; r },
    'missing timestamp' => ->(r) { r.take(11) },
    'empty timestamp' => ->(r) { r[11] = []; r },
    'missing language ID' => ->(r) { r[12] = ['en']; r },
    'empty language code' => ->(r) { r[12] = [':1']; r },
    'nonnumeric language ID' => ->(r) { r[12] = ['en:abc']; r },
    'partial numeric language ID' => ->(r) { r[12] = ['en:1x']; r },
    'missing extension key' => ->(r) { r[13] = ['', '1']; r },
    'missing extension value' => ->(r) { r[13] = ['extra']; r },
    'invalid late extension' => ->(r) { r << ['late']; r }
  }

  malformed.each do |name, mutate|
    it "rejects #{name} without publishing initial or reloaded state" do
      bad = mutate.call(records)
      allow(api).to receive(:app_settings).and_return(packet(bad))
      expect { settings.load }.to raise_error(Hackers::Serializer::ParserError)
      expect_empty
      load_rows(records)
      allow(api).to receive(:app_settings).and_return(packet(bad))
      expect { settings.load }.to raise_error(Hackers::Serializer::ParserError)
      expect_empty
    end
  end

  it 'preserves API exceptions while invalidating prior state' do
    load_rows(records)
    error = IOError.new('offline failure')
    allow(api).to receive(:app_settings).and_raise(error)
    expect { settings.load }.to raise_error { |raised| expect(raised).to equal(error) }
    expect_empty
  end
end
