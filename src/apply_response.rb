#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'prism'

source_path = ARGV[0]
response_path = ARGV[1]
target_function = ARGV[2]

unless source_path && response_path && target_function
  warn 'Usage: ruby src/apply_response.rb SOURCE RESPONSE TARGET_FUNCTION'
  exit 2
end

source = File.read(source_path)
response = File.read(response_path)

def extract_code(text)
  if text =~ /```ruby\s*\n(.*?)```/m
    Regexp.last_match(1).strip
  elsif text =~ /```\s*\n?(.*?)```/m
    Regexp.last_match(1).strip
  else
    text.strip
  end
end

Component = Struct.new(:name, :short_name, :start_offset, :end_offset, :slice, keyword_init: true)

def walk_defs(node, defs, nesting = '')
  return unless node.respond_to?(:child_nodes)

  if node.is_a?(Prism::DefNode)
    short = node.name.to_s.sub(/\Aself\./, '')
    full = nesting.empty? ? short : "#{nesting}.#{short}"
    defs << Component.new(
      name: full,
      short_name: short,
      start_offset: node.location.start_character_offset,
      end_offset: node.location.end_character_offset,
      slice: node.slice
    )
    walk_defs(node.body, defs, full) if node.body
  elsif node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
    name = node.constant_path&.slice || ''
    full = nesting.empty? ? name : "#{nesting}::#{name}"
    walk_defs(node.body, defs, full) if node.body
  else
    node.child_nodes&.compact&.each { |child| walk_defs(child, defs, nesting) }
  end
end

def parse_defs(code, label)
  parsed = Prism.parse(code)
  unless parsed.success?
    warn JSON.generate(status: 'PARSE_ERROR', label: label, error: parsed.errors.first&.message)
    exit 1
  end

  defs = []
  walk_defs(parsed.value, defs)
  defs
end

code = extract_code(response)
response_defs = parse_defs(code, 'response')
if response_defs.empty?
  warn JSON.generate(status: 'NO_FUNCTIONS_IN_RESPONSE')
  exit 1
end

source_defs = parse_defs(source, 'source')
target_short = target_function.split('.').last
target_source = source_defs.find { |d| d.name == target_function } ||
                source_defs.find { |d| d.name.end_with?("::#{target_function}") } ||
                source_defs.find { |d| d.short_name == target_short }
target_defs = response_defs.select { |d| d.short_name == target_short || d.name == target_function }
target_defs = response_defs if target_defs.empty?

edits = []
added = []
target_defs.each do |resp_def|
  src_def = if resp_def.short_name == target_short && target_source
              target_source
            else
              source_defs.find { |d| d.name == resp_def.name } ||
                source_defs.find { |d| d.short_name == resp_def.short_name }
            end
  if src_def
    edits << [src_def.start_offset, src_def.end_offset, resp_def.slice]
  else
    added << resp_def.slice
  end
end

if edits.empty? && added.empty?
  warn JSON.generate(status: 'NO_APPLICABLE_FUNCTIONS')
  exit 1
end

updated = source.dup
edits.sort_by { |start_offset, _, _| -start_offset }.each do |start_offset, end_offset, replacement|
  updated[start_offset...end_offset] = "#{replacement.chomp}\n"
end

unless added.empty?
  updated << "\n\n" unless updated.end_with?("\n\n")
  updated << added.join("\n\n")
  updated << "\n"
end

File.write(source_path, updated)
puts JSON.generate(status: 'APPLIED', replaced: edits.size, added: added.size)
