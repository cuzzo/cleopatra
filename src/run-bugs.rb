#!/usr/bin/env ruby
# frozen_string_literal: true

# run-bugs.rb — Query models on bugs.
#
# - blind: stack trace + bug description only
# - ctx: stack trace + buggy function body (simulating `ctx` tool)
#
# Usage:
#   ruby src/run-bugs.rb [--count 50] [--cats 3B-blind,3B-ctx,...]
#   OPENROUTER_API_KEY=sk-... ruby src/run-bugs.rb --cats 32B-blind,32B-ctx

require "optparse"
require "json"
require "fileutils"
require "net/http"
require "uri"
require "open3"
require "tempfile"

ROOT = File.expand_path('..', __dir__)
BUGS_FILE = File.join(ROOT, "bugs.jsonl")
OUT       = File.join(ROOT, "bugfix")
MODEL_3B  = File.join(ROOT, "data/models/qwen2.5-coder-3b-instruct.gguf")
MODEL_7B  = File.join(ROOT, "data/models/qwen2.5-coder-7b-instruct.gguf")
VENV_PY   = File.join(ROOT, ".venv/bin/python3")
API_KEY   = ENV["OPENROUTER_API_KEY"]
MODEL_32B = "qwen/qwen-2.5-coder-32b-instruct"

SYS = "You are a senior Ruby developer. Fix the bug. Return ONLY corrected code in a ```ruby block."

opts = { count: 50, cats: "3B-blind,3B-ctx,7B-blind,32B-blind,32B-ctx" }
OptionParser.new do |o|
  o.banner = "Usage: ruby src/run-bugs.rb [options]"
  o.on("--count N", Integer, "Number of bugs (default: 50)") { |v| opts[:count] = v }
  o.on("--cats LIST", "Comma-separated categories (default: all 5)") { |v| opts[:cats] = v }
  o.on("-h", "--help") { puts o; exit 0 }
end.parse!

cats = opts[:cats].split(",").map(&:strip)
count = opts[:count]

# ── Prompts ────────────────────────────────────────────

def def_line(filepath, func)
  File.readlines(filepath).find { |l| l =~ /def\s+(self\.)?#{Regexp.escape(func)}\b/ }&.rstrip || "def #{func}"
end

def prompt_blind(bug)
  rel  = bug["file"].sub(%r{^/home/yahn/cheat/}, "")
  func = bug["function"].split(".").last
  src  = File.read(bug["file"])
  <<~PROMPT
    File: #{rel}
    Function: #{func}

    Full source file:
    ```ruby
    #{src}
    ```

    Error:
    #{bug["stack_trace"]}
    #{bug["prompt"]}
    Return ONLY the corrected function `#{func}` in a ```ruby block.
  PROMPT
end

def prompt_with_context(bug)
  rel   = bug["file"].sub(%r{^/home/yahn/cheat/}, "")
  func  = bug["function"].split(".").last
  src   = File.read(bug["file"])
  dline = def_line(bug["file"], func)
  <<~PROMPT
    File: #{rel}
    Function: #{func}

    Full source file:
    ```ruby
    #{src}
    ```

    The buggy function (#{func}):
    ```ruby
    #{dline}
    #{bug["mutated_body"]}
    ```

    Error:
    #{bug["stack_trace"]}
    #{bug["prompt"]}
    Return ONLY the corrected function `#{func}` in a ```ruby block.
  PROMPT
end

# ── GGUF via llama_cpp (Python subprocess) ─────────────

def query_gguf(model_path, prompt)
  tmp = Tempfile.new(["llama_prompt", ".py"])
  tmp.write(<<~PYTHON)
    import sys, json, tempfile, os
    from llama_cpp import Llama
    prompt_file = #{tmp.path.sub(/\.py\z/, '.txt').to_json}
    with open(prompt_file) as f:
        user_msg = f.read()
    llm = Llama(model_path=#{model_path.to_json}, n_ctx=32768, n_threads=32, verbose=False)
    sys_msg = #{SYS.to_json}
    p = f"<|im_start|>system\\n{sys_msg}\\n<|im_end|>\\n<|im_start|>user\\n{user_msg}\\n<|im_end|>\\n<|im_start|>assistant\\n```ruby\\n"
    r = llm(p, max_tokens=1024, temperature=0.1, stop=["<|im_end|>", "<|end|>"])
    print(r["choices"][0]["text"].strip())
  PYTHON
  tmp.close
  prompt_file = tmp.path.sub(/\.py\z/, ".txt")
  File.write(prompt_file, prompt)
  out, err, st = Open3.capture3(VENV_PY, tmp.path)
  File.unlink(tmp.path, prompt_file) rescue nil
  raise err unless st.success?
  "```ruby" + out.strip
rescue => e
  "[[GGUF_ERROR: #{e.message[0..200]}]]"
end

# ── OpenRouter ─────────────────────────────────────────

def query_openrouter(prompt)
  return "[[SKIPPED: OPENROUTER_API_KEY not set]]" unless ENV["OPENROUTER_API_KEY"]
  uri  = URI("https://openrouter.ai/api/v1/chat/completions")
  body = {
    model:    MODEL_32B,
    messages: [
      { role: "system", content: SYS },
      { role: "user",   content: prompt },
    ],
    max_tokens: 1500, temperature: 0.1,
  }.to_json
  req = Net::HTTP::Post.new(uri,
    "Content-Type"  => "application/json",
    "Authorization" => "Bearer #{ENV["OPENROUTER_API_KEY"]}")
  resp = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
  data = JSON.parse(resp.body)
  if data["error"]
    "[[API_ERROR: #{data["error"]["message"]}]]"
  else
    data.dig("choices", 0, "message", "content")&.strip || "[[EMPTY]]"
  end
rescue => e
  "[[API_ERROR: #{e.message}]]"
end

# ── Main ───────────────────────────────────────────────

sample = File.readlines(BUGS_FILE).map { |l| JSON.parse(l.strip) rescue nil }.compact
srand(42)
sample = sample.sample(count)
puts "Running #{sample.size} bugs\n"

blinds = sample.map { |b| prompt_blind(b) }
ctxs   = sample.map { |b| prompt_with_context(b) }

cats.each do |cat|
  dir = File.join(OUT, cat)
  FileUtils.mkdir_p(dir)
  prompts = cat.include?("ctx") ? ctxs : blinds

  sample.each_with_index do |_bug, i|
    fpath = File.join(dir, format("%02d.txt", i + 1))
    label = "[#{cat}] #{i + 1}/#{sample.size}"
    print "  #{label.ljust(25)}"
    $stdout.flush

    result = case cat
             when /\A3B/  then query_gguf(MODEL_3B, prompts[i])
             when /\A7B/  then query_gguf(MODEL_7B, prompts[i])
             when /\A32B/ then query_openrouter(prompts[i])
             else "[[UNKNOWN CATEGORY]]"
             end
    File.write(fpath, result + "\n")
    File.write(fpath.sub(/\.txt\z/, '.prompt.txt'), prompts[i] + "\n")
    puts "OK"
  end
end

puts "\nDone."
