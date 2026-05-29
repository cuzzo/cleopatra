#!/usr/bin/env ruby
# frozen_string_literal: true

# format-train.rb — Convert bug.jsonl trajectories into training examples.
#
# For each bug, we produce a multi-turn conversation:
#   [user prompt] → [model: tool_call] → [tool_result] → [model: fix]
#
# Output: train.jsonl / val.jsonl / held.jsonl in the format expected by
# PyTorch/HuggingFace fine-tuning pipelines.

require 'json'
require 'fileutils'

ROOT = File.expand_path('..', __dir__)
BUGS_FILE = File.join(ROOT, 'bugs.jsonl')
OUTDIR = File.join(ROOT, 'training_data')
FileUtils.mkdir_p(OUTDIR)

# === Special tokens for tool calling ===
TOOL_CALL = '<|tool_call|>'
TOOL_RESULT = '<|tool_result|>'
FIX = '<|fix|>'
END_TOKEN = '<|end|>'

# === Render one step into training tokens ===
def render_step(step)
  case step['action']
  when 'tool_call'
    "#{TOOL_CALL} #{step['tool']} #{step['args']}\n"
  when 'tool_result', 'result'
    "#{TOOL_RESULT} #{step['result'] || '(function body)'}\n"
  when 'decide'
    "# step: #{step['decision']}\n"
  when 'fix'
    "#{FIX}\n#{step['code']}\n#{END_TOKEN}"
  else
    "# step: #{step.inspect}\n"
  end
end

# === Build a full training example from a bug trajectory ===
def build_example(bug, trajectory_key)
  traj = bug['trajectories'][trajectory_key]
  prompt = bug['prompt']
  steps = traj['steps']

  # The conversation:
  #   User: [prompt]
  #   Assistant: [tool_call tool_result ... fix]
  input = prompt
  output = steps.map { |s| render_step(s) }.join

  # For loss masking: we only compute loss on the assistant's output tokens,
  # not on the user's input or tool results.
  # We return the full [input + output] but mark output positions.
  {
    'id' => "#{bug['id']}-#{trajectory_key}",
    'input' => input,
    'output' => output,
    'full_text' => input + "\n" + output,
    'reward' => traj['reward'],
    'difficulty' => bug['difficulty'],
    'subproject' => bug['subproject'],
    'trajectory_type' => trajectory_key,
    'tool_calls' => traj['tool_calls'],
    'prompt' => prompt,
    'ideal_tool_sequence' => bug['ideal_tool_calls'],
  }
end

# === Write a split ===
def write_split(bugs, split_name)
  path = File.join(OUTDIR, "#{split_name}.jsonl")
  count = 0
  File.open(path, 'w') do |f|
    bugs.each do |bug|
      # Write all 5 trajectories per bug
      %w[y_clean y_broken_wrong_fn y_sloppy_over y_sloppy_under y_blind_native].each do |tk|
        ex = build_example(bug, tk)
        f.puts JSON.generate(ex)
        count += 1
      end
    end
  end
  puts "#{split_name}: #{count} examples (from #{bugs.size} bugs)"
  count
end

# === Main ===
bugs = File.readlines(BUGS_FILE).map { |l| JSON.parse(l.strip) rescue nil }.compact
puts "Total bugs: #{bugs.size}"

# Shuffle
srand(42)
bugs.shuffle!

# Held-back split: 60% train, 24% val, 16% held
n = bugs.size
train = bugs[0...(n * 0.60).to_i]
val   = bugs[(n * 0.60).to_i...(n * 0.84).to_i]
held  = bugs[(n * 0.84).to_i..-1]

puts "Splits: train=#{train.size} val=#{val.size} held=#{held.size}"

total = 0
total += write_split(train, 'train')
total += write_split(val, 'val')
total += write_split(held, 'held')

puts ""
puts "=== Summary ==="
puts "Total training examples: #{total}"
puts "  (1,200 bugs x 5 trajectories = 6,000 examples)"
puts ""
puts "Output directory: #{OUTDIR}"
puts "  train.jsonl  — for supervised fine-tuning"
puts "  val.jsonl    — for validation during training"
puts "  held.jsonl   — for held-back evaluation"
puts ""
puts "=== How to use ==="
puts "Each line is a JSON object with:"
puts "  full_text: input + output to train on"
puts "  input: the bug prompt"
puts "  output: the assistant's tool calls + fix"
puts "  reward: training signal weight"
puts "  trajectory_type: which variant this is"
puts ""
puts "For supervised fine-tuning:"
puts "  1. Tokenize full_text"
puts "  2. Compute loss ONLY on output tokens (mask input tokens)"
puts "  3. Weight loss by reward (y_clean=10x, y_blind_native=0.1x)"
puts ""
puts "For RL fine-tuning:"
puts "  1. Feed input to model"
puts "  2. Let model generate tool calls + fix"
puts "  3. Compare against ideal_tool_sequence"
puts "  4. Score: tool_call_match * 10 + fix_quality * 5"
