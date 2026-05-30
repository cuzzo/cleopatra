#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'net/http'
require 'open3'
require 'optparse'
require 'prism'
require 'tempfile'
require 'timeout'
require 'uri'

ROOT = File.expand_path('../..', __dir__)
BUGS_FILE = File.join(ROOT, 'bugs.jsonl')
OUT = File.join(ROOT, 'bugfix')
VENV_PY = File.join(ROOT, '.venv/bin/python3')
LLAMA_CLI = ENV.fetch('LLAMA_CLI', '/tmp/llama.cpp/build/bin/llama-cli')
LFM_SERVER_URL = ENV.fetch('LFM_SERVER_URL', 'http://127.0.0.1:18081')
MODEL_PATH_3B = File.join(ROOT, 'data/models/qwen2.5-coder-3b-instruct.gguf')
MODEL_PATH_7B = File.join(ROOT, 'data/models/qwen2.5-coder-7b-instruct.gguf')
MODEL_PATH_A1B = File.join(ROOT, 'data/models/LFM2.5-8B-A1B-Q4_K_M.gguf')
MODEL_32B = 'qwen/qwen3-32b'
MODEL_405B = 'nousresearch/hermes-3-llama-3.1-405b'
SYSTEM_PROMPT = 'You are a senior Ruby developer. Fix the bug in the code shown below. Return ONLY the corrected Ruby code in a ```ruby block.'
LOCAL_CONTEXT_TOKENS = 16_384
OPENROUTER_32B_CONTEXT_TOKENS = 40_960
OPENROUTER_405B_CONTEXT_TOKENS = 131_072
OUTPUT_TOKENS = 8_192
OPENROUTER_32B_OUTPUT_TOKENS = 2_048
CHARS_PER_TOKEN_BUDGET = 3
MAX_CTX_FUNCTIONS = 3
OPENROUTER_RETRIES = 8
OPENROUTER_32B_PROVIDERS = %w[DeepInfra Nebius Alibaba].freeze
CTX_COMPACT = :compact
CTX_LARGE = :large

opts = { count: 50, cats: '', dry_run_prompts: false, responses_only: false }
OptionParser.new do |o|
  o.banner = 'Usage: ruby src/synthetic-bugs/run-bugs.rb [options]'
  o.on('--count N', Integer) { |v| opts[:count] = v }
  o.on('--cats LIST') { |v| opts[:cats] = v }
  o.on('--dry-run-prompts') { opts[:dry_run_prompts] = true }
  o.on('--responses-only') { opts[:responses_only] = true }
end.parse!

def repo_path_for(bug)
  bug.fetch('repo', {})['repo_path'] || File.join(ROOT, '.eval', 'cheat')
end

def file_rel_for(bug)
  bug['file_rel'] || bug['file'].sub(%r{\A/home/yahn/cheat/}, '')
end

def source_path_for(bug)
  File.join(repo_path_for(bug), file_rel_for(bug))
end

def simulated_worktree_state(bug)
  discovery = bug['discovery'] || {
    'scenario' => 'production_stack_trace',
    'worktree_dirty' => false,
    'dirty_scope' => 'clean_tree',
    'dirty_files' => [],
    'hint' => 'Clean tree; treat this as a production/existing bug that slipped through tests.'
  }
  file_rel = file_rel_for(bug)
  dirty_files = discovery['dirty_files'] || []
  target_dirty = dirty_files.select { |entry| entry['file_rel'] == file_rel }
  lines = [
    '=' * 60,
    'WORKTREE STATE',
    '=' * 60,
    "Scenario: #{discovery.fetch('scenario', 'unknown')}",
    "Worktree: #{discovery['worktree_dirty'] ? 'dirty' : 'clean'}"
  ]
  if target_dirty.any?
    lines << "Target file: dirty (#{file_rel})"
    target_dirty.each do |entry|
      (entry['line_ranges'] || []).each do |range|
        lines << "  lines #{range['start']}-#{range['end']}: #{range['reason']}"
      end
    end
  else
    lines << "Target file: clean (#{file_rel})"
  end
  other_dirty = dirty_files.reject { |entry| entry['file_rel'] == file_rel }
  if other_dirty.any?
    lines << 'Other dirty files:'
    other_dirty.first(10).each do |entry|
      lines << "  #{entry.fetch('status', 'modified')} #{entry['file_rel']} (#{entry.fetch('role', 'unknown')})"
    end
  end
  lines << "Interpretation: #{discovery.fetch('hint', 'unknown')}"
  lines.join("\n")
end

