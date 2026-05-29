#!/usr/bin/env python3
"""Query models on 50 bugs with realistic prompts.

- blind: stack trace + bug description, no code = pure guesswork
- ctx: stack trace + the buggy function body (simulating `ctx` tool output)

Usage:
  python3 run-bugs.py [--count 50] [--cats 3B-blind,3B-ctx]
"""
import json, os, sys, random, argparse, textwrap

BUGS_FILE = os.path.join(os.path.dirname(__file__), 'bugs.jsonl')
OUT = os.path.join(os.path.dirname(__file__), 'bugfix')
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '.venv', 'lib', 'python3.12', 'site-packages'))

MODEL_PATH_3B = os.path.join(os.path.dirname(__file__), 'data/models/qwen2.5-coder-3b-instruct.gguf')
MODEL_PATH_7B = os.path.join(os.path.dirname(__file__), 'data/models/qwen2.5-coder-7b-instruct.gguf')
API_KEY = os.environ.get('OPENROUTER_API_KEY')
MODEL_32B = 'qwen/qwen-2.5-coder-32b-instruct'

SYSTEM_PROMPT = 'You are a senior Ruby developer. Fix the bug in the code shown below. Return ONLY the corrected Ruby code in a ```ruby block.'

def repo_path_for(bug):
    repo = bug.get('repo') or {}
    return repo.get('repo_path') or os.path.join(os.path.dirname(__file__), '.eval', 'cheat')

def file_rel_for(bug):
    return bug.get('file_rel') or bug['file'].replace('/home/yahn/cheat/', '')

def source_path_for(bug):
    return os.path.join(repo_path_for(bug), file_rel_for(bug))

def simulated_worktree_state(bug):
    discovery = bug.get('discovery') or {
        'scenario': 'production_stack_trace',
        'worktree_dirty': False,
        'dirty_scope': 'clean_tree',
        'dirty_files': [],
        'hint': 'Clean tree; treat this as a production/existing bug that slipped through tests.'
    }
    file_rel = file_rel_for(bug)
    dirty_files = discovery.get('dirty_files') or []
    target_dirty = [f for f in dirty_files if f.get('file_rel') == file_rel]
    lines = [
        '=' * 60,
        'WORKTREE STATE',
        '=' * 60,
        f"Scenario: {discovery.get('scenario', 'unknown')}",
        f"Worktree: {'dirty' if discovery.get('worktree_dirty') else 'clean'}",
    ]
    if target_dirty:
        lines.append(f"Target file: dirty ({file_rel})")
        for entry in target_dirty:
            for r in entry.get('line_ranges', []):
                lines.append(f"  lines {r.get('start')}-{r.get('end')}: {r.get('reason')}")
    else:
        lines.append(f"Target file: clean ({file_rel})")
    other_dirty = [f for f in dirty_files if f.get('file_rel') != file_rel]
    if other_dirty:
        lines.append('Other dirty files:')
        for entry in other_dirty[:10]:
            lines.append(f"  {entry.get('status', 'modified')} {entry.get('file_rel')} ({entry.get('role', 'unknown')})")
    lines.append(f"Interpretation: {discovery.get('hint', 'unknown')}")
    return '\n'.join(lines)

def prompt_blind(bug):
    file_rel = file_rel_for(bug)
    func = bug['function'].split('.')[-1]
    return textwrap.dedent(f"""\
File: {file_rel}
Function: {func}

{bug['prompt']}

Return ONLY the corrected function `{func}` in a ```ruby block.""")

def prompt_with_context(bug):
    file_rel = file_rel_for(bug)
    func = bug['function'].split('.')[-1]
    # Simulate what `ctx {file}#{line}` would return: the buggy function body
    # (We show the mutated body, which is what ctx would see on disk after the bug was introduced)
    return textwrap.dedent(f"""\
File: {file_rel}
Function: {func}

Here is the current (buggy) code of function `{func}`:

```ruby
{build_function_with_context(bug)}
```

{simulated_worktree_state(bug)}

{bug['prompt']}

Return ONLY the corrected function `{func}` in a ```ruby block.""")

