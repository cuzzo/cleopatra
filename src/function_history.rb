#!/usr/bin/env ruby
# frozen_string_literal: true

# Function History Miner
#
# For a given file + function name, walks git history and extracts every
# version of that function. Shows the progression over time and identifies
# which training tasks have real sloppy predecessors.

require 'json'
require 'prism'

REPO_PATH = File.expand_path('~/cheat')

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

# === Simple code quality heuristic (no CodeQL needed) ===
def score_sloppiness(code)
  score = 100
  return score if code.nil? || code.empty?
  
  lines = code.split("\n")
  score -= 5 * lines.count { |l| l.match?(/\bT\.untyped\b/) }  # untyped = sloppy
  score -= 3 * lines.count { |l| l.match?(/\b&\.\b/) }         # safe nav = defensive
  score -= 8 * lines.count { |l| l.match?(/\brescue\b/) }      # rescue = hiding errors
  score -= 4 * lines.count { |l| l.match?(/\bif\s+!\b/) }      # unless-style negation
  score -= 2 * lines.count { |l| l.match?(/^\s*#\s*(TODO|FIXME|HACK)/) }  # tech debt markers
  score -= lines.count { |l| l.length > 100 }                   # long lines
  score -= 3 * (code.scan(/\bdef\s/).size - 1)                  # nested defs
  score -= lines.count { |l| l.match?(/\bputs\b/) }             # debug prints
  
  [score, 0].max
end

# === Get all versions of a function from git history ===
def get_function_history(file_path, function_name, max_commits: 100)
  Dir.chdir(REPO_PATH) do
    # Get commits that touched this file, newest first
    commits = `git log --oneline --format="%H %ct" -- "#{file_path}"`.lines
      .map { |l| l.strip.split(' ', 2) }
      .first(max_commits)
    
    versions = []
    prev_body = nil
    
    commits.reverse_each do |sha, _timestamp|
      content = `git show #{sha}:#{file_path} 2>/dev/null`
      next if content.empty?
      
      functions = find_functions(content)
      fn = functions.find { |f| f[:name] == function_name }
      next unless fn
      
      body = fn[:body]
      next if body == prev_body  # skip unchanged versions
      
      versions << {
        sha: sha,
        body: body,
        slice: fn[:slice],
        lines: fn[:lines],
        sloppiness: score_sloppiness(body),
        changed: prev_body ? diff_similarity(body, prev_body) : 1.0
      }
      
      prev_body = body
    end
    
    versions.reverse  # oldest first
  end
end

# === Diff similarity (0 = completely different, 1 = identical) ===
def diff_similarity(a, b)
  return 1.0 if a == b
  lines_a = a.split("\n")
  lines_b = b.split("\n")
  
  common = (lines_a & lines_b).size
  total = [lines_a.size, lines_b.size].max
  total > 0 ? common.to_f / total : 0
end

# === Find which training tasks have historical sloppy versions ===
def find_tasks_with_history(tasks_file)
  tasks = JSON.parse(File.read(tasks_file)) rescue []
  tasks_with_history = []
  tasks_without_history = []
  
  tasks.each do |task|
    functions = task["function_details"] || []
    has_history = false
    
    functions.each do |fn|
      file = fn["file"]
      name = fn["name"]
      
      history = get_function_history(file, name, max_commits: 30)
      versions = history.select { |v| v[:sloppiness] < 80 && v[:changed] > 0.3 }
      
      if versions.size >= 2
        has_history = true
        fn["historical_versions"] = versions.size
        fn["sloppiest_score"] = versions.map { |v| v[:sloppiness] }.min
      end
    end
    
    if has_history
      tasks_with_history << task
    else
      tasks_without_history << task
    end
  end
  
  { with_history: tasks_with_history, without: tasks_without_history }
end

# === CLI ===
if ARGV[0] == '--history'
  file = ARGV[1]
  func = ARGV[2]
  
  unless file && func
    puts "Usage: ruby src/function_history.rb --history <file> <function_name>"
    puts "Example: ruby src/function_history.rb --history src/mir/hoist.rb Hoist.hoist_body!"
    exit 1
  end
  
  versions = get_function_history(file, func)
  
  puts "Function history for #{func} in #{file}:"
  puts "  #{versions.size} unique versions found"
  puts ""
  
  versions.each_with_index do |v, i|
    score_label = v[:sloppiness] >= 80 ? "clean" : v[:sloppiness] >= 60 ? "sloppy" : "messy"
    puts "--- Version #{i + 1} (#{v[:sha][0..8]}, score=#{v[:sloppiness]}, #{score_label}) ---"
    puts v[:slice][0..200]
    puts "  ... (#{v[:lines]} lines)" if v[:slice].lines.size > 5
    puts ""
  end

elsif ARGV[0] == '--check-tasks'
  tasks_file = ARGV[1] || 'decomposed_too_large.json'
  result = find_tasks_with_history(tasks_file)
  
  puts "Tasks checked: #{result[:with_history].size + result[:without].size}"
  puts "With historical sloppy versions: #{result[:with_history].size}"
  puts "Without: #{result[:without].size}"
  
  if result[:with_history].any?
    puts "\n=== Sample tasks with history ==="
    result[:with_history].first(10).each do |t|
      fns = t["function_details"] || []
      hist_fns = fns.select { |f| f["historical_versions"] }
      puts "  #{t["sha"][0..8]} #{t["message"][0..50]}"
      hist_fns.each do |f|
        puts "    #{f["file"]}::#{f["name"]} — #{f["historical_versions"]} versions, sloppiest=#{f["sloppiest_score"]}"
      end
    end
  end

elsif ARGV[0] == '--scan-all'
  # Scan all decomposed tasks across all files
  files = Dir["decomposed_*.json"] + ["classified_commits.json"]
  total_with = 0
  total_without = 0
  
  files.each do |fname|
    next unless File.exist?(fname)
    data = JSON.parse(File.read(fname))
    entries = data["results"] || [data].flat_map { |d| 
      %w[simplification feature bug].flat_map { |c| d[c] || [] }
    }
    entries = data.values.flatten if entries.empty?
    
    entries.each do |entry|
      tasks = entry["tasks"] || [entry]
      tasks = [entry] if entry["function_details"]
      
      (tasks).each do |task|
        fns = task["function_details"] || []
        next if fns.empty?
        
        has_hist = false
        fns.each do |fn|
          file = fn["file"] || fn["id"]&.split("::")&.first
          name = fn["name"] || fn["id"]&.split("::")&.last
          next unless file && name
          
          history = get_function_history(file, name, max_commits: 20)
          sloppy_versions = history.select { |v| v[:sloppiness] < 80 && v[:changed] > 0.3 }
          if sloppy_versions.size >= 2
            has_hist = true
            fn["sloppy_count"] = sloppy_versions.size
          end
        end
        
        if has_hist
          total_with += 1
        else
          total_without += 1
        end
      end
    end
  end
  
  puts "=== Full scan results ==="
  puts "  Scanned files: #{files.size}"
  puts "  Tasks WITH historical sloppy versions: #{total_with}"
  puts "  Tasks WITHOUT: #{total_without}"
  puts "  % with history: #{(total_with.to_f / (total_with + total_without) * 100).round(1)}%"

else
  # Demo mode: show a few functions with their history
  puts "Usage:"
  puts "  ruby src/function_history.rb --history <file> <function>  # Show all versions of a function"
  puts "  ruby src/function_history.rb --check-tasks [file.json]    # Check tasks for history"
  puts "  ruby src/function_history.rb --scan-all                   # Scan all task files"
  puts ""
  puts "Demo: Hoist.hoist_body! in src/mir/hoist.rb"
  versions = get_function_history("src/mir/hoist.rb", "Hoist.hoist_body!")
  puts "  #{versions.size} unique versions across git history"
  versions.each_with_index do |v, i|
    label = v[:sloppiness] >= 80 ? "✓ clean" : v[:sloppiness] >= 60 ? "△ sloppy" : "✗ messy"
    puts "  #{i+1}. #{v[:sha][0..8]} score=#{v[:sloppiness]} #{label} (#{v[:lines]} lines)"
  end
end