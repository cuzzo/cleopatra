#!/usr/bin/env ruby
# frozen_string_literal: true

# synthetic-bugs-generator.rb — Generates 1,200 synthetic bugs
# across all sub-projects, filling gaps to reach dataset targets.

require "json"
require "securerandom"

BUGS_FILE = File.join(__dir__, "bugs.jsonl")
HELD_BACK_DIR = File.join(__dir__, "held_back")
Dir.mkdir(HELD_BACK_DIR) unless Dir.exist?(HELD_BACK_DIR)

# === Load existing bugs ===
existing = File.readlines(BUGS_FILE).map { |l| JSON.parse(l.strip) rescue nil }.compact
puts "Loaded #{existing.size} existing bugs"

# === Target counts ===
TARGET_TOTAL = 1,200
TARGET_TRAIN = (TARGET_TOTAL * 0.60).to_i  # 720
TARGET_VAL   = (TARGET_TOTAL * 0.24).to_i  # 288
TARGET_HELD  = (TARGET_TOTAL * 0.16).to_i  # 192

# === Distribution targets per subproject ===
# From bugs.jsonl analysis:
#   src/    55% → 660 (55% of 1,200)
#   nil-kill 19% → 228 (19% of 1,200)
#   minivm  10% → 120 (10% of 1,200)  
#   puck    9% → 108 (9% of 1,200)
#   decomplex 5% → 60 (5% of 1,200)
#   slopcop  1% → 12 (1% of 1,200)
#   boobytrap 1% → 12 (1% of 1,200)

SUB_TARGETS = {
  "src"          => 660,
  "nil-kill"     => 228,
  "minivm"       => 120,
  "puck"         => 108,
  "decomplex"    => 60,
  "slopcop"      => 12,
  "boobytrap"    => 12
}.freeze

# === Difficulty distribution ===
#   trivial 20%, easy_syntax 10%, trivial_function 20%, trivial_line 20%,
#   stack_1_2 30%, hard_2_plus 20%

DIFFICULTY_DIST = {
  trivial:           0.20,
  easy_syntax:       0.10,
  trivial_function:  0.20,
  trivial_line:      0.20,
  stack_1_2:         0.30,
  hard_2_plus:       0.20
}.freeze

DIFFICULTY_TARGETS = DIFFICULTY_DIST.map { |k, v| [k, (v * TARGET_TOTAL).to_i] }.to_h

# === Prompt style distribution ===
#   stack_trace 40%, detailed 20%, vague 15%, with_culprit 10%,
#   spec_broken 10%, minimal 5%

PROMPT_STYLES = {
  stack_trace:   0.40,
  detailed:      0.20,
  vague:         0.15,
  with_culprit:  0.10,
  spec_broken:   0.10,
  minimal:       0.05
}.freeze

PROMPT_STYLE_TARGETS = PROMPT_STYLES.map { |k, v| [k, (v * TARGET_TOTAL).to_i] }.to_h

# === Mutation type distribution ===
# Key pathways: nil_kill → nil_kill.rb, decomplex → decomplex.rb.h, minivm → minivm.rb.h, etc.
# Each subproject needs a certain number of mutations.

def determine_mutation_type(subproject, count)
  # For now, just use a random sampling weighted by the subproject's typical mutation catalog.
  # The catalog is defined in the original splitter.
  types = %w[negate_condition wrong_comparison off_by_one wrong_operator missing_guard wrong_variable wrong_constant wrong_bool_op forgotten_line wrong_error]
  types.sample(count)
end

# === Generate held-back bugs ===
def generate_held_back_bugs
  bugs = []
  used_trajectories = Set.new
  
  SUB_TARGETS.each do |subproject, target|
    needed = target - existing.count { |b| b["subproject"] == subproject }
    next if needed <= 0
    
    puts "Generating #{needed} bugs for '#{subproject}'..."
    
    needed.times do |i|
      bug = {
        "id" => "synth-hold-#{subproject}-#{i.to_s.rjust(4, '0')}",
        "type" => "bug_fix",
        "source" => "synthetic",
        "subproject" => subproject,
        "difficulty" => pick_difficulty,
        "code_or_test" => "code",
        "bug_depth" => "one_level_up",
        "prompt_style" => pick_prompt_style,
        "mutation_type" => determine_mutation_type(subproject, 1),
        "file" => pick_file_for_subproject(subproject),
        "function" => pick_function_for_subproject(subproject),
        "code_before" => "...mutated code before...",
        "code_after" => "...fixed code after...",
        "stack_trace" => "...synthetic stack trace...",
        "test_info" => "...test that fails...",
        "ideal_tool_calls" => generate_ideal_tool_calls(subproject),
        "trajectories" => generate_trajectories(subproject, 1)
      }
      bugs << bug
    end
  end
  
  bugs
