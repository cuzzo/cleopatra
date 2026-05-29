#!/usr/bin/env ruby
# frozen_string_literal: true

# mutant-bug-gen.rb — Synthetic Mutant Bug Generator
#
# Generates bugs across all CLEAR sub-projects by applying mutations
# to Ruby functions parsed via Prism. Each bug gets 5 tool-calling
# trajectories computed from the bug's metadata:
#   1. y_clean       (ideal tool calls, walks stack trace)
#   2. y_broken_wrong_fn (calls my_tool on wrong function)
#   3. y_sloppy_over (over-calls, too much context)
#   4. y_sloppy_under (under-calls, too little or too much noise)
#   5. y_blind_native (no tool calls, pure guess)

require 'json'
require 'fileutils'
require 'open3'
require 'optparse'
require 'prism'
require 'set'
require 'securerandom'
require 'tempfile'
require 'timeout'

DEFAULT_BUNDLE = File.expand_path('archives/cheat.bundle', __dir__)
DEFAULT_REPO = File.expand_path('.eval/cheat', __dir__)
DEFAULT_OUT = File.join(__dir__, 'bugs.jsonl')

OPTIONS = {
  repo: DEFAULT_REPO,
  bundle: DEFAULT_BUNDLE,
  ref: 'refs/remotes/bundle/master',
  out: DEFAULT_OUT,
  failure_log: File.join(__dir__, 'bug_generation_failures.jsonl'),
  total: 1200,
  subprojects: nil,
  verify_tests: true,
  test_timeout: 90,
  max_test_candidates: 12,
  bundle_path: '/home/yahn/cheat/vendor/bundle',
  append: false,
  seed: 42,
}.freeze

opts = OPTIONS.dup
OptionParser.new do |o|
  o.banner = 'Usage: ruby mutant-bug-gen.rb [options]'
  o.on('--repo PATH', 'Local restored repo checkout to generate from') { |v| opts[:repo] = File.expand_path(v) }
  o.on('--bundle PATH', 'Git bundle used to restore the repo') { |v| opts[:bundle] = File.expand_path(v) }
  o.on('--ref REF', 'Bundle/restored repo ref to pin for generation') { |v| opts[:ref] = v }
  o.on('--out PATH', 'Output bugs JSONL path') { |v| opts[:out] = File.expand_path(v) }
  o.on('--failures PATH', 'Generation failure JSONL path') { |v| opts[:failure_log] = File.expand_path(v) }
  o.on('--target N', Integer, 'Total bugs to generate') { |v| opts[:total] = v }
  o.on('--subprojects LIST', 'Comma-separated subprojects to generate, e.g. src,nil_kill') { |v| opts[:subprojects] = v.split(',').map(&:strip).reject(&:empty?) }
  o.on('--[no-]verify-tests', 'Require each mutation to fail at least one test file') { |v| opts[:verify_tests] = v }
  o.on('--test-timeout N', Integer, 'Seconds per candidate test file') { |v| opts[:test_timeout] = v }
  o.on('--max-test-candidates N', Integer, 'Max candidate test files to try per mutation') { |v| opts[:max_test_candidates] = v }
  o.on('--bundle-path PATH', 'Bundler install path used for test verification') { |v| opts[:bundle_path] = File.expand_path(v) }
  o.on('--append', 'Append to --out instead of replacing it') { opts[:append] = true }
  o.on('--seed N', Integer, 'Random seed for reproducible generation') { |v| opts[:seed] = v }
  o.on('-h', '--help') { puts o; exit 0 }
end.parse!

srand(opts[:seed])

CHEAT = opts[:repo]
BUGS_FILE = opts[:out]
TOTAL_TARGET = opts[:total]
BUNDLE = opts[:bundle]
SOURCE_REF = opts[:ref]
FAILURE_LOG = opts[:failure_log]
VERIFY_TESTS = opts[:verify_tests]
TEST_TIMEOUT = opts[:test_timeout]
MAX_TEST_CANDIDATES = opts[:max_test_candidates]
BUNDLE_PATH = opts[:bundle_path]

# === Sub-project dirs ===
SUBS = {
  'src'       => { dir: 'src',             target: 660 },
  'nil_kill'  => { dir: 'gems/nil-kill',   target: 228 },
  'minivm'    => { dir: 'examples/minivm', target: 120 },
  'puck'      => { dir: 'examples/puck',   target: 108 },
  'decomplex' => { dir: 'gems/decomplex',  target: 60  },
  'slopcop'   => { dir: 'gems/slopcop',    target: 12  },
  'boobytrap' => { dir: 'gems/boobytrap',  target: 12  },
}.freeze
ACTIVE_SUBS = if opts[:subprojects]
                unknown = opts[:subprojects] - SUBS.keys
                raise "Unknown subprojects: #{unknown.join(', ')}" unless unknown.empty?
                SUBS.select { |key, _| opts[:subprojects].include?(key) }
              else
                SUBS
              end

# === Difficulty distribution ===
DIFFICULTY_WEIGHTS = {
  'easy_syntax'       => 10,
  'trivial_line'      => 20,
  'trivial_function'  => 20,
  'stack_1_2'         => 30,
  'hard_2_plus'       => 20,
}.freeze

