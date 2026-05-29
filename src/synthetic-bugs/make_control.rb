#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'open3'
require 'optparse'

ROOT = File.expand_path('../..', __dir__)
BUGS_FILE = File.join(ROOT, 'bugs.jsonl')

opts = { count: 50, out: File.join(ROOT, 'bugfix', 'control') }
OptionParser.new do |o|
  o.banner = 'Usage: ruby src/synthetic-bugs/make_control.rb [options]'
  o.on('--count N', Integer) { |v| opts[:count] = v }
  o.on('--out PATH') { |v| opts[:out] = File.expand_path(v) }
end.parse!

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
FileUtils.mkdir_p(opts[:out])

def repo_path_for(bug)
  bug.fetch('repo', {})['repo_path'] || File.join(ROOT, '.eval', 'cheat')
end

def file_rel_for(bug)
  bug['file_rel'] || bug['file'].sub(%r{\A/home/yahn/cheat/}, '')
end

def reset_repo(bug)
  repo = repo_path_for(bug)
  commit = bug.fetch('repo', {})['commit']
  [%w[git checkout --detach], %w[git reset --hard], %w[git clean -fdx]].each do |prefix|
    cmd = prefix + (prefix.include?('clean') ? [] : [commit])
    _out, err, status = Open3.capture3(*cmd, chdir: repo)
    raise err unless status.success?
  end
end

sample.each_with_index do |bug, index|
  reset_repo(bug)
  path = File.join(repo_path_for(bug), file_rel_for(bug))
  lines = File.readlines(path, chomp: true)
  function_source = lines[(bug['function_start_line'] - 1)..(bug['function_end_line'] - 1)].join("\n")
  File.write(File.join(opts[:out], format('%02d.txt', index + 1)), "```ruby\n#{function_source}\n```\n")
end

puts "Wrote #{sample.length} controls to #{opts[:out]}"
