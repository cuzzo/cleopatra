#!/usr/bin/env ruby
# frozen_string_literal: true

# Decompose large commits into training tasks
#
# Takes commits that exceed context/output limits and splits them into
# function-level tasks where ideal context fits ≤16k tokens.
#
# For pre-squash backup branches, the decomposition is already done
# (each commit is a natural chunk). This script handles:
#   1. Type A: Group pre-squash commits into multi-step tasks
#   2. Type B: Programmatically split large squashed commits

require 'json'
require 'prism'

REPO_PATH = File.expand_path('~/cheat')
CUTOFFS = {
  ideal_ctx: 16_000,  # tokens
  max_fns:   4,       # output functions
  max_lines: 100,     # output lines
  max_files: 5,       # files per task
}.freeze

# === Token estimation ===
def estimate_tokens(text)
  (text.length / 4.0).round
end

# === Prism function finder ===
def find_functions(source_code)
  parsed = Prism.parse(source_code)
  return [] unless parsed.success?

  functions = []
  walk = ->(node, nesting = '') {
    return unless node.respond_to?(:child_nodes)
    if node.is_a?(Prism::DefNode)
      full_name = nesting.empty? ? node.name.to_s : "#{nesting}.#{node.name}"
      functions << {
        name: full_name,
        start_line: node.location.start_line,
        end_line: node.location.end_line,
        lines: node.location.end_line - node.location.start_line + 1,
        body: (node.body&.slice || ''),
        slice: node.slice
      }
      walk.call(node.body, full_name) if node.body
    elsif node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
      cn = node.constant_path&.slice || node.name.to_s
      fn2 = nesting.empty? ? cn : "#{nesting}::#{cn}"
      walk.call(node.body, fn2) if node.body
    else
      node.child_nodes&.compact&.each { |c| walk.call(c, nesting) }
    end
  }
  walk.call(parsed.value)
  functions
end

