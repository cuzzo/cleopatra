#!/usr/bin/env ruby
# frozen_string_literal: true

# Classify commits against model tier cutoffs
#
# Takes triage_results.json (promising commits) and produces
# classified_commits.json with:
#   - Function-level decomposition of each diff
#   - Context size estimates (ideal context in tokens)
#   - Output size measurements (functions changed, lines changed)
#   - Tier classification (3B, 14B, 30B, or too_large)
#   - Pre-squash match info (for backup branch commits)

require 'json'
require 'prism'

# === Token estimation ===
# Qwen2.5-Coder tokenizer averages ~10 tok/line for real Ruby code.
# We use a character-based heuristic: ~0.25 tok/char (a close proxy).
def estimate_tokens(text)
  (text.length / 4.0).round
end

# === Cutoffs ===
CUTOFFS = {
  '3B'  => { ideal_ctx: 16_000, max_ctx: 32_000, max_fns: 4,  max_lines: 100, max_out_tok: 4_096 },
  '14B' => { ideal_ctx: 32_000, max_ctx: 64_000, max_fns: 8,  max_lines: 250, max_out_tok: 8_192 },
  '30B' => { ideal_ctx: 64_000, max_ctx: 128_000, max_fns: 15, max_lines: 500, max_out_tok: 16_384 },
}.freeze

REPO_PATHS = {
  cheat:   File.expand_path('~/cheat'),
  clear:   File.expand_path('~/clear'),
  easy_vm: File.expand_path('~/easy-vm'),
  manual:  File.expand_path('~/manual/clear'),
  litedb:  File.expand_path('~/litedb'),
}.freeze

# === Ruby Function Finder (Prism) ===
class FunctionFinder
  # Find function boundaries in Ruby source using Prism.
  # Returns [{name:, start_line:, end_line:, lines:, body:, slice:}]
  def find_functions(source_code)
    parsed = Prism.parse(source_code)
    return [] unless parsed.success?
    
    functions = []
    walk_defs(parsed.value, functions)
    functions
  end
  
  # Find class boundaries
  def find_classes(source_code)
    parsed = Prism.parse(source_code)
    return [] unless parsed.success?
    
    classes = []
    walk_classes(parsed.value, classes)
    classes
  end

  private

  def walk_defs(node, result, nesting = '')
    return unless node.respond_to?(:child_nodes)
    
    if node.is_a?(Prism::DefNode)
      name = node.name.to_s
      full_name = nesting.empty? ? name : "#{nesting}.#{name}"
      body = node.body&.slice || ''
      
      result << {
        name: full_name,
        start_line: node.location.start_line,
        end_line: node.location.end_line,
        lines: node.location.end_line - node.location.start_line + 1,
        body: body,
        slice: node.slice
      }
      
      # Recurse into body for nested defs
      walk_defs(node.body, result, full_name) if node.body
    elsif node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
      class_name = node.constant_path&.slice || node.name.to_s
      full_nesting = nesting.empty? ? class_name : "#{nesting}::#{class_name}"
      walk_defs(node.body, result, full_nesting) if node.body
    else
      node.child_nodes&.compact&.each { |child| walk_defs(child, result, nesting) }
    end
  end
  
  def walk_classes(node, result, nesting = '')
    return unless node.respond_to?(:child_nodes)
    
    if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
      name = node.constant_path&.slice || node.name.to_s
      full_name = nesting.empty? ? name : "#{nesting}::#{name}"
      
      # Get methods in this class
      methods = []
      walk_defs(node.body, methods) if node.body
      
      result << {
        name: full_name,
        start_line: node.location.start_line,
        end_line: node.location.end_line,
        lines: node.location.end_line - node.location.start_line + 1,
        methods: methods,
        slice: node.slice
      }
      
      # Nested classes/modules
      walk_classes(node.body, result, full_name) if node.body
    else
      node.child_nodes&.compact&.each { |child| walk_classes(child, result, nesting) }
    end
  end
end

