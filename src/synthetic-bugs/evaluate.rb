#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'open3'
require 'optparse'
require 'tempfile'
require 'timeout'

ROOT = File.expand_path('../..', __dir__)
BUGS_FILE = File.join(ROOT, 'bugs.jsonl')
BUGFIX_DIR = File.join(ROOT, 'bugfix')
DEFAULT_REPO = File.join(ROOT, '.eval', 'cheat')
APPLY_MUTATION = File.join(__dir__, 'apply_mutation.rb')
APPLY_RESPONSE = File.join(__dir__, 'apply_response.rb')
DEFAULT_BUNDLE_PATH = '/home/yahn/cheat/vendor/bundle'

opts = {
  count: 50,
  cats: '3B-blind,3B-ctx,7B-blind,32B-blind',
  verbose_failures: false,
  failure_log: File.join(BUGFIX_DIR, 'evaluation_failures.jsonl'),
  test_timeout: 300,
  bundle_path: DEFAULT_BUNDLE_PATH
}

OptionParser.new do |o|
  o.banner = 'Usage: ruby src/synthetic-bugs/evaluate.rb [options]'
  o.on('--count N', Integer) { |v| opts[:count] = v }
  o.on('--cats LIST') { |v| opts[:cats] = v }
  o.on('--verbose-failures') { opts[:verbose_failures] = true }
  o.on('--failure-log PATH') { |v| opts[:failure_log] = File.expand_path(v) }
  o.on('--test-timeout N', Integer) { |v| opts[:test_timeout] = v }
  o.on('--bundle-path PATH') { |v| opts[:bundle_path] = File.expand_path(v) }
end.parse!

bugs = File.readlines(BUGS_FILE, chomp: true).filter_map { |line| JSON.parse(line) unless line.empty? }
PYTHON_RANDOM_42_ORDER_50 = [
  40, 7, 1, 17, 15, 14, 8, 6, 34, 5, 37, 27, 2, 47, 49, 13, 44, 32, 36, 46,
  42, 22, 20, 28, 30, 41, 48, 33, 18, 43, 0, 35, 24, 10, 38, 39, 3, 12, 21,
  31, 16, 29, 9, 26, 45, 4, 11, 19, 23, 25
].freeze

sample =
  if bugs.length == 50 && opts[:count] <= 50
    PYTHON_RANDOM_42_ORDER_50.first(opts[:count]).map { |index| bugs[index] }
  else
    srand(42)
    bugs.sample(opts[:count])
  end

def repo_path_for(bug)
  bug.fetch('repo', {})['repo_path'] || DEFAULT_REPO
end

def file_rel_for(bug)
  bug['file_rel'] || bug['file'].sub(%r{\A/home/yahn/cheat/}, '')
end

def source_path_for(bug)
  File.join(repo_path_for(bug), file_rel_for(bug))
end

def run_capture(cmd, chdir:, env: {}, timeout: 60)
  out = +''
  err = +''
  timed_out = false

  Open3.popen3(env, *cmd, chdir: chdir, pgroup: true) do |stdin, stdout, stderr, wait_thr|
    stdin.close
    out_reader = Thread.new { stdout.read }
    err_reader = Thread.new { stderr.read }

    unless wait_thr.join(timeout)
      timed_out = true
      begin
        Process.kill('TERM', -wait_thr.pid)
      rescue Errno::ESRCH
      end
      sleep 0.5
      if wait_thr.alive?
        begin
          Process.kill('KILL', -wait_thr.pid)
        rescue Errno::ESRCH
        end
      end
      wait_thr.join
    end

    out = out_reader.value.to_s
    err = err_reader.value.to_s
    { out: out, err: err, status: wait_thr.value, timeout: timed_out }
  end
end