def prompt_blind(bug, max_chars: local_context_chars)
  file_rel = file_rel_for(bug)
  func = bug['function'].split('.').last
  source = centered_buggy_source_for_prompt(bug, max_chars)
  <<~PROMPT
    File: #{file_rel}
    Function: #{func}

    #{source[:label]}:
    ```ruby
    #{source[:text]}
    ```

    #{bug['prompt']}

    Return ONLY the corrected function `#{func}` in a ```ruby block.
  PROMPT
end

def build_buggy_source_file(bug)
  source = File.read(source_path_for(bug)).tr("\r", '')
  source.sub(bug['original_body'].tr("\r", ''), bug['mutated_body'].tr("\r", ''))
rescue StandardError
  bug['mutated_body']
end

def fixed_prompt_overhead_chars
  @fixed_prompt_overhead_chars ||= 1_500
end

def local_context_chars
  ((LOCAL_CONTEXT_TOKENS - 1024) * CHARS_PER_TOKEN_BUDGET) - fixed_prompt_overhead_chars
end

def openrouter_32b_context_chars
  ((OPENROUTER_32B_CONTEXT_TOKENS - OUTPUT_TOKENS) * CHARS_PER_TOKEN_BUDGET) - fixed_prompt_overhead_chars
end

def openrouter_405b_context_chars
  ((OPENROUTER_405B_CONTEXT_TOKENS - OUTPUT_TOKENS) * CHARS_PER_TOKEN_BUDGET) - fixed_prompt_overhead_chars
end

def prompt_context_chars_for_category(cat)
  if cat.start_with?('3B') || cat.start_with?('7B')
    local_context_chars
  elsif cat.start_with?('32B')
    openrouter_32b_context_chars
  elsif cat.start_with?('405B')
    openrouter_405b_context_chars
  else
    local_context_chars
  end
end

def ctx_mode_for_category(cat)
  return CTX_LARGE if cat.start_with?('32B') || cat.start_with?('405B')

  CTX_COMPACT
end

def centered_buggy_source_for_prompt(bug, max_chars)
  source = build_buggy_source_file(bug)
  return { label: 'Full source file', text: source } if source.length <= max_chars

  lines = source.lines(chomp: true)
  start_line = [bug['function_start_line'].to_i, 1].max
  end_line = [bug['function_end_line'].to_i, start_line].max
  center_index = ((start_line + end_line) / 2) - 1

  selected_start = center_index
  selected_end = center_index
  current = lines[center_index].to_s.length + 1

  while current < max_chars && (selected_start.positive? || selected_end < lines.length - 1)
    if selected_start.positive?
      next_len = lines[selected_start - 1].length + 1
      break if current + next_len > max_chars

      selected_start -= 1
      current += next_len
    end
    if selected_end < lines.length - 1
      next_len = lines[selected_end + 1].length + 1
      break if current + next_len > max_chars

      selected_end += 1
      current += next_len
    end
  end

  prefix = "# ... file truncated before line #{selected_start + 1}; centered around #{bug['function']} lines #{start_line}-#{end_line} ..."
  suffix = "# ... file truncated after line #{selected_end + 1}; original file has #{lines.length} lines ..."
  window = lines[selected_start..selected_end].join("\n")
  {
    label: "Source file excerpt centered around `#{bug['function']}`",
    text: [prefix, window, suffix].join("\n")
  }
end

FunctionDef = Struct.new(:name, :short_name, :start_line, :end_line, :slice, :ivars, :callees, keyword_init: true)
ClassInfo = Struct.new(:name, :type, :start_line, :end_line, keyword_init: true)
ConstantInfo = Struct.new(:name, :start_line, :end_line, :slice, keyword_init: true)

