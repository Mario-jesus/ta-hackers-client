# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'tmpdir'

RSpec.describe 'versioned .gitignore privacy policy' do
  def with_isolated_git_fixture
    Dir.mktmpdir('ta-hackers-gitignore-') do |dir|
      template = File.join(dir, 'empty-template')
      FileUtils.mkdir_p(template)
      gitignore = File.expand_path('../.gitignore', __dir__)
      FileUtils.cp(gitignore, File.join(dir, '.gitignore')) if File.exist?(gitignore)

      env = {
        'GIT_CONFIG_GLOBAL' => File::NULL,
        'GIT_CONFIG_SYSTEM' => File::NULL
      }
      stdout, stderr, status = Open3.capture3(
        env,
        'git', 'init', '--template', template,
        chdir: dir
      )
      expect(status).to be_success, "git init failed: #{stdout}#{stderr}"

      yield dir, env
    end
  end

  def check_ignore_status(dir, env, path)
    _stdout, _stderr, status = Open3.capture3(
      env,
      'git', '-c', 'core.excludesFile=/dev/null', 'check-ignore', '--no-index', '-q', path,
      chdir: dir
    )
    status.exitstatus
  end

  def expect_ignored(dir, env, path)
    expect(check_ignore_status(dir, env, path)).to eq(0), "expected #{path.inspect} to be ignored"
  end

  def expect_allowed(dir, env, path)
    expect(check_ignore_status(dir, env, path)).to eq(1), "expected #{path.inspect} to remain eligible for tracking"
  end

  it 'ignores private configs, credentials, keys, local logs, received repos, APKs, dumps, and local indexes' do
    with_isolated_git_fixture do |dir, env|
      ignored_paths = [
        'configs/private.conf',
        'configs/auth/credentials.json',
        'credentials.json',
        '.credentials.yaml',
        '.env',
        '.env.local',
        'certificates/client.pem',
        'certificates/signing.key',
        'certificates/archive.p12',
        'accounts/ledger.json',
        'private/session.txt',
        'logs/client.log',
        'tmp/client.log',
        'ta-hackers/received-nested/lib/hackers/client.rb',
        'ta-hackers/.git/config',
        'APKs/current.apk',
        'build/release.aab',
        'dumps/session.raw',
        '.codegraph/index.sqlite',
        '.atl/cache.json',
        '.bundle/config',
        'coverage/index.html'
      ]

      ignored_paths.each { |path| expect_ignored(dir, env, path) }
    end
  end

  it 'keeps public fixtures, source, tests, docs, and task files eligible for tracking' do
    with_isolated_git_fixture do |dir, env|
      allowed_paths = [
        'configs/default.conf',
        'data/countries.conf',
        'data/public-catalog.json',
        'Gemfile.lock',
        'lib/hackers/client.rb',
        'bin/sandbox',
        'scripts/helpers.rb',
        'spec/gitignore_spec.rb',
        'docs/client-robustness-refactor.md',
        'docs/public-catalog.json',
        'odd/tasks/client-robustness-refactor.md',
        '.env.example'
      ]

      allowed_paths.each { |path| expect_allowed(dir, env, path) }
    end
  end
end