# === Prompt style distribution ===
PROMPT_WEIGHTS = {
  'stack_trace'    => 40,
  'detailed'       => 20,
  'vague'          => 15,
  'with_culprit'   => 10,
  'spec_broken'    => 10,
  'minimal'        => 5,
}.freeze

DISCOVERY_WEIGHTS = {
  'dirty_source_change' => 30,
  'new_unit_test' => 30,
  'production_stack_trace' => 40,
}.freeze

DIRTY_SOURCE_SCOPE_WEIGHTS = {
  'whole_function_dirty' => 50,
  'multi_line_dirty' => 25,
  'exact_line_dirty' => 25,
}.freeze

# === Mutation types ===
MUTATIONS = %i[
  negate_condition wrong_comparison off_by_one wrong_operator
  missing_guard wrong_variable wrong_constant wrong_bool_op
  forgotten_line wrong_error swallowed_error
].freeze

RUBY_KEYWORDS = %w[
  BEGIN END alias and begin break case class def defined? do else elsif end ensure false
  for if in module next nil not or redo rescue retry return self super then true undef
  unless until when while yield new
].freeze

def quota_targets(total, weights)
  raw = weights.map { |k, w| [k.to_s, total * w / 100.0] }.to_h
  targets = raw.transform_values(&:floor)
  remainder = total - targets.values.sum
  raw.sort_by { |k, v| [-(v - v.floor), k] }.first(remainder).each do |k, _|
    targets[k] += 1
  end
  targets
end

SUB_WEIGHTS = ACTIVE_SUBS.transform_values { |cfg| cfg[:target] * 100.0 / ACTIVE_SUBS.values.sum { |v| v[:target] } }.freeze
SUB_TARGETS = quota_targets(TOTAL_TARGET, SUB_WEIGHTS).freeze
DIFFICULTY_TARGETS = quota_targets(TOTAL_TARGET, DIFFICULTY_WEIGHTS).freeze
PROMPT_STYLE_TARGETS = quota_targets(TOTAL_TARGET, PROMPT_WEIGHTS).freeze
DISCOVERY_TARGETS = quota_targets(TOTAL_TARGET, DISCOVERY_WEIGHTS).freeze
DIRTY_SOURCE_SCOPE_TARGETS = quota_targets(DISCOVERY_TARGETS['dirty_source_change'], DIRTY_SOURCE_SCOPE_WEIGHTS).freeze

def run_cmd(*cmd, chdir: nil)
  out, err, status = Open3.capture3(*cmd, chdir: chdir)
  raise "command failed: #{cmd.join(' ')}\n#{err}" unless status.success?
  out
end

def prepare_repo(repo_path, bundle_path, ref)
  unless Dir.exist?(File.join(repo_path, '.git'))
    raise "Bundle not found: #{bundle_path}" unless File.exist?(bundle_path)

    FileUtils.mkdir_p(File.dirname(repo_path))
    run_cmd('git', 'clone', '--no-checkout', bundle_path, repo_path)
  end

  if File.exist?(bundle_path)
    run_cmd('git', 'fetch', bundle_path,
      '+refs/heads/*:refs/remotes/bundle/*',
      '+refs/remotes/*:refs/remotes/*',
      '+refs/tags/*:refs/tags/*',
      chdir: repo_path)
  end
  run_cmd('git', 'checkout', '--detach', ref, chdir: repo_path)
  run_cmd('git', 'reset', '--hard', ref, chdir: repo_path)
  run_cmd('git', 'clean', '-fdx', chdir: repo_path)

  commit = run_cmd('git', 'rev-parse', 'HEAD', chdir: repo_path).strip
  tree = run_cmd('git', 'rev-parse', 'HEAD^{tree}', chdir: repo_path).strip
  {
    'bundle' => bundle_path.sub("#{__dir__}/", ''),
    'repo_path' => repo_path,
    'ref' => ref,
    'commit' => commit,
    'tree' => tree,
  }
end

