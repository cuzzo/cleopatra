#!/usr/bin/env python3
"""Write control fixes for the deterministic bug sample."""
import argparse
import json
import os
import random
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUGS = os.path.join(ROOT, 'bugs.jsonl')

parser = argparse.ArgumentParser()
parser.add_argument('--count', type=int, default=50)
parser.add_argument('--out', default=os.path.join(ROOT, 'bugfix', 'control'))
args = parser.parse_args()

with open(BUGS) as f:
    bugs = [json.loads(line) for line in f if line.strip()]

random.seed(42)
sample = random.sample(bugs, min(args.count, len(bugs)))
os.makedirs(args.out, exist_ok=True)


def repo_path_for(bug):
    return (bug.get('repo') or {}).get('repo_path') or os.path.join(ROOT, '.eval', 'cheat')


def file_rel_for(bug):
    return bug.get('file_rel') or bug['file'].replace('/home/yahn/cheat/', '')


def reset_repo(bug):
    repo = repo_path_for(bug)
    commit = bug['repo']['commit']
    for cmd in (['git', 'checkout', '--detach', commit],
                ['git', 'reset', '--hard', commit],
                ['git', 'clean', '-fdx']):
        subprocess.run(cmd, cwd=repo, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


for index, bug in enumerate(sample, 1):
    reset_repo(bug)
    path = os.path.join(repo_path_for(bug), file_rel_for(bug))
    with open(path) as f:
        lines = f.read().splitlines()
    start = bug['function_start_line']
    end = bug['function_end_line']
    function_source = '\n'.join(lines[start - 1:end])
    with open(os.path.join(args.out, f'{index:02d}.txt'), 'w') as f:
        f.write(f'```ruby\n{function_source}\n```\n')

print(f'Wrote {len(sample)} controls to {args.out}')