# === Commit Classifier ===
class CommitClassifier
  def initialize
    @finder = FunctionFinder.new
  end

  def classify_commit(entry)
    repo = entry['repo']&.to_sym || :cheat
    path = REPO_PATHS[repo] || REPO_PATHS[:cheat]
    sha = entry['sha']
    category = entry['category'] || 'simplification'
    area = entry['area']

    # Verify the commit exists
    return nil if `cd #{path} && git cat-file -e #{sha} 2>&1` !~ /^\s*$/

    # 1. Get the diff stat
    files, insertions, deletions = get_diff_stat(path, sha)
    return nil unless files && files.any?

    total_changes = insertions + deletions

    # 2. For each changed Ruby file, extract function-level changes
    function_changes = []
    context_deps = []  # Type dependencies across all changed functions

    files.each do |file|
      next unless file.end_with?('.rb')
      
      before_content = git_show(path, "#{sha}^", file)
      after_content  = git_show(path, sha, file)
      
      next unless before_content && after_content

      # Find functions in both versions
      before_fns = @finder.find_functions(before_content)
      after_fns  = @finder.find_functions(after_content)
      
      # Build a name→fn map
      before_map = before_fns.each_with_object({}) { |f, h| h[f[:name]] = f }
      after_map  = after_fns.each_with_object({}) { |f, h| h[f[:name]] = f }
      
      all_names = (before_map.keys + after_map.keys).uniq
      
      all_names.each do |name|
        bfn = before_map[name]
        afn = after_map[name]
        
        if bfn && afn
          # Modified function
          next if bfn[:body] == afn[:body]  # unchanged
          
          changed_lines = count_diff_lines(bfn[:body], afn[:body])
          
          function_changes << {
            type: 'modified',
            file: file,
            function: name,
            before_lines: bfn[:lines],
            after_lines: afn[:lines],
            changed_lines: changed_lines,
            before_body: bfn[:body],
            after_body: afn[:body],
            sig: extract_signature(afn[:body])
          }
        elsif afn
          # New function
          function_changes << {
            type: 'added',
            file: file,
            function: name,
            before_lines: 0,
            after_lines: afn[:lines],
            changed_lines: afn[:lines],
            before_body: '',
            after_body: afn[:body],
            sig: extract_signature(afn[:body])
          }
        elsif bfn
          # Deleted function (note but don't include as output)
        end
      end
      
      # Extract type/constant dependencies from changed functions
      after_fns.each do |fn|
        context_deps.concat(extract_dependencies(fn[:body]))
      end
    end

    return nil if function_changes.empty?

    # 3. Compute metrics for each tier
    total_output_fns = function_changes.size
    total_output_lines = function_changes.sum { |fc| fc[:changed_lines] }
    
    # Ideal context: all changed function bodies + their dependencies + type defs
    # (We estimate this as the after-code of all changed functions plus 20% overhead for deps)
    changed_bodies = function_changes.map { |fc| fc[:after_body] }.join("\n\n")
    ideal_context = changed_bodies
    # Add dependency definitions (type defs, callee sigs — estimated as 30% of body size)
    dep_overhead = (changed_bodies.length * 0.3).round
    ideal_context += "\n\n# Types & dependencies:\n#{' ' * dep_overhead}"
    
    ideal_ctx_tokens = estimate_tokens(ideal_context)
    output_tokens    = estimate_tokens(changed_bodies)
    
    # 4. Classify by tier
    classification = classify(ideal_ctx_tokens, total_output_fns, total_output_lines, output_tokens)

    {
      sha: sha,
      message: entry['message'],
      category: category,
      area: area,
      repo: repo,
      insertions: insertions,
      deletions: deletions,
      files: files,
      tier: classification[:tier],
      fits_ideal_context: classification[:fits_ideal],
      fits_max_context: classification[:fits_max],
      
      metrics: {
        output_functions: total_output_fns,
        output_lines: total_output_lines,
        ideal_context_tokens: ideal_ctx_tokens,
        max_context_tokens: ideal_ctx_tokens + output_tokens + 2048,  # instruction overhead
        output_tokens: output_tokens,
        total_files_changed: files.size,
        total_ruby_files_changed: files.count { |f| f.end_with?('.rb') },
      },
      
      function_changes: function_changes.map { |fc|
        {
          type: fc[:type],
          file: fc[:file],
          function: fc[:function],
          changed_lines: fc[:changed_lines],
          sig: fc[:sig]
        }
      },
      
      # Why it's classified this way
      classification_reason: classification[:reason]
    }
  end

  private

  def get_diff_stat(repo_path, sha)
    result = `cd #{repo_path} && git diff-tree --no-commit-id -r --numstat #{sha} 2>/dev/null`.strip
    return [nil, nil, nil] if result.empty?
    
    files = []
    insertions = 0
    deletions = 0
    
    result.lines.each do |line|
      parts = line.split("\t")
      next unless parts.size == 3
      files << parts[2].strip
      insertions += parts[0].to_i
      deletions += parts[1].to_i
    end
    
    [files, insertions, deletions]
  end

  def git_show(repo_path, sha, file)
    `cd #{repo_path} && git show #{sha}:#{file} 2>/dev/null`
  end

  def count_diff_lines(before, after)
    # Simple line diff count
    before_lines = before.split("\n")
    after_lines  = after.split("\n")
    (before_lines - after_lines).size + (after_lines - before_lines).size
  end

  def extract_signature(body)
    # First line of the function body (usually the sig + def line)
    lines = body.split("\n")
    sig_lines = lines.select { |l| l.strip.start_with?('sig ') || l.strip.start_with?('def ') }
    sig_lines.first(3).join("\n")  # sig, def, maybe a type annotation
  end

  def extract_dependencies(body)
    # Find type references and method calls in the body
    deps = []
    body.scan(/\b([A-Z]\w*)\b/) { |m| deps << m[0] }  # Type names (capitalized)
    body.scan(/require(?:_relative)?\s+['"]([^'"]+)['"]/) { |m| deps << "require: #{m[0]}" }
    deps.uniq
  end

  def classify(ctx_tokens, out_fns, out_lines, out_tokens)
    # Try tiers from smallest to largest — assign the smallest that fits
    %w[3B 14B 30B].each do |tier|
      c = CUTOFFS[tier]
      fits_ideal = ctx_tokens <= c[:ideal_ctx]
      fits_max   = ctx_tokens <= c[:max_ctx]
      
      if out_fns <= c[:max_fns] && out_lines <= c[:max_lines] && out_tokens <= c[:max_out_tok] && fits_ideal
        return { tier: tier, fits_ideal: true, fits_max: true, reason: "Fits #{tier} ideal context" }
      elsif out_fns <= c[:max_fns] && out_lines <= c[:max_lines] && out_tokens <= c[:max_out_tok] && fits_max
        return { tier: tier, fits_ideal: false, fits_max: true, reason: "Fits #{tier} max but not ideal — needs context trimming" }
      end
    end
    
    # Check if it fits 30B max context at all
    c = CUTOFFS['30B']
    if ctx_tokens <= c[:max_ctx]
      { tier: 'too_large_output', fits_ideal: false, fits_max: true,
        reason: "Context fits 30B max (#{ctx_tokens} ≤ #{c[:max_ctx]}) but output exceeds limits: #{out_fns}fns #{out_lines}lines #{out_tokens}tok" }
    else
      { tier: 'too_large', fits_ideal: false, fits_max: false,
        reason: "Exceeds 30B max context: #{ctx_tokens} > #{c[:max_ctx]}" }
    end
  end
