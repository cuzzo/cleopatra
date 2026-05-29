#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'prism'

source_path = ARGV[0]
body_path = ARGV[1]
target_function = ARGV[2]

unless source_path && body_path && target_function
  warn 'Usage: ruby src/synthetic-bugs/apply_mutation.rb SOURCE BODY TARGET_FUNCTION'
  exit 2
end

source = File.read(source_path)
body = File.read(body_path).sub(/\s+\z/, '')

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

parsed = Prism.parse(source)
unless parsed.success?
  warn JSON.generate(status: 'PARSE_ERROR', label: 'source', error: parsed.errors.first&.message)
  exit 1
end

defs = []
walk_defs(parsed.value, defs)
target_short = target_function.split('.').last
target = defs.find { |d| d.name == target_function } || defs.find { |d| d.short_name == target_short }

unless target
  warn JSON.generate(status: 'TARGET_FUNCTION_NOT_FOUND', function: target_function)
  exit 1
end

lines = target.slice.lines
signature = lines.first&.chomp
unless signature && signature.lstrip.start_with?('def ')
  warn JSON.generate(status: 'UNSUPPORTED_DEF_SHAPE', function: target_function)
  exit 1
end

indent = signature[/\A\s*/] || ''
replacement = "#{signature}\n#{body}\n#{indent}end\n"
updated = source.dup
updated[target.start_offset...target.end_offset] = replacement
File.write(source_path, updated)
puts JSON.generate(status: 'APPLIED_MUTATION', function: target.name)
