#!/usr/bin/env python3
"""Test Qwen3-30B on bugs via OpenRouter — same scoring as 3B/7B."""
import json, os, random, requests

API_KEY = "REPLACE_WITH_YOUR_KEY"
MODEL = "qwen/qwen3-coder-30b-a3b-instruct"
BUGS_FILE = os.path.join(os.path.dirname(__file__), 'bugs.jsonl')

def query(prompt):
    resp = requests.post(
        "https://openrouter.ai/api/v1/chat/completions",
        headers={"Authorization": f"Bearer {API_KEY}", "Content-Type": "application/json"},
        json={
            "model": MODEL,
            "messages": [
                {"role": "system", "content": "You are a senior Ruby developer. Fix the bug. Return only the fixed code."},
                {"role": "user", "content": prompt},
            ],
            "max_tokens": 512, "temperature": 0.1,
        },
        timeout=60,
    ).json()
    if "error" in resp: raise Exception(str(resp["error"]))
    return resp["choices"][0]["message"]["content"].strip()

def score(response, original_body, mutated_body):
    if not response or len(response) < 5: return 'TOO_SHORT'
    resp_clean = response.replace('```ruby', '').replace('```', '').strip()
    orig = original_body.strip()
    if resp_clean == mutated_body.strip(): return 'UNCHANGED'
    if orig in resp_clean or len(resp_clean) > len(orig) * 0.8: return 'PASS'
    return 'WRONG'

with open(BUGS_FILE) as f:
    bugs = [json.loads(line) for line in f if line.strip()]
random.seed(42)
sample = random.sample(bugs, 50)

print(f"Model: {MODEL}")
print(f"Bugs: 50")
print("=" * 60)

results = {'PASS': 0, 'WRONG': 0, 'UNCHANGED': 0, 'TOO_SHORT': 0}

for i, bug in enumerate(sample):
    try:
        resp = query(bug['prompt'])
        s = score(resp, bug['original_body'], bug['mutated_body'])
        results[s] += 1
    except Exception as e:
        results['WRONG'] += 1
    passed = results['PASS']
    print(f"\r  {i+1}/50 | PASS: {passed:3d} | last: {s:15s}", end='', flush=True)

print()
print()
print("=" * 60)
print(f"RESULTS: {MODEL}")
print("=" * 60)
print(f"  PASS:        {results['PASS']:3d}/50 ({results['PASS']*2:3d}%)")
print(f"  WRONG:       {results['WRONG']:3d}/50")
print(f"  UNCHANGED:   {results['UNCHANGED']:3d}/50")
print(f"  TOO_SHORT:   {results['TOO_SHORT']:3d}/50")
print()
print("=" * 60)
print("Comparison (SAME 50 bugs, SAME string-match scoring):")
print("=" * 60)
print(f"  Qwen2.5-Coder-3B  prompt only: 70%")
print(f"  Qwen2.5-Coder-7B  prompt only: 78%")
print(f"  Qwen3-Coder-30B   prompt only: {results['PASS']*2:3d}%")
print()
if results['PASS'] > 39:
    print("30B beats 7B (78% threshold)")
else:
    print(f"30B ({results['PASS']*2}%) {'=' if results['PASS'] == 40 else '<' if results['PASS'] < 40 else '>'} 7B (78%)")