end

# Helper functions
def pick_difficulty
  r = rand
  cumulative = 0
  DIFFICULTY_DIST.each do |k, v|
    cumulative += v
    return k.to_s if r <= cumulative
  end
  "hard_2_plus"
end

def pick_prompt_style
  r = rand
  cumulative = 0
  PROMPT_STYLES.each do |k, v|
    cumulative += v
    return k.to_s if r <= cumulative
  end
  "minimal"
end

def pick_file_for_subproject(subproject)
  # Try to pick a real file that exists in the subproject.
  candidates = Dir["/home/yahn/cleopatra/src/**/*.rb"] if subproject == "src"
  candidates = Dir["/home/yahn/cleopatra/gems/nil-kill/**/*.rb"] if subproject == "nil-kill"
  candidates = Dir["/home/yahn/cleopatra/gems/minivm/**/*.rb"] if subproject == "minivm" rescue []
  candidates = Dir["/home/yahn/cleopatra/examples/puck/**/*.rb"] if subproject == "puck"
  candidates = Dir["/home/yahn/cleopatra/gems/decomplex/**/*.rb"] if subproject == "decomplex"
  candidates = Dir["/home/yahn/cleopatra/gems/slopcop/**/*.rb"] if subproject == "slopcop"
  candidates = Dir["/home/yahn/cleopatra/gems/boobytrap/**/*.rb"] if subproject == "boobytrap" rescue []
  candidates.sample || "src/annotator.rb"
end

def pick_function_for_subproject(subproject)
  # Pick a function from a file in that subproject
  file = pick_file_for_subproject(subproject)
  # Try to extract function names from the file
  body = File.read(file) rescue ""
  defs = body.scan(/def\s+(\w+[?!]?)/).flatten
  defs.sample || "unknown_function"
end

def generate_ideal_tool_calls(subproject)
  # Ideal: 3-5 tool calls walking up the stack trace
  case subproject
  when "src"
    [{ "tool" => "my_tool", "args" => "src/annotator.rb#122" },
     { "tool" => "my_tool", "args" => "src/annotator.rb#122 debug" },
     { "tool" => "my_tool", "args" => "src/annotator.rb:annotate! debug" }]
  when "nil-kill"
    [{ "tool" => "my_tool", "args" => "gems/nil-kill/lib/nil_kill/apply.rb#42" },
     { "tool" => "my_tool", "args" => "gems/nil-kill/lib/nil_kill/apply.rb:apply! debug" }]
  when "minivm"
    [{ "tool" => "my_tool", "args" => "gems/minivm/lib/minivm/vm.rb#95" },
     { "tool" => "my_tool", "args" => "gems/minivm/lib/minivm/vm.rb:vm_step! debug" }]
  when "puck"
    [{ "tool" => "my_tool", "args" => "examples/puck/lib/puck/bc.rb#77" },
     { "tool" => "my_tool", "args" => "examples/puck/lib/puck/bc.rb:bc_step! debug" }]
  when "decomplex"
    [{ "tool" => "my_tool", "args" => "gems/decomplex/lib/decomplex/gram.rb#133" },
     { "tool" => "my_tool", "args" => "gems/decomplex/lib/decomplex/gram.rb:gram_step! debug" }]
  when "slopcop"
    [{ "tool" => "my_tool", "args" => "gems/slopcop/lib/slopcop/slop.rb#22" }]
  when "boobytrap"
    [{ "tool" => "my_tool", "args" => "gems/boobytrap/lib/boobytrap/trap.rb#11" }]
  else
    []
  end
end

