#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'net/http'
require 'open3'
require 'optparse'
require 'tempfile'
require 'uri'

ROOT = File.expand_path('../..', __dir__)
BUGS_FILE = File.join(ROOT, 'bugs.jsonl')
OUT = File.join(ROOT, 'bugfix')
VENV_PY = File.join(ROOT, '.venv/bin/python3')
MODEL_PATH_3B = File.join(ROOT, 'data/models/qwen2.5-coder-3b-instruct.gguf')
MODEL_PATH_7B = File.join(ROOT, 'data/models/qwen2.5-coder-7b-instruct.gguf')
MODEL_32B = 'qwen/qwen-2.5-coder-32b-instruct'
SYSTEM_PROMPT = 'You are a senior Ruby developer. Fix the bug in the code shown below. Return ONLY the corrected Ruby code in a ```ruby block.'

opts = { count: 50, cats: '', dry_run_prompts: false }
OptionParser.new do |o|
  o.banner = 'Usage: ruby src/synthetic-bugs/run-bugs.rb [options]'
  o.on('--count N', Integer) { |v| opts[:count] = v }
  o.on('--cats LIST') { |v| opts[:cats] = v }
  o.on('--dry-run-prompts') { opts[:dry_run_prompts] = true }
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

def prompt_blind(bug)
  file_rel = file_rel_for(bug)
  func = bug['function'].split('.').last
  <<~PROMPT
    File: #{file_rel}
    Function: #{func}

    #{bug['prompt']}

    Return ONLY the corrected function `#{func}` in a ```ruby block.
  PROMPT
end

def build_function_with_context(bug)
  source = File.read(source_path_for(bug)).tr("\r", '')
  source = source.sub(bug['original_body'].tr("\r", ''), bug['mutated_body'].tr("\r", ''))
  lines = source.lines(chomp: true)
  start_line = bug['function_start_line']
  end_line = bug['function_end_line']
  return lines[(start_line - 1)..(end_line - 1)].join("\n") if start_line && end_line

  bug['mutated_body']
rescue StandardError
  bug['mutated_body']
end

def prompt_with_context(bug)
  file_rel = file_rel_for(bug)
  func = bug['function'].split('.').last
  <<~PROMPT
    File: #{file_rel}
    Function: #{func}

    Here is the current (buggy) code of function `#{func}`:

    ```ruby
    #{build_function_with_context(bug)}
    ```

    #{simulated_worktree_state(bug)}

    #{bug['prompt']}

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
      llm = Llama(model_path=#{model_path.to_json}, n_ctx=4096, n_threads=32, verbose=False, n_gpu_layers=0)
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

def query_openrouter(prompt)
  return '[[SKIPPED: API key not set]]' unless ENV['OPENROUTER_API_KEY']

  uri = URI('https://openrouter.ai/api/v1/chat/completions')
  req = Net::HTTP::Post.new(uri)
  req['Authorization'] = "Bearer #{ENV['OPENROUTER_API_KEY']}"
  req['Content-Type'] = 'application/json'
  req.body = JSON.generate(
    model: MODEL_32B,
    messages: [
      { role: 'system', content: SYSTEM_PROMPT },
      { role: 'user', content: prompt }
    ],
    max_tokens: 1500,
    temperature: 0.1
  )
  resp = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
  data = JSON.parse(resp.body)
  raise "API error: #{data['error']}" if data['error']

  data.dig('choices', 0, 'message', 'content').to_s.strip
rescue StandardError => e
  "[[ERROR: #{e.message}]]"
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

cats = opts[:cats].empty? ? %w[3B-blind 3B-ctx 7B-blind 32B-blind 32B-ctx] : opts[:cats].split(',').map(&:strip)
blinds = sample.map { |bug| prompt_blind(bug) }
ctxs = sample.map { |bug| prompt_with_context(bug) }

cats.each do |cat|
  dir = File.join(OUT, cat)
  FileUtils.mkdir_p(dir)
  prompts = cat.include?('ctx') ? ctxs : blinds

  sample.each_with_index do |_bug, index|
    fpath = File.join(dir, format('%02d.txt', index + 1))
    ppath = File.join(dir, format('%02d.prompt.txt', index + 1))
    label = "[#{cat}] bug #{index + 1}/#{sample.length}"
    puts "  #{label}"
    File.write(ppath, "#{prompts[index]}\n")
    next if opts[:dry_run_prompts]

    result =
      if cat.start_with?('3B')
        query_gguf(MODEL_PATH_3B, prompts[index])
      elsif cat.start_with?('7B')
        query_gguf(MODEL_PATH_7B, prompts[index])
      elsif cat.start_with?('32B')
        query_openrouter(prompts[index])
      else
        '[[UNKNOWN CATEGORY]]'
      end
    File.write(fpath, "#{result}\n")
  end
end

puts
puts 'Done.'
puts 'Dry run: wrote prompt files only.' if opts[:dry_run_prompts]
