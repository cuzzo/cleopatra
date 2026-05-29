#!/usr/bin/env python3
"""Evaluate model bugfixes against the pinned bundle checkout recorded per bug."""
import argparse
import json
import os
import random
import re
import subprocess
import tempfile
import time

ROOT = '/home/yahn/cleopatra'
BUGS = os.path.join(ROOT, 'bugs.jsonl')
DEFAULT_REPO = os.path.join(ROOT, '.eval', 'cheat')
APPLY_RESPONSE = os.path.join(ROOT, 'bugfix', 'apply_response.rb')
APPLY_MUTATION = os.path.join(ROOT, 'bugfix', 'apply_mutation.rb')
DEFAULT_BUNDLE_PATH = '/home/yahn/cheat/vendor/bundle'

with open(BUGS) as f:
    bugs = [json.loads(line) for line in f if line.strip()]

parser = argparse.ArgumentParser(description='Evaluate model bugfixes against the fixed bug sample.')
parser.add_argument('--count', type=int, default=50)
parser.add_argument('--cats', default='3B-blind,3B-ctx,7B-blind,32B-blind,32B-ctx')
parser.add_argument('--verbose-failures', action='store_true')
parser.add_argument('--failure-log', default=os.path.join(ROOT, 'bugfix', 'evaluation_failures.jsonl'))
parser.add_argument('--test-timeout', type=int, default=300)
parser.add_argument('--bundle-path', default=DEFAULT_BUNDLE_PATH)
args = parser.parse_args()

random.seed(42)
sample = random.sample(bugs, args.count)


def repo_path_for(bug):
    return (bug.get('repo') or {}).get('repo_path') or DEFAULT_REPO


def file_rel_for(bug):
    return bug.get('file_rel') or bug['file'].replace('/home/yahn/cheat/', '')


def source_path_for(bug):
    return os.path.join(repo_path_for(bug), file_rel_for(bug))


def reset_repo_for_bug(bug):
    repo = repo_path_for(bug)
    commit = (bug.get('repo') or {}).get('commit')
    expected_tree = (bug.get('repo') or {}).get('tree')
    if not commit:
        return {'ok': False, 'status': 'MISSING_REPO_COMMIT'}
    for cmd in (['git', 'checkout', '--detach', commit],
                ['git', 'reset', '--hard', commit],
                ['git', 'clean', '-fdx']):
        res = subprocess.run(cmd, cwd=repo, capture_output=True, text=True, timeout=60)
        if res.returncode != 0:
            return {'ok': False, 'status': 'REPO_RESET_FAILED', 'error': (res.stderr or res.stdout)[-1000:]}
    if expected_tree:
        res = subprocess.run(['git', 'rev-parse', 'HEAD^{tree}'], cwd=repo, capture_output=True, text=True, timeout=10)
        actual = res.stdout.strip()
        if actual != expected_tree:
            return {'ok': False, 'status': 'TREE_MISMATCH', 'error': f'{actual} != {expected_tree}'}
    return {'ok': True}


def unsupported_response_format(text):
    lowered = text.lower()
    markers = ('change this line', 'replace this line', 'change `', 'replace `', 'diff --git', '```diff')
    return any(marker in lowered for marker in markers)


def parse_helper_output(res, fallback):
    payload = (res.stdout or res.stderr or '').strip().splitlines()
    if payload:
        try:
            return json.loads(payload[-1])
        except json.JSONDecodeError:
            pass
    return {'status': fallback, 'error': ((res.stdout or '') + (res.stderr or ''))[-1000:]}


def syntax_check(filepath):
    res = subprocess.run(['ruby', '-c', filepath], capture_output=True, text=True, timeout=20)
    if res.returncode == 0:
        return {'status': 'SYNTAX_OK'}
    return {'status': 'SYNTAX_ERROR', 'error': (res.stderr or res.stdout)[-1000:]}


def apply_mutation_with_prism(bug):
    with tempfile.NamedTemporaryFile(mode='w', suffix='.body', delete=False) as tmp:
        tmp.write(bug['mutated_body'])
        body_path = tmp.name
    try:
        res = subprocess.run(
            ['ruby', APPLY_MUTATION, source_path_for(bug), body_path, bug['function']],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=30,
        )
    finally:
        os.unlink(body_path)
    if res.returncode != 0:
        return parse_helper_output(res, 'MUTATION_APPLY_FAILED')
    return {'status': 'MUTATION_APPLIED', 'detail': parse_helper_output(res, 'MUTATION_APPLIED')}


