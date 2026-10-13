# frozen_string_literal: true

SCRIPT_DIR = File.join(BASE_DIR, 'scripts')
SCRIPT_EXT = '.rb'

SCRIPT_JOBS = {}
# Serializes SCRIPT_JOBS admission and mutation reads/writes. Never held
# across IO: take a snapshot inside synchronize, act on it outside.
SCRIPT_JOBS_MUTEX = Mutex.new
SCRIPT_VARS = {
  job_counter: 0
}

SCRIPT_LOG_CHAR = "\u273f"

SCRIPT_LOGGER = Sandbox::Logger.new(SHELL)
SCRIPT_LOGGER.log_prefix = "\u273f "
SCRIPT_LOGGER.log_prefix_cterm = ColorTerm.blue.bold
SCRIPT_LOGGER.log_cterm = ColorTerm.blue
SCRIPT_LOGGER.error_prefix = "\u273f "
SCRIPT_LOGGER.error_prefix_cterm = ColorTerm.red.bold
SCRIPT_LOGGER.error_cterm = ColorTerm.red

def script_file_identity(file)
  File.realpath(file)
rescue StandardError
  File.expand_path(file)
end

# Script identity is the ACTUAL resolved file path, not the typed alias:
# ./autohack collapses onto the canonical scripts/autohack.rb. The guard
# never silently executes a different file, because the typed file path
# itself is what load executes below.
def script_canonical_identity(script, file)
  return 'autohack' if script_file_identity(file) == script_file_identity(File.join(SCRIPT_DIR, "autohack#{SCRIPT_EXT}"))

  script
end

def script_run(shell, script, file, args, job)
  # Re-check the reservation after the spawn: a withdrawn reservation means
  # the user (or booking failure) retracted this job before it started.
  admitted = SCRIPT_JOBS_MUTEX.synchronize do
    SCRIPT_JOBS.key?(job)
  end
  return unless admitted

  logger = Sandbox::Logger.new(shell)
  logger.log_prefix = "\u276f [#{script}] "
  logger.log_prefix_cterm = ColorTerm.cyan.bold
  logger.log_cterm = ColorTerm.cyan
  logger.error_prefix = "\u276f [#{script}] "
  logger.error_prefix_cterm = ColorTerm.red.bold
  logger.error_cterm = ColorTerm.red
  logger.info_prefix = "\u276f [#{script}] "
  logger.info_prefix_cterm = ColorTerm.white.bold
  logger.info_cterm = ColorTerm.white

  name = script.capitalize

  begin
    load file unless Object.const_defined?(name)
    raise "Class #{name} not found" unless Object.const_defined?(name)

    instance = Object.const_get(name).new(GAME, shell, logger, args)
    SCRIPT_JOBS_MUTEX.synchronize do
      record = SCRIPT_JOBS[job]
      record[:instance] = instance if record
    end
    SCRIPT_LOGGER.log("Run: #{script} [#{job}]")
    instance.main
    instance.finish
    SCRIPT_LOGGER.log("Done: #{script} [#{job}]")
  rescue SyntaxError, StandardError => e
    script_log_backtrace(script, job, e)
  ensure
    # One execution owns the job record end to end: this deletion covers
    # normal end, failure and every exception unwind of this job.
    SCRIPT_JOBS_MUTEX.synchronize { SCRIPT_JOBS.delete(job) }
    last_holder = SCRIPT_JOBS_MUTEX.synchronize do
      SCRIPT_JOBS.any? { |_id, record| record[:script] == script }
    end
    Object.send(:remove_const, name) unless last_holder || !Object.const_defined?(name)
  end
end

def script_log_backtrace(script, job, e)
  msg = String.new
  (e.backtrace.length - 1).downto(0) do |i|
    msg += "#{i + 1}. #{e.backtrace[i]}\n"
  end

  SCRIPT_LOGGER.error("Error: #{script} [#{job}]\n\n#{msg}\n=> #{e.message}")
end

## Commands

# run
CONTEXT_SCRIPT_RUN = CONTEXT_SCRIPT.add_command(
  :run,
  description: 'Run the script',
  params: ['<name>']
) do |tokens, shell|
  script = tokens[1]

  file = File.join(SCRIPT_DIR, "#{script}#{SCRIPT_EXT}")
  unless File.file?(file)
    shell.puts('No such script')
    next
  end

  canonical = script_canonical_identity(script, file)

  # One writer per active autohack run: the busy check and the fee-free
  # reservation (`thread: nil`) commit atomically before any thread spawn.
  # The job counter only advances for admitted jobs, so refusals leave no
  # gaps. Every other script name stays freely concurrent.
  admission = nil
  SCRIPT_JOBS_MUTEX.synchronize do
    active_job = nil
    if canonical == 'autohack'
      SCRIPT_JOBS.each do |id, record|
        next unless record[:script] == 'autohack'

        thread = record[:thread]
        if thread.nil? || thread.alive?
          active_job = id
          break
        end
      end
    end

    if active_job
      admission = [:busy, active_job]
    else
      job = SCRIPT_VARS[:job_counter] += 1
      SCRIPT_JOBS[job] = { script: canonical, thread: nil, instance: nil }
      admission = [:admitted, job]
    end
  end

  if admission[0] == :busy
    shell.puts("autohack is already running as job [#{admission[1]}]; wait for it to finish")
    next
  end

  job = admission[1]

  begin
    thread = Thread.new { script_run(shell, canonical, file, tokens[2..], job) }
  rescue StandardError
    # Thread creation failed: release the reservation so a future run can
    # start, and surface the error instead of swallowing it silently.
    SCRIPT_JOBS_MUTEX.synchronize { SCRIPT_JOBS.delete(job) }
    raise
  end

  # Publish the thread handle into the reserved record. Very fast completion
  # can delete the record first: update only when it is still present.
  SCRIPT_JOBS_MUTEX.synchronize do
    record = SCRIPT_JOBS[job]
    record[:thread] = thread if record
  end