def reset_repo_for_bug(bug)
  repo = repo_path_for(bug)
  commit = bug.fetch('repo', {})['commit']
  expected_tree = bug.fetch('repo', {})['tree']
  return { ok: false, status: 'MISSING_REPO_COMMIT' } unless commit

  [%w[git checkout --detach], %w[git reset --hard], %w[git clean -fdx]].each do |prefix|
    cmd = prefix + (prefix.include?('clean') ? [] : [commit])
    res = run_capture(cmd, chdir: repo, timeout: 60)
    unless res[:status]&.success?
      return { ok: false, status: 'REPO_RESET_FAILED', error: (res[:err] + res[:out])[-1000..] }
    end
  end

  if expected_tree
    res = run_capture(%w[git rev-parse HEAD^{tree}], chdir: repo, timeout: 10)
    actual = res[:out].strip
    return { ok: false, status: 'TREE_MISMATCH', error: "#{actual} != #{expected_tree}" } if actual != expected_tree
  end

  { ok: true }
end

def unsupported_response_format?(text)
  lowered = text.downcase
  ['change this line', 'replace this line', 'change `', 'replace `', 'diff --git', '```diff'].any? do |marker|
    lowered.include?(marker)
  end
end

def parse_helper_output(text, fallback)
  lines = text.to_s.strip.lines.map(&:strip)
  return { 'status' => fallback, 'error' => text[-1000..] } if lines.empty?

  JSON.parse(lines.last)
rescue JSON::ParserError
  { 'status' => fallback, 'error' => text[-1000..] }
end

def syntax_check(filepath)
  res = run_capture(['ruby', '-c', filepath], chdir: ROOT, timeout: 20)
  return { status: 'SYNTAX_OK' } if res[:status]&.success?

  { status: 'SYNTAX_ERROR', error: (res[:err] + res[:out])[-1000..] }
end

def apply_mutation_with_prism(bug)
  Tempfile.create(['cleopatra-mutated-body-', '.rb']) do |tmp|
    tmp.write(bug['mutated_body'])
    tmp.close
    res = run_capture(['ruby', APPLY_MUTATION, source_path_for(bug), tmp.path, bug['function']], chdir: ROOT, timeout: 30)
    parsed = parse_helper_output(res[:out] + res[:err], 'MUTATION_APPLY_FAILED')
    return parsed unless res[:status]&.success?

    return { status: 'MUTATION_APPLIED', detail: parsed }
  end
end

def apply_response_with_prism(bug, response_text)
  Tempfile.create(['cleopatra-response-', '.txt']) do |tmp|
    tmp.write(response_text)
    tmp.close
    res = run_capture(['ruby', APPLY_RESPONSE, source_path_for(bug), tmp.path, bug['function']], chdir: ROOT, timeout: 30)
    parsed = parse_helper_output(res[:out] + res[:err], 'RESPONSE_APPLY_FAILED')
    return parsed unless res[:status]&.success?

    return { status: 'RESPONSE_APPLIED', detail: parsed }
  end
end

def test_files(repo, rel_dir)
  root = File.join(repo, rel_dir)
  return [] unless Dir.exist?(root)

  Dir[File.join(root, '**/*_test.rb')].map { |path| path.delete_prefix("#{repo}/") }.sort
end

def unit_test_commands(bug)
  commands = []
  (bug['test_failures'] || []).each do |failure|
    if failure['command']
      commands << failure['command']
      next
    end

    file_rel = failure['file_rel']
    next unless file_rel

    if file_rel.end_with?('_spec.rb') || file_rel.start_with?('spec/') || file_rel.include?('/spec/')
      commands << ['bundle', 'exec', 'rspec', file_rel]
    else
      commands << ['bundle', 'exec', 'ruby', file_rel]
    end
  end
  return commands unless commands.empty?

  repo = repo_path_for(bug)
  case bug['subproject']
  when 'src' then [['bundle', 'exec', 'prspec', 'spec']]
  when 'nil_kill' then [['bundle', 'exec', 'prspec', 'gems/nil-kill/spec']]
  when 'minivm' then [['ruby', 'examples/minivm/run_tests.rb', '--all']]
  when 'decomplex' then [['ruby', '-I', 'gems/decomplex/lib', '-I', 'gems/decomplex/test', *test_files(repo, 'gems/decomplex/test')]]
  when 'slopcop' then [['ruby', '-I', 'gems/slopcop/lib', '-I', 'gems/slopcop/test', *test_files(repo, 'gems/slopcop/test')]]
  when 'boobytrap' then [['ruby', '-I', 'gems/boobytrap/lib', '-I', 'gems/boobytrap/test', *test_files(repo, 'gems/boobytrap/test')]]
  else []
  end
