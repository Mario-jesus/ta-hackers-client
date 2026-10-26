# frozen_string_literal: true

require 'rbconfig'
require 'fileutils'

# No dependency installation and no build products beside tracked sources.
root = File.realpath(File.join(__dir__, '..'))
abort 'run from repository root' unless Dir.pwd == root
abort 'arguments are not supported' unless ARGV.empty?
abort 'unexpected Ruby ABI' unless RUBY_VERSION == '3.3.12'
# Optional private GNU Readline installation; Bundler paths belong to the caller.
prefix = ENV['READLINE_PREFIX']
if prefix
  abort 'READLINE_PREFIX must be an absolute directory' unless
    prefix.start_with?('/') && File.directory?(prefix)
  prefix = File.realpath(prefix)
end

# Check every ancestor and existing child before allowing any tool to write.
# Reject links rather than canonicalizing them into another writable location.
def no_links(path)
  abort "symlink prohibited: #{path}" if File.symlink?(path)
  return unless File.directory?(path)

  Dir.each_child(path) { |entry| no_links(File.join(path, entry)) }
end

bundle = File.join(root, '.bundle')
abort 'bundle directory is a symlink' if File.symlink?(bundle)
build = File.join(bundle, 'native-readline-callback')
no_links(build)
FileUtils.mkdir_p(build)
abort 'build escaped repository' unless File.realpath(build) == build
sources = %w[extconf.rb cli_readline_callback.c]
sources.each do |name|
  source = File.join(root, 'ext', 'cli_readline_callback', name)
  %w[ext ext/cli_readline_callback].each do |relative|
    abort 'source directory is a symlink' if File.symlink?(File.join(root, relative))
  end
  abort 'source is not a regular file' unless File.file?(source) && !File.symlink?(source)
  FileUtils.copy_file(source, File.join(build, name))
end

Dir.chdir(build) do
  require 'shellwords'
  options = prefix ? ["--with-readline-dir=#{prefix}",
                      "--with-ldflags=#{Shellwords.escape("-Wl,-rpath,#{prefix}/lib")}"] : []
  abort 'mkmf failed' unless system(RbConfig.ruby, 'extconf.rb', *options)
  no_links(build)
  abort 'compilation failed' unless system('make', '-B')
end
artifact = File.join(build, "cli_readline_callback.#{RbConfig::CONFIG.fetch('DLEXT')}")
abort 'missing native artifact' unless File.file?(artifact) && !File.symlink?(artifact)
abort 'unsupported GNU Readline library' unless system(
  RbConfig.ruby, '-e',
  'require ARGV.fetch(0); abort "GNU Readline 8.3 required" unless CliReadlineCallback.version == "8.3"',
  artifact
)
puts artifact