def build_function_with_context(bug):
    """Reconstruct the buggy function with its def signature and mutated body."""
    filepath = source_path_for(bug)
    mutated = bug['mutated_body']

    try:
        with open(filepath) as f:
            source = f.read().replace('\r\n', '\n')
        source = source.replace(bug['original_body'].replace('\r\n', '\n'), mutated.replace('\r\n', '\n'), 1)
        lines = source.splitlines()
        start = bug.get('function_start_line')
        end = bug.get('function_end_line')
        if start and end:
            return '\n'.join(lines[start - 1:end])
    except:
        pass
    # Fallback: just show the mutated body
    return mutated

def load_model(path):
    from llama_cpp import Llama
    print(f"Loading: {path}")
    return Llama(model_path=path, n_ctx=4096, n_threads=32, verbose=False, n_gpu_layers=0)

def query_gguf(llm, prompt):
    full = '<|im_start|>system\n' + SYSTEM_PROMPT + '\n<|im_end|>\n<|im_start|>user\n' + prompt + '\n<|im_end|>\n<|im_start|>assistant\n```ruby\n'
    output = llm(full, max_tokens=1024, temperature=0.1, stop=['<|im_end|>', '<|end|>', '\n```'])
    return '```ruby\n' + output['choices'][0]['text'].strip() + '\n```'

def query_api(prompt):
    import requests
    if not API_KEY:
        return '[[SKIPPED: API key not set]]'
    resp = requests.post(
        'https://openrouter.ai/api/v1/chat/completions',
        headers={'Authorization': f'Bearer {API_KEY}', 'Content-Type': 'application/json'},
        json={'model': MODEL_32B, 'messages': [
            {'role': 'system', 'content': SYSTEM_PROMPT},
            {'role': 'user', 'content': prompt},
        ], 'max_tokens': 1500, 'temperature': 0.1},
        timeout=120,
    ).json()
    if 'error' in resp:
        raise Exception(f"API error: {resp['error']}")
    return resp['choices'][0]['message']['content'].strip()

# === Main ===
parser = argparse.ArgumentParser()
parser.add_argument('--count', type=int, default=50)
parser.add_argument('--cats', type=str, default='')
parser.add_argument('--dry-run-prompts', action='store_true', help='write .prompt.txt files and skip model calls')
args = parser.parse_args()

with open(BUGS_FILE) as f:
    bugs = [json.loads(line) for line in f if line.strip()]
random.seed(42)
sample = random.sample(bugs, min(args.count, len(bugs)))
n = len(sample)
print(f"Sample: {n} bugs\n")

cats = args.cats.split(',') if args.cats else ['3B-blind', '3B-ctx', '7B-blind', '32B-blind', '32B-ctx']
blinds = [prompt_blind(b) for b in sample]
ctxs = [prompt_with_context(b) for b in sample]

models = {}

for cat in cats:
    dirpath = os.path.join(OUT, cat)
    os.makedirs(dirpath, exist_ok=True)
    prompts = ctxs if 'ctx' in cat else blinds

    for i, (bug, prompt) in enumerate(zip(sample, prompts)):
        fpath = os.path.join(dirpath, f'{i+1:02d}.txt')
        ppath = os.path.join(dirpath, f'{i+1:02d}.prompt.txt')
        label = f'[{cat}] bug {i+1}/{n}'
        print(f'  {label}', flush=True)
        with open(ppath, 'w') as f:
            f.write(prompt + '\n')
        if args.dry_run_prompts:
            continue

        try:
            if cat.startswith('3B'):
                if '3B' not in models:
                    models['3B'] = load_model(MODEL_PATH_3B)
                result = query_gguf(models['3B'], prompt)
            elif cat.startswith('7B'):
                if '7B' not in models:
                    models['7B'] = load_model(MODEL_PATH_7B)
                result = query_gguf(models['7B'], prompt)
            elif cat.startswith('32B'):
                result = query_api(prompt)
            else:
                result = '[[UNKNOWN CATEGORY]]'

            with open(fpath, 'w') as f:
                f.write(result + '\n')
        except Exception as e:
            with open(fpath, 'w') as f:
                f.write(f'[[ERROR: {e}]]\n')

print('\nDone.')
if args.dry_run_prompts:
    print('Dry run: wrote prompt files only.')
