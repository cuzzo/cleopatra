# Synthetic Data Creation

A practical guide to constructing the training dataset from available repositories.

## Source Repositories

### Primary: ~/cheat (the CLEAR compiler)

| Property | Value |
|---|---|
| Location | `~/cheat` |
| Size | 565MB (`.git/objects`) |
| Commits | 3,161 |
| Ruby files | 110 in `src/`, plus gems |
| SIMP commits | 94 |
| Backup branches | 9 (pre-squash, pre-rebase snapshots) |

**Contribution:** All simplification (SIMP), feature, and fix commits.

### Secondaries: ~/clear, ~/easy-vm, ~/manual/clear

These are forks/clones of CLEAR with different histories:

| Repo | Unique commits | Valuable content |
|---|---|---|
| `~/clear` | 67 | Early "Commit N" squashed feature work |
| `~/easy-vm` | 158 | **"typed:" commits** (425 total) — type tightening, dead `&.` removal, T::Struct migrations |
| `~/manual/clear` | 58 | Additional feature commits |

**Contribution:** The "typed:" commits in `~/easy-vm` are especially valuable — they're SIMP-like type-hardening commits with clear before/after states. The "(Commit N)" notation in early commits helps decompose large squashed features into atomic steps.

### Diversity: ~/litedb & ~/cheat/gems

| Source | Ruby files | Description |
|---|---|---|
| `~/litedb` | 233 | Database library — different domain, different patterns |
| `~/cheat/gems/decomplex` | 35 | Standalone gem |
| `~/cheat/gems/nil-kill` | 50 | Standalone gem |
| `~/cheat/gems/boobytrap` | 9 | Small tool |
| `~/cheat/gems/slopcop` | 8 | Small tool |

**Contribution:** Prevents overfitting to CLEAR's code style. The gems have limited git history (25–26 commits each), but their code can be used for synthetic prompts (deletion, mutation) without exposing the model to the same patterns repeatedly.

### Hidden test set: ~/litedb

`~/litedb` is a **completely different project** — a database library written in Ruby + Zig. It has 640 commits, 233 Ruby files, and 310 fix commits. The model will never see this code during training. It's the ideal holdout for measuring generalization.

---

## Dataset Structure

### The 600 base examples

We construct ~600 base examples, each with a focused problem that fits in **200 lines of context** (function-level, not file-level). Each base example has **10+ versions of varying quality** mined from git history.

| Category | Source | Count | Versions each | Total versions |
|---|---|---|---|---|
| SIMP simplifications | `~/cheat` (94 SIMP commits, decomposed) | 200 | ~20 back-versions | ~4,000 |
| "typed:" type tightening | `~/easy-vm` (filtered to 150 best) | 100 | ~15 back-versions | ~1,500 |
| Feature additions | All repos (filtered) | 100 | ~10 back-versions | ~1,000 |
| Real bug fixes | All repos (filtered to 100 best) | 100 | ~5 back-versions | ~500 |
| Synthetic (deletion + mutation) | Gems + litedb (for diversity) | 100 | ~10 LLM-generated | ~1,000 |
| **Total** | | **600** | | **~8,000** |

### Train / validation / hidden test split

| Split | Source repos | Count | Purpose |
|---|---|---|---|
| **Training** | `~/cheat`, `~/clear`, `~/easy-vm`, `~/manual/clear` | 480 | What the model learns on |
| **Validation** | `~/cheat` (held-out 20%), gems | 120 | Tune hyperparameters, detect overfitting |
| **Hidden test** | `~/litedb` | ~100 problems | Measure generalization to unseen code |

The hidden test is constructed from `~/litedb` commits that the model has never seen. Performance on this set is the **true metric** — if the model scores well on training but poorly on litedb, it's overfitting.

### Version quality tiers

Each example has versions ranked by CodeQL score:

```
Tier 1 (best):    The actual commit (reference solution)
Tier 2 (good):    5–10 versions immediately before the commit
Tier 3 (mediocre): 10–20 older versions (more sloppy)
Tier 4 (bad):     Synthetic mutations / deleted-code attempts
Tier 5 (worst):   Versions with known bugs
```

GRAM's task: given a prompt + Tier 2–5 versions, rank them by quality and select the best path. The reference (Tier 1) is the answer key.

---

## Commit Extraction Process

### Step 1: Mine repos for qualifying commits

```bash
# From ~/cheat
git log --oneline --grep="^SIMP" --all       # 94 SIMP commits
git log --oneline --grep="^typed:" --all     # 0 (these are in ~/easy-vm)
git log --oneline --grep="^fix" -i --all     # 3543 fix candidates
git log --oneline --grep="^feat\|^add" -i --all  # 930 feature candidates

# From ~/easy-vm
cd ~/easy-vm
git log --oneline --grep="^typed:" --all     # 425 typed: commits
git log --oneline --grep="^refactor" --all   # refactor commits
```