def apply_response_with_prism(bug, response_text):
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as tmp:
        tmp.write(response_text)
        response_path = tmp.name
    try:
        res = subprocess.run(
            ['ruby', APPLY_RESPONSE, source_path_for(bug), response_path, bug['function']],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=30,
        )
    finally:
        os.unlink(response_path)
    if res.returncode != 0:
        return parse_helper_output(res, 'RESPONSE_APPLY_FAILED')
    return {'status': 'RESPONSE_APPLIED', 'detail': parse_helper_output(res, 'RESPONSE_APPLIED')}


def test_files(repo, rel_dir):
    root = os.path.join(repo, rel_dir)
    found = []
    if not os.path.isdir(root):
        return found
    for dirpath, _, filenames in os.walk(root):
        for filename in filenames:
            if filename.endswith('_test.rb'):
                found.append(os.path.relpath(os.path.join(dirpath, filename), repo))
    return sorted(found)


def unit_test_commands(bug):
    recorded = bug.get('test_failures') or []
    commands = []
    for failure in recorded:
        command = failure.get('command')
        if command:
            commands.append(command)
            continue
        file_rel = failure.get('file_rel')
        if file_rel:
            if file_rel.endswith('_spec.rb') or file_rel.startswith('spec/') or '/spec/' in file_rel:
                commands.append(['bundle', 'exec', 'rspec', file_rel])
            else:
                commands.append(['bundle', 'exec', 'ruby', file_rel])
    if commands:
        return commands

    subproject = bug['subproject']
    repo = repo_path_for(bug)
    if subproject == 'src':
        return [['bundle', 'exec', 'prspec', 'spec']]
    if subproject == 'nil_kill':
        return [['bundle', 'exec', 'prspec', 'gems/nil-kill/spec']]
    if subproject == 'minivm':
        return [['ruby', 'examples/minivm/run_tests.rb', '--all']]
    if subproject == 'decomplex':
        return [['ruby', '-I', 'gems/decomplex/lib', '-I', 'gems/decomplex/test', *test_files(repo, 'gems/decomplex/test')]]
    if subproject == 'slopcop':
        return [['ruby', '-I', 'gems/slopcop/lib', '-I', 'gems/slopcop/test', *test_files(repo, 'gems/slopcop/test')]]
    if subproject == 'boobytrap':
        return [['ruby', '-I', 'gems/boobytrap/lib', '-I', 'gems/boobytrap/test', *test_files(repo, 'gems/boobytrap/test')]]
    return []


def run_all_tests(bug):
    repo = repo_path_for(bug)
    commands = [cmd for cmd in unit_test_commands(bug) if len(cmd) > 1]
    if not commands:
        return {'status': 'NO_RECORDED_TEST_FAILURE', 'test_command': None, 'test_output': 'Bug has no recorded failing test command'}

    outputs = []
    test_env = {**os.environ, 'RUBYOPT': '-W0'}
    if args.bundle_path and os.path.isdir(args.bundle_path):
        test_env['BUNDLE_PATH'] = args.bundle_path
    for cmd in commands:
        try:
            tr = subprocess.run(
                cmd,
                cwd=repo,
                capture_output=True,
                text=True,
                timeout=args.test_timeout,
                env=test_env,
            )
        except subprocess.TimeoutExpired:
            return {'status': 'TEST_TIMEOUT', 'test_command': cmd, 'test_output': 'TIMEOUT'}

        output = tr.stdout + tr.stderr
        outputs.append(f'$ {" ".join(cmd)}\n{output[-4000:]}')
        if tr.returncode != 0:
            env_markers = (
                'Could not find gem',
                'Could not locate Gemfile or .bundle',
                'Bundler::GemNotFound',
                'cannot load such file -- rspec',
                'cannot load such file -- sorbet-runtime',
                'command not found',
                'No such file or directory',
            )
            status = 'TEST_ENV_ERROR' if any(marker in output for marker in env_markers) else 'TEST_FAILED'
            return {'status': status, 'test_command': cmd, 'test_output': '\n'.join(outputs)[-6000:]}
    return {'status': 'TEST_PASSED', 'test_command': commands, 'test_output': ''}