end

CONTEXT_SCRIPT_RUN.completion do |line|
  files = Dir.children(SCRIPT_DIR).select { |f| f.end_with?(SCRIPT_EXT) }
  files.map! { |f| f.delete_suffix(SCRIPT_EXT) }
  files.grep(/^#{Regexp.escape(line)}/)
end

# list
CONTEXT_SCRIPT.add_command(
  :list,
  description: 'List scripts'
) do |tokens, shell|
  scripts = []
  Dir.children(SCRIPT_DIR).sort.each do |child|
    file = File.join(SCRIPT_DIR, child)
    next unless File.file?(file) && child.end_with?(SCRIPT_EXT)

    child.delete_suffix!(SCRIPT_EXT)
    scripts << child
  end

  if scripts.empty?
    shell.puts('No scripts')
    next
  end

  shell.puts('Scripts:')
  scripts.each do |script|
    shell.puts(" #{script}")
  end
end

# jobs
CONTEXT_SCRIPT.add_command(
  :jobs,
  description: 'List active scripts'
) do |tokens, shell|
  listing = SCRIPT_JOBS_MUTEX.synchronize do
    SCRIPT_JOBS.map { |id, record| format(' [%d] %s', id, record[:script]) }
  end

  if listing.empty?
    shell.puts('No active jobs')
    next
  end

  shell.puts('Active jobs:')
  listing.each { |line| shell.puts(line) }
end

# kill
CONTEXT_SCRIPT_KILL = CONTEXT_SCRIPT.add_command(
  :kill,
  description: 'Kill the script',
  params: ['<id>']
) do |tokens, shell|
  job = tokens[1].to_i

  record = nil
  SCRIPT_JOBS_MUTEX.synchronize do
    entry = SCRIPT_JOBS[job]
    record = entry && { script: entry[:script], thread: entry[:thread], instance: entry[:instance] }
  end

  unless record
    shell.puts('No such job')
    next
  end

  script = record[:script]

  begin
    record[:instance].finish if record[:instance]
  rescue StandardError => e
    script_log_backtrace(script, job, e)
  end

  if record[:thread]
    # Kill and join OUTSIDE the mutex so the worker's unwinding cleanup
    # cannot deadlock against the kill command itself.
    record[:thread].kill
    record[:thread].join
  else
    # Reserved but never started: withdraw the admission.
    SCRIPT_JOBS_MUTEX.synchronize { SCRIPT_JOBS.delete(job) }
  end

  SCRIPT_LOGGER.log("Killed: #{script} [#{job}]")

  # The worker's ensure deletes its own record; this post-join release keeps
  # the legacy kill chain explicit and is a no-op when already removed.
  SCRIPT_JOBS_MUTEX.synchronize { SCRIPT_JOBS.delete(job) }
  name = script.capitalize
  last_holder = SCRIPT_JOBS_MUTEX.synchronize do
    SCRIPT_JOBS.any? { |_id, entry| entry[:script] == script }
  end
  Object.send(:remove_const, name) unless last_holder || !Object.const_defined?(name)
end

CONTEXT_SCRIPT_KILL.completion do |line|
  jobs = SCRIPT_JOBS_MUTEX.synchronize { SCRIPT_JOBS.keys }.map(&:to_s)
  jobs.grep(/^#{Regexp.escape(line)}/)
end

# admin
CONTEXT_SCRIPT_ADMIN = CONTEXT_SCRIPT.add_command(
  :admin,
  description: 'Administrate the script',
  params: ['<id>']
) do |tokens, shell|
  job = tokens[1].to_i

  present, script_name, instance = nil
  SCRIPT_JOBS_MUTEX.synchronize do
    entry = SCRIPT_JOBS[job]
    present = !entry.nil?
    script_name = entry&.fetch(:script, nil)
    instance = entry&.fetch(:instance, nil)
  end

  unless present
    shell.puts('No such job')
    next
  end

  unless instance.respond_to?(:admin)
    shell.puts('Not implemented')
    next
  end

  shell.puts('Enter ! or ^D to quit')
  prompt = ColorTerm.blue.bold("#{script_name}:#{job} #{SCRIPT_LOG_CHAR} ")
  loop do
    line = shell.readline(prompt, true)
    if line.nil?
      shell.puts
      break
    end

    line.strip!
    next if line.empty?

    break if line == '!'

    alive = SCRIPT_JOBS_MUTEX.synchronize { SCRIPT_JOBS.key?(job) }
    unless alive
      SCRIPT_LOGGER.error("Job #{job} was terminated")
      break
    end

    msg = instance.admin(line)
    next if msg.nil? || msg.empty?

    shell.puts(msg)
  end
end

CONTEXT_SCRIPT_ADMIN.completion do |line|
  jobs = SCRIPT_JOBS_MUTEX.synchronize { SCRIPT_JOBS.keys }.map(&:to_s)
  jobs.grep(/^#{Regexp.escape(line)}/)
end