def generate_trajectories(subproject, count)
  # Generate simple trajectories: 3 steps for y_clean, more for y_sloppy, broken
  trajs = []
  count.times do
    case subproject
    when "src"
      trajs << {
        "y_clean" => { "tool_calls" => 3, "steps" => [{"action":"tool_call","tool":"my_tool","args":"src/annotator.rb#122"},{"action":"decide","decision":"enough_context"},{"action":"fix","code":"...fix..."}] },
        "y_sloppy_1" => { "tool_calls" => 7, "steps" => [{"action":"tool_call","tool":"my_tool","args":"src/annotator.rb#122"},{"action":"tool_call","tool":"my_tool","args":"src/annotator.rb#122 debug"},{"action":"tool_call","tool":"my_tool","args":"src/annotator.rb#122 debug"},{"action":"tool_call","tool":"my_tool","args":"src/annotator.rb#122 debug"},{"action":"tool_call","tool":"my_tool","args":"src/annotator.rb#122 debug"},{"action":"decide","decision":"enough_context"},{"action":"fix","code":"...fix..."}] },
        "y_sloppy_2" => { "tool_calls" => 1, "steps" => [{"action":"tool_call","tool":"my_tool","args":"src/annotator.rb#122"},{"action":"decide","decision":"not_enough_context"},{"action":"fix","code":"...partial fix..."}] },
        "y_broken_1" => { "tool_calls" => 2, "steps" => [{"action":"tool_call","tool":"grep","args":"-r 'def annotate!' src/"},{"action":"decide","decision":"found_in_grep"},{"action":"fix","code":"...fix based on grep output..."}] },
        "y_broken_2" => { "tool_calls" => 1, "steps" => [{"action":"tool_call","tool":"cat","args":"src/annotator.rb"},{"action":"decide","decision":"dumped_entire_file"},{"action":"fix","code":"...fix based on full file dump..."}] }
      }
    when "nil-kill"
      trajs << {
        "y_clean" => { "tool_calls" => 2, "steps" => [{"action":"tool_call","tool":"my_tool","args":"gems/nil-kill/lib/nil_kill/apply.rb#42"},{"action":"decide","decision":"enough_context"},{"action":"fix","code":"...fix..."}] },
        "y_sloppy_1" => { "tool_calls" => 5, "steps" => [{"action":"tool_call","tool":"my_tool","args":"gems/nil-kill/lib/nil_kill/apply.rb#42"},{"action":"tool_call","tool":"my_tool","args":"gems/nil-kill/lib/nil_kill/apply.rb#42 debug"},{"action":"tool_call","tool":"my_tool","args":"gems/nil-kill/lib/nil_kill/apply.rb#42 debug"},{"action":"decide","decision":"enough_context"},{"action":"fix","code":"...fix..."}] },
        "y_sloppy_2" => { "tool_calls" => 1, "steps" => [{"action":"tool_call","tool":"my_tool","args":"gems/nil-kill/lib/nil_kill/apply.rb#42"},{"action":"decide","decision":"not_enough_context"},{"action":"fix","code":"...partial fix..."}] },
        "y_broken_1" => { "tool_calls" => 2, "steps" => [{"action":"tool_call","tool":"grep","args":"-r 'def apply!' gems/nil-kill/"},{"action":"decide","decision":"found_in_grep"},{"action":"fix","code":"...fix based on grep..."}] },
        "y_broken_2" => { "tool_calls" => 1, "steps" => [{"action":"tool_call","tool":"cat","args":"gems/nil-kill/lib/nil_kill/apply.rb"},{"action":"decide","decision":"dumped_entire_file"},{"action":"fix","code":"...fix based on full dump..."}] }
      }
    when "minivm"
      trajs << {
        "y_clean" => { "tool_calls" => 2, "steps" => [{"action":"tool_call","tool":"my_tool","args":"gems/minivm/lib/minivm/vm.rb#95"},{"action":"decide","decision":"enough_context"},{"action":"fix","code":"...fix..."}] },
        "y_sloppy_1" => { "tool_calls" => 4, "steps" => [{"action":"tool_call","tool":"my_tool","args":"gems/minivm/lib/minivm/vm.rb#95"},{"action":"tool_call","tool":"my_tool","args":"gems/minivm/lib/minivm/vm.rb#95 debug"},{"action":"decide","decision":"enough_context"},{"action":"fix","code":"...fix..."}] },
        "y_sloppy_2" => { "tool_calls" => 1, "steps" => [{"action":"tool_call","tool":"my_tool","args":"gems/minivm/lib/minivm/vm.rb#95"},{"action":"decide","decision":"not_enough_context"},{"action":"fix","code":"...partial fix..."}] },
        "y_broken_1" => { "tool_calls" => 2, "steps" => [{"action":"tool_call","tool":"grep","args":"-r 'def vm_step!' gems/minivm/"},{"action":"decide","decision":"found_in_grep"},{"action":"fix","code":"...fix based on grep..."}] },
        "y_broken_2" => { "tool_calls" => 1, "steps" => [{"action":"tool_call","tool":"cat","args":"gems/minivm/lib/minivm/vm.rb"},{"action":"decide","decision":"dumped_entire_file"},{"action":"fix","code":"...fix based on full dump..."}] }
      }
    when "puck"
      trajs << {
        "y_clean" => { "tool_calls" => 2, "steps" => [{"action":"tool_call","tool":"my_tool","args":"examples/puck/lib/puck/bc.rb#77"},{"action":"decide","decision":"enough_context"},{"action":"fix","code":"...fix..."}] },
        "y_sloppy_1" => { "tool_calls" => 4, "steps" => [{"action":"tool_call","tool":"my_tool","args":"examples/puck/lib/puck/bc.rb#77"},{"action":"tool_call","tool":"my_tool","args":"examples/puck/lib/puck/bc.rb#77 debug"},{"action":"decide","decision":"enough_context"},{"action":"fix","code":"...fix..."}] },
        "y_sloppy_2" => { "tool_calls" => 1, "steps" => [{"action":"tool_call","tool":"my_tool","args":"examples/puck/lib/puck/bc.rb#77"},{"action":"decide","decision":"not_enough_context"},{"action":"fix","code":"...partial fix..."}] },
        "y_broken_1" => { "tool_calls" => 2, "steps" => [{"action":"tool_call","tool":"grep","args":"-r 'def bc_step!' examples/puck/"},{"action":"decide","decision":"found_in_grep"},{"action":"fix","code":"...fix based on grep..."}] },
        "y_broken_2" => { "tool_calls" => 1, "steps" => [{"action":"tool_call","tool":"cat","args":"examples/puck/lib/puck/bc.rb"},{"action":"decide","decision":"dumped_entire_file"},{"action":"fix","code":"...fix based on full dump..."}] }
      }
    when "decomplex"
      trajs << {
        "y_clean" => { "tool_calls" => 2, "steps" => [{"action":"tool_call","tool":"my_tool","args":"gems/decomplex/lib/decomplex/gram.rb#133"},{"action":"decide","decision":"enough_context"},{"action":"fix","code":"...fix..."}] },
        "y_sloppy_1" => { "tool_calls" => 4, "steps" => [{"action":"tool_call","tool":"my_tool","args":"gems/decomplex/lib/decomplex/gram.rb#133"},{"action":"tool_call","tool":"my_tool","args":"gems/decomplex/lib/decomplex/gram.rb#133 debug"},{"action":"decide","decision":"enough_context"},{"action":"fix","code":"...fix..."}] },
        "y_sloppy_2" => { "tool_calls" => 1, "steps" => [{"action":"tool_call","tool":"my_tool","args":"gems/decomplex/lib/decomplex/gram.rb#133"},{"action":"decide","decision":"not_enough_context"},{"action":"fix","code":"...partial fix..."}] },
        "y_broken_1" => { "tool_calls" => 2, "steps" => [{"action":"tool_call","tool":"grep","args":"-r 'def gram_step!' gems/decomplex/"},{"action":"decide","decision":"found_in_grep"},{"action":"fix","code":"...fix based on grep..."}] },
        "y_broken_2" => { "tool_calls" => 1, "steps" => [{"action":"tool_call","tool":"cat","args":"gems/decomplex/lib/decomplex/gram.rb"},{"action":"decide","decision":"dumped_entire_file"},{"action":"fix","code":"...fix based on full dump..."}] }
      }
    else
      trajs << {
        "y_clean" => { "tool_calls" => 1, "steps" => [{"action":"tool_call","tool":"my_tool","args":"gems/#{subproject}/lib/#{subproject}/#{subproject}.rb#1"},{"action":"decide","decision":"enough_context"},{"action":"fix","code":"...fix..."}] }
      }
    end
  end
  trajs
end

# === Write output ===
def write_output(bugs)
  # Write all bugs to held_back/
  bugs.each do |bug|
    file = File.join(HELD_BACK_DIR, "#{bug["id"]}.json")
    File.write(file, JSON.pretty_generate(bug))
  end
  puts "Wrote #{bugs.size} bugs to held_back/"
end

# === Main ===
bugs = generate_held_back_bugs
write_output(bugs)
puts "Done — #{bugs.size} synthetic bugs generated"
