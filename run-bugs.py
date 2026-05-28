#!/usr/bin/env python3
"""Query models on 50 bugs, store raw outputs.

Creates:
  bugfix/sample_ids.txt          — bug IDs for the 50 samples
  bugfix/3B-blind/01.txt ...     — 3B, prompt only
  bugfix/3B-ctx/01.txt ...       — 3B, prompt + ideal context
  bugfix/32B-blind/01.txt ...    — 32B via OpenRouter, prompt only
  bugfix/32B-ctx/01.txt ...      — 32B via OpenRouter, prompt + ideal context

Usage:
  python3 run-bugs.py [--count 50]
  OPENROUTER_API_KEY=sk-or-... python3 run-bugs.py
"""
import json, os, sys, random, argparse, textwrap

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '.venv', 'lib', 'python3.12', 'site-packages'))

BUGS_FILE = os.path.join(os.path.dirname(__file__), 'bugs.jsonl')
OUT = os.path.join(os.path.dirname(__file__), 'bugfix')
MODEL_PATH_3B = os.path.join(os.path.dirname(__file__), 'data/models/qwen2.5-coder-3b-instruct.gguf')
API_KEY = os.environ.get('OPENROUTER_API_KEY')
MODEL_32B = 'qwen/qwen-2.5-coder-32b-instruct'

parser = argparse.ArgumentParser()
parser.add_argument('--count', type=int, default=50)
args = parser.parse_args()
COUNT = args.count

def prompt_blind(bug):
    return bug['prompt']

def prompt_with_context(bug):
    file_rel = bug['file'].replace('/home/yahn/cheat/', '')
    short = bug['function'].split('.')[-1]
    return textwrap.dedent(f"""File: {file_rel}
Function: {short}
The correct code is:
{bug['original_body']}

---

{bug['prompt']}""")

def load_local_3b():
    from llama_cpp import Llama
    print(f"Loading 3B: {MODEL_PATH_3B}")
    return Llama(model_path=MODEL_PATH_3B, n_ctx=4096, n_threads=32, verbose=False, n_gpu_layers=0)

def query_local(llm, prompt):
    full = '### Instruction:\n' + prompt + '\n\n### Response:\n'
    output = llm(full, max_tokens=512, temperature=0.1, stop=['<|end|>', '###', 'Example'])
    return output['choices'][0]['text'].strip()

def query_api(prompt):
    import requests
    if not API_KEY:
        return None
    resp = requests.post(
        "https://openrouter.ai/api/v1/chat/completions",
        headers={"Authorization": f"Bearer {API_KEY}", "Content-Type": "application/json"},
        json={
            "model": MODEL_32B,
            "messages": [
                {"role": "system", "content": "You are a senior Ruby developer. Fix the bug. Return ONLY fixed Ruby code."},
                {"role": "user", "content": prompt},
            ],
            "max_tokens": 1500,
            "temperature": 0.1,
        },
        timeout=120,
    ).json()
    if 'error' in resp:
        raise Exception(f"API error: {resp['error']}")
    return resp['choices'][0]['message']['content'].strip()

def write_outputs(bugs, prompts, label, model_name, llm=None):
    dirpath = os.path.join(OUT, label)
    os.makedirs(dirpath, exist_ok=True)
    for i, (bug, prompt) in enumerate(zip(bugs, prompts)):
        fpath = os.path.join(dirpath, f"{i+1:02d}.txt")
        print(f"  [{label}] bug {i+1}/{len(bugs)}", flush=True)
        try:
            if model_name == '3B':
                result = query_local(llm, prompt)
            else:
                result = query_api(prompt)
                if result is None:
                    result = '[[SKIPPED: OPENROUTER_API_KEY not set]]'
            with open(fpath, 'w') as f:
                f.write(result + '\n')
        except Exception as e:
            with open(fpath, 'w') as f:
                f.write(f'[[ERROR: {e}]]\n')

with open(BUGS_FILE) as f:
    bugs = [json.loads(line) for line in f if line.strip()]
random.seed(42)
sample = random.sample(bugs, min(COUNT, len(bugs)))
n = len(sample)
print(f"Running {n} bugs\n")

os.makedirs(OUT, exist_ok=True)
with open(os.path.join(OUT, 'sample_ids.txt'), 'w') as f:
    for bug in sample:
        f.write(f"{bug['id']}\n")

blinds = [prompt_blind(b) for b in sample]
ctxs = [prompt_with_context(b) for b in sample]

llm_3b = load_local_3b()
write_outputs(sample, blinds, '3B-blind', '3B', llm_3b)
write_outputs(sample, ctxs,   '3B-ctx',   '3B', llm_3b)

write_outputs(sample, blinds, '32B-blind', '32B')
write_outputs(sample, ctxs,   '32B-ctx',   '32B')

print("\nDone. Output in bugfix/")