# === Extract dependencies a function has on other functions/types ===
def extract_dependencies(body)
  deps = { types: [], calls: [], constants: [], requires: [] }
  return deps if body.nil? || body.empty?

  # Type references (capitalized names)
  body.scan(/\b([A-Z]\w*)\b/) { |m| deps[:types] << m[0] }
  # Method calls on self (snake_case def names)
  body.scan(/\b([a-z_][a-z_0-9]*[?!]?)\s*[\(]/) { |m| deps[:calls] << m[0] }
  # Constants (ALL_CAPS)
  body.scan(/\b([A-Z][A-Z_0-9]+)\b/) { |m| deps[:constants] << m[0] }
  # Requires
  body.scan(/require(?:_relative)?\s+['"]([^'"]+)['"]/) { |m| deps[:requires] << m[0] }

  deps.transform_values { |v| v.uniq - ['T', 'sig', 'params', 'returns', 'void', 'nilable'] }
end

# === Extract function-level changes from a commit ===
def extract_function_changes(repo_path, sha)
  # Get changed files
  stat = `cd #{repo_path} && git diff-tree --no-commit-id -r --numstat #{sha}`.strip
  return [] if stat.empty?

  files = stat.lines.map { |l| (c = l.split("\t")) && c.size == 3 ? c[2].strip : nil }.compact
  changes = []

  files.each do |file|
    next unless file.end_with?('.rb')

    before = `cd #{repo_path} && git show #{sha}^:#{file} 2>/dev/null`
    after  = `cd #{repo_path} && git show #{sha}:#{file} 2>/dev/null`
    next if before.empty? && after.empty?

    before_fns = find_functions(before)
    after_fns  = find_functions(after)

    before_map = before_fns.each_with_object({}) { |f, h| h[f[:name]] = f }
    after_map  = after_fns.each_with_object({}) { |f, h| h[f[:name]] = f }

    all_names = (before_map.keys + after_map.keys).uniq

    all_names.each do |name|
      bfn = before_map[name]
      afn = after_map[name]

      if bfn && afn && bfn[:body] != afn[:body]
        # Modified function
        changes << {
          id: "#{file}::#{name}",
          file: file,
          name: name,
          type: :modified,
          before_body: bfn[:body],
          after_body: afn[:body],
          before_slice: bfn[:slice],
          after_slice: afn[:slice],
          before_lines: bfn[:lines],
          after_lines: afn[:lines],
          changed_lines: (bfn[:body].split("\n") - afn[:body].split("\n")).size +
                         (afn[:body].split("\n") - bfn[:body].split("\n")).size,
          deps: extract_dependencies(afn[:body])
        }
      elsif afn && bfn.nil?
        # New function
        changes << {
          id: "#{file}::#{name}",
          file: file,
          name: name,
          type: :added,
          before_body: '',
          after_body: afn[:body],
          before_slice: '',
          after_slice: afn[:slice],
          before_lines: 0,
          after_lines: afn[:lines],
          changed_lines: afn[:lines],
          deps: extract_dependencies(afn[:body])
        }
      end
      # Deleted functions are ignored (not training targets)
    end
  end

  changes
end

# === Build cross-function dependency graph ===
def build_dependency_graph(changes)
  graph = {}

  # All function IDs
  all_ids = changes.map { |c| c[:id] }

  changes.each do |c|
    deps = []

    # Dependencies on other changed functions
    all_ids.each do |other_id|
      next if other_id == c[:id]
      other_file, other_name = other_id.split('::', 2)
      other_short = other_name.split('.').last  # get just the method name

      # Check if this function calls the other
      if c[:deps][:calls].include?(other_short)
        deps << other_id
      end
      # Check if this function uses types from the other
      if c[:deps][:types].include?(other_name.split('.').first)
        deps << other_id
      end
    end

    # Same-file shared state dependency (instance variables)
    same_file = changes.select { |ch| ch[:file] == c[:file] && ch[:id] != c[:id] }
    same_file.each do |sf|
      # If they share instance variables, they're dependent
      c_ivars = c[:after_body].scan(/@\w+/)
      sf_ivars = sf[:after_body].scan(/@\w+/)
      if (c_ivars & sf_ivars).any?
        deps << sf[:id]
      end
    end

    graph[c[:id]] = deps.uniq
  end

  graph
end

# === Topological sort functions by dependency, handling cycles ===
def topological_sort(graph)
  sorted = []
  visited = {}
  temp = {}
  in_cycle = Set.new

  # First pass: detect cycles by finding SCCs
  # Functions in a cycle get grouped together
  visit = ->(node, path = []) {
    return if visited[node]
    if temp[node]
      # Cycle detected — mark all nodes in the cycle
      cycle_start = path.index(node)
      (path[cycle_start..]).each { |n| in_cycle << n }
      return
    end
    temp[node] = true
    path.push(node)
    (graph[node] || []).each { |dep| visit.call(dep, path) }
    path.pop
    temp.delete(node)
    visited[node] = true
    sorted.unshift(node) unless in_cycle.include?(node)
  }

  graph.keys.each { |node| visit.call(node) }

  # For cycles, insert them as a group at the end
  cycle_nodes = in_cycle.to_a
  sorted.concat(graph.keys.select { |n| in_cycle.include?(n) && !sorted.include?(n) })

  sorted
end

# === Greedy pack functions into tasks respecting cutoffs ===
def group_into_tasks(changes, dep_graph, cutoffs = CUTOFFS)
  ordered = topological_sort(dep_graph)
  change_map = changes.each_with_object({}) { |c, h| h[c[:id]] = c }

  tasks = []
  current = { functions: [], context_tokens: 0, output_fns: 0, output_lines: 0, files: Set.new }

  ordered.each do |fid|
    fc = change_map[fid]
    next unless fc

    # Calculate what adding this function would cost
    # Ideal context = function body + type deps + callee sigs
    # (estimated as 1.3x the function body)
    fn_context_tokens = estimate_tokens(fc[:after_body]) * 1.3
    fn_output_lines = fc[:changed_lines]

    new_ctx = current[:context_tokens] + fn_context_tokens
    new_fns = current[:output_fns] + 1
    new_lines = current[:output_lines] + fn_output_lines
    new_files = current[:files] + [fc[:file]]

    if new_ctx <= cutoffs[:ideal_ctx] &&
       new_fns <= cutoffs[:max_fns] &&
       new_lines <= cutoffs[:max_lines] &&
       new_files.size <= cutoffs[:max_files]
      # Fits — add to current task
      current[:functions] << fid
      current[:context_tokens] = new_ctx
      current[:output_fns] = new_fns
      current[:output_lines] = new_lines
      current[:files] = new_files
    else
      # Doesn't fit — save current, start new
      tasks << current if current[:functions].any?
      current = {
        functions: [fid],
        context_tokens: fn_context_tokens,
        output_fns: 1,
        output_lines: fn_output_lines,
        files: Set.new([fc[:file]])
      }
    end
  end

  tasks << current if current[:functions].any?
  tasks
end

# === Extract ideal context for a task ===
def build_ideal_context(task_functions, change_map, repo_path, sha)
  context_parts = []
  seen_types = Set.new

  task_functions.each do |fid|
    fc = change_map[fid]
    next unless fc

    # The function body (after the change)
    context_parts << "# #{fc[:file]}::#{fc[:name]}"
    context_parts << fc[:after_slice]
    context_parts << ""

    # Type dependencies (look up type definitions from the file)
    fc[:deps][:types].each do |type_name|
      next if seen_types.include?(type_name)
      seen_types << type_name
      # Try to find the type definition in the changed files
      type_def = find_type_definition(type_name, fc[:file], repo_path, sha)
      context_parts << "# #{type_name} (dependency)" if type_def
      context_parts << type_def if type_def
    end

    # Callee signatures (just the sig, not the body)
    fc[:deps][:calls].each do |call_name|
      sig = find_function_signature(call_name, fc[:file], repo_path, sha)
      context_parts << "# Caller: #{call_name}" if sig
      context_parts << sig if sig
    end
  end

  context_parts.reject(&:nil?).reject(&:empty?).join("\n")
end

# === Find type definition in changed files ===
def find_type_definition(type_name, current_file, repo_path, sha)
  # Check current file first
  content = `cd #{repo_path} && git show #{sha}:#{current_file} 2>/dev/null`
  if content
    # Look for class/module definition
    match = content.match(/^\s*(?:class|module)\s+#{Regexp.escape(type_name)}\b.*?^end\s*$/m)
    return match[0] if match
  end
  nil
end

# === Find function signature in changed files ===
def find_function_signature(func_name, current_file, repo_path, sha)
  content = `cd #{repo_path} && git show #{sha}:#{current_file} 2>/dev/null`
  return nil unless content

  # Look for sig block followed by def
  match = content.match(/(sig\s+\{[^}]+\})\s*\n\s*def\s+#{Regexp.escape(func_name)}\b/m)
  return match[1] if match

  # Just the def line
  match = content.match(/^\s*def\s+#{Regexp.escape(func_name)}\b[^;]*$/m)
  return match[0] if match

  nil
end

# === Main decomposition ===
def decompose_commit(sha, repo_path = REPO_PATH)
  message = `cd #{repo_path} && git log --oneline -1 #{sha}`.strip.sub(/^[a-f0-9]+\s+/, '')
  puts "\nDecomposing #{sha[0..8]}: #{message[0..60]}"

  # Extract function-level changes
  changes = extract_function_changes(repo_path, sha)
  return { sha: sha, message: message, error: 'No function changes found' } if changes.empty?

  puts "  #{changes.size} function changes across #{changes.map { |c| c[:file] }.uniq.size} files"

  # Build dependency graph
  dep_graph = build_dependency_graph(changes)
  change_map = changes.each_with_object({}) { |c, h| h[c[:id]] = c }

  # Group into tasks
  tasks = group_into_tasks(changes, dep_graph)

  puts "  Grouped into #{tasks.size} tasks"

  # Build task data
  task_data = []
  tasks.each_with_index do |task, i|
    task_fns = task[:functions]
    task_changes = task_fns.map { |fid| change_map[fid] }.compact

    # Build ideal context
    ideal_context = build_ideal_context(task_fns, change_map, repo_path, sha)
    ideal_ctx_tokens = estimate_tokens(ideal_context)

    # Output reference code (what the model should produce)
    output_code = task_changes.map { |fc| fc[:after_slice] }.join("\n\n")
    output_tokens = estimate_tokens(output_code)
    output_lines = task_changes.sum { |fc| fc[:changed_lines] }

    # Prompt code (what the model sees before the change)
    prompt_code = task_changes.map { |fc|
      "# #{fc[:file]}::#{fc[:name]}\n#{fc[:before_slice]}"
    }.join("\n\n")

    task_info = {
      task_index: i + 1,
      total_tasks: tasks.size,
      functions: task_fns,
      files: task[:files].to_a,
      ideal_context_tokens: ideal_ctx_tokens,
      has_room_for_overhead: ideal_ctx_tokens <= 16_000,
      overhead_room: [16_000 - ideal_ctx_tokens, 0].max,
      output_functions: task[:output_fns],
      output_lines: output_lines,
      output_tokens: output_tokens,
      fits_3b: task[:output_fns] <= 4 && output_lines <= 100 && ideal_ctx_tokens <= 16_000,
      fits_14b: task[:output_fns] <= 8 && output_lines <= 250 && ideal_ctx_tokens <= 32_000,
      ideal_context: ideal_context,
      prompt_code: prompt_code,
      output_code: output_code,
      function_details: task_changes.map { |fc|
        {
          id: fc[:id],
          file: fc[:file],
          name: fc[:name],
          type: fc[:type],
          changed_lines: fc[:changed_lines],
          deps: fc[:deps][:calls].first(5),
          type_deps: fc[:deps][:types].first(5),
        }
      }
    }

    puts "  Task #{i + 1}: #{task[:output_fns]} fns, #{output_lines} lines, " +
         "#{ideal_ctx_tokens} ctx tok, #{task[:files].size} files" +
         (task_info[:fits_3b] ? ' [3B ✓]' : task_info[:fits_14b] ? ' [14B ✓]' : ' [too large]')

    task_data << task_info
  end

  {
    sha: sha,
    message: message,
    n_tasks: tasks.size,
    n_function_changes: changes.size,
    n_files: changes.map { |c| c[:file] }.uniq.size,
    tasks: task_data
  }
end

# === Pre-squash sequence decomposition ===
def decompose_pre_squash_sequence(branch_name, repo_path = REPO_PATH)
  puts "\n=== Decomposing pre-squash branch: #{branch_name} ==="

  # Get all commits on this branch not in master
  commits = `cd #{repo_path} && git log --oneline --reverse #{branch_name} --not master --format="%H@@@%s"`.lines.map(&:strip)
  puts "  #{commits.size} pre-squash commits"

  results = []
  commits.each_with_index do |line, i|
    sha, msg = line.split("@@@", 2)
    result = decompose_commit(sha, repo_path)
    result[:sequence_index] = i + 1
    results << result
  end

  results
end

# === CLI ===
if ARGV[0] == '--branch'
  # Decompose a pre-squash branch
  branch = ARGV[1] || 'vm-fix-rewrite-backup'
  results = decompose_pre_squash_sequence(branch)
  output_file = "decomposed_#{branch.tr('/', '_')}.json"
elsif ARGV[0] == '--large'
  # Decompose the 85 too-large commits
  classified = JSON.parse(File.read('classified_commits.json'))
  too_large = classified['too_large'] || []
  puts "Decomposing #{too_large.size} too-large commits..."
  results = []
  too_large.each_with_index do |entry, i|
    sha = entry['sha']
    print "\r  [#{i + 1}/#{too_large.size}] #{sha[0..8]}..."
    $stdout.flush
    begin
      result = decompose_commit(sha)
      result[:triage_entry] = entry
      results << result
    rescue => e
      results << { sha: sha, error: e.message, message: entry['message'] }
      puts "\n  Error on #{sha[0..8]}: #{e.message[0..80]}"
    end
  end
  output_file = 'decomposed_too_large.json'
else
  # Decompose a specific commit SHA
  sha = ARGV[0]
  if sha.nil? || sha.empty?
    puts "Usage:"
    puts "  ruby src/decompose.rb <sha>          # Decompose a specific commit"
    puts "  ruby src/decompose.rb --branch <name> # Decompose a pre-squash branch"
    puts "  ruby src/decompose.rb --large         # Decompose all too-large commits"
    exit 1
  end
  result = decompose_commit(sha)
  results = [result]
  output_file = "decomposed_#{sha[0..8]}.json"
end

require 'set'
File.write(output_file, JSON.pretty_generate({
  generated_at: Time.now.strftime('%Y-%m-%dT%H:%M:%S%z'),
  cutoffs: CUTOFFS,
  results: results
}))

# Summary
total_tasks = results.sum { |r| r[:tasks]&.size || 0 }
total_fitting_3b = results.sum { |r| (r[:tasks] || []).count { |t| t[:fits_3b] } }
total_fitting_14b = results.sum { |r| (r[:tasks] || []).count { |t| t[:fits_14b] } }
puts "\n=== Summary ==="
puts "  Input commits: #{results.size}"
puts "  Output tasks: #{total_tasks}"
puts "  Fit 3B: #{total_fitting_3b}"
puts "  Fit 14B: #{total_fitting_14b}"
puts "  Written to: #{output_file}"