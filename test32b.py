#!/usr/bin/env python3
"""Test 32B by applying fixes and running actual Ruby tests."""
import json, sys, os, subprocess, tempfile, re

API_KEY = "REPLACE_WITH_YOUR_KEY"
MODEL = "qwen/qwen-2.5-coder-32b-instruct"
CHEAT = os.path.expanduser("~/cheat")
BUGS_FILE = os.path.join(os.path.dirname(__file__), 'bugs.jsonl')

import requests
def query(prompt, sysmsg="You are a senior Ruby developer. Fix the bug. Return ONLY fixed Ruby code."):
    for attempt in range(3):
        try:
            resp = requests.post(
                "https://openrouter.ai/api/v1/chat/completions",
                headers={"Authorization": f"Bearer {API_KEY}", "Content-Type": "application/json"},
                json={"model": MODEL, "messages": [{"role": "system", "content": sysmsg}, {"role": "user", "content": prompt}], "max_tokens": 1500, "temperature": 0.1},
                timeout=120,
            ).json()
            if "choices" in resp:
                return resp["choices"][0]["message"]["content"].strip()
            if attempt < 2:
                continue
            return None
        except:
            if attempt < 2:
                continue
            return None
    return None

with open(BUGS_FILE) as f:
    bugs = [json.loads(line) for line in f if line.strip()]

# Pick first bug for a test run
bug = bugs[0]
print(f"Bug: {bug['function']}")
print(f"File: {bug['file']}")
print(f"Mutation: {bug['mutation'][:80]}")

# Read original source
filepath = bug['file']
with open(filepath) as f:
    original_src = f.read()

mutated = bug['mutated_body'].strip()
orig = bug['original_body'].strip()

# Check mutated version is in the file
if mutated not in original_src:
    print("ERROR: mutated body not found in source file")
    sys.exit(1)

# Query 32B
print(f"\nQuerying {MODEL}...")
fix = query(bug['prompt'])
if not fix:
    print("ERROR: no response from API")
    sys.exit(1)
fix_clean = fix.replace('```ruby', '').replace('```', '').strip()
print(f"Fix ({len(fix_clean)} chars): {fix_clean[:100]}...")

# Apply fix
new_src = original_src.replace(mutated, fix_clean, 1)
tmp = tempfile.NamedTemporaryFile(mode='w', suffix='.rb', delete=False, dir='/tmp')
tmp.write(new_src)
tmp_path = tmp.name
tmp.close()

# Syntax check
res = subprocess.run(['ruby', '-c', tmp_path], capture_output=True, text=True, timeout=10)
if res.returncode != 0:
    print(f"\nSYNTAX ERROR:\n{res.stderr[:500]}")
    os.unlink(tmp_path)
    sys.exit(0)
print("Syntax: OK")

# Find and run test
func = bug['function'].split('.')[-1]
test_dirs = {'src': ['spec'], 'nil_kill': ['gems/nil-kill/spec'], 'minivm': ['examples/minivm'], 'puck': [], 'decomplex': ['gems/decomplex/test'], 'slopcop': ['gems/slopcop/test'], 'boobytrap': ['gems/boobytrap/test']}
test_file = None
for d in test_dirs.get(bug['subproject'], []):
    for root, _, files in os.walk(os.path.join(CHEAT, d)):
        for f in files:
            if f.endswith('.rb'):
                tp = os.path.join(root, f)
                with open(tp) as tf:
                    if func in tf.read():
                        test_file = tp
                        break
        if test_file:
            break
    if test_file:
        break

if test_file:
    print(f"Test: {test_file}")
    # Copy our fixed file into the right location
    shutil = __import__('shutil')
    backup_f = filepath + '.bak'
    shutil.copy2(filepath, backup_f)
    shutil.copy2(tmp_path, filepath)
    
    res = subprocess.run(['ruby', '-Ilib', '-Ispec', test_file], capture_output=True, text=True, timeout=60,
                        env={**os.environ, 'RUBYOPT': '-W0'})
    
    # Restore original
    shutil.move(backup_f, filepath)
    os.unlink(tmp_path)
    
    if res.returncode == 0:
        print(f"TEST PASSES!")
    else:
        print(f"TEST FAILS. Output: {res.stdout[-300:] + res.stderr[-300:]}")
else:
    os.unlink(tmp_path)
    print("No test file found - manual inspection needed")
    print(f"\nCompare:\n  FIX:    {fix_clean[:200]}\n  ORIG:   {orig[:200]}")