end

def run_all_tests(bug, opts)
  repo = repo_path_for(bug)
  commands = unit_test_commands(bug).select { |cmd| cmd.length > 1 }
  return { status: 'NO_RECORDED_TEST_FAILURE', test_command: nil, test_output: 'Bug has no recorded failing test command' } if commands.empty?

  env = { 'RUBYOPT' => '-W0' }
  env['BUNDLE_PATH'] = opts[:bundle_path] if opts[:bundle_path] && Dir.exist?(opts[:bundle_path])
  outputs = []
  commands.each do |cmd|
    res = run_capture(cmd, chdir: repo, env: env, timeout: opts[:test_timeout])
    return { status: 'TEST_TIMEOUT', test_command: cmd, test_output: 'TIMEOUT' } if res[:timeout]

    output = res[:out] + res[:err]
    outputs << "$ #{cmd.join(' ')}\n#{output[-4000..]}"
    next if res[:status]&.success?

    env_markers = [
      'Could not find gem',
      'Could not locate Gemfile or .bundle',
      'Bundler::GemNotFound',
      'cannot load such file -- rspec',
      'cannot load such file -- sorbet-runtime',
      'command not found',
      'No such file or directory'
    ]
    status = env_markers.any? { |marker| output.include?(marker) } ? 'TEST_ENV_ERROR' : 'TEST_FAILED'
    return { status: status, test_command: cmd, test_output: outputs.join("\n")[-6000..] }
  end

  { status: 'TEST_PASSED', test_command: commands, test_output: '' }
end

def eval_bug(bug, response_text, opts)
  reset = reset_repo_for_bug(bug)
  return reset unless reset[:ok]

  filepath = source_path_for(bug)
  begin
    mutation = apply_mutation_with_prism(bug)
    return mutation unless mutation[:status] == 'MUTATION_APPLIED'

    syntax = syntax_check(filepath)
    return { status: 'MUTATION_SYNTAX_ERROR', error: syntax[:error].to_s } unless syntax[:status] == 'SYNTAX_OK'

    response = apply_response_with_prism(bug, response_text)
    return response unless response[:status] == 'RESPONSE_APPLIED'

    syntax = syntax_check(filepath)
    return syntax unless syntax[:status] == 'SYNTAX_OK'

    result = run_all_tests(bug, opts)
    result[:apply_detail] = response[:detail]
    result
  ensure
    reset_repo_for_bug(bug)
  end
end

def record_failure(opts, category, index, bug, response_path, raw_response, status, detail = '')
  FileUtils.mkdir_p(File.dirname(opts[:failure_log]))
  rec = {
    bug_id: bug['id'],
    index: index,
    category: category,
    repo_commit: bug.fetch('repo', {})['commit'],
    repo_tree: bug.fetch('repo', {})['tree'],
    file_rel: file_rel_for(bug),
    function: bug['function'],
    response_path: response_path,
    raw_response: raw_response,
    status: status,
    detail: detail
  }
  File.open(opts[:failure_log], 'a') { |f| f.puts(JSON.generate(rec)) }
end

def result_label(status)
  case status
  when 'TEST_PASSED'
    'PASS'
  when 'TEST_FAILED'
    'FAIL'
  when 'SYNTAX_ERROR', 'MUTATION_SYNTAX_ERROR'
    'SYNTAX'
  when 'TEST_TIMEOUT'
    'TIMEOUT'
  when 'TEST_ENV_ERROR'
    'ENVERR'
  when 'NO_TEST_SUITE', 'NO_RECORDED_TEST_FAILURE'
    'NOSUITE'
  when nil
    'MISSING'
  else
    'ERROR'
  end