def eval_bug(bug, response_text):
    reset = reset_repo_for_bug(bug)
    if not reset['ok']:
        return reset

    filepath = source_path_for(bug)
    try:
        mutation = apply_mutation_with_prism(bug)
        if mutation['status'] != 'MUTATION_APPLIED':
            return mutation
        syntax = syntax_check(filepath)
        if syntax['status'] != 'SYNTAX_OK':
            return {'status': 'MUTATION_SYNTAX_ERROR', 'error': syntax.get('error', '')}

        response = apply_response_with_prism(bug, response_text)
        if response['status'] != 'RESPONSE_APPLIED':
            return response
        syntax = syntax_check(filepath)
        if syntax['status'] != 'SYNTAX_OK':
            return syntax

        result = run_all_tests(bug)
        result['apply_detail'] = response.get('detail')
        return result
    finally:
        reset_repo_for_bug(bug)


def record_failure(category, index, bug, response_path, raw_response, status, detail=''):
    os.makedirs(os.path.dirname(args.failure_log), exist_ok=True)
    rec = {
        'bug_id': bug.get('id'),
        'index': index,
        'category': category,
        'repo_commit': (bug.get('repo') or {}).get('commit'),
        'repo_tree': (bug.get('repo') or {}).get('tree'),
        'file_rel': file_rel_for(bug),
        'function': bug.get('function'),
        'response_path': response_path,
        'raw_response': raw_response,
        'status': status,
        'detail': detail,
    }
    with open(args.failure_log, 'a') as f:
        f.write(json.dumps(rec) + '\n')


started = time.monotonic()
open(args.failure_log, 'w').close()
print(f'\n{"Category":<15} {"Responses":<10} {"TestPass":<9} {"TestFail":<9} {"EnvErr":<7} {"NoSuite":<8} {"Errors":<7}')
print('-' * 76)

for cat in [cat.strip() for cat in args.cats.split(',') if cat.strip()]:
    d = os.path.join(ROOT, 'bugfix', cat)
    if not os.path.isdir(d):
        continue
    n = passed = tfail = enverr = nosuite = err = 0
    statuses = {}
    for i in range(args.count):
        fp = os.path.join(d, f'{i + 1:02d}.txt')
        if not os.path.exists(fp):
            continue
        n += 1
        with open(fp) as f:
            txt = f.read()
        if unsupported_response_format(txt):
            err += 1
            status = 'UNSUPPORTED_RESPONSE_FORMAT'
            statuses[status] = statuses.get(status, 0) + 1
            record_failure(cat, i + 1, sample[i], fp, txt, status)
            continue

        result = eval_bug(sample[i], txt)
        status = result['status']
        statuses[status] = statuses.get(status, 0) + 1
        if status == 'TEST_PASSED':
            passed += 1
        elif status == 'TEST_FAILED':
            tfail += 1
            record_failure(cat, i + 1, sample[i], fp, txt, status, result.get('test_output', ''))
            if args.verbose_failures:
                rel = file_rel_for(sample[i])
                print(f'  fail {i + 1:02d}: {sample[i]["subproject"]} {rel} {sample[i]["function"]}')
                print(f'    {result.get("test_output", "").replace(chr(10), " ")[:240]}')
        elif status == 'TEST_ENV_ERROR':
            enverr += 1
            record_failure(cat, i + 1, sample[i], fp, txt, status, result.get('test_output', ''))
        elif status in ('NO_TEST_SUITE', 'NO_RECORDED_TEST_FAILURE'):
            nosuite += 1
            record_failure(cat, i + 1, sample[i], fp, txt, status, result.get('test_output', ''))
        else:
            err += 1
            record_failure(cat, i + 1, sample[i], fp, txt, status, result.get('error', result.get('test_output', '')))

    print(f'{cat:<15} {n:<10} {passed:<9} {tfail:<9} {enverr:<7} {nosuite:<8} {err:<7}')
    if err or tfail or enverr or nosuite:
        print('  statuses:', ', '.join(f'{k}={v}' for k, v in sorted(statuses.items())))

print()
print('TestPass = response was applied with Prism and the full mapped unit test suite passed')
print('NoSuite/EnvErr are failures for scoring; syntax-only success is never counted as a pass')
print('The evaluator resets the pinned checkout before and after every bug')
print(f'Failure log: {args.failure_log}')
print(f'Elapsed: {time.monotonic() - started:.2f}s')
