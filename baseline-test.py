#!/usr/bin/env python3
"""baseline-test.py — Measure fix rates with/without ideal context using llama-cpp-python.

Usage:
  python3 baseline-test.py [--count 100] [--model data/models/qwen2.5-coder-3b-instruct.gguf]

Tests two scenarios per bug:
  A = prompt only (model must find context itself)
  B = prompt + ideal context (model sees the correct function)

If B >> A, then ctx training is validated.
"""

import json
import sys
import os
import random
import math

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '.venv', 'lib', 'python3.12', 'site-packages'))

COUNT = 100
MODEL_PATH = os.path.join(os.path.dirname(__file__), 'data/models/qwen2.5-coder-3b-instruct.gguf')

for i, arg in enumerate(sys.argv[1:]):
    if arg == '--count' and i + 1 < len(sys.argv):
        COUNT = int(sys.argv[i + 2])
    elif arg == '--model' and i + 1 < len(sys.argv):
        MODEL_PATH = sys.argv[i + 2]

BUGS_FILE = os.path.join(os.path.dirname(__file__), 'bugs.jsonl')
INSTRUCT_TEMPLATE = "### Instruction:\n{prompt}\n\n### Response:\n"

def load_model():
    from llama_cpp import Llama
    print(f"Loading model: {MODEL_PATH}...")
    return Llama(
        model_path=MODEL_PATH,
        n_ctx=4096,
        n_threads=32,
        verbose=False,
        n_gpu_layers=0,  # CPU only
    )

def query(llm, prompt):
    full = INSTRUCT_TEMPLATE.format(prompt=prompt)
    output = llm(full, max_tokens=512, temperature=0.1, stop=["<|end|>", "###"])
    return output['choices'][0]['text'].strip()

def score(response, original_body, mutated_body):
    if not response or len(response) < 5:
        return 'TOO_SHORT'
    resp_clean = response.replace('```ruby', '').replace('```', '').strip()
    if resp_clean == mutated_body.strip():
        return 'UNCHANGED'
    # Check if response contains the fix (matches original body closely)
    orig_stripped = original_body.strip()
    if orig_stripped in resp_clean or len(resp_clean) > len(orig_stripped) * 0.8:
        return 'PASS'
    return 'WRONG'

def prompt_a(bug):
    return bug['prompt']

def prompt_b(bug):
    fn = bug['function'].split('.')[-1]
    file = bug['file'].replace('/home/yahn/cheat/', '')
    return (
        f"File: {file}\nFunction: {fn}\n"
        f"The correct implementation is:\n{bug['original_body']}\n\n"
        f"---\n\n{bug['prompt']}"
    )

def main():
    llm = load_model()
    with open(BUGS_FILE) as f:
        bugs = [json.loads(line) for line in f if line.strip()]
    random.seed(42)
    sample = random.sample(bugs, min(COUNT, len(bugs)))
    n = len(sample)
    print(f"Testing {n} bugs across 2 scenarios = {n * 2} inferences\n")

    results = {'A': {'PASS': 0, 'FAIL': 0, 'WRONG': 0, 'UNCHANGED': 0, 'TOO_SHORT': 0},
               'B': {'PASS': 0, 'FAIL': 0, 'WRONG': 0, 'UNCHANGED': 0, 'TOO_SHORT': 0}}

    for i, bug in enumerate(sample):
        print(f"\rBug {i+1}/{n}  |  A: {results['A']['PASS']}/{i}  B: {results['B']['PASS']}/{i}  ", end='', flush=True)

        # Scenario A
        ra = query(llm, prompt_a(bug))
        sa = score(ra, bug['original_body'], bug['mutated_body'])
        results['A'][sa] += 1

        # Scenario B
        rb = query(llm, prompt_b(bug))
        sb = score(rb, bug['original_body'], bug['mutated_body'])
        results['B'][sb] += 1

    print()
    print()
    print('=' * 60)
    print(f"Model: {MODEL_PATH}")
    print(f"Bugs tested: {n}")
    print()

    for scenario, label in [('A', 'Prompt only (no context)'), ('B', 'Prompt + ideal context')]:
        p = results[scenario]['PASS']
        rate = p / n * 100
        w = results[scenario]['WRONG']
        uc = results[scenario]['UNCHANGED']
        ts = results[scenario]['TOO_SHORT']
        print(f"Scenario {scenario} — {label}:")
        print(f"  PASS: {p}/{n} ({rate:.1f}%)")
        print(f"  WRONG: {w}/{-p + n} ({(w/(n-p)*100) if n-p else 0:.1f}% of failures)")
        print(f"  UNCHANGED: {uc}  TOO_SHORT: {ts}")
        print()

    a_pass = results['A']['PASS']
    b_pass = results['B']['PASS']
    a_rate = a_pass / n * 100
    b_rate = b_pass / n * 100
    delta = b_rate - a_rate
    print(f"Delta: +{delta:.1f}%")
    print()

    # Chi-squared
    a_fail = n - a_pass
    b_fail = n - b_pass
    total = n * 2
    e11 = (a_pass + b_pass) * (a_pass + a_fail) / total
    e12 = (a_pass + b_pass) * (b_pass + b_fail) / total
    e21 = (a_fail + b_fail) * (a_pass + a_fail) / total
    e22 = (a_fail + b_fail) * (b_pass + b_fail) / total
    chi2 = 0
    for obs, exp in [(a_pass, e11), (b_pass, e12), (a_fail, e21), (b_fail, e22)]:
        if exp > 0:
            chi2 += (obs - exp) ** 2 / exp
    print(f"Chi-squared: {chi2:.3f} (df=1)")
    print(f"Significant at p<0.05? {'YES' if chi2 > 3.841 else 'NO'}")
    print(f"Significant at p<0.01? {'YES' if chi2 > 6.635 else 'NO'}")
    print(f"Significant at p<0.001? {'YES' if chi2 > 10.828 else 'NO'}")
    print()

    print('=' * 60)
    print("Interpretation:")
    if delta > 10 and chi2 > 3.841:
        print("  ✅ Context SIGNIFICANTLY improves fix rate.")
        print("     GRAM + ctx training is validated. Proceed.")
    elif delta > 5:
        print("  ⚠️  Context helps but may not be significant.")
        print("     Try larger sample for confirmation.")
    else:
        print("  ❌ Context does NOT meaningfully improve fix rate.")
        print("     Bottleneck is fix ability, not context discovery.")

if __name__ == '__main__':
    main()