end

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
FileUtils.mkdir_p(File.dirname(opts[:failure_log]))
File.write(opts[:failure_log], '')
categories = opts[:cats].split(',').map(&:strip).reject(&:empty?)
matrix = Hash.new { |hash, key| hash[key] = {} }

puts
printf "%-15s %-10s %-9s %-9s %-7s %-8s %-7s\n", 'Category', 'Responses', 'TestPass', 'TestFail', 'EnvErr', 'NoSuite', 'Errors'
puts '-' * 76

categories.each do |cat|
  dir = File.join(BUGFIX_DIR, cat)
  next unless Dir.exist?(dir)

  n = passed = tfail = enverr = nosuite = err = 0
  statuses = Hash.new(0)

  opts[:count].times do |i|
    fp = File.join(dir, format('%02d.txt', i + 1))
    unless File.exist?(fp)
      matrix[i + 1][cat] = 'MISSING'
      next
    end

    n += 1
    txt = File.read(fp)
    bug = sample[i]

    if unsupported_response_format?(txt)
      err += 1
      statuses['UNSUPPORTED_RESPONSE_FORMAT'] += 1
      matrix[i + 1][cat] = 'ERROR'
      record_failure(opts, cat, i + 1, bug, fp, txt, 'UNSUPPORTED_RESPONSE_FORMAT')
      next
    end

    result = eval_bug(bug, txt, opts)
    status = result[:status] || result['status']
    statuses[status] += 1
    matrix[i + 1][cat] = result_label(status)

    case status
    when 'TEST_PASSED'
      passed += 1
    when 'TEST_FAILED'
      tfail += 1
      record_failure(opts, cat, i + 1, bug, fp, txt, status, result[:test_output].to_s)
      if opts[:verbose_failures]
        puts "  fail #{format('%02d', i + 1)}: #{bug['subproject']} #{file_rel_for(bug)} #{bug['function']}"
        puts "    #{result[:test_output].to_s.tr("\n", ' ')[0, 240]}"
      end
    when 'TEST_ENV_ERROR'
      enverr += 1
      record_failure(opts, cat, i + 1, bug, fp, txt, status, result[:test_output].to_s)
    when 'NO_TEST_SUITE', 'NO_RECORDED_TEST_FAILURE'
      nosuite += 1
      record_failure(opts, cat, i + 1, bug, fp, txt, status, result[:test_output].to_s)
    else
      err += 1
      record_failure(opts, cat, i + 1, bug, fp, txt, status, result[:error].to_s + result[:test_output].to_s)
    end
  end

  printf "%-15s %-10d %-9d %-9d %-7d %-8d %-7d\n", cat, n, passed, tfail, enverr, nosuite, err
  puts "  statuses: #{statuses.sort.map { |k, v| "#{k}=#{v}" }.join(', ')}" if err.positive? || tfail.positive? || enverr.positive? || nosuite.positive?
end

puts
puts 'Per-Test Results'
printf "%-6s", 'Test'
categories.each { |cat| printf " %-12s", cat }
puts
puts '-' * (6 + (13 * categories.length))
opts[:count].times do |i|
  test_number = i + 1
  printf "%-6s", format('%02d', test_number)
  categories.each { |cat| printf " %-12s", matrix[test_number][cat] || 'MISSING' }
  puts
end

puts
puts 'TestPass = response was applied with Prism and the full mapped unit test suite passed'
puts 'Per-test labels: PASS, FAIL, SYNTAX, TIMEOUT, ENVERR, NOSUITE, ERROR, MISSING'
puts 'NoSuite/EnvErr are failures for scoring; syntax-only success is never counted as a pass'
puts 'The evaluator resets the pinned checkout before and after every bug'
puts "Failure log: #{opts[:failure_log]}"
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
puts "Elapsed: #{format('%.2f', elapsed)}s"
