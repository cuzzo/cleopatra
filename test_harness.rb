#!/usr/bin/env ruby
# frozen_string_literal: true

# Test Harness for GRAM model evaluation
#
# Tests a model's ability to:
#   1. Use my_tool to discover context
#   2. Generate or fix code
#   3. Improve based on decomplex feedback
#
# Usage:
#   ruby test_harness.rb --task tasks/sample_task.json --model qwen3b
#   ruby test_harness.rb --list-tasks
#   ruby test_harness.rb --run-all --model qwen3b

require 'json'
require 'open3'
require 'fileutils'

REPO = File.expand_path('~/cheat')
TOOL_PATH = File.expand_path('my_tool.rb', __dir__)
RESULTS_DIR = File.expand_path('test_results', __dir__)
FileUtils.mkdir_p(RESULTS_DIR)

TASKS_DIR = File.expand_path('tasks', __dir__)
FileUtils.mkdir_p(TASKS_DIR)

# === Task Definition ===
# Each task is a JSON file:
# {
#   "id": "fix-043",
#   "type": "bug_fix",          # bug_fix, implement, refactor
#   "difficulty": "easy",       # easy, medium, hard
#   "file": "src/mir/hoist.rb",
#   "function": "hoist_body!",
#   "context": "<code before bug>",
#   "expected": "<code after fix>",
#   "decomplex_score_expected": 85,
#   "prompt": "There is a bug in hoist_body!...",
#   "tests": ["spec/mir/hoist_spec.rb:45"]
# }

# === Seed Tasks ===

def seed_tasks
  # Task 1: SIMP — simple cleanup (easy)
  task1 = {
    id: "simp-001",
    type: "refactor",
    difficulty: "easy",
    file: "src/mir/hoist.rb",
    function: "Hoist.hoist_body!",
    prompt: "Simplify hoist_body! by removing the unused return_type parameter and its related logic.",
    expected_function: "Hoist.hoist_body!",
    tests: [],
    metrics: {}
  }
  
  # Task 2: Fix — real bug fix (medium)
  task2 = {
    id: "fix-001",
    type: "bug_fix",
    difficulty: "medium",
    file: "src/mir/mir_lowering.rb",
    function: "MIRLowering.lower",
    prompt: "Fix the bug: lower_copy routes struct-with-cleanup-fields through full_value instead of the correct path.",
    expected_function: "MIRLowering.lower",
    context_hint: "Need to understand how CleanupEntry interacts with lower_copy",
    tests: [],
    metrics: {}
  }
  
  # Task 3: Implement — new function (hard)
  task3 = {
    id: "feat-001",
    type: "implement",
    difficulty: "hard",
    file: "src/mir/hoist.rb",
    function: "Hoist.hoist_escape_value!",
    prompt: "Implement hoist_escape_value! that promotes values escaping via return to heap storage.",
    expected_function: "Hoist.hoist_escape_value!",
    context_hint: "Need to understand escape analysis + heap storage patterns",
    tests: [],
    metrics: {}
  }
  
  [task1, task2, task3].each do |t|
    File.write(File.join(TASKS_DIR, "#{t[:id]}.json"), JSON.pretty_generate(t))
  end
  puts "Seeded 3 tasks in #{TASKS_DIR}"
end

# === Tool Interface ===

class MyTool
  def self.call(query, debug: false)
    debug_flag = debug ? 'debug' : ''
    cmd = "cd #{REPO} && ruby #{TOOL_PATH} '#{query}' #{debug_flag}"
    stdout, stderr, status = Open3.capture3(cmd)
    { stdout: stdout, stderr: stderr, success: status.success? }
  end
end

# === Decomplex Interface ===

class DecomplexScorer
  def self.score(file, function)
    # Extract the function body from the file
    result = MyTool.call("#{file}:#{function}")
    return nil unless result[:success]
    
    body = result[:stdout]
    # Simple heuristic score (replace with real decomplex later)
    score = 100
    score -= 5 * body.scan(/T\.untyped/).size
    score -= 3 * body.scan(/&\./).size
    score -= 8 * body.scan(/rescue/).size
    score -= body.scan(/^\s*#\s*(TODO|FIXME|HACK)/).size * 2
    score -= body.scan(/def\s/).size * 2  # nested defs
    [score, 0].max
  end
end

# === Model Interface ===

class ModelRunner
  def initialize(model_name)
    @model = model_name
  end
  
  def generate(prompt, max_tokens: 512)
    case @model
    when 'mock'
      # Mock model for testing the harness itself
      { text: "Mock model output for: #{prompt[0..50]}", tool_calls: [] }
    else
      # Real model via Ollama
      run_ollama(prompt, max_tokens)
    end
  end
  
  private
  
  def run_ollama(prompt, max_tokens)
    prompt_file = Tempfile.new(['prompt', '.txt'])
    prompt_file.write(prompt)
    prompt_file.close
    
    cmd = "ollama run #{@model} < #{prompt_file.path}"
    stdout, stderr, status = Open3.capture3(cmd)
    
    if status.success?
      { text: stdout.strip, tool_calls: extract_tool_calls(stdout) }
    else
      { text: "Error: #{stderr}", tool_calls: [] }
    end
  ensure
    prompt_file&.unlink
  end
  
  def extract_tool_calls(text)
    calls = []
    text.scan(/my_tool\s+'([^']+)'/) { |m| calls << { tool: 'my_tool', args: m[0] } }
    text.scan(/my_tool\s+"([^"]+)"/) { |m| calls << { tool: 'my_tool', args: m[0] } }
    calls
  end
