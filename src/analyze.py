import json, os, re

categories = ['3B-blind', '3B-ctx', '7B-blind', '32B-blind', '32B-ctx']
results = {}

for cat in categories:
    dirpath = os.path.join('bugfix', cat)
    if not os.path.isdir(dirpath):
        continue
    total = 0
    has_backtick = 0
    looks_like_code = 0
    no_code = 0
    too_short = 0

    for fname in sorted(os.listdir(dirpath)):
        fpath = os.path.join(dirpath, fname)
        if not fname.endswith('.txt'):
            continue
        total += 1
        with open(fpath) as f:
            text = f.read()
        stripped = text.strip()
        if len(stripped) < 10:
            too_short += 1
            continue
        if stripped.count('```') >= 2 or '```ruby' in stripped:
            has_backtick += 1
        elif 'def ' in stripped or 'class ' in stripped:
            looks_like_code += 1
        else:
            no_code += 1

    extractable = has_backtick + looks_like_code
    results[cat] = {'total': total, 'extractable': extractable, 'no_code': no_code, 'too_short': too_short, 'pct': extractable / total * 100 if total else 0}

print()
print('=== EXTRACTABLE CODE PER CATEGORY ===')
print()
print(f'{"Category":<15} {"Total":<8} {"Extractable":<12} {"No code":<10} {"Too short":<12} {"Pct"}')
print('-' * 65)
for cat in categories:
    r = results.get(cat, {})
    print(f'{cat:<15} {r.get("total",0):<8} {r.get("extractable",0):<12} {r.get("no_code",0):<10} {r.get("too_short",0):<12} {r.get("pct",0):.0f}%')