end

# === Main ===

def load_triage_results
  if File.exist?('triage_results.json')
    data = JSON.parse(File.read('triage_results.json'))
    # Handle both old format (plural keys) and new format (singular keys)
    data
  else
    puts "No triage_results.json found. Run triage_commits.rb first."
    exit 1
  end
end

def classify_all
  triage = load_triage_results
  classifier = CommitClassifier.new
  
  all_entries = []
  # Try both singular and plural keys
  %w[simplification simplifications feature features bug bugs].each do |key|
    (triage[key] || []).each do |entry|
      cat = key.sub(/s$/, '')  # simplifications -> simplification
      entry['category'] = cat
      all_entries << entry
    end
  end

  puts "Classifying #{all_entries.size} commits..."
  
  classified = { simplification: [], feature: [], bug: [],
                  too_large: [], errors: [] }
  
  all_entries.each_with_index do |entry, i|
    sha = entry['sha'][0..8]
    print "\r  [#{i+1}/#{all_entries.size}] #{sha}..."
    $stdout.flush
    
    begin
      result = classifier.classify_commit(entry)
      
      if result.nil?
        classified[:errors] << { sha: entry['sha'], message: entry['message'], error: 'No function changes found' }
      elsif result[:tier] == 'too_large' || result[:tier] == 'too_large_output'
        classified[:too_large] << result
      else
        cat = entry['category'].to_sym
        classified[cat] << result
      end
    rescue => e
      classified[:errors] << { sha: entry['sha'], message: entry['message'], error: e.message }
    end
  end

  puts "\n\nDone."
  classified
