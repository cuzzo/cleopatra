#!/usr/bin/env ruby
# frozen_string_literal: true

# held-back-splitter.rb — Splits bugs into train/validation/holdback sets
# following the 5:3:2 ratio defined in docs/agents/synthetic-bugs.md.

ROOT = File.expand_path('..', __dir__)
BUGS_FILE = File.join(ROOT, 'bugs.jsonl')
TRAINING_DIR = File.join(ROOT, 'training')
VALIDATION_DIR = File.join(ROOT, 'validation')
HELD_BACK_DIR = File.join(ROOT, 'held_back')

require 'json'

def main
  bugs = File.readlines(BUGS_FILE).map { |l| JSON.parse(l.strip) rescue nil }.compact
  total = bugs.size
  puts "Total bugs: #{total}"

  # 5:3:2 ratio → train:val:held = 60%:24%:16%
  train_target = (total * 0.60).to_i
  val_target   = (total * 0.24).to_i
  held_target  = (total * 0.16).to_i

  # Ensure rounding doesn't over/under allocate  
  allocated = train_target + val_target + held_target
  excess = total - allocated
  if excess > 0
    held_target += excess
  elsif excess < 0
    held_target -= excess.abs
  end

  # Shuffle and slice
  bugs.shuffle!
  train_set = bugs[0, train_target]
  val_set   = bugs[train_target, val_target]
  held_set  = bugs[train_target + val_target, held_target]

  # Ensure no overlap
  overlap = train_set & val_set | train_set & held_set | val_set & held_set
  if overlap.any?
    puts "WARNING: overlap detected (#{overlap.size} items) — re-shuffling"
    bugs.shuffle!
    train_set = bugs[0, train_target]
    val_set   = bugs[train_target, val_target]
    held_set  = bugs[train_target + val_target, held_target]
  end

  # Write each set
  write_set(train_set, TRAINING_DIR, 'train')
  write_set(val_set,   VALIDATION_DIR, 'val')
  write_set(held_set,  HELD_BACK_DIR, 'held')
  
  puts ""
  puts "=== Distribution ==="
  puts "  Train: #{train_set.size} (#{(train_set.size.to_f / total * 100).round(1)}%)"
  puts "  Val:   #{val_set.size} (#{(val_set.size.to_f / total * 100).round(1)}%)"
  puts "  Held:  #{held_set.size} (#{(held_set.size.to_f / total * 100).round(1)}%)"
  puts ""
end

def write_set(set, dir, label)
  Dir.mkdir(dir) unless Dir.exist?(dir)
  set.each_with_index do |bug, i|
    subdir = File.join(dir, bug['subproject'] || 'unsorted')
    Dir.mkdir(subdir) unless Dir.exist?(subdir)
    file = File.join(subdir, "#{label}-#{i.to_s.rjust(6, '0')}.json")
    File.write(file, JSON.pretty_generate(bug))
  end
end

main