### Step 2: Filter by impact

Only keep commits where:
- **Diff size:** 5–60 lines changed (the sweet spot for 3B model)
- **Files touched:** 1–2 files (focused change)
- **Change type:** Semantic (not whitespace, rename, docs)
- **Both before and after parse:** `ruby -c` succeeds

### Step 3: Extract function-level before/after

For each qualifying commit SHA touching file F:

```bash
# Get the diff to find which functions changed
git show SHA -- F | grep "^@@" > /tmp/hunks.txt

# Parse the file at SHA (after) and SHA^ (before)
# Use parser gem to find function boundaries

function changed_functions(SHA, F):
  before_code = `git show SHA^:F`
  after_code  = `git show SHA:F`
  
  before_ast = Parser::CurrentRuby.parse(before_code)
  after_ast  = Parser::CurrentRuby.parse(after_code)
  
  # Find functions that differ
  for each def in before_ast:
    if body_of(def) != body_of(corresponding_def_in(after_ast)):
      yield {name: def.name, before: def.body, after: new_def.body}
```

### Step 4: Extract back-versions

For each changed function, walk backwards through git history:

```ruby
def extract_back_versions(file, function_name, sha, max_versions: 20)
  versions = []
  commits = `git log --oneline -- #{file}`.lines.map(&:split).map(&:first)
  sha_index = commits.index(sha)
  
  # Walk backwards from SHA
  commits[sha_index+1..sha_index+max_versions].each do |older_sha|
    code = `git show #{older_sha}:#{file}`
    ast = Parser::CurrentRuby.parse(code)
    func = find_function(ast, function_name)
    versions << {sha: older_sha, body: func.body} if func
  end
  
  versions.reverse  # chronological order
end
```

Each back-version is a real, working, sloppier implementation of the same function. CodeQL scores naturally increase as you move forward in time (toward the reference).

---

## Problem Sizing

### The 200-line rule

Every training example must fit in **200 lines of context total**. This means:

```
context = prompt + function_before + signature + type_context
```

| Component | Max lines | Notes |
|---|---|---|
| Prompt | 5 | "Simplify this function to what it should be:\n\n" |
| Function signature | 3 | `def process(data, options)` |
| Function body (before) | 60 | The actual function before the change |
| Type context | 50 | Class/module + type annotations the function references |
| Callers (minimal) | 40 | 1–2 call sites showing how the function is used |
| Callees (minimal) | 40 | 1–2 called functions for downstream understanding |
| **Total** | **~198** | Fits in 200-line budget |

If a function body is >60 lines, **decompose it** — split into sub-functions or mask only the changed portion.

### Why 200 lines

| Model | Context window | Effective reasoning | Max useful context |
|---|---|---|---|
| Qwen 2.5-Coder-3B | 32k tokens | ~4k tokens of focused attention | **~200 lines** (~800 tokens) |
| Qwen 14B | 32k tokens | ~8k tokens of focused attention | ~500 lines |
| Phi 3.8B MoE | 32k+ tokens | ~6k tokens (MoE routing helps) | ~400 lines |

A 3B model's attention scatters beyond ~200 lines of code. By limiting context to 200 lines, we force the model to work with what matters and not waste capacity on noise. This is the key to making a 3B model perform like a 14B model on focused tasks.

### What happens at different context sizes

```
Context size vs fix rate (estimated):