end

def print_summary(classified)
  puts "=" * 72
  puts "CLASSIFICATION SUMMARY"
  puts "=" * 72
  
  total = 0
  %i[simplification feature bug].each do |cat|
    entries = classified[cat]
    next if entries.empty?
    
    tiers = entries.group_by { |e| e[:tier] }
    total += entries.size
    
    puts "\n#{cat.to_s.capitalize}: #{entries.size} commits"
    tiers.sort.each do |tier, group|
      fits = group.count { |e| e[:fits_ideal_context] }
      puts "  #{tier}: #{group.size} (#{fits} fit ideal context)"
    end
  end
  
  puts "\nToo large / needs splitting: #{classified[:too_large].size}"
  puts "Errors: #{classified[:errors].size}"
  puts "\nTotal viable: #{total}"
  
  # Print top examples for each tier
  %w[3B 14B 30B].each do |tier|
    examples = []
    %i[simplification feature bug].each do |cat|
      classified[cat].select { |e| e[:tier] == tier }.first(3).each do |e|
        examples << e
      end
    end
    next if examples.empty?
    
    puts "\n--- Top #{tier} examples ---"
    examples.each do |e|
      m = e[:metrics]
      icon = e[:fits_ideal_context] ? '✓' : '△'
      puts "  #{icon} #{e[:sha][0..8]} | #{e[:message][0..55]}"
      puts "       #{m[:output_functions]}fns #{m[:output_lines]}lines ctx:#{m[:ideal_context_tokens]}tok out:#{m[:output_tokens]}tok"
    end
  end
end

# === Run ===
classified = classify_all
print_summary(classified)

# Export
output = {
  generated_at: Time.now.strftime('%Y-%m-%dT%H:%M:%S%z'),
  cutoffs: CUTOFFS,
  simplification: classified[:simplification],
  feature: classified[:feature],
  bug: classified[:bug],
  too_large: classified[:too_large],
  errors: classified[:errors],
  stats: {
    simplification: classified[:simplification].size,
    feature: classified[:feature].size,
    bug: classified[:bug].size,
    too_large: classified[:too_large].size,
    errors: classified[:errors].size,
    tier_14b: classified[:simplification].count { |c| c[:tier] == '3B' } +
              classified[:feature].count { |c| c[:tier] == '3B' } +
              classified[:bug].count { |c| c[:tier] == '3B' },
    tier_30b: classified[:simplification].count { |c| c[:tier] == '14B' } +
              classified[:feature].count { |c| c[:tier] == '14B' } +
              classified[:bug].count { |c| c[:tier] == '14B' },
  }
}

File.write('classified_commits.json', JSON.pretty_generate(output))
puts "\n  → classified_commits.json"