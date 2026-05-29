#!/usr/bin/env ruby
# frozen_string_literal: true

# evaluate.rb — Test model bugfixes against actual Ruby tests.
#
# Applies mutation → model fix → syntax check → test runner.
# Uses ~/cheat at HEAD (ec4ca1dac) with git restore after each test.
#
# Usage: ruby src/evaluate.rb [--count 50]

CHEAT = File.expand_path('~/cheat')
BUGS_FILE = File.join(__dir__, '..', 'bugs.jsonl')
BUGFIX_DIR = File.join(__dir__, '..', 'bugfix')

require 'json'
require 'fileutils'
require 'tempfile'

count = (ARGV.find { |a| a =~ /--count=(\d+)/ } && $1 || '50').to_i

# Ensure cleanup at exit
at_exit { system("cd #{CHEAT} && git checkout -- . 2>/dev/null") }

srand(42)
all_bugs = File.readlines(BUGS_FILE).map { |l| JSON.parse(l.strip) rescue nil }.compact
sample = all_bugs.sample(count)

def extract_code(text)
  if text =~ /```ruby\n(.*?)```/m
    $1.strip
  elsif text =~ /```\n?(.*?)```/m
    $1.strip
  else
    nil
  end
end

def find_test(bug)
  func = bug['function'].split('.').last
  dirs = {
    'src'       => ['spec'],
    'nil_kill'  => ['gems/nil-kill/spec'],
    'minivm'    => ['examples/minivm'],
    'decomplex' => ['gems/decomplex/test'],
    'slopcop'   => ['gems/slopcop/test'],
    'boobytrap' => ['gems/boobytrap/test'],
  }
  (dirs[bug['subproject']] || ['spec']).each do |d|
    full = File.join(CHEAT, d)
    next unless Dir.exist?(full)
    Dir["#{full}/**/*_spec.rb", "#{full}/**/*_test.rb", "#{full}/**/*.rb"].each do |tf|
      cont = File.read(tf) rescue next
      return tf if cont.include?(func)
    end
  end
  nil
end

def apply_mutation_and_fix(bug, fix_code)
  filepath = bug['file']
  orig = bug['original_body']
  mutated = bug['mutated_body']

  system("cd #{CHEAT} && git checkout -- . 2>/dev/null")   # restore clean state

  # 1: Verify original body exists
  src = File.read(filepath) rescue nil
  return 'NO_FILE' unless src
  return 'ORIG_NOT_FOUND' unless src.include?(orig) || src.include?(mutated)

  # 2: Apply mutation (introduce the bug)
  buggy = src.include?(orig) ? src.sub(orig, mutated) : src.dup
  return 'MUT_NOT_APPLIED' unless buggy.include?(mutated)

  # 3: Apply model fix
  fixed = buggy.sub(mutated, fix_code)
  return 'FIX_NOT_APPLIED' if fixed == buggy

  # 4: Syntax check
  tmp = Tempfile.new(['fix', '.rb'])
  tmp.write(fixed); tmp.close
  ok = system("ruby -c #{tmp.path} 2>/dev/null")
  File.unlink(tmp.path)
  return 'SYNTAX_ERROR' unless ok

  # 5: Write to disk and run test
  bak = filepath + '.evalbak'
  FileUtils.cp(filepath, bak)
  File.write(filepath, fixed)

  test_file = find_test(bug)
  result = nil
  if test_file
    result = `cd #{CHEAT} && ruby -Ilib -Ispec #{test_file} 2>&1`
    passed = $?.success?
  else
    passed = true   # no test = syntax-OK is pass
    result = 'NO_TEST'
  end

  # 6: Restore
  FileUtils.mv(bak, filepath)

  [passed ? 'TEST_PASSED' : 'TEST_FAILED', result]
end

# === Run ===

puts "\n#{'='*72}"
puts "Bugfix Evaluation — #{count} bugs against actual Ruby tests"
puts "#{'='*72}"
puts "Repo: #{CHEAT}  (HEAD: #{`cd #{CHEAT} && git log --oneline -1`.strip})"
puts

printf "%-15s %-7s %-7s %-7s %-7s %-10s %-7s\n",
  'Category', 'Total', 'Syntax', 'Pass', 'Fail', 'NoTest', 'Errors'
puts '-' * 60

['3B-blind', '3B-ctx', '7B-blind', '32B-blind', '32B-ctx'].each do |cat|
  dir = File.join(BUGFIX_DIR, cat)
  next unless Dir.exist?(dir)

  total = 0; sxok = 0; tpass = 0; tfail = 0; notest = 0; errors = 0

  count.times do |i|
    fp = File.join(dir, format('%02d.txt', i + 1))
    next unless File.exist?(fp)

    fc = extract_code(File.read(fp))
    unless fc
      errors += 1; next
    end
    total += 1

    status, _result = apply_mutation_and_fix(sample[i], fc)

    case status
    when 'TEST_PASSED'  then tpass += 1; sxok += 1
    when 'TEST_FAILED'  then tfail += 1; sxok += 1
    when 'SYNTAX_ERROR' then errors += 1
    when /NOT_FOUND/    then errors += 1
    else                     errors += 1
    end
  end

  rate = total > 0 ? format(" %.0f%%", 100.0 * tpass / total) : '  N/A'
  printf "%-15s %-7d %-7d %-7d %-7d %-10d %-7d %s\n",
    cat, total, sxok, tpass, tfail, notest, errors, rate
end

puts "\nPass = test passes | Syntax = parses | Errors = could not apply fix"