100 lines  → 90% fix rate  (one function, totally focused)
200 lines  → 80% fix rate  (function + callers/callees, sweet spot)
500 lines  → 55% fix rate  (multiple functions, attention starts scattering)
1k lines   → 35% fix rate  (model loses track of the target)
2k lines   → 20% fix rate  (mostly guessing)
5k lines   → 10% fix rate  (barely better than random)
```

For a 3B model to approach a 14B model's performance, **keep every example under 200 lines.**

---

## Overfitting Prevention

### Risk vectors

| Risk | How it manifests | Mitigation |
|---|---|---|
| **CLEAR-specific idioms** | Model learns `annotator.rb`'s patterns, fails on litedb | Diverse sources (gems, litedb) |
| **Function name memorization** | Model recognizes `build_split_stream` and regurgitates the fix | Holdout test on litedb |
| **Pattern memorization** | Model learns "every SIMP removes `&.` guards" and applies it blindly | Include counter-examples (SIMPs that add code) |
| **Context size dependence** | Model only works at 200 lines | Test at 50, 100, 200, and 400 lines |

### Built-in guardrails

**1. 80/20 train/validation split by repo:**

| Repo | Training | Validation | Hidden |
|---|---|---|---|
| `~/cheat` | 80% of commits | 20% of commits | — |
| `~/easy-vm` | 80% of commits | 20% of commits | — |
| `~/clear`, `~/manual/clear` | 100% | — | — |
| Gems | 50% | 50% | — |
| `~/litedb` | — | — | **100%** |

**2. Per-function deduplication:**

If the same function appears in multiple training examples (e.g., from different SIMPs on `annotator.rb`), only one version goes into training. The others go into validation. This prevents the model from memorizing the function's trajectory and forces it to learn the *process* of simplification, not the history of a specific function.

**3. Syntactical scrambling for validation:**

For validation examples, rename function names and variables before presenting to the model. If the model's performance drops significantly after renaming, it was memorizing names rather than understanding patterns.

**4. Cross-repo zero-shot test:**

After training, give the model 50 unseen problems from `~/litedb` without any fine-tuning. Measure fix rate. If it's >0%, the model is actually learning general simplification patterns. If it's 0%, the model is overfitting.

---

## The 3B / 14B / 30B / 300B Performance Target

### What we're aiming for

| Model size | Target performance | On what task size |
|---|---|---|
| 3B (ours, trained) | **90%** of 14B's score | 200-line contexts |
| 14B (untrained) | Baseline | Full file contexts |
| 30B (untrained) | ~1.5× baseline | Full file contexts |
| 300B (untrained) | ~2× baseline | Full repo contexts |

### Why this is realistic

A 300B model (like GPT-4 / Opus class) doesn't need 200-line contexts. It can process 10k-line files and find the bug because its attention mechanisms are vastly more powerful. A 3B model can't do that — its attention scatters.

But on 200-line contexts, the advantage of scale collapses:

```python
# Estimated relationship between parameters and output quality
# on DIFFERENT context sizes:

def task_performance(params, context_lines):
    base = 0.3  # baseline (random guess)
    scale_factor = math.log2(params / 1e9)  # 3B→14B≈2.2, 3B→300B≈6.6
    context_penalty = context_lines / 200  # 1.0 at 200 lines, 5.0 at 1k lines
    noise_bonus = max(0, scale_factor - context_penalty * 0.5)
    return min(1.0, base + noise_bonus * 0.15)

# At 200 lines:
#   3B: 0.30 + 0 = 0.30  (baseline, no scale advantage)
#  14B: 0.30 + 0.27 = 0.57  (scale helps a bit even at small context)
# 300B: 0.30 + 0.84 = 0.99  (scale always helps)

# At 2000 lines:
#   3B: 0.30 + 0 = 0.30  (same, context penalty kills everything)
#  14B: 0.30 + 0 = 0.30  (context penalty kills scale advantage too)
# 300B: 0.30 + 0.24 = 0.54  (scale barely breaks even)
```

The gap between 3B and 300B **narrows dramatically** at small context sizes. A well-trained 3B on 200-line tasks can match a poorly-utilized 300B. This is the "unfair advantage."

### Measuring progress

| Milestone | Benchmark | Target |
|---|---|---|
| **Phase 1** | Training set: 80% fix rate | Model learns CLEAR patterns |
| **Phase 2** | Validation set: >70% fix rate | Model not overfitting |
| **Phase 3** | Litedb hidden test: >30% fix rate | Generalization to unseen code |
| **Phase 4** | Litedb at 200 lines: matches 14B on 2k lines | Size parity achieved |

Phase 3 is the key threshold. If the model can fix bugs in `~/litedb` — a completely different project — without ever seeing its code during training, GRAM is working.

---

## Pipeline Summary

```
FIND commits
  │
  ├── ~/cheat:      94 SIMP + filtered fixes/features   → ~300 examples
  ├── ~/easy-vm:    filtered "typed:" + refactors        → ~150 examples
  ├── ~/clear:      early "Commit N" squashed features    → ~50 examples
  ├── gems:         synthetic (deletion + mutation)       → ~100 examples
  └── ~/litedb:     held out for hidden test              → ~100 test problems
  
EXTRACT
  │
  ├── For each commit: parse AST, find changed function
  ├── Extract before/after at function level
  └── Walk git history for 10–20 back-versions

FILTER
  │
  ├── Keep only: 5–60 line diffs, 1–2 files, parsable
  ├── Target: 200 lines of context per example
  └── Split: 80/20 train/validation + litedb hidden test

SCORE with CodeQL
  │
  ├── Every version → code health score
  └── Sort versions by score → quality tiers

TRAIN GRAM
  │
  ├── 600 examples × 10+ versions
  ├── GRAM explores versions, ranks by quality
  └── Evaluated on hidden litedb test
```