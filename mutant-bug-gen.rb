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
require 'prism'
require 'set'
require 'securerandom'

CHEAT = File.expand_path('~/cheat')
BUGS_FILE = File.join(__dir__, 'bugs.jsonl')
TOTAL_TARGET = (ARGV[0] || 1200).to_i

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

# === Mutation types ===
MUTATIONS = %i[
  negate_condition wrong_comparison off_by_one wrong_operator
  missing_guard wrong_variable wrong_constant wrong_bool_op
  forgotten_line wrong_error swallowed_error
].freeze

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

def find_test(sub_key, function_name, file_path)
  dirs = TEST_DIRS[sub_key] || []
  return nil if dirs.empty?
  short = function_name.split('.').last
  candidates = []
  dirs.each do |d|
    full = File.join(CHEAT, d)
    next unless Dir.exist?(full)
    Dir["#{full}/**/*_spec.rb", "#{full}/**/*_test.rb", "#{full}/**/*.rb"].each do |tf|
      next if tf == file_path
      content = File.read(tf) rescue next
      next unless content.include?(short)
      line_num = content.lines.index { |l| l.include?(short) }
      candidates << { file: tf, line: (line_num || 0) + 1, content: content }
    end
  end
  candidates.sample
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
    vars = body.scan(/\b([a-z_]\w*)\b/).flatten.uniq - %w[if unless end def return nil true false while do next break raise rescue ensure self]
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
  file = fn[:file].sub(CHEAT + '/', '')
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

def build_bug(sub_key, fn, difficulty, prompt_style, mutation_desc, mutated_body, test_info)
  short = fn[:name].split('.').last
  file_rel = fn[:file].sub(CHEAT + '/', '')
  stack = "  #{test_info ? test_info[:file] : 'spec/'}:#{test_info ? test_info[:line] : 1}\n" \
          "  #{file_rel}:#{fn[:start_line]}:in `#{short}'"

  prompt = case prompt_style
  when 'stack_trace'
    "Test failure:\n  #{mutation_desc}\n\n#{stack}\n\nFix the bug."
  when 'detailed'
    "Bug in `#{fn[:name]}` at #{file_rel}:#{fn[:start_line]}.\nIssue: #{mutation_desc}\n\n#{stack}\n\nFix it."
  when 'vague'
    "Something wrong in `#{short}`. #{mutation_desc}\n\nFix it."
  when 'with_culprit'
    "Suspect bug in `#{short}` at #{file_rel}:#{fn[:start_line]}.\nIssue: #{mutation_desc}\n\n#{stack}\n\nFix it."
  when 'spec_broken'
    "CI failing #{test_info ? test_info[:file] : 'spec/'}:#{test_info ? test_info[:line] : '?'}.\n\n#{stack}\n\nFix the code."
  when 'minimal'
    "CI broken.\n\n#{stack}\n\nFix the bug."
  else "Fix bug in `#{short}`:\n\n#{stack}"
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
    'file'             => fn[:file],
    'function'         => fn[:name],
    'mutation'         => mutation_desc,
    'prompt'           => prompt,
    'stack_trace'      => stack,
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

existing = File.exist?(BUGS_FILE) ? File.readlines(BUGS_FILE).map { |l| JSON.parse(l.strip) rescue nil }.compact : []
puts "Existing bugs: #{existing.size}"

needed_total = TOTAL_TARGET - existing.size
if needed_total <= 0
  puts "Already have #{existing.size} bugs, no more needed."
  exit 0
end
puts "Need #{needed_total} more bugs."

all_fns = {}
SUBS.each do |key, cfg|
  fns = []
  dir = File.join(CHEAT, cfg[:dir])
  Dir["#{dir}/**/*.rb"].each do |file|
    next if file.include?('/spec/') || file.include?('/test/')
    src = File.read(file) rescue next
    fns.concat(extract_functions(src, file))
  end
  all_fns[key] = fns
  puts "  #{key}: #{fns.size} functions"
end

have = Hash.new(0)
existing.each { |b| have[b['subproject']] += 1 }

new_bugs = []
errors = 0
max_errors = needed_total * 15

while new_bugs.size < needed_total && errors < max_errors
  need_left = {}
  SUBS.each do |k, v|
    need = v[:target] - (have[k] + new_bugs.count { |b| b['subproject'] == k })
    need_left[k] = need if need > 0
  end
  break if need_left.empty?

  sub_key = need_left.keys.sample
  fns = all_fns[sub_key]
  next if fns.nil? || fns.empty?
  fn = fns.sample
  next unless fn && fn[:lines] >= 3

  difficulty = pick_weighted(DIFFICULTY_WEIGHTS)
  prompt_style = pick_weighted(PROMPT_WEIGHTS)

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
    test_info = find_test(sub_key, fn[:name], fn[:file])
    new_bugs << build_bug(sub_key, fn, difficulty, prompt_style, desc, mutated, test_info)
    found = true
  end
  errors += 1 unless found
end

if new_bugs.empty?
  puts "No new bugs."
  exit 0
end

File.open(BUGS_FILE, 'a') { |f| new_bugs.each { |b| f.puts JSON.generate(b) } }
puts "Generated #{new_bugs.size} new bugs, appended to #{BUGS_FILE}"

total = File.readlines(BUGS_FILE).map { |l| JSON.parse(l.strip) rescue nil }.compact.size
puts "Total bugs: #{total}"
final_have = Hash.new(0)
File.readlines(BUGS_FILE).map { |l| JSON.parse(l.strip) rescue nil }.compact.each { |b| final_have[b['subproject']] += 1 }
final_have.each { |k, v| puts "  #{k}: #{v} (target: #{SUBS[k][:target]})" }