end

# === Test Runner ===

class TestRunner
  def initialize(model_name)
    @model = ModelRunner.new(model_name)
  end
  
  def run_task(task_file)
    task = JSON.parse(File.read(task_file))
    puts "\n#{'=' * 60}"
    puts "Task: #{task['id']} (#{task['type']}, #{task['difficulty']})"
    puts "File: #{task['file']}##{task['function']}"
    puts "Prompt: #{task['prompt']}"
    puts '=' * 60
    
    # Step 1: Initial context (function + debug info)
    puts "\n→ Calling my_tool for initial context..."
    context = MyTool.call("#{task['file']}:#{task['function']}", debug: true)
    unless context[:success]
      puts "  Tool error: #{context[:stderr]}"
      context = MyTool.call("#{task['file']}:#{task['function']}")
    end
    
    # Step 2: Build prompt for the model
    prompt = build_prompt(task, context[:stdout])
    
    # Step 3: Model generates code
    puts "\n→ Model generating..."
    response = @model.generate(prompt)
    
    # Step 4: Check if model made tool calls
    tool_calls = response[:tool_calls]
    if tool_calls.any?
      puts "  Model made #{tool_calls.size} tool calls:"
      tool_calls.each do |tc|
        puts "    my_tool #{tc[:args]}"
        result = MyTool.call(tc[:args], debug: true)
        puts "    → #{result[:stdout].lines.first(3).join('    → ')}"
      end
    end
    
    # Step 5: Score with decomplex
    score_before = DecomplexScorer.score(task['file'], task['function'])
    
    # Write model output to a temp file for scoring
    output_file = "/tmp/test_model_output_#{task['id']}.rb"
    File.write(output_file, response[:text])
    
    score_after = DecomplexScorer.score(output_file, task['function'])
    
    # Step 6: Results
    result = {
      task_id: task['id'],
      model: @model,
      score_before: score_before,
      score_after: score_after,
      tool_calls: tool_calls.size,
      context_size: context[:stdout].length,
      output: response[:text]
    }
    
    # Save result
    result_file = File.join(RESULTS_DIR, "#{task['id']}_#{Time.now.to_i}.json")
    File.write(result_file, JSON.pretty_generate(result))
    
    puts "\n#{'=' * 60}"
    puts "RESULT:"
    puts "  Score before (original): #{score_before}"
    puts "  Score after (model):     #{score_after}"
    puts "  Tool calls:              #{tool_calls.size}"
    puts "  Saved to:                #{result_file}"
    puts '=' * 60
    
    result
  end
  
  private
  
  def build_prompt(task, context)
    <<~PROMPT
      You are implementing a Ruby function. You have access to a tool:
      
      `my_tool <file>:<function>` — shows the body of a function in the source code
      `my_tool <file>:<function> debug` — same, plus parameter types, called methods, and sibling methods
      `my_tool <file>#<line>` — shows the function at a specific line number
      
      Call my_tool to explore the codebase before writing your solution.
      
      TASK: #{task['prompt']}
      
      File: #{task['file']}
      Function: #{task['function']}
      
      Current code context:
      #{context}
      
      Write your implementation. Use `my_tool` to explore any types or functions you need to understand.
    PROMPT
  end
end

# === CLI ===

case ARGV[0]
when '--seed'
  seed_tasks
  puts "Seeded tasks. Run with: ruby test_harness.rb --run-all --model qwen3b"
  
when '--list-tasks'
  tasks = Dir[File.join(TASKS_DIR, '*.json')]
  puts "Available tasks (#{tasks.size}):"
  tasks.each do |t|
    task = JSON.parse(File.read(t))
    puts "  #{task['id']}: #{task['type']} (#{task['difficulty']}) — #{task['prompt'][0..60]}"
  end
  
when '--run'
  task_file = ARGV[1]
  model = ARGV[2] || 'mock'
  runner = TestRunner.new(model)
  runner.run_task(task_file)
  
when '--run-all'
  model = ARGV[1] || 'mock'
  tasks = Dir[File.join(TASKS_DIR, '*.json')].sort
  runner = TestRunner.new(model)
  results = []
  tasks.each do |t|
    results << runner.run_task(t)
  end
  puts "\n\n=== FINAL RESULTS ==="
  results.each do |r|
    puts "  #{r[:task_id]}: #{r[:score_before]} → #{r[:score_after]} (#{r[:tool_calls]} tool calls)"
  end
  
else
  puts "Usage:"
  puts "  ruby test_harness.rb --seed                    # Create seed tasks"
  puts "  ruby test_harness.rb --list-tasks               # List available tasks"
  puts "  ruby test_harness.rb --run <task.json> [model]  # Run one task"
  puts "  ruby test_harness.rb --run-all [model]          # Run all tasks"
  puts ""
  puts "Models: mock (default), qwen3b, qwen7b, qwen14b, llama3b, etc."
  puts "Mock model tests the harness without a real LLM."
end