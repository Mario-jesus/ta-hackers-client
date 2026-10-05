# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

require 'cli/sandbox'

# Offline tests for sandbox config path resolution and loading (task C1).
#
# Only synthetic tempfiles are used. No repository config (and especially no
# private account config) is read by these tests.
RSpec.describe Sandbox::Config do
  describe '.resolve_path' do
    let(:configs_dir) { Dir.mktmpdir('sandbox-configs') }
    let(:home_dir) { Dir.mktmpdir('sandbox-home') }

    after do
      FileUtils.remove_entry(configs_dir)
      FileUtils.remove_entry(home_dir)
    end

    it 'resolves a plain name against the configs directory' do
      named = File.join(configs_dir, 'alpha.conf')
      File.write(named, '{}')

      expect(described_class.resolve_path('alpha', configs_dir)).to eq(named)
    end

    it 'returns nil for a missing plain name without implicit account search' do
      expect(described_class.resolve_path('missing', configs_dir)).to be_nil
    end

    it 'accepts an explicit absolute .conf path' do
      explicit = File.join(configs_dir, 'beta.conf')
      File.write(explicit, '{}')

      expect(described_class.resolve_path(explicit, configs_dir)).to eq(explicit)
    end

    it 'accepts an explicit absolute .json path' do
      explicit = File.join(configs_dir, 'gamma.json')
      File.write(explicit, '{}')

      expect(described_class.resolve_path(explicit, configs_dir)).to eq(explicit)
    end

    it 'accepts an explicit relative path containing a separator' do
      subdir = File.join(configs_dir, 'subdir')
      FileUtils.mkdir_p(subdir)
      explicit = File.join(subdir, 'delta.conf')
      File.write(explicit, '{}')

      resolved = nil
      Dir.chdir(configs_dir) do
        resolved = described_class.resolve_path('subdir/delta.conf', configs_dir)
      end

      expect(resolved).to eq(explicit)
    end

    it 'expands ~ in explicit paths' do
      home_file = File.join(home_dir, 'epsilon.json')
      File.write(home_file, '{}')
      original_home = ENV['HOME']
      ENV['HOME'] = home_dir

      expect(described_class.resolve_path('~/epsilon.json', configs_dir)).to eq(home_file)
    ensure
      ENV['HOME'] = original_home
    end

    it 'returns nil for a missing explicit path' do
      missing = File.join(configs_dir, 'does-not-exist.json')

      expect(described_class.resolve_path(missing, configs_dir)).to be_nil
    end

    it 'treats a bare .conf suffix as an explicit cwd-relative path' do
      expect(described_class.resolve_path('no-such.conf', configs_dir)).to be_nil
    end
  end

  describe '#load / #save' do
    let(:dir) { Dir.mktmpdir('sandbox-config') }
    let(:path) { File.join(dir, 'synthetic.conf') }

    after { FileUtils.remove_entry(dir) }

    it 'loads a synthetic 0600 JSON tempfile' do
      File.write(path, JSON.generate('id' => 777, 'password' => 'synthetic-pw'))
      File.chmod(0o600, path)

      config = described_class.new(path)
      config.load

      expect(config['id']).to eq(777)
      expect(config['password']).to eq('synthetic-pw')
      expect(config.file).to eq(path)
      expect(File.stat(path).mode & 0o777).to eq(0o600)
    end

    it 'saves the configuration as pretty JSON' do
      config = described_class.new(path)
      config['id'] = 777
      config.save

      expect(JSON.parse(File.read(path))).to eq('id' => 777)
    end

    it 'ignores JSON documents that are not objects' do
      File.write(path, '[1,2]')

      config = described_class.new(path)
      expect(config.load).to be_nil
      expect(config).to be_empty
    end
  end

  describe 'malformed config privacy (real entrypoint subprocess)' do
    let(:dir) { Dir.mktmpdir('sandbox-config') }

    after { FileUtils.remove_entry(dir) }

    it 'fails friendly without echoing private config content fragments' do
      marker_id = 'MARKER_ID_818181'
      marker_pw = 'MARKER_PW_778877'
      marker_file = File.join(dir, 'broken.conf')
      File.write(marker_file, %({"id": #{marker_id}, "password": "#{marker_pw}",))

      repo_root = File.expand_path('..', __dir__)
      out, err, status = Open3.capture3(RbConfig.ruby, File.join(repo_root, 'bin', 'sandbox'),
                                        '-c', marker_file, chdir: repo_root)

      expect(status.exitstatus).to eq(1)
      expect(out + err).not_to include(marker_id)
      expect(out + err).not_to include(marker_pw)
      expect(out).to include('invalid')
    end
  end
end