def walk_function_defs(node, defs, nesting = '')
  return unless node.respond_to?(:child_nodes)

  if node.is_a?(Prism::DefNode)
    short = node.name.to_s.sub(/\Aself\./, '')
    full = nesting.empty? ? short : "#{nesting}.#{short}"
    slice = node.slice
    defs << FunctionDef.new(
      name: full,
      short_name: short,
      start_line: node.location.start_line,
      end_line: node.location.end_line,
      slice: slice,
      ivars: slice.scan(/@([a-zA-Z_]\w*)/).flatten.uniq.sort.map { |ivar| "@#{ivar}" },
      callees: slice.scan(/(?:\.|\b)([a-zA-Z_]\w*[?!]?)\s*\(/).flatten.uniq.sort
    )
    walk_function_defs(node.body, defs, full) if node.body
  elsif node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
    name = node.constant_path&.slice || ''
    full = nesting.empty? ? name : "#{nesting}::#{name}"
    walk_function_defs(node.body, defs, full) if node.body
  else
    node.child_nodes&.compact&.each { |child| walk_function_defs(child, defs, nesting) }
  end
end

def parse_function_defs(source)
  parsed = Prism.parse(source)
  return [] unless parsed.success?

  defs = []
  walk_function_defs(parsed.value, defs)
  defs
end

def walk_class_infos(node, classes, nesting = '')
  return unless node.respond_to?(:child_nodes)

  if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
    name = node.constant_path&.slice || ''
    full = nesting.empty? ? name : "#{nesting}::#{name}"
    classes << ClassInfo.new(
      name: full,
      type: node.is_a?(Prism::ClassNode) ? 'class' : 'module',
      start_line: node.location.start_line,
      end_line: node.location.end_line
    )
    walk_class_infos(node.body, classes, full) if node.body
  else
    node.child_nodes&.compact&.each { |child| walk_class_infos(child, classes, nesting) }
  end
end

def parse_class_infos(source)
  parsed = Prism.parse(source)
  return [] unless parsed.success?

  classes = []
  walk_class_infos(parsed.value, classes)
  classes
end

def ruby_structural_delta(line)
  stripped = line.sub(/#.*/, '')
  opens = stripped.count('({[')
  closes = stripped.count(')}]')
  opens - closes
end

def parse_constant_infos(source)
  lines = source.lines(chomp: true)
  constants = []
  lines.each_with_index do |line, index|
    next unless line =~ /^\s*([A-Z]\w*)\s*=/

    start_idx = index
    end_idx = index
    depth = ruby_structural_delta(line)
    while depth.positive? && end_idx < lines.length - 1 && (end_idx - start_idx) < 40
      end_idx += 1
      depth += ruby_structural_delta(lines[end_idx])
    end

    constants << ConstantInfo.new(
      name: Regexp.last_match(1),
      start_line: start_idx + 1,
      end_line: end_idx + 1,
      slice: lines[start_idx..end_idx].join("\n")
    )
  end
  constants
end

def find_function_def(defs, key)
  if key.is_a?(Integer)
    return defs.find { |fn| fn.start_line <= key && fn.end_line >= key }
  end

  key = key.to_s
  normalized = key.tr(':', '.')
  short = normalized.split('.').last
  defs.find { |fn| fn.name == key || fn.name == normalized } ||
    defs.find { |fn| fn.name.end_with?(".#{normalized}") || fn.name.end_with?("::#{normalized}") } ||
    defs.find { |fn| fn.name.end_with?(".#{short}") || fn.name.end_with?("::#{short}") } ||
    defs.find { |fn| fn.short_name == short }
end

def ideal_context_function_keys(bug)
  keys = [bug['function']]
  (bug['ideal_tool_calls'] || []).each do |call|
    args = call['args'].to_s.sub(/\s+debug\z/, '')
    if args.include?('#')
      keys << args.split('#', 2).last.to_i
    elsif args.include?(':')
      keys << args.split(':', 2).last
    end
  end
  keys.concat(bug['function_callees'] || [])
  keys
end

def stack_frame_refs(bug)
  text = bug['stack_trace'].to_s
  refs = []
  text.scan(%r{(?:\./)?((?:src|gems|examples)/[^:\s]+\.rb):(\d+)}) do |file_rel, line|
    refs << [file_rel, line.to_i]
  end
  refs = refs.uniq
  target_file = file_rel_for(bug)
  target_start = bug['function_start_line'].to_i
  target_end = bug['function_end_line'].to_i
  target_index = refs.index do |file_rel, line|
    file_rel == target_file && line >= target_start && line <= target_end
  end
  target_index ? refs[0..target_index] : refs.first(1)
end

def source_for_file_rel(bug, rel)
  return build_buggy_source_file(bug) if rel == file_rel_for(bug)

  path = File.join(repo_path_for(bug), rel)
  File.file?(path) ? File.read(path).tr("\r", '') : nil
end

def enclosing_class_for(fn, classes)
  return nil unless fn

  classes
    .select { |klass| klass.start_line <= fn.start_line && klass.end_line >= fn.end_line }
    .min_by { |klass| klass.end_line - klass.start_line }
end

def constants_for_class(constants, klass)
  return [] unless klass

  constants.select { |const| klass.start_line <= const.start_line && klass.end_line >= const.end_line }
end

def referenced_constant_names(slice)
  slice.to_s.scan(/\b[A-Z]\w*\b/).flatten.uniq.sort
end

def constructor_names(slice)
  slice.to_s.scan(/\b([A-Z]\w*(?:::[A-Z]\w*)*)\.new\b/).flatten.map { |name| name.split('::').last }.uniq
end

def constructor_context_needed?(bug)
  mutation = bug['mutation'].to_s
  evidence = [
    bug['prompt'],
    bug['stack_trace'],
    (bug['test_failures'] || []).map { |failure| failure['failure_excerpt'] }
  ].flatten.compact.join("\n")
  mutation.match?(/renamed variable|off-by-one|argument|keyword|arity/i) ||
    evidence.match?(/wrong number of arguments|unknown keyword|missing keyword|ArgumentError/i)
end

def constructor_index_for_repo(repo)
  @constructor_index_for_repo ||= {}
  @constructor_index_for_repo[repo] ||= begin
    index = Hash.new { |hash, key| hash[key] = [] }
    Dir[File.join(repo, 'src/**/*.rb')].sort.each do |path|
      rel = path.delete_prefix("#{repo}/")
      src = File.read(path).tr("\r", '')
      file_defs = parse_function_defs(src)
      file_classes = parse_class_infos(src)
      file_classes.each do |klass|
        init = file_defs.find do |fn|
          klass.start_line <= fn.start_line &&
            klass.end_line >= fn.end_line &&
            fn.short_name == 'initialize'
        end
        next unless init

        index[klass.name.split('::').last] << { file_rel: rel, klass: klass, init: init }
      end
    rescue StandardError
      next
    end
    index
  end
end

def same_file_constructor_entry(name, defs, classes, file_rel)
  klass = classes.find { |candidate| candidate.name.split('::').last == name }
  return nil unless klass

  init = defs.find do |fn|
    klass.start_line <= fn.start_line &&
      klass.end_line >= fn.end_line &&
      fn.short_name == 'initialize'
  end
  return nil unless init

  { file_rel: file_rel, klass: klass, init: init }
end

def constructor_context_entries(primary, defs, classes, bug, file_rel)
  return [] unless primary
  return [] unless constructor_context_needed?(bug)

  names = constructor_names(primary.slice)
  return [] if names.empty?

  repo = repo_path_for(bug)
  names.flat_map do |name|
    entries = []
    same_file = same_file_constructor_entry(name, defs, classes, file_rel)
    entries << same_file if same_file
    entries.concat(constructor_index_for_repo(repo)[name])
    entries.compact.uniq { |entry| [entry[:file_rel], entry[:klass].name, entry[:init].start_line] }.first(2)
  end.map do |entry|
    init = entry[:init]
    signature = init.slice.lines.first.to_s.strip
    "CONSTRUCTOR SIGNATURE: #{entry[:file_rel]}:#{entry[:klass].name} (lines #{init.start_line}-#{init.end_line})\n```ruby\n#{signature}\n```"
  end
end

def constant_context_needed?(bug)
  evidence = [
    bug['prompt'],
    bug['stack_trace'],
    (bug['test_failures'] || []).map { |failure| failure['failure_excerpt'] }
  ].flatten.compact.join("\n")
  bug['mutation'].to_s.include?('constant') ||
    evidence.match?(/uninitialized constant|NameError.*constant/i)
end

def mutation_constant_names(bug)
  bug['mutation'].to_s.scan(/'([A-Z]\w*)'/).flatten.uniq
end

def constant_signature_slice(const)
  lines = const.slice.lines(chomp: true)
  return const.slice.rstrip if lines.length <= 8

  (lines.first(8) + ['  # ...']).join("\n")
end

def constant_context_entries(primary, constants, klass, bug)
  return [] unless primary && klass
  return [] unless constant_context_needed?(bug)

  class_constants = constants_for_class(constants, klass)
  return [] if class_constants.empty?

  refs = referenced_constant_names(primary.slice)
  wanted_names = (refs + mutation_constant_names(bug)).uniq
  if bug['mutation'].to_s.include?('constant')
    wanted = class_constants.select { |const| wanted_names.include?(const.name) }
  else
    wanted = class_constants.select { |const| refs.include?(const.name) }
  end

  dependent_names = wanted.flat_map { |const| referenced_constant_names(const.slice) }.uniq - wanted.map(&:name)
  if dependent_names.any?
    wanted.concat(class_constants.select { |const| dependent_names.include?(const.name) })
    wanted.uniq!(&:name)
  end

  wanted.first(12).map do |const|
    "CLASS CONSTANT SIGNATURE: #{klass.name}::#{const.name} (lines #{const.start_line}-#{const.end_line})\n```ruby\n#{constant_signature_slice(const)}\n```"
  end
end

def missing_method_names(bug)
  text = [
    bug['prompt'],
    bug['stack_trace'],
    (bug['test_failures'] || []).map { |failure| failure['failure_excerpt'] }
  ].flatten.compact.join("\n")
  text.scan(/undefined method [`']([^`']+)[`']/i).flatten.uniq
end

def include_class_debug?(bug, primary, defs, classes)
  klass = enclosing_class_for(primary, classes)
  return false unless klass

  class_defs = defs.select { |fn| klass.start_line <= fn.start_line && klass.end_line >= fn.end_line }
  missing = missing_method_names(bug)
  return false if missing.empty?

  class_defs.any? { |fn| primary && fn.name != primary.name && missing.include?(fn.short_name) }
end

def debug_context_for_function(bug, primary, chosen, defs, classes)
  lines = [
    '=' * 60,
    'DEBUG CONTEXT',
    '=' * 60
  ]
  klass = enclosing_class_for(primary, classes)
  if klass
    lines << "Class/module: #{klass.name} (#{klass.type}, lines #{klass.start_line}-#{klass.end_line})"
    class_defs = defs.select { |fn| klass.start_line <= fn.start_line && klass.end_line >= fn.end_line }
    missing = missing_method_names(bug)
    matching_siblings = class_defs.reject { |fn| primary && fn.name == primary.name }
                                  .select { |fn| missing.include?(fn.short_name) }
    if include_class_debug?(bug, primary, defs, classes)
      lines << 'Relevant sibling methods matching undefined-method evidence:'
      matching_siblings.each do |fn|
        signature = fn.slice.lines.first.to_s.strip
        lines << "  #{fn.name} -- line #{fn.start_line}: #{signature}"
      end
    end
  else
    lines << 'Class/module: (none)'
  end
  params = (bug['function_params'] || []).map { |param| "#{param['name']}: #{param['type']}" }
  lines << "Params: #{params.empty? ? '(none recorded)' : params.join(', ')}"
  lines << "Recorded callees: #{(bug['function_callees'] || []).empty? ? '(none)' : bug['function_callees'].join(', ')}"
  lines << "Recorded instance vars: #{(bug['function_ivars'] || []).empty? ? '(none)' : bug['function_ivars'].map { |ivar| "@#{ivar}" }.join(', ')}"
  if primary
    lines << "Prism-detected callees in primary function: #{primary.callees.empty? ? '(none)' : primary.callees.join(', ')}"
    lines << "Prism-detected ivars in primary function: #{primary.ivars.empty? ? '(none)' : primary.ivars.join(', ')}"
  end
  related = chosen.drop(1)
  lines << "Included related functions: #{related.empty? ? '(none)' : related.map(&:name).join(', ')}"
  lines.join("\n")
end

def build_functions_with_context(bug, max_chars: local_context_chars, mode: CTX_COMPACT)
  target_file = file_rel_for(bug)
  source = build_buggy_source_file(bug)
  defs = parse_function_defs(source)
  classes = parse_class_infos(source)
  constants = parse_constant_infos(source)
  chosen = []

  ideal_context_function_keys(bug).each do |key|
    fn = find_function_def(defs, key)
    next unless fn
    next if chosen.any? { |entry| entry[:file_rel] == target_file && entry[:fn].name == fn.name }

    chosen << { file_rel: target_file, fn: fn, defs: defs, classes: classes, constants: constants }
  end

  stack_frame_refs(bug).each do |rel, line|
    src = source_for_file_rel(bug, rel)
    next unless src

    frame_defs = rel == target_file ? defs : parse_function_defs(src)
    frame_classes = rel == target_file ? classes : parse_class_infos(src)
    frame_constants = rel == target_file ? constants : parse_constant_infos(src)
    fn = find_function_def(frame_defs, line)
    next unless fn
    next if chosen.any? { |entry| entry[:file_rel] == rel && entry[:fn].name == fn.name }

    chosen << { file_rel: rel, fn: fn, defs: frame_defs, classes: frame_classes, constants: frame_constants }
  end

  primary_entry = chosen.first
  if primary_entry && chosen.size > MAX_CTX_FUNCTIONS
    related = chosen.drop(1).sort_by { |entry| [entry[:fn].slice.length, entry[:fn].name] }
    chosen = [primary_entry] + related.first(MAX_CTX_FUNCTIONS - 1)
  end

  return "```ruby\n#{bug['mutated_body']}\n```" if chosen.empty?

  primary_entry = chosen.first
  primary = primary_entry[:fn]
  primary_class = enclosing_class_for(primary, primary_entry[:classes])
  dependency_chunks =
    if mode == CTX_LARGE
      constructor_context_entries(primary, primary_entry[:defs], primary_entry[:classes], bug, primary_entry[:file_rel]) +
        constant_context_entries(primary, primary_entry[:constants], primary_class, bug)
    else
      []
    end
  chunks = [debug_context_for_function(bug, primary, chosen.map { |entry| entry[:fn] }, primary_entry[:defs], primary_entry[:classes])]
  omitted = []
  used_chars = chunks.join("\n\n").length
  code_entries = if chosen.size > 1
                   seed = bug.fetch('id', '').each_byte.reduce(0) { |acc, byte| ((acc * 33) + byte) & 0x7fffffff }
                   chosen.shuffle(random: Random.new(seed))
                 else
                   chosen
                 end

  code_entries.each do |entry|
    fn = entry[:fn]
    role = entry.equal?(primary_entry) ? 'BUG TARGET FUNCTION' : 'RELATED FUNCTION'
    chunk = "#{role}: #{entry[:file_rel]}:#{fn.name} (lines #{fn.start_line}-#{fn.end_line})\n```ruby\n#{fn.slice.rstrip}\n```"
    if used_chars + chunk.length > max_chars
      omitted << "#{entry[:file_rel]}:#{fn.name}"
      next
    end

    chunks << chunk
    used_chars += chunk.length
  end

  dependency_chunks.each do |chunk|
    if used_chars + chunk.length > max_chars
      omitted << chunk.lines.first.to_s.sub(/: .*/, '').strip
      next
    end

    chunks << chunk
    used_chars += chunk.length
  end

  chunks << "Omitted related context due to context budget: #{omitted.join(', ')}" if omitted.any?
  chunks.join("\n\n")
rescue StandardError
  "```ruby\n#{bug['mutated_body']}\n```"
end

def strip_ansi(text)
  text.to_s.gsub(/\e\[[0-9;]*m/, '')
end

def truncate_middle(text, max_chars)
  text = strip_ansi(text)
  return text if text.length <= max_chars

  head = max_chars / 2
  tail = max_chars - head
  "#{text[0, head]}\n... truncated ...\n#{text[-tail, tail]}"
end

def failure_lines_for(failure)
  file_rel = failure['file_rel']
  lines = []
  excerpt = failure['failure_excerpt'].to_s
  escaped = Regexp.escape(file_rel.to_s)

  excerpt.scan(%r{#\s+\./#{escaped}:(\d+)}).each { |match| lines << match.first.to_i }
  lines << failure['line']
  excerpt.scan(%r{rspec\s+(?:\./)?#{escaped}:(\d+)}).each { |match| lines << match.first.to_i }
  excerpt.scan(%r{(?:\./)?#{escaped}:(\d+)}).each { |match| lines << match.first.to_i }
  lines.map(&:to_i).select(&:positive?).uniq.first(3)
end

def test_source_window(bug, failure, line, radius: 5)
  path = File.join(repo_path_for(bug), failure['file_rel'].to_s)
  return nil unless File.file?(path)

  lines = File.readlines(path, chomp: true)
  return nil if lines.empty?

  start_line = [line - radius, 1].max
  end_line = [line + radius, lines.length].min
  body = lines[(start_line - 1)..(end_line - 1)].each_with_index.map do |src, offset|
    actual = start_line + offset
    marker = actual == line ? '=>' : '  '
    "#{marker} #{actual.to_s.rjust(4)}: #{src}"
  end.join("\n")
  "From #{failure['file_rel']}:#{line}\n#{body}"
end

def ruby_block_delta(line)
  stripped = line.sub(/#.*/, '')
  opens = stripped.scan(/\b(do|def|class|module|if|unless|case|begin|while|until|for)\b/).size
  closes = stripped.scan(/\bend\b/).size
  opens - closes
end

def test_source_block(bug, failure, line, max_lines: 90)
  path = File.join(repo_path_for(bug), failure['file_rel'].to_s)
  return nil unless File.file?(path)

  lines = File.readlines(path, chomp: true)
  return nil if lines.empty?

  idx = [[line.to_i - 1, 0].max, lines.length - 1].min
  start_idx = idx.downto(0).find do |i|
    lines[i].match?(/^\s*(it|specify|example|test)\b.*\bdo\b/) ||
      lines[i].match?(/^\s*def\s+test_/)
  end
  return test_source_window(bug, failure, line, radius: 8) unless start_idx

  depth = 0
  end_idx = [start_idx + max_lines - 1, lines.length - 1].min
  (start_idx..end_idx).each do |i|
    depth += ruby_block_delta(lines[i])
    if i > start_idx && depth <= 0
      end_idx = i
      break
    end
  end

  body = lines[start_idx..end_idx].each_with_index.map do |src, offset|
    actual = start_idx + offset + 1
    marker = actual == line.to_i ? '=>' : '  '
    "#{marker} #{actual.to_s.rjust(4)}: #{src}"
  end.join("\n")
  "From #{failure['file_rel']}:#{line}\n#{body}"
end

def new_unit_test_context(bug)
  new_test = bug.dig('discovery', 'new_test') || {}
  content = new_test['content'].to_s.strip
  return nil if content.empty?
  return nil if content.include?('flunk "Regression for')

  file_rel = new_test['file_rel'] || (bug.dig('discovery', 'dirty_files') || []).find { |f| f['role'] == 'test' }&.dig('file_rel')
  [
    '=' * 60,
    'TEST FAILURE CONTEXT',
    '=' * 60,
    'New failing unit test:',
    "File: #{file_rel}",
    '```ruby',
    content,
    '```'
  ].join("\n")
end

def sanitized_bug_prompt(bug)
  text = bug['prompt'].to_s.dup
  text.gsub!(/\n\nNew test file: .+?```ruby\n.*?```\n/m, "\n")
  text.gsub!(/\n{3,}/, "\n\n")
  text.strip
end

def test_diagnostics_context(bug, mode: CTX_COMPACT)
  if bug.dig('discovery', 'scenario') == 'new_unit_test'
    context = new_unit_test_context(bug)
    return context if context
  end

  failures = bug['test_failures'] || []
  lines = [
    '=' * 60,
    'TEST FAILURE CONTEXT',
    '=' * 60
  ]

  if bug['stack_trace'].to_s.strip != ''
    lines << 'Recorded stack trace:'
    lines << bug['stack_trace'].to_s.rstrip
  end

  failures.first(1).each_with_index do |failure, index|
    lines << ''
    lines << "Failure #{index + 1}: #{failure['file_rel']}:#{failure['line']}"
    lines << "Command: #{failure['command'].join(' ')}" if failure['command']

    excerpt = failure['failure_excerpt'].to_s
    if excerpt.strip != ''
      focused = excerpt.lines.grep(/Failure\/Error|expected|got |NoMethodError|NameError|undefined method|ArgumentError|TypeError|SyntaxError|Error:|TIMEOUT/i).first(12).join
      unless focused.strip.empty?
        lines << 'Failure output excerpt:'
        lines << truncate_middle(focused, 700).rstrip
      end
    end

    max_test_blocks = mode == CTX_LARGE ? 3 : 1
    windows = failure_lines_for(failure).first(max_test_blocks).filter_map { |line| test_source_block(bug, failure, line) }
    next if windows.empty?

    lines << 'Failing test code:'
    lines << windows.join("\n\n")
  end

  lines.join("\n")
end

def prompt_with_context(bug, mode: CTX_COMPACT)
  file_rel = file_rel_for(bug)
  func = bug['function'].split('.').last
  <<~PROMPT
    File: #{file_rel}
    Function: #{func}

    Here is the ideal current code context. It includes debug-style metadata,
    the bug target function, and related functions when available:

    #{build_functions_with_context(bug, mode: mode)}

    #{simulated_worktree_state(bug)}

    #{test_diagnostics_context(bug, mode: mode)}

    #{sanitized_bug_prompt(bug)}

    Return ONLY the corrected function `#{func}` in a ```ruby block.
  PROMPT
end

def query_gguf(model_path, prompt)
  Tempfile.create(['cleopatra-llama-', '.py']) do |script|
    prompt_file = script.path.sub(/\.py\z/, '.prompt.txt')
    File.write(prompt_file, prompt)
    script.write(<<~PY)
      import sys
      from llama_cpp import Llama
      with open(#{prompt_file.to_json}) as f:
          user_msg = f.read()
      llm = Llama(model_path=#{model_path.to_json}, n_ctx=#{LOCAL_CONTEXT_TOKENS}, n_threads=32, verbose=False, n_gpu_layers=0)
      system_prompt = #{SYSTEM_PROMPT.to_json}
      full = '<|im_start|>system\\n' + system_prompt + '\\n<|im_end|>\\n<|im_start|>user\\n' + user_msg + '\\n<|im_end|>\\n<|im_start|>assistant\\n```ruby\\n'
      output = llm(full, max_tokens=1024, temperature=0.1, stop=['<|im_end|>', '<|end|>', '\\n```'])
      print(output['choices'][0]['text'].strip())
    PY
    script.close
    out, err, status = Open3.capture3(VENV_PY, script.path)
    File.unlink(prompt_file) if File.exist?(prompt_file)
    raise err unless status.success?

    "```ruby\n#{out.strip}\n```"
end
rescue StandardError => e
  "[[ERROR: #{e.message}]]"
end

def lfm_system_prompt
  "#{SYSTEM_PROMPT} Return only method definitions that should be inserted; no module/class wrappers, no comments, no prose."
end

def lfm_prompt(prompt)
  <<~PROMPT
    Think only as much as needed, then final answer must be exactly one ```ruby fenced code block.
    Do not include prose outside the code block.
    Do not include module/class wrappers unless the target function itself is a class method.

    #{prompt}
  PROMPT
end

def query_lfm(model_path, prompt)
  query_lfm_server(prompt)
rescue StandardError
  query_lfm_cli(model_path, prompt)
end

def query_lfm_server(prompt)
  errors = []
  last_response = nil
  3.times do |attempt|
    effective_prompt =
      if attempt.zero?
        lfm_prompt(prompt)
      else
        retry_prompt_for_invalid_response(errors.last, last_response)
      end
    result = query_lfm_server_once(effective_prompt, max_tokens: attempt.zero? ? 1_536 : 768)
    validation = validate_response_code(result)
    return result if validation[:ok]

    last_response = result
    errors << "attempt #{attempt + 1}: #{validation[:error]}"
    warn "LFM invalid response: #{errors.last}"
  end

  "[[ERROR: invalid LFM response after retries: #{errors.join('; ')}]]"
end

def query_lfm_server_once(prompt, max_tokens:)
  uri = URI("#{LFM_SERVER_URL}/v1/chat/completions")
  req = Net::HTTP::Post.new(uri)
  req['Content-Type'] = 'application/json'
  req.body = JSON.generate(
    model: 'lfm',
    messages: [
      { role: 'system', content: lfm_system_prompt },
      { role: 'user', content: prompt }
    ],
    max_tokens: max_tokens,
    temperature: 0.1,
    stream: false
  )
  resp = Net::HTTP.start(uri.hostname, uri.port, read_timeout: 240) { |http| http.request(req) }
  data = JSON.parse(resp.body)
  raise "LFM server error: #{data['error']}" if data['error']
  finish_reason = data.dig('choices', 0, 'finish_reason')
  raise "LFM finish_reason=#{finish_reason}" if finish_reason && finish_reason != 'stop'

  out = data.dig('choices', 0, 'message', 'content').to_s
  out = clean_lfm_response(out)
  out.include?('```') ? out : "```ruby\n#{out}\n```"
end

def query_lfm_cli(model_path, prompt)
  Tempfile.create(['cleopatra-lfm-', '.prompt.txt']) do |prompt_file|
    prompt_file.write(lfm_prompt(prompt))
    prompt_file.close
    cmd = [
      LLAMA_CLI,
      '-m', model_path,
      '-sys', lfm_system_prompt,
      '-f', prompt_file.path,
      '-n', '1536',
      '-t', '32',
      '-c', LOCAL_CONTEXT_TOKENS.to_s,
      '--temp', '0.1',
      '--no-display-prompt',
      '--single-turn',
      '--reasoning', 'on',
      '--reasoning-budget', '256',
      '--reasoning-format', 'deepseek',
      '--log-disable'
    ]
    out = err = status = nil
    Timeout.timeout(180) do
      out, err, status = Open3.capture3(*cmd)
    end
    raise err unless status.success?

    out = clean_lfm_cli_output(out)
    out.include?('```') ? out : "```ruby\n#{out}\n```"
  end
rescue StandardError => e
  "[[ERROR: #{e.message}]]"
end

def clean_lfm_cli_output(text)
  text = text.delete("\b\r")
  if text.include?('</think>')
    text = text.split('</think>').last.to_s
  else
    raise 'LFM output did not contain </think>; refusing to parse prompt echo as response'
  end
  text = text.sub(/\n\[ Prompt:.*\z/m, '')
  text = text.gsub(/\n?Exiting\.\.\.\s*\z/, '')
  clean_lfm_response(text)
end

def clean_lfm_response(text)
  text.gsub(%r{<think>.*?</think>}m, '').strip
end

def query_openrouter(model, prompt)
  return '[[SKIPPED: API key not set]]' unless ENV['OPENROUTER_API_KEY']

  errors = []
  last_response = nil
  OPENROUTER_RETRIES.times do |attempt|
    effective_prompt = attempt.zero? ? prompt : retry_prompt_for_invalid_response(errors.last, last_response)
    system_prompt = attempt.zero? ? SYSTEM_PROMPT : 'You write complete parseable Ruby functions.'
    token_limit =
      if attempt.zero? && model == MODEL_32B
        OPENROUTER_32B_OUTPUT_TOKENS
      elsif attempt.zero?
        OUTPUT_TOKENS
      else
        1_000
      end
    result = query_openrouter_once(model, effective_prompt, system_prompt: system_prompt, max_tokens: token_limit)
    validation = validate_response_code(result)
    return result if validation[:ok]

    last_response = result
    errors << "attempt #{attempt + 1}: #{validation[:error]}"
    warn "OpenRouter invalid response for #{model}: #{errors.last}"
  end

  "[[ERROR: invalid OpenRouter response after #{OPENROUTER_RETRIES} attempts: #{errors.join('; ')}]]"
end

def retry_prompt_for_invalid_response(last_error, last_response)
  <<~PROMPT
    The following Ruby function is incomplete and does not parse:
    #{last_response}

    Parser error: #{last_error}

    Return the complete parseable corrected Ruby function only.
  PROMPT
end

def openrouter_body_for(model, prompt, system_prompt, max_tokens)
  body = {
    model: model,
    messages: [
      { role: 'system', content: system_prompt },
      { role: 'user', content: prompt }
    ],
    max_tokens: max_tokens,
    temperature: 0.1
  }

  if model == MODEL_32B
    body[:provider] = { order: OPENROUTER_32B_PROVIDERS, allow_fallbacks: true }
    body[:reasoning] = { effort: 'none', exclude: true }
  end

  body
end

def query_openrouter_once(model, prompt, system_prompt: SYSTEM_PROMPT, max_tokens: OUTPUT_TOKENS)
  uri = URI('https://openrouter.ai/api/v1/chat/completions')
  req = Net::HTTP::Post.new(uri)
  req['Authorization'] = "Bearer #{ENV['OPENROUTER_API_KEY']}"
  req['Content-Type'] = 'application/json'
  req.body = JSON.generate(openrouter_body_for(model, prompt, system_prompt, max_tokens))
  resp = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 120) { |http| http.request(req) }
  data = JSON.parse(resp.body)
  raise "API error: #{data['error']}" if data['error']

  choice = data.fetch('choices', []).first || {}
  finish_reason = choice['finish_reason']
  return "[[ERROR: OpenRouter choice error=#{choice['error']}]]" if choice['error']
  return "[[ERROR: OpenRouter missing finish_reason]]" unless finish_reason
  return "[[ERROR: OpenRouter finish_reason=#{finish_reason}]]" if finish_reason != 'stop'

  choice.dig('message', 'content').to_s.strip
rescue StandardError => e
  "[[ERROR: #{e.message}]]"
end

def extract_response_code(text)
  if text =~ /```ruby\s*\n(.*?)```/m
    Regexp.last_match(1).strip
  elsif text =~ /```\s*\n?(.*?)```/m
    Regexp.last_match(1).strip
  elsif text =~ /```ruby\s*\n(.*)\z/m
    Regexp.last_match(1).strip
  elsif text =~ /```\s*\n?(.*)\z/m
    Regexp.last_match(1).strip
  else
    text.strip
  end
end

def validate_response_code(text)
  return { ok: false, error: text } if text.start_with?('[[ERROR:', '[[SKIPPED:', '[[UNKNOWN')

  code = extract_response_code(text)
  return { ok: false, error: 'empty response' } if code.empty?
  return { ok: false, error: 'no Ruby def in response' } unless code.match?(/(^|\n)\s*def\s+/)

  parsed = Prism.parse(code)
  return { ok: true } if parsed.success?

  message = parsed.errors.first&.message || 'Prism parse failed'
  { ok: false, error: message }
end

bugs = File.readlines(BUGS_FILE, chomp: true).filter_map { |line| JSON.parse(line) unless line.empty? }
PYTHON_RANDOM_42_ORDER_50 = [
  40, 7, 1, 17, 15, 14, 8, 6, 34, 5, 37, 27, 2, 47, 49, 13, 44, 32, 36, 46,
  42, 22, 20, 28, 30, 41, 48, 33, 18, 43, 0, 35, 24, 10, 38, 39, 3, 12, 21,
  31, 16, 29, 9, 26, 45, 4, 11, 19, 23, 25
].freeze

sample_count = [opts[:count], bugs.length].min
sample =
  if bugs.length == 50 && sample_count <= 50
    PYTHON_RANDOM_42_ORDER_50.first(sample_count).map { |index| bugs[index] }
  else
    srand(42)
    bugs.sample(sample_count)
  end
puts "Sample: #{sample.length} bugs"
puts

cats = opts[:cats].empty? ? %w[3B-blind 3B-ctx 7B-blind 32B-blind 405B-blind] : opts[:cats].split(',').map(&:strip)
if cats.any? { |cat| cat.start_with?('32B') || cat.start_with?('405B') } &&
   !opts[:dry_run_prompts] &&
   !ENV['OPENROUTER_API_KEY']
  abort 'OPENROUTER_API_KEY is required for OpenRouter-backed categories; refusing to overwrite responses with skipped markers.'
end
cats.each do |cat|
  dir = File.join(OUT, cat)
  FileUtils.mkdir_p(dir)
  prompts =
    if cat.include?('ctx')
      mode = ctx_mode_for_category(cat)
      sample.map { |bug| prompt_with_context(bug, mode: mode) }
    else
      sample.map { |bug| prompt_blind(bug, max_chars: prompt_context_chars_for_category(cat)) }
    end

  sample.each_with_index do |_bug, index|
    fpath = File.join(dir, format('%02d.txt', index + 1))
    ppath = File.join(dir, format('%02d.prompt.txt', index + 1))
    label = "[#{cat}] bug #{index + 1}/#{sample.length}"
    puts "  #{label}"
    if opts[:responses_only]
      unless File.file?(ppath)
        warn "Missing prompt for responses-only run: #{ppath}"
        next
      end
      prompts[index] = File.read(ppath)
    else
      File.write(ppath, "#{prompts[index]}\n")
    end
    next if opts[:dry_run_prompts]

    result =
      if cat.start_with?('3B')
        query_gguf(MODEL_PATH_3B, prompts[index])
      elsif cat.start_with?('7B')
        query_gguf(MODEL_PATH_7B, prompts[index])
      elsif cat.start_with?('A1B')
        query_lfm(MODEL_PATH_A1B, prompts[index])
      elsif cat.start_with?('32B')
        query_openrouter(MODEL_32B, prompts[index])
      elsif cat.start_with?('405B')
        query_openrouter(MODEL_405B, prompts[index])
      else
        '[[UNKNOWN CATEGORY]]'
      end
    File.write(fpath, "#{result}\n")
  end
end

puts
puts 'Done.'
puts 'Dry run: wrote prompt files only.' if opts[:dry_run_prompts]
