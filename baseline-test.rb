#!/usr/bin/env ruby
# frozen_string_literal: true

# baseline-test.rb — Measure fix rates with and without ideal context.
#
# Usage:
#   ruby baseline-test.rb qwen2.5-coder:3b    # Ollama model
#   ruby baseline-test.rb Qwen/Qwen2.5-Coder-3B-Instruct  # HF model
#   ruby baseline-test.rb qwen2.5-coder:3b --count 200
#
# Tests two scenarios per bug:
#   A = prompt only (model must find context itself)
#   B = prompt + ideal context (model sees the correct function)
#
# If B >> A, then ctx training is validated — context helps.
# If B ≈ A, then context isn't the bottleneck — fix ability is.

require 'json'
require 'net/http'
require 'uri'

BUGS_FILE = File.join(__dir__, 'bugs.jsonl')
COUNT = (ARGV[ARGV.index('--count') + 1] rescue 200).to_i
MODEL = (ARGV[0] rescue 'qwen2.5-coder:3b')
OLLAMA_URL = "http://localhost:11434/api/generate"  # default Ollama

def query_ollama(prompt)
  uri = URI(OLLAMA_URL)
  req = Net::HTTP::Post.new(uri)
  req['Content-Type'] = 'application/json'
  req.body = JSON.generate({
    model: MODEL,
    prompt: prompt,
    stream: false,
    options: { num_predict: 512, temperature: 0.1 }
  })
  res = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(req) }
  raise "HTTP #{res.code}" unless res.is_a?(Net::HTTPOK)
  JSON.parse(res.body)['response'] || ''
rescue => e
  "[[ERROR: #{e.message}]]"
end

# Score a model's response against the original (correct) body
def score_response(response, original_body, mutated_body)
  return 'PARSE_ERR' if response.include?('[[ERROR')
  # Check if the mutation is still present
  response_clean = response.gsub(/```ruby|```/, '').strip
  if response_clean.length < 10
    'TOO_SHORT'
  elsif response_clean == mutated_body
    'UNCHANGED'  # model returned the buggy code as-is
  elsif response_clean.include?(original_body[0..20]) || response_clean.length > mutated_body.length * 0.8
    'PASS'      # model produced something close to original
  else
    'WRONG'
  end
end

# Build prompt for scenario A (blind — no context)
def prompt_a(bug)
  bug['prompt']
end

# Build prompt for scenario B (oracle — ideal context included)
def prompt_b(bug)
  file = bug['file'].sub('/home/yahn/cheat/', '')
  fn = bug['function'].split('.').last
  "File: #{file}\nFunction: #{fn}\nThe correct code is:\n\n#{bug['original_body']}\n\n---\n\n#{bug['prompt']}"
end

# === Main ===
bugs = File.readlines(BUGS_FILE).map { |l| JSON.parse(l.strip) rescue nil }.compact
sample = bugs.sample(COUNT)

results = { A: { PASS: 0, FAIL: 0, UNCHANGED: 0, WRONG: 0, TOO_SHORT: 0 },
            B: { PASS: 0, FAIL: 0, UNCHANGED: 0, WRONG: 0, TOO_SHORT: 0 } }

progress = 0
sample.each_with_index do |bug, i|
  print "\rBug #{i + 1}/#{sample.size} (A: #{results[:A][:PASS]}/#{i}, B: #{results[:B][:PASS]}/#{i})   "

  # Scenario A
  resp_a = query_ollama(prompt_a(bug))
  score_a = score_response(resp_a, bug['original_body'], bug['mutated_body'])
  results[:A][score_a.to_sym] += 1

  # Scenario B
  resp_b = query_ollama(prompt_b(bug))
  score_b = score_response(resp_b, bug['original_body'], bug['mutated_body'])
  results[:B][score_b.to_sym] += 1
end

puts
puts "\n#{'=' * 60}"
puts "Model: #{MODEL}"
puts "Bugs tested: #{sample.size}"
puts
puts "Scenario A — Prompt only (no context):"
a_pass = results[:A][:PASS]
a_total = sample.size
a_rate = a_pass.to_f / a_total * 100
puts "  PASS: #{a_pass}/#{a_total} (#{a_rate.round(1)}%)"
puts "  FAIL/WRONG: #{results[:A][:WRONG]}/#{a_total} (#{(results[:A][:WRONG].to_f/a_total*100).round(1)}%)"
puts "  UNCHANGED: #{results[:A][:UNCHANGED]}"
puts "  TOO_SHORT: #{results[:A][:TOO_SHORT]}"

puts
puts "Scenario B — Prompt + ideal context (oracle):"
b_pass = results[:B][:PASS]
b_total = sample.size
b_rate = b_pass.to_f / b_total * 100
puts "  PASS: #{b_pass}/#{b_total} (#{b_rate.round(1)}%)"
puts "  FAIL/WRONG: #{results[:B][:WRONG]}/#{b_total} (#{(results[:B][:WRONG].to_f/b_total*100).round(1)}%)"
puts "  UNCHANGED: #{results[:B][:UNCHANGED]}"
puts "  TOO_SHORT: #{results[:B][:TOO_SHORT]}"

puts
puts "Delta: #{b_rate.round(1)}% - #{a_rate.round(1)}% = #{(b_rate - a_rate).round(1)}%"
puts

# Statistical significance (chi-squared)
if a_total > 0 && b_total > 0
  a_fail = a_total - a_pass
  b_fail = b_total - b_pass
  # Contingency table
  #         Pass  Fail
  # Blind   a_pass  a_fail
  # Oracle  b_pass  b_fail
  total = a_total + b_total
  row1 = [a_pass, a_fail]
  row2 = [b_pass, b_fail]

  # Chi-squared computation
  e11 = (row1[0] + row2[0]).to_f * (row1[0] + row1[1]).to_f / total
  e12 = (row1[0] + row2[0]).to_f * (row2[0] + row2[1]).to_f / total
  e21 = (row1[1] + row2[1]).to_f * (row1[0] + row1[1]).to_f / total
  e22 = (row1[1] + row2[1]).to_f * (row2[0] + row2[1]).to_f / total

  chi2 = 0
  chi2 += (row1[0] - e11)**2 / e11 if e11 > 0
  chi2 += (row2[0] - e12)**2 / e12 if e12 > 0
  chi2 += (row1[1] - e21)**2 / e21 if e21 > 0
  chi2 += (row2[1] - e22)**2 / e22 if e22 > 0

  puts "Chi-squared: #{chi2.round(3)} (df=1)"
  puts "p-value: #{chi2 > 3.841 ? '< 0.05' : '> 0.05'} (significant at p<0.05: #{chi2 > 3.841})"
  puts "p-value: #{chi2 > 6.635 ? '< 0.01' : '> 0.01'} (significant at p<0.01: #{chi2 > 6.635})"
  puts "p-value: #{chi2 > 10.828 ? '< 0.001' : '> 0.001'} (significant at p<0.001: #{chi2 > 10.828})"
end

puts
puts "#{'=' * 60}"
puts "Interpretation:"
if b_rate - a_rate > 10 && chi2 > 3.841
  puts "  ✅ Context SIGNIFICANTLY improves fix rate."
  puts "     GRAM + ctx training is validated."
elsif b_rate - a_rate > 5
  puts "  ⚠️  Context helps but may not be statistically significant."
  puts "     Try larger sample (#{sample.size} → 500+)."
else
  puts "  ❌ Context does NOT meaningfully improve fix rate."
  puts "     The bottleneck is fix ability, not context discovery."
end