def rel_path(path)
  path.sub(%r{\A#{Regexp.escape(CHEAT)}/?}, '')
end

def record_failure(reason, data = {})
  File.open(FAILURE_LOG, 'a') do |f|
    f.puts JSON.generate({ reason: reason }.merge(data))
  end
end

def apply_mutation_to_file(fn, mutated_body)
  Tempfile.create(['cleopatra-mutant-body-', '.rb']) do |tmp|
    tmp.write(mutated_body)
    tmp.close
    out, err, status = Open3.capture3(
      'ruby',
      File.join(__dir__, 'bugfix', 'apply_mutation.rb'),
      fn[:file],
      tmp.path,
      fn[:name],
    )
    return [status.success?, out, err]
  end
end

def ruby_parse_ok_after_replacement(fn, mutated_body)
  original = File.read(fn[:file])
  ok, out, err = apply_mutation_to_file(fn, mutated_body)
  return [false, (err.empty? ? out : err).strip] unless ok

  _out, syntax_err, status = Open3.capture3('ruby', '-c', fn[:file])
  [status.success?, syntax_err.strip]
ensure
  File.write(fn[:file], original) if original
end

def changed_body_line_numbers(fn, mutated_body)
  original = fn[:body].split("\n", -1)
  mutated = mutated_body.split("\n", -1)
  max = [original.length, mutated.length].max
  changed = []
  max.times do |i|
    changed << fn[:start_line] + i + 1 if original[i] != mutated[i]
  end
  changed.empty? ? [fn[:start_line]] : changed
end

def dirty_line_ranges(fn, mutated_body, dirty_scope)
  changed = changed_body_line_numbers(fn, mutated_body)
  case dirty_scope
  when 'whole_function_dirty'
    [{ 'start' => fn[:start_line], 'end' => fn[:end_line], 'reason' => 'entire function edited' }]
  when 'multi_line_dirty'
    lines = changed.dup
    anchor = changed.first
    lines << [anchor - 1, fn[:start_line]].max
    lines << [anchor + 1, fn[:end_line]].min
    lines.uniq.sort.map { |line| { 'start' => line, 'end' => line, 'reason' => line == anchor ? 'mutated bug line' : 'nearby edited line' } }
  when 'exact_line_dirty'
    changed.map { |line| { 'start' => line, 'end' => line, 'reason' => 'mutated bug line' } }
  else
    []
  end
end

def synthetic_test_path(fn)
  base = File.basename(fn[:file_rel], '.rb')
  case fn[:file_rel]
  when %r{\Agems/([^/]+)/}
    "gems/#{$1}/spec/#{base}_generated_spec.rb"
  when %r{\Aexamples/minivm/}
    "examples/minivm/generated_#{base}_test.rb"
  when %r{\Aexamples/puck/}
    "examples/puck/generated_#{base}_test.rb"
  else
    "spec/generated/#{base}_spec.rb"
  end
end

def synthetic_test_content(fn, mutation_desc)
  short = fn[:name].split('.').last
  <<~RUBY
    # Generated failing test for Cleopatra mutant #{fn[:name]}.
    # Mutation under test: #{mutation_desc}
    require "minitest/autorun"

    class Generated#{short.gsub(/\W+/, '_').capitalize}Test < Minitest::Test
      def test_#{short.gsub(/\W+/, '_')}_regression
        flunk "Regression for #{fn[:name]}: #{mutation_desc}"
      end
    end
  RUBY
end

def build_discovery(fn, mutated_body, mutation_desc, scenario, dirty_scope)
  file_rel = fn[:file_rel]
  case scenario
  when 'dirty_source_change'
    {
      'scenario' => scenario,
      'worktree_dirty' => true,
      'dirty_scope' => dirty_scope,
      'expected_bug_location' => 'changed_source_lines',
      'mutant_tests_should_find' => true,
      'dirty_files' => [
        {
          'file_rel' => file_rel,
          'status' => 'modified',
          'role' => 'source',
          'line_ranges' => dirty_line_ranges(fn, mutated_body, dirty_scope)
        }
      ],
      'hint' => 'Active source edits exist; inspect dirty changed lines first.'
    }
  when 'new_unit_test'
    test_path = synthetic_test_path(fn)
    {
      'scenario' => scenario,
      'worktree_dirty' => true,
      'dirty_scope' => 'new_test_file',
      'expected_bug_location' => 'source_exposed_by_new_test',
      'mutant_tests_should_find' => true,
      'dirty_files' => [
        {
          'file_rel' => test_path,
          'status' => 'added',
          'role' => 'test',
          'line_ranges' => [{ 'start' => 1, 'end' => 8, 'reason' => 'new failing unit test' }]
        }
      ],
      'new_test' => {
        'file_rel' => test_path,
        'status' => 'added',
        'content' => synthetic_test_content(fn, mutation_desc)
      },
      'hint' => 'A new failing unit test was added; use it to understand expected behavior.'
    }
  else
    {
      'scenario' => 'production_stack_trace',
      'worktree_dirty' => false,
      'dirty_scope' => 'clean_tree',
      'expected_bug_location' => 'committed_source',
      'mutant_tests_should_find' => false,
      'dirty_files' => [],
      'hint' => 'Clean tree; treat this as a production/existing bug that slipped through tests.'
    }
  end
end

# ──────────────────────────────────────────────
# 1. Function Extraction (Prism)
# ──────────────────────────────────────────────

def extract_functions(source, file_path)
  parsed = Prism.parse(source)
  return [] unless parsed.success?

  fns = []
  walk_node = ->(node, nesting) {
    return unless node.respond_to?(:child_nodes)

    if node.is_a?(Prism::DefNode)
      name = nesting.empty? ? node.name.to_s : "#{nesting}.#{node.name}"
      lines = node.location.end_line - node.location.start_line + 1
      if lines >= 3 && lines <= 80
        body_slice = node.body&.slice || ''
        fns << {
          name: name, file: file_path,
          start_line: node.location.start_line,
          end_line: node.location.end_line, lines: lines, body: body_slice,
          params: extract_params_from_source(source, node.location.start_line - 1),
          callees: body_slice.scan(/(\w+[?!]?)\s*\(/).flatten.uniq,
          ivars: body_slice.scan(/@(\w+)/).flatten.uniq,
          guards: body_slice.scan(/\b(return|next|break)\s+if\b/).size,
        }
      end
      walk_node.call(node.body, name) if node.body
    elsif node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
      cn = (node.constant_path&.slice rescue node.name.to_s)
      full = nesting.empty? ? cn : "#{nesting}::#{cn}"
      walk_node.call(node.body, full) if node.body
    else
      node.child_nodes&.compact&.each { |c| walk_node.call(c, nesting) }
    end
  }
  walk_node.call(parsed.value, '')
  fns
end

def extract_params_from_source(source, line_idx)
  line = (source.lines[line_idx] || '')
  m = line.match(/def\s+\w+[?!]?\s*\(([^)]*)\)/)
  return [] unless m
  m[1].split(',').map(&:strip).reject(&:empty?).map { |p|
    if p =~ /^(\w+)\s*:\s*(\S+)/
      { name: $1, type: $2 }
    else
      { name: p.split(/\s/).first || p, type: '?' }
    end
  }
end

# ──────────────────────────────────────────────
# 2. Test Mapping
# ──────────────────────────────────────────────

TEST_DIRS = {
  'src'       => ['spec'],
  'nil_kill'  => ['gems/nil-kill/spec'],
  'minivm'    => ['examples/minivm'],
  'puck'      => [],
  'decomplex' => ['gems/decomplex/test'],
  'slopcop'   => ['gems/slopcop/test'],
  'boobytrap' => ['gems/boobytrap/test'],
}.freeze

$test_file_cache = {}

def test_file_cache(sub_key)
  return $test_file_cache[sub_key] if $test_file_cache.key?(sub_key)

  dirs = TEST_DIRS[sub_key] || []
  files = []
  dirs.each do |d|
    full = File.join(CHEAT, d)
    next unless Dir.exist?(full)
    Dir["#{full}/**/*_spec.rb", "#{full}/**/*_test.rb", "#{full}/**/*.rb"].uniq.each do |tf|
      content = File.read(tf) rescue next
      files << { path: tf, rel: rel_path(tf), content: content, lines: content.lines }
    end
  end
  $test_file_cache[sub_key] = files
end

def candidate_tests(sub_key, function_name, file_path)
  short = function_name.split('.').last
  candidates = []
  test_file_cache(sub_key).each do |tf|
    next if tf[:path] == file_path
    next unless tf[:content].include?(short)
    line_num = tf[:lines].index { |l| l.include?(short) }
    candidates << { file: tf[:rel], line: (line_num || 0) + 1, content: tf[:content] }
  end
  candidates.shuffle.first(MAX_TEST_CANDIDATES)
end

def test_command_for_file(rel)
  if rel.end_with?('_spec.rb') || rel.start_with?('spec/') || rel.include?('/spec/')
    ['bundle', 'exec', 'rspec', rel]
  elsif rel.end_with?('_test.rb')
    ['bundle', 'exec', 'ruby', rel]
  else
    ['bundle', 'exec', 'ruby', rel]
  end
end

def test_env
  env = { 'RUBYOPT' => '-W0' }
  env['BUNDLE_PATH'] = BUNDLE_PATH if BUNDLE_PATH && Dir.exist?(BUNDLE_PATH)
  env
end

def run_test_command(command)
  stdout = +''
  stderr = +''
  status = nil
  Open3.popen3(test_env, *command, chdir: CHEAT, pgroup: true) do |_stdin, out, err, wait_thr|
    out_reader = Thread.new { out.read }
    err_reader = Thread.new { err.read }
    begin
      Timeout.timeout(TEST_TIMEOUT) { status = wait_thr.value }
    rescue Timeout::Error
      begin
        Process.kill('TERM', -wait_thr.pid)
        sleep 1
        Process.kill('KILL', -wait_thr.pid)
      rescue Errno::ESRCH
      end
      stdout = out_reader.value rescue ''
      stderr = err_reader.value rescue ''
      return { ok: false, output: "#{stdout}#{stderr}\nTIMEOUT after #{TEST_TIMEOUT}s: #{command.join(' ')}" }
    end
    stdout = out_reader.value
    stderr = err_reader.value
  end
  { ok: status.success?, output: "#{stdout}#{stderr}" }
rescue StandardError => e
  { ok: false, output: "#{e.class}: #{e.message}" }
end

$baseline_test_cache = {}

def verified_failing_tests(sub_key, fn, mutated_body)
  tests = candidate_tests(sub_key, fn[:name], fn[:file])
  return [] if tests.empty?

  original = File.read(fn[:file])
  failures = []
  tests.each do |test|
    command = test_command_for_file(test[:file])
    baseline = $baseline_test_cache[test[:file]]
    unless baseline
      result = run_test_command(command)
      baseline = $baseline_test_cache[test[:file]] = result[:ok] ? :pass : :fail
    end
    next unless baseline == :pass

    File.write(fn[:file], original)
    ok, out, err = apply_mutation_to_file(fn, mutated_body)
    unless ok
      record_failure('test_verification_mutation_apply_failed',
        subproject: sub_key,
        file: fn[:file_rel],
        function: fn[:name],
        test_file: test[:file],
        error: (err.empty? ? out : err))
      next
    end

    mutated = run_test_command(command)
    next if mutated[:ok]

    failures << {
      'file_rel' => test[:file],
      'line' => test[:line],
      'command' => command,
      'failure_excerpt' => mutated[:output][-4000..] || mutated[:output]
    }
  ensure
    File.write(fn[:file], original)
  end
  failures.uniq { |failure| failure['file_rel'] }
end

# ──────────────────────────────────────────────
# 3. Mutation Engine
# ──────────────────────────────────────────────

def apply_mutation(fn, type)
  body = fn[:body]
  case type
  when :negate_condition
    m = body.match(/\bif\s+(.+?)(?:\n|$)/)
    return nil unless m && !m[1].strip.empty?
    cond = m[1].strip
    neg = cond.start_with?('!') ? cond.sub('!', '') : "!(#{cond})"
    [body.sub("if #{cond}", "if #{neg}"), "negated condition: '#{cond}'"]
  when :wrong_comparison
    swaps = { '==' => '!=', '!=' => '==', '>' => '<=', '<' => '>=', '>=' => '<', '<=' => '>' }
    swaps.each do |from, to|
      next unless body.include?(from)
      idx = body.index(from)
      near = body[[idx-15,0].max, 30].strip
      return [body.sub(from, to), "swapped comparison: '#{from}' -> '#{to}' near '#{near}'"]
    end; nil
  when :off_by_one
    if body =~ /\[(\w+)\s*\+\s*1\]/
      [body.sub($&, "[#{$1}]"), "off-by-one: removed +1 from index '#{$1}'"]
    elsif body =~ /\[(\w+)\]/
      [body.sub($&, "[#{$1} + 1]"), "off-by-one: added +1 to index '#{$1}'"]
    elsif body.include?('..')
      [body.sub('..', '...'), "off-by-one: inclusive -> exclusive"]
    elsif body.include?('...')
      [body.sub('...', '..'), "off-by-one: exclusive -> inclusive"]
    else; nil
    end
  when :wrong_operator
    swaps = { '+' => '-', '-' => '+', '*' => '/', '/' => '*' }
    ops = body.scan(/\s[+\-*\/]\s/).map(&:strip).uniq
    return nil if ops.empty?
    op = ops.sample; new_op = swaps[op]
    return nil unless new_op
    [body.sub(" #{op} ", " #{new_op} "), "swapped operator: '#{op}' -> '#{new_op}'"]
  when :missing_guard
    m = body.match(/\b(return|next|break)\s+if\s+(.+?)(\n|$)/)
    return nil unless m
    [body.sub(m[0], ''), "removed guard clause"]
  when :wrong_variable
    vars = body.scan(/\b([a-z_]\w*)\b/).flatten.uniq - RUBY_KEYWORDS
    cands = vars.select { |v| body.scan(/\b#{Regexp.escape(v)}\b/).size >= 2 }
    return nil if cands.size < 2
    old_v = cands[0]; new_v = cands[1]
    [body.gsub(/\b#{Regexp.escape(old_v)}\b/, new_v), "renamed variable: '#{old_v}' -> '#{new_v}'"]
  when :wrong_constant
    consts = body.scan(/\b([A-Z]\w+)\b/).flatten.uniq
    return nil if consts.size < 2
    old_c = consts.sample; new_c = (consts - [old_c]).sample
    [body.gsub(/\b#{Regexp.escape(old_c)}\b/, new_c), "swapped constant: '#{old_c}' -> '#{new_c}'"]
  when :wrong_bool_op
    if body.include?('&&')
      [body.sub('&&', '||'), "swapped && -> ||"]
    elsif body.include?('||')
      [body.sub('||', '&&'), "swapped || -> &&"]
    else; nil
    end
  when :forgotten_line
    lines = body.split("\n")
    return nil if lines.size < 4
    idx = (lines.size * 0.5).to_i
    removed = lines.delete_at(idx)
    [lines.join("\n"), "forgotten line: '#{removed&.strip}'"]
  when :wrong_error
    m = body.match(/\braise\s+(\w+)/)
    return nil unless m
    [body.sub(m[0], 'raise RuntimeError'), "wrong error: '#{m[1]}' -> RuntimeError"]
  when :swallowed_error
    if body.include?('rescue')
      [body.sub(/\brescue\s+.*?(?=\n)/, 'rescue'), "swallowed error"]
    else; nil
    end
  else; nil
  end
end

# ──────────────────────────────────────────────
# 4. Trajectory Generator (algorithmic)
# ──────────────────────────────────────────────

def pick_weighted(h)
  r = rand(1..100)
  h.each { |k, w| r -= w; return k.to_s if r <= 0 }
  h.keys.last.to_s
end

def pick_with_remaining_quota(targets, counts)
  remaining = targets.select { |k, target| counts[k] < target }
  return nil if remaining.empty?

  total_left = remaining.sum { |k, target| target - counts[k] }
  roll = rand(total_left)
  remaining.each do |k, target|
    roll -= (target - counts[k])
    return k if roll < 0
  end
  remaining.keys.last
end

def estimate_context_tokens(fn, difficulty)
  t = fn[:lines] * 10
  case difficulty
  when 'easy_syntax', 'trivial_line' then t + 200
  when 'trivial_function' then t * 2 + 300
  when 'stack_1_2' then t * 3 + 500
  when 'hard_2_plus' then t * 5 + 800
  else t * 2 + 300
  end
end

def ideal_tool_count(difficulty)
  case difficulty
  when 'easy_syntax' then 0
  when 'trivial_line' then 1
  when 'trivial_function' then 2
  when 'stack_1_2' then 3
  when 'hard_2_plus' then 5
  else 2
  end
end

# ──────────────────────────────────────────────
# 5. 5-Variant Trajectory Computation
# ──────────────────────────────────────────────

def make_trajectories(fn, difficulty)
  clean_calls = ideal_tool_count(difficulty)
  file = fn[:file_rel]
  short = fn[:name].split('.').last
  callees = fn[:callees] || []

  # Variant 1: y_clean — walk stack trace from crash site to root cause
  clean_steps = []
  if clean_calls == 0
    clean_steps = [
      { 'action' => 'decide', 'decision' => 'syntax_error_visible' },
      { 'action' => 'fix', 'code' => '...correct fix...', 'decomplex_score' => 85 }
    ]
  else
    clean_calls.times do |i|
      if i == 0
        clean_steps << { 'action' => 'tool_call', 'tool' => 'ctx',
          'args' => "#{file}##{fn[:start_line]}", 'result' => 'function body' }
      elsif i == clean_calls - 1
        clean_steps << { 'action' => 'tool_call', 'tool' => 'ctx',
          'args' => "#{file}:#{short} debug", 'result' => 'body with types' }
      else
        clean_steps << { 'action' => 'tool_call', 'tool' => 'ctx',
          'args' => "#{file}:#{short}", 'result' => 'function body' }
      end
    end
    clean_steps << { 'action' => 'decide', 'decision' => 'enough_context' }
    clean_steps << { 'action' => 'fix', 'code' => '...correct fix...', 'decomplex_score' => 85 }
  end

  # Variant 2: y_broken_wrong_fn — call my_tool on a random callee instead of the buggy fn
  wrong_fn = callees[0] || short
  wrong_steps = [
    { 'action' => 'tool_call', 'tool' => 'ctx',
      'args' => "#{file}:#{wrong_fn}", 'result' => 'wrong function body' },
    { 'action' => 'decide', 'decision' => 'found_the_function' },
    { 'action' => 'fix', 'code' => '...fix applied to wrong function...', 'decomplex_score' => 15 }
  ]

  # Variant 3: y_sloppy_over — call on fn + all callees + debug
  over_steps = [
    { 'action' => 'tool_call', 'tool' => 'ctx', 'args' => "#{file}:#{short}" }
  ]
  callees.each { |c|
    over_steps << { 'action' => 'tool_call', 'tool' => 'ctx', 'args' => "#{file}:#{c}" }
  }
  over_steps << { 'action' => 'tool_call', 'tool' => 'ctx', 'args' => "#{file}:#{short} debug" }
  over_steps << { 'action' => 'decide', 'decision' => 'enough_context_after_wasteful_search' }
  over_steps << { 'action' => 'fix', 'code' => '...correct but verbose...', 'decomplex_score' => 70 }

  # Variant 4: y_sloppy_under
  # If bug is at crash line: use FAR too much (cat + grep) instead
  # If bug is deeper: call only crash site, miss root cause
  if %w[trivial_line easy_syntax].include?(difficulty)
    under_steps = [
      { 'action' => 'tool_call', 'tool' => 'cat', 'args' => file },
      { 'action' => 'tool_call', 'tool' => 'grep', 'args' => "-r '#{short}' #{file.split('/').first}/" },
      { 'action' => 'decide', 'decision' => 'overloaded_with_context' },
      { 'action' => 'fix', 'code' => '...fix lost in noise...', 'decomplex_score' => 15 }
    ]
  else
    under_steps = [
      { 'action' => 'tool_call', 'tool' => 'ctx',
        'args' => "#{file}##{fn[:start_line]}", 'result' => 'crash site only' },
      { 'action' => 'decide', 'decision' => 'enough_context_without_checking' },
      { 'action' => 'fix', 'code' => '...partial fix misses root cause...', 'decomplex_score' => 20 }
    ]
  end

  # Variant 5: y_blind_native — zero tool calls, pure guess
  native_steps = [
    { 'action' => 'decide', 'decision' => 'skip_context_discovery' },
    { 'action' => 'fix', 'code' => '...guess without context...', 'decomplex_score' => 10 }
  ]

  {
    'y_clean'           => { 'label' => 'y_clean',           'reward' => 10,  'description' => 'Called exactly the right tools - ideal context',          'tool_calls' => clean_calls,              'steps' => clean_steps },
    'y_broken_wrong_fn' => { 'label' => 'y_broken_wrong_fn', 'reward' => -5,  'description' => 'Called my_tool on wrong function',                         'tool_calls' => 1,                         'steps' => wrong_steps },
    'y_sloppy_over'     => { 'label' => 'y_sloppy_over',     'reward' => 2,   'description' => 'Called my_tool on too many functions - over-context',     'tool_calls' => 1 + callees.size + 1,      'steps' => over_steps },
    'y_sloppy_under'    => { 'label' => 'y_sloppy_under',    'reward' => -5,  'description' => 'Called too few tools - under-context',                      'tool_calls' => 1,                         'steps' => under_steps },
    'y_blind_native'    => { 'label' => 'y_blind_native',    'reward' => -10, 'description' => 'No tool calls - model guesses without context',             'tool_calls' => 0,                         'steps' => native_steps },
  }
end

# ──────────────────────────────────────────────
# 6. Build Bug Entry
# ──────────────────────────────────────────────

def build_bug(sub_key, fn, difficulty, prompt_style, mutation_desc, mutated_body, test_failures, discovery)
  short = fn[:name].split('.').last
  file_rel = fn[:file_rel]
  first_failure = test_failures.first
  stack = "  #{first_failure ? first_failure['file_rel'] : 'spec/'}:#{first_failure ? first_failure['line'] : 1}\n" \
          "  #{file_rel}:#{fn[:start_line]}:in `#{short}'"

  base_prompt = case prompt_style
  when 'stack_trace'
    "Test failure:\n  #{mutation_desc}\n\n#{stack}\n\nFix the bug."
  when 'detailed'
    "Bug in `#{fn[:name]}` at #{file_rel}:#{fn[:start_line]}.\nIssue: #{mutation_desc}\n\n#{stack}\n\nFix it."
  when 'vague'
    "Something wrong in `#{short}`. #{mutation_desc}\n\nFix it."
  when 'with_culprit'
    "Suspect bug in `#{short}` at #{file_rel}:#{fn[:start_line]}.\nIssue: #{mutation_desc}\n\n#{stack}\n\nFix it."
  when 'spec_broken'
    "CI failing #{first_failure ? first_failure['file_rel'] : 'spec/'}:#{first_failure ? first_failure['line'] : '?'}.\n\n#{stack}\n\nFix the code."
  when 'minimal'
    "CI broken.\n\n#{stack}\n\nFix the bug."
  else "Fix bug in `#{short}`:\n\n#{stack}"
  end
  prompt = case discovery['scenario']
           when 'dirty_source_change'
             "A mutant/regression test is failing after local source edits.\n#{discovery['hint']}\n\n#{base_prompt}"
           when 'new_unit_test'
             "A new unit test was added and is failing.\n#{discovery['hint']}\n\nNew test file: #{discovery.dig('new_test', 'file_rel')}\n```ruby\n#{discovery.dig('new_test', 'content')}```\n\n#{base_prompt}"
           else
             "Production stack trace from a clean committed tree.\n#{discovery['hint']}\n\n#{base_prompt}"
           end

  {
    'id'               => SecureRandom.uuid[0..7],
    'type'             => 'bug_fix',
    'source'           => 'synthetic_mutant',
    'subproject'       => sub_key,
    'difficulty'       => difficulty,
    'code_or_test'     => 'code',
    'bug_depth'        => difficulty.gsub('_', ' '),
    'prompt_style'     => prompt_style,
    'discovery'        => discovery,
    'repo'             => SOURCE_INFO,
    'file'             => file_rel,
    'file_rel'         => file_rel,
    'function'         => fn[:name],
    'function_start_line' => fn[:start_line],
    'function_end_line' => fn[:end_line],
    'mutation'         => mutation_desc,
    'prompt'           => prompt,
    'stack_trace'      => stack,
    'test_failures'    => test_failures,
    'mutated_body'     => mutated_body,
    'original_body'    => fn[:body],
    'ideal_tool_calls' => [{ 'tool' => 'ctx', 'args' => "#{file_rel}##{fn[:start_line]}" }],
    'function_params'  => fn[:params],
    'function_callees' => fn[:callees],
    'function_ivars'   => fn[:ivars],
    'trajectories'     => make_trajectories(fn, difficulty),
  }
end

# ──────────────────────────────────────────────
# 7. Main
# ──────────────────────────────────────────────

FileUtils.mkdir_p(File.dirname(BUGS_FILE))
FileUtils.mkdir_p(File.dirname(FAILURE_LOG))
File.write(FAILURE_LOG, '') unless opts[:append]

SOURCE_INFO = prepare_repo(CHEAT, BUNDLE, SOURCE_REF)
puts "Source repo: #{SOURCE_INFO['repo_path']}"
puts "Source ref:  #{SOURCE_INFO['ref']}"
puts "Commit:      #{SOURCE_INFO['commit']}"
puts "Tree:        #{SOURCE_INFO['tree']}"

existing = if opts[:append] && File.exist?(BUGS_FILE)
             File.readlines(BUGS_FILE).map { |l| JSON.parse(l.strip) rescue nil }.compact
           else
             []
           end
puts "Existing bugs: #{existing.size}"

needed_total = TOTAL_TARGET - existing.size
if needed_total <= 0
  puts "Already have #{existing.size} bugs, no more needed."
  exit 0
end
puts "Need #{needed_total} more bugs."

all_fns = {}
ACTIVE_SUBS.each do |key, cfg|
  fns = []
  dir = File.join(CHEAT, cfg[:dir])
  Dir["#{dir}/**/*.rb"].each do |file|
    next if file.include?('/spec/') || file.include?('/test/')
    src = File.read(file) rescue next
    extracted = extract_functions(src, file)
    extracted.each { |fn| fn[:file_rel] = rel_path(fn[:file]) }
    fns.concat(extracted)
  end
  fns = fns.select { |fn| !candidate_tests(key, fn[:name], fn[:file]).empty? } if VERIFY_TESTS
  all_fns[key] = fns
  puts "  #{key}: #{fns.size} functions"
end

have = Hash.new(0)
existing.each { |b| have[b['subproject']] += 1 }
difficulty_have = Hash.new(0)
prompt_have = Hash.new(0)
discovery_have = Hash.new(0)
dirty_scope_have = Hash.new(0)
existing.each do |b|
  difficulty_have[b['difficulty']] += 1 if b['difficulty']
  prompt_have[b['prompt_style']] += 1 if b['prompt_style']
  discovery_have[b.dig('discovery', 'scenario')] += 1 if b.dig('discovery', 'scenario')
  dirty_scope_have[b.dig('discovery', 'dirty_scope')] += 1 if b.dig('discovery', 'scenario') == 'dirty_source_change'
end

new_bugs = []
errors = 0
max_errors = needed_total * (VERIFY_TESTS ? 1000 : 15)

while new_bugs.size < needed_total && errors < max_errors
  need_left = {}
  ACTIVE_SUBS.each_key do |k|
    need = SUB_TARGETS[k] - (have[k] + new_bugs.count { |b| b['subproject'] == k })
    need_left[k] = need if need > 0
  end
  break if need_left.empty?

  sub_key = need_left.keys.sample
  fns = all_fns[sub_key]
  next if fns.nil? || fns.empty?
  fn = fns.sample
  next unless fn && fn[:lines] >= 3

  difficulty = pick_with_remaining_quota(DIFFICULTY_TARGETS, difficulty_have)
  prompt_style = pick_with_remaining_quota(PROMPT_STYLE_TARGETS, prompt_have)
  discovery_scenario = pick_with_remaining_quota(DISCOVERY_TARGETS, discovery_have)
  dirty_scope = if discovery_scenario == 'dirty_source_change'
                  pick_with_remaining_quota(DIRTY_SOURCE_SCOPE_TARGETS, dirty_scope_have)
                end
  break unless difficulty && prompt_style && discovery_scenario
  break if discovery_scenario == 'dirty_source_change' && dirty_scope.nil?

  if estimate_context_tokens(fn, difficulty) > 16_000
    errors += 1; next
  end

  mt = MUTATIONS.sample(3)
  found = false
  mt.each do |mtype|
    next if found
    r = apply_mutation(fn, mtype)
    next unless r
    mutated, desc = r
    next if mutated.strip.empty? || mutated == fn[:body]
    ok, parse_error = ruby_parse_ok_after_replacement(fn, mutated)
    unless ok
      record_failure('mutated_file_does_not_parse',
        subproject: sub_key,
        file: fn[:file_rel],
        function: fn[:name],
        mutation: mtype,
        error: parse_error)
      next
    end
    test_failures = VERIFY_TESTS ? verified_failing_tests(sub_key, fn, mutated) : []
    if VERIFY_TESTS && test_failures.empty?
      record_failure('no_verified_failing_test',
        subproject: sub_key,
        file: fn[:file_rel],
        function: fn[:name],
        mutation: mtype)
      next
    end
    discovery = build_discovery(fn, mutated, desc, discovery_scenario, dirty_scope)
    new_bugs << build_bug(sub_key, fn, difficulty, prompt_style, desc, mutated, test_failures, discovery)
    difficulty_have[difficulty] += 1
    prompt_have[prompt_style] += 1
    discovery_have[discovery_scenario] += 1
    dirty_scope_have[dirty_scope] += 1 if discovery_scenario == 'dirty_source_change'
    found = true
  end
  errors += 1 unless found
end

if new_bugs.empty?
  puts "No new bugs."
  exit 0
end

File.open(BUGS_FILE, opts[:append] ? 'a' : 'w') { |f| new_bugs.each { |b| f.puts JSON.generate(b) } }
puts "Generated #{new_bugs.size} new bugs, wrote #{BUGS_FILE}"

total = File.readlines(BUGS_FILE).map { |l| JSON.parse(l.strip) rescue nil }.compact.size
puts "Total bugs: #{total}"
final_have = Hash.new(0)
File.readlines(BUGS_FILE).map { |l| JSON.parse(l.strip) rescue nil }.compact.each { |b| final_have[b['subproject']] += 1 }
final_have.each { |k, v| puts "  #{k}: #{v} (target: #{SUB_TARGETS[k]})" }
