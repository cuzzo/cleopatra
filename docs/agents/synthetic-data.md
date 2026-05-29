# Synthetic Data Generation Plan

Generate 1300+ training examples from the [CLEAR](https://github.com/ahn-ml/clear) codebase
using git history mining, programmatic mutation, and (for bugs) outsourced LLM generation.

## Overview

| # | Dataset | Target | From history | Extras via combinations | Total potential |
|---|---|---|---|---|---|
| 1 | Simplification commits | 200 | 94 SIMP × ~20 back-versions = ~1,880 | — | **~1,880** |
| 2 | Feature commits | 200 | ~300 qualifying × 5–10 back-versions = ~1,500–3,000 | — | **~1,500–3,000** |
| 3 | Synthetic features | 400 | — | 400 deletions × 10 versions = ~4,000 | **~4,000** |
| 4 | Synthetic bugs | 400 | Limited (2–5 per real fix) | Outsource to DeepSeek/Qwen: 400 × 10 shots = 4,000 attempts | **~400 working** |
| 5 | Real bugs | 100 | ~100 fixes × 2–5 back-versions = ~200–500 | — | **~200–500** |
| | **Total** | **1,300** | | | **~8,000+** |

We have far more raw material than the 1,300 target. The pipeline should generate
everything it can, then select the best 1,300 by CodeQL score spread and diversity.

---

## Dataset 1: Simplification Commits (target 200)

### Source

94 SIMP-tagged commits touching 55 files (30 Ruby source files, rest test/spec/docs).

Top files by SIMP density:

| File | SIMP touches | Total versions | Versions per SIMP |
|---|---|---|---|
| `src/mir/mir_lowering.rb` | 32 | 292 | ~9 |
| `src/mir/promotion_plan.rb` | 25 | 82 | ~3 |
| `src/mir/mir_emitter.rb` | 22 | 96 | ~4 |
| `src/ast/ast.rb` | 18 | 131 | ~7 |
| `src/annotator.rb` | 15 | 557 | ~37 |
| `src/mir/mir_pass.rb` | 13 | 89 | ~7 |
| `src/mir/escape_graph.rb` | 9 | 46 | ~5 |
| `src/mir/control_flow.rb` | 9 | 72 | ~8 |

### Version extraction (the "worse" alternatives)

For each SIMP commit `SHA` touching file `F`:

```
1. git log --oneline -- F          → all versions of F, newest-first
2. Find SHA in that list           → position N
3. Every version OLDER than SHA    → a "worse" alternative (code before the SIMP)
4. Every version NEWER than SHA    → a "cleaner" version (later SIMPs or fixes)
```

For training, we use:
- **Reference:** version at SHA (the SIMP applied)
- **Prompt:** version at SHA^ (immediately before the SIMP)
- **Alternatives:** versions SHA-1, SHA-2, ... SHA-N going backward

### How far back to go

Stop when the file structure diverges too much (heuristic: when the diff between
SHA and SHA-N exceeds 2× the SIMP's own diff size, or when function names change).

For most files, this gives **10–40 valid back-versions** per SIMP commit.

### Estimated yield

| File | SIMP touches | Avg back-versions | Examples |
|---|---|---|---|
| mir_lowering.rb | 32 | 9 | 288 |
| promotion_plan.rb | 25 | 3 | 75 |
| mir_emitter.rb | 22 | 4 | 88 |
| ast.rb | 18 | 7 | 126 |
| annotator.rb | 15 | 37 | 555 |
| mir_pass.rb | 13 | 7 | 91 |
| escape_graph.rb | 9 | 5 | 45 |
| control_flow.rb | 9 | 8 | 72 |
| Other files (~20) | ~12 | ~4 | ~48 |
| **Total** | **94** | | **~1,880** |

### Combinatorial expansions

Within a single file, SIMP commits are often independent (they touch different
functions). Any **subset** of SIMPs targeting the same file can be applied
together, creating additional intermediate versions.

For `annotator.rb` (15 SIMPs, each touching different functions):

```
Base (0 SIMPs) → SIMP-01 only → SIMP-01 + SIMP-03 → ... → all 15
```

This is a prefix-chain: apply SIMPs in chronological order to the same file.
Each prefix is a valid working version. 15 SIMPs → 15 versions (we already
get these from git history, no need to construct them).

True combinatorial generation (any subset, not just prefixes) would yield 2^15
combinations, but most won't compile due to dependencies. Not worth the effort
for Dataset 1 — the 1,880 back-versions are sufficient.

---

## Dataset 2: Feature Commits (target 200)

### Source

~930 commits matching "feat", "add", "implement" in their message.
Filter to those that:
- Touch ≤3 files (focused)
- Have a diff of 5–200 lines (not trivial, not a sweep)
- Change Ruby source files (not spec, docs, or config)

Estimated yield after filtering: **300–400 qualifying commits**.

### Version extraction

Same approach as Dataset 1. For each qualifying feature commit:

```
Reference:  version at SHA (the feature added)
Prompt:     version at SHA^ (before the feature)
Alternatives: versions SHA-1 through SHA-N (older versions of the same file)
```

### Estimated yield

| Filter stage | Count |
|---|---|
| Raw "feat/add" commits | ~930 |
| After diff size filter (5–200 lines) | ~600 |
| After file count filter (≤3 files) | ~500 |
| After Ruby-only filter | ~350 |
| Avg back-versions per commit | 5–10 |
| **Total examples** | **~1,750–3,500** |

Sample 200 best from these by CodeQL score spread.

---

## Dataset 3: Synthetic Feature Requests (target 400)

### Generation method

Programmatic deletion: take a working version of a file, remove a function
body, class, or entire file, and use the next historical version as the
reference solution.

For each of 400 iterations:

1. **Pick a file** from the SIMP-touched set (guaranteed to have many versions)
2. **Pick two commits:** an older version (source) and a newer version (target)
   where the newer version has a meaningful change to the function/class
3. **Parse the source** with the Ruby `parser` gem (or Prism) to find
   function and class boundaries
4. **Delete a function body** (keep the `def` signature) or an entire class
5. **Prompt:** the source file with the deletion (hole marked `# TODO`)
6. **Reference:** the target version's implementation of that function/class
7. **Alternatives:** all versions between source and target

### Stratification

| Type | Count | Back-versions each | Total candidates |
|---|---|---|---|
| Function body removal | 200 | ~10 | 2,000 |
| Class removal | 100 | ~5 | 500 |
| File removal | 100 | ~3 | 300 |
| **Total** | **400** | | **~2,800** |

### Heuristic filtering

Only keep examples where:
- The deleted function/class exists in all intermediate versions (so alternatives
  are structurally comparable)
- The reference solution exists (target version has the function)
- Ruby can parse the deleted version (no syntax errors from the deletion)
- The CodeQL score of the reference is higher than the source (true improvement)

### Estimated yield

~2,800 candidates, filter to best 400.

---

## Dataset 4: Synthetic Bugs via Mutation (target 400)

### Why history doesn't help here

Unlike SIMP and feature commits (which have 10–40 back-versions each), bug fix
commits have very few usable back-versions. A bug exists in the code, the fix
fixes it, and that's usually 1–3 versions. We can't get "many wrong attempts"
from history for bugs.

### Generation method: outsourced to LLMs

For each of 400 examples:

1. **Pick a function** from `src/` that has tests or is independently verifiable
2. **Inject a mutation** from one of 7 types:
   - Negate condition (`if a > b` → `if a <= b`)
   - Swap operands (`a + b` → `b + a`)
   - Remove null check
   - Off-by-one (`arr[i]` → `arr[i+1]`)
   - Wrong operator (`&&` → `||`)
   - Delete a critical line
   - Wrong variable (`result` → `temp_result`)
3. **Send to DeepSeek v4 Flash** (and optionally Qwen) with the prompt:
   > "The following Ruby code has a bug. Find and fix it:\n\n<mutated code>"
4. **Collect 10 shots** from the LLM (even ones that don't pass all tests)
5. **Score each shot** with CodeQL
6. **Save the reference** (the original unmutated code) as the ground truth

### Why this is different from the other datasets

| Dataset | Alternatives come from | Quality guarantee |
|---|---|---|
| 1, 2, 3, 5 | Git history (real committed code) | All parse, all worked |
| 4 | LLM generation (DeepSeek/Qwen) | May not compile, may not fix the bug |

For Dataset 4, we keep **all 10 shots** even if they fail tests. Failed fixes
are valuable training data — GRAM should learn to reject paths that don't
compile or don't fix the bug.

### Tool calling data

DeepSeek's tool calls during generation (invocations of `check_syntax`,
`run_tests`, `edit_file`, etc.) are saved alongside the generated code.
These can train tool calling in a more powerful model later.

### Estimated yield

| Step | Count |
|---|---|
| Functions to mutate | ~500 candidates |
| Mutations attempted | 400 |
| LLM shots per mutation | 10 |
| Total generated responses | 4,000 |
| Responses that parse | ~2,800 (70%) |
| Responses that fix the bug | ~800 (20%) |
| **Training examples (keep all 10 shots)** | **400** |

---

## Dataset 5: Real Bugs (target 100)

### Source

~820 commits matching "fix", "bug", "crash" in their message.
Filter to those that:
- Are explicitly labeled as bug fixes (not "fix formatting" or "fix typo")
- Touch ≤2 files
- Diff is 5–100 lines (focused fix)
- Have a clear bug description

Estimated yield after filtering: **100–150 qualifying commits**.

### Version extraction

For each qualifying fix commit:

```
Reference:  version at SHA (the bug fixed)
Prompt:     version at SHA^ (the buggy code)
Alternatives: versions SHA-1 through SHA-N (older versions, may also have the bug)
```

Bug fix commits have fewer back-versions than SIMP commits because:
- Bugs are usually introduced and fixed quickly (2–5 versions)
- The buggy code doesn't persist through many refactors

### Estimated yield

| Filter stage | Count |
|---|---|
| Raw "fix" commits | ~820 |
| After filtering | ~100–150 |
| Avg back-versions per fix | 2–5 |
| **Total examples** | **~200–500** |

Sample 100 best by CodeQL score spread and bug severity.

---

## Generating "worse" versions via combinatorial prefix-chaining

Across all 5 datasets, the core technique is **prefix-chaining**: take a file's
git history, order commits chronologically, and every prefix is a valid working
version.

```
File F has commits: [A, B, C, D, E] (oldest → newest)

v0 = state at commit A (first version, sloppiest)
v1 = state at commit B (A + one improvement)
v2 = state at commit C (A + B + C improvements)
v3 = state at commit D (reference for SIMP at D)
v4 = state at commit E (cleanest version)

Training example targeting SIMP at D:
  prompt:       v2 (just before D)
  reference:    v3 (the SIMP)
  alternatives: v0, v1, v2 (all worse versions)
```

This works for any file with ≥5 versions and at least one SIMP/feature/fix commit.

---

## Total estimated yield

| Dataset | Target | Raw candidates | After filtering |
|---|---|---|---|
| 1. Simplification commits | 200 | ~1,880 | 200 (pick best spread) |
| 2. Feature commits | 200 | ~1,750–3,500 | 200 (pick best spread) |
| 3. Synthetic features | 400 | ~2,800 | 400 (pick best) |
| 4. Synthetic bugs | 400 | 400 × 10 shots = 4,000 | 400 (keep all 10 per) |
| 5. Real bugs | 100 | ~200–500 | 100 (pick best spread) |
| **Total** | **1,300** | **~6,600–8,600** | **1,300** |

We have ~5–7× the target in raw material. The selection strategy should
prioritize examples with the widest CodeQL score spread between the reference
and the worst alternative (so GRAM has a clear signal about which paths are
better).

---

## Pipeline summary

```
EXTRACT
  │
  ├── For each SIMP commit (94):     collect file, before, after, N back-versions
  ├── For each feature commit (350): collect file, before, after, N back-versions
  ├── For each fix commit (150):     collect file, before, after, N back-versions
  └── Programmatic deletion (400):   parse AST, delete function/class, save prompt
  
SCORE with CodeQL
  │
  ├── Every version → CodeQL health score
  └── Score spread = reference_score - worst_alternative_score
  
SELECT
  │
  ├── Sort by score spread (descending)
  └── Pick top 1,300
  
GENERATE (Dataset 4 only)
  │
  ├── For each mutation: send to DeepSeek + Qwen, collect 10 shots
  └── Save tool calls for future training
  
TRAIN GRAM
  │
  └── prompt + reference + alternatives + scores → explore paths, pick best

---

## Commit size: sweet spot analysis

### Why commit size matters

The models we're testing have very different capacities:

| Model | Parameters | Context window | Feasible diff size |
|---|---|---|---|
| Qwen 2.5-Coder-3B | ~3B | Limited | **5–50 lines** (focused changes) |
| Qwen 14B | ~14B | Larger | 20–200 lines |
| Phi 3.8B MoE (target) | ~3.8B active | Efficient | 20–150 lines **(target sweet spot)** |

A 3B model can understand a single function or a small refactor across 2 files.
It cannot understand a 500-line diff touching 10 files.

### Commit size distribution in CLEAR history

```
SIMP commits:  5–848 lines changed  (average ~30 lines, 1–2 files)
Fix commits:   1–100 lines changed  (average ~15 lines, 1 file)
Feature adds:  5–200 lines changed (average ~40 lines, 1–3 files)
Feature branch (squashed): 1,000–74,000 lines (~125 files)
```

Most SIMP and fix commits are already in the right size range for a 3B model.
The problem is the **feature branches** that got squashed into giant commits.

### Sweet spot by model

| Model | Sweet spot | Rationale |
|---|---|---|
| **Qwen 2.5-Coder-3B** | **5–30 lines, 1 file** | Small enough to fit in context + attention. The model can see the whole function and the change. |
| **Qwen 14B** (comparison) | 10–100 lines, 1–2 files | More capacity, can track cross-file changes. |
| **Phi 3.8B MoE** (target) | **10–60 lines, 1–2 files** | MoE means only ~3.8B active params, but efficient routing lets it handle ~2× the diff size of dense 3B. |

### What happens outside the sweet spot

| Diff size | Problem |
|---|---|
| **<5 lines** | Too trivial. The model just changes one token. No meaningful exploration — every path converges. CodeQL score spread is tiny. |
| **5–30 lines** | **Sweet spot for 3B.** The model must understand context and make a non-trivial change. Multiple valid approaches exist. CodeQL shows clear differentiation. |
| **30–100 lines** | Acceptable for Phi MoE. Requires understanding multiple functions or cross-function interaction. Some exploration. |
| **100–500 lines** | Too large for 3B. Model's attention scatters. Hard to generate correct output consistently. Low compilation rate. |
| **>500 lines** | Only usable if carefully decomposed. |

---

## How to quantify "Qwen 3B outperforming Qwen 14B"

Define a benchmark with 3 axes, all measured on held-out CLEAR commits
(50 commits not used in training any model):

### Axis 1: Functional correctness (pass/fail)

For each test commit:
1. Feed the prompt to each model
2. Does the generated code **compile?** (Ruby syntax + type-check)
3. Does the generated code **pass existing tests?**
4. Does the generated code **achieve the stated goal?** (manual review
   or CodeQL diff comparison)

Score: **% of test commits where the model passes all 3 checks.**

### Axis 2: Code quality (CodeQL score)

For each test commit where both models generate compiling code:
1. Run CodeQL on both outputs
2. Compare scores to the reference solution's score (the actual SIMP commit)

Score: **How close does each model get to the reference CodeQL score?**
  - Qwen 3B achieves 92% of reference → closer than 14B at 88%

### Axis 3: Efficiency (tokens/sec / memory)

For each model:
1. Tokens per second on target hardware (M5 MacBook)
2. Peak memory usage
3. Time to generate a correct output

Score: **Combined efficiency metric.** If 3B achieves comparable code quality
at 3× the speed and 1/4 the memory, that's a win even if 14B has slightly
better raw scores.

### Combined win condition

```
win_condition = (
  model.functional_correctness >= baseline.functional_correctness * 0.9
  && model.codeql_score >= baseline.codeql_score * 0.95
  && model.tokens_per_sec >= baseline.tokens_per_sec * 2
)
```

Qwen 3B beats Qwen 14B if it achieves ≥90% of 14B's fix rate, ≥95% of 14B's
CodeQL score, at ≥2× the throughput. This mirrors the README's goal:

> *"get Qwen2.5-Coder-3B to outperform a 7B model on a mix of implementation tasks"*

---

## Context retrieval: training the model to find what it needs

### The unfair advantage

A 14B model given an 83k-line file and told "fix the bug" must:
1. Find the relevant function among 50+ in the file
2. Understand its context within the file
3. Figure out the fix
4. Generate the correct output

Its 14B parameters are spent mostly on **filtering noise** — attention is
scattered across thousands of tokens, most of which are irrelevant.

A 3B model trained to **retrieve strategically** can do better by seeing
*less total code* but *more relevant code*:

```
3B trained to retrieve:                   14B reading everything:
  ┌─────────────────────┐                  ┌─────────────────────┐
  │ search("SplitStream")│                  │ (reads all 83k lines)│
  │   → found 1 function│                  │                     │
  │ fetch_function(...) │                  │ attention scattered │
  │   → sees 30 lines   │                  │                     │
  │ fetch_callers(...)  │                  │ might find the bug  │
  │   → 2 usage sites   │                  │ might miss it       │
  │                     │                  │                     │
  │ 90 lines total      │                  │ 83k lines total     │
  │ correct fix         │                  │ random guess        │
  └─────────────────────┘                  └─────────────────────┘
```

The 3B's parameters are spent on reasoning about the right thing, not
filtering noise. On tasks where the relevant context fits in 200 lines,
the 3B can match or beat the 14B — because both end up working with
the same 200 lines, the 3B just had to work harder (a few tool calls)
to find them.

### Training data from git history

Every commit in CLEAR history contains the retrieval path implicitly.
The diff tells us exactly which functions changed. We can derive the
*minimal context set* needed to make that change:

```
For each commit SHA touching file F with functions [f1, f2] changed:

MINIMAL_CONTEXT = {
  # Functions that changed (the target)
  changed: [f1, f2],

  # Functions that call them (upstream context)
  callers: call_graph.callers_of(f1) + call_graph.callers_of(f2),

  # Functions they call (downstream context)
  callees: call_graph.callees_of(f1) + call_graph.callees_of(f2),

  # Types/classes they reference
  types: type_deps_of(f1) + type_deps_of(f2),
}
```

This minimal set is the **training target** for retrieval. The model
should fetch exactly these functions, in dependency order (callers,
changed function, callees), before attempting a fix.

### Tool interface

The model has access to tools it can call before editing:

| Tool | Purpose | Example call |
|---|---|---|
| `search(query)` | Find functions by name | `search("SplitStream")` |
| `fetch_function(name)` | Get source of a function | `fetch_function("build_split_stream")` |
| `fetch_callers(name)` | Find who calls this function | `fetch_callers("build_split_stream")` |
| `fetch_callees(name)` | Find what this function calls | `fetch_callees("build_split_stream")` |
| `search_by_file(path)` | Find all functions in a file | `search_by_file("src/mir/fsm_lowering.rb")` |
| `edit_file(path, replacement)` | Make the change | final step |

### Training the retrieval strategy

For each commit, construct a training example:

```
PROMPT:
  "The code has a bug: [commit message].
   You have access to search, fetch_function, fetch_callers,
   fetch_callees, and edit_file.
   Find and fix the bug."

REFERENCE RETRIEVAL PATH:
  Step 1: search("[bug symptom]")     → finds the relevant function
  Step 2: fetch_callers("found_fn")    → understands usage context
  Step 3: fetch_function("found_fn")   → reads the buggy code
  Step 4: fetch_callees("found_fn")    → checks downstream effects
  Step 5: edit_file(path, replacement) → makes the fix

ALTERNATIVE PATHS (from older versions where the model fetches wrong things):
  ✗ search("wrong query") → wrong function, wrong fix
  ✗ fetch_function without callers → misses context, wrong fix
  ✗ edit_file without any fetch → guesses, almost certainly wrong

SCORE:
  - Correct fix with minimal fetches:  100 points
  - Correct fix with extra fetches:     80 points
  - Wrong fix with good retrieval:      30 points (strategy was right)
  - Wrong fix with bad retrieval:        0 points
```

GRAM explores multiple retrieval strategies as different "paths."
The best path minimizes fetches while producing a correct fix.

### Building the call graph from git history

The call graph is constructed by parsing every version of every file
in the repo. For each version:

```ruby
require 'parser/current'

def build_call_graph(sha)
  graph = {}
  Dir["src/**/*.rb"].each do |file|
    code = `git show #{sha}:#{file}`
    ast = Parser::CurrentRuby.parse(code)
    next unless ast

    ast.each_descendant(:def, :defs) do |func|
      name = func.children[0].to_s
      calls = []
      func.each_descendant(:send) do |send|
        callee = send.children[1].to_s
        calls << callee
      end
      graph[name] = calls
    end
  end
  graph
end
```

This gives us the call graph at each commit. The minimal context for
changing function `f` is: `f` + callers of `f` + callees of `f`.

### Training data volume

| Source | Commits | Retrieval paths |
|---|---|---|
| SIMP commits | 94 | 94 |
| Feature commits | ~350 | ~350 |
| Fix commits | ~150 | ~150 |
| WHERE branch (decomposed) | ~100 atomic | ~100 |
| **Total retrieval examples** | **~694** | **~694** |

Each commit generates:
- 1 reference retrieval path (the optimal set of tool calls)
- 3–5 alternative paths (suboptimal strategies, derived from what a
  naive model might do: wrong search query, missing caller context, etc.)

Total: ~694 reference paths + ~2,000–3,500 alternative paths

### What the model learns

The model learns a **retrieval policy**:

1. **Search strategically** — use the commit message or symptom as a query
2. **Understand structure first** — fetch callers before the function itself
   (understand context before code)
3. **Check downstream** — fetch callees before making a change
   (understand consequences before acting)
4. **Minimize context** — fetch only what's needed, ignore everything else

This is the "unfair advantage" for a 3B model. It doesn't need to process
83k lines — it needs to process 200 lines, but it must know *which* 200.

### Synergy with GRAM

GRAM explores multiple paths. In retrieval terms:

```
Path 1: search → fetch_callers → fetch_function → edit
  Score: correct fix, 4 tool calls → 95/100

Path 2: search → fetch_function → edit
  Score: wrong fix (missed caller context) → 20/100

Path 3: search → fetch_function → fetch_callees → edit
  Score: correct fix, 4 tool calls → 90/100 (correct but could be faster)

Path 4: search(wrong) → fetch_function(wrong) → edit
  Score: wrong fix → 0/100
```

GRAM selects path 1 — the optimal retrieval strategy. The model learns
not just "how to fix this bug" but "how to find the information needed
to fix this bug."

### Projected impact

| Task type | 14B (full context) | 3B + GRAM (retrieval) | Verdict |
|---|---|---|---|
| Single-function bug fix | 70% pass | 85% pass | **3B wins** |
| Cross-function refactor | 45% pass | 55% pass | **3B wins** (narrower) |
| Cross-file change (≤3 files) | 30% pass | 35% pass | **Tie** |
| Large feature (>5 files) | 15% pass | 15% pass | Tie (neither can do it) |

On focused tasks, retrieval training gives a 3B model a **meaningful
advantage** over a 14B model drowning in irrelevant context.

## Breaking up gigantic commits

Feature branches often produce squashed commits with 1,000–74,000 lines changed.
These are useless as training examples for a 3B model — they must be decomposed.

### Decomposition strategy

For a large commit touching many files, extract **atomic changes** by parsing
the diff:

```
Gigantic commit (74k lines, 125 files changed)
  │
  ├── Atomic change 1:  Add new function `foo` (30 lines, 1 file)
  ├── Atomic change 2:  Refactor `bar` to use `foo` (15 lines, 1 file)
  ├── Atomic change 3:  Add test for `foo` (40 lines, 1 file)
  ├── Atomic change 4:  Update type signatures (25 lines, 2 files)
  ├── Atomic change 5:  Remove dead code from `baz` (12 lines, 1 file)
  └── ... (20–100 atomic changes total)
```

Each atomic change is a separate training example with its own prompt,
reference, and alternatives. Atomic changes are ordered by dependency:
early changes (foundational) before later changes (that depend on them).

### Identifying atomic changes

Use `git diff --word-diff` or a diff parser to find contiguous blocks within
a single function/file:

1. **By file:** Each file changed in the commit is a candidate
2. **By function:** Within a file, each function/method changed is a separate
   atomic change
3. **By diff hunk:** Each `@@ ... @@` hunk in the diff is a separate change

### Filtering atomic changes

Only keep changes that:
- Are **5–60 lines** (sweet spot for Qwen 3B → Phi MoE)
- Touch **1–2 files**
- Are **semantically complete** (not a partial refactor that leaves dead code)
- Have **clear dependency ordering** (can be applied independently or in sequence)

### Generating training examples from atomic changes

For each atomic change within a large commit:

```
1. Checkout parent commit (before the large commit)
2. Apply atomic change 1 → this is the "after" state for example 1
3. Revert to parent
4. Apply atomic changes 1 + 2 → this is "after" state for example 2
5. Continue for all atomic changes
```

Alternatives for each atomic example are:
- The parent commit (worse — doesn't have the change)
- Versions of the same file from before the feature branch was created
- (If available) intermediate WIP commits from the feature branch's development

### Practical yield from decomposition

| Source | Raw | Atomic changes (5–60 lines each) | Training examples |
|---|---|---|---|
| WHERE branch (74k lines, 125 files) | 1 squashed commit | ~50–150 atomic | ~50–150 |
| hot-split branch | 1 squashed commit | ~20–80 atomic | ~20–80 |
| Other feature branches | ~10 squashed commits | ~100–300 atomic total | ~100–300 |

### Example: breaking down a SIMP Plan

A commit like `SIMP-Plan-A purge: delete the dead promote subsystem (-848 LOC)`
is already a 848-line change. But its diff touches multiple independent
components:

```
SIMP-Plan-A purge:
  ├── Delete promoteFields wrapper          (15 lines, 1 file)
  ├── Delete promoteDeep logic              (40 lines, 1 file)
  ├── Delete promoteFromStorage             (25 lines, 1 file)
  ├── Delete VarDecl branch in insert_promo (12 lines, 1 file)
  ├── Delete retag_expr in promote          (8 lines, 1 file)
  ├── Hoist heap into return-literal subs   (35 lines, 1 file)
  └── Remove 11 defensive &. arms           (20 lines, 1 file)
```

Each of these could be a standalone training example (5–40 lines each).
The total SIMP yield goes from 94 SIMP commits → **~200–300 atomic SIMP examples**
by decomposing the multi-file SIMP plans.

---

## Prompt framing: what to ask and how

### The core problem

A single commit can touch 10+ files and 10k+ lines of code. Even Opus 4.7
high-reasoning can't understand the full context of a change that took a
developer 100+ commits to produce. Asking the model to "make this change to
this file" is asking it to replicate a multi-week refactor in one shot.

Instead, **decompose to the function level** and frame each prompt as:

> "Ignore everything else in this file. We want to simplify THIS function to
> what it *should* be. Generate what this function *should* look like."

### The function-level framing

For each atomic change, extract just the function from git history:

```
Before (sloppy):                          After (reference):
┌──────────────────────┐                  ┌──────────────────────┐
│ def process(data)    │                  │ def process(data)    │
│   result = []        │                  │   data.map { |d|     │
│   data.each do |d|   │                  │     transform(d)     │
│     result << ...    │    ────────►     │   }.compact          │
│   end                │                  │ end                  │
│   result             │                  └──────────────────────┘
└──────────────────────┘
```

The model sees only these ~10 lines, not the surrounding 500-line file.

### Prompt templates by change type

| Change type | Template | Example |
|---|---|---|
| **Simplify function** | "This function can be simplified. Ignore everything else in the file. Generate what this function *should* look like:

```<function before>```" | "Simplify this function to what it should be" |
| **Tighten type** | "This type annotation is too loose. Tighten it to the most specific correct type:

```<code with loose type>```" | "Tighten FnNodes from T.untyped to the real type" |
| **Remove dead code** | "These [guards/branches/checks] are provably dead because [reason]. Remove them:

```<code with dead guards>```" | "Remove 11 dead defensive `&.` guards" |
| **Collapse logic** | "This conditional logic can be collapsed. Generate the simplified version:

```<code with verbose conditional>```" | "Collapse 22 cleanup kinds into `:uniform`" |
| **Extract helper** | "This repeated logic should be extracted to a helper method. Name it appropriately:

```<code with duplication>```" | "Extract `uses_runtime?` helper, collapse 4-term OR" |
| **Inline helper** | "This one-use helper should be inlined:

```<code with trivial helper>```" | "Inline 5 trivial classify_* into classify_binding" |
| **Fix bug** | "This function has a bug. Fix it to what it should be:

```<buggy function>```" | "Fix SplitStream deinit waitgroup hang" |
| **Implement feature** | "Implement this feature for the following function:

```<function before feature>```" | "Add CONCURRENT pipeline modifier" |

### Why function-level framing works for GRAM

| Level | What the model sees | Exploration space | CodeQL signal |
|---|---|---|---|
| **Whole file** (500+ lines) | Entire file, 10 functions, 1 changes | Overwhelming. Model can't find the right function. | Weak. File-level score change is small. |
| **Function only** (5–30 lines) | Just the target function | Focused. Multiple valid implementations of one function. | Strong. Function-level score change is clear. |
| **Diff hunk** (3–15 lines) | Just the changed lines | Too narrow. Only one correct output. | Weak. Almost no variation. |

The function level is the sweet spot: enough context to understand intent,
but narrow enough that the model can explore multiple valid implementations.

### Extracting functions from git history

Use the Ruby `parser` gem to find function/method boundaries:

```ruby
require 'parser/current'

# Parse file at a given commit
code = `git show #{SHA}:#{file}`
ast = Parser::CurrentRuby.parse(code)

# Find all function/method definitions
defs = []
ast.each_descendant(:def, :defs) do |node|
  defs << {
    name: node.children[0],
    start_line: node.loc.first_line,
    end_line: node.loc.last_line,
    body: code.lines[(node.loc.first_line-1)..(node.loc.last_line-1)].join
  }
end
```

For each SIMP or feature commit, extract just the function(s) that the diff
touches. The prompt shows only that function. The reference is the function
after the change. Alternatives are that function before the change and in
older versions.

### Example: from commit to function-level prompt

Commit: `SIMP: tighten FnNodes value type, drop 11 dead defensive &. arms`

Full diff: 40 lines, touches 2 functions in 1 file.

After extraction:

```
PROMPT:
"""
Simplify this function to what it should be:

  fn_nodes.each do |_n, fn|
    next unless fn&.body
    loop_carry_names(fn)
    promote_heapmut_concats!(fn)
  end
"""

The `fn&.body` guard is defensive — `fn` is always an AST::FunctionDef here.
Remove the unnecessary guard.

REFERENCE:
  fn_nodes.each do |_n, fn|
    next unless fn.body
    loop_carry_names(fn)
    promote_heapmut_concats!(fn)
  end
```

This is 8 lines of prompt for a 3B model. The model can see the whole
function, understand the change, and generate a correct output.

### When to keep file-level context

Some changes require file-level context. Keep the whole file when:
- The change touches **multiple functions** that interact (e.g., extract
  helper + call it from 3 sites)
- The change is a **type annotation** at the class/module level
- The change is a **class-level refactor** (add/remove method, change
  inheritance)

In these cases, show the entire file but highlight the specific region(s)
to change with `# <-- MODIFY THIS` comments.

### Yield from function-level extraction

By extracting individual functions from commits, we multiply our training
examples:

| Source | Raw commits | Functions extracted | Training examples |
|---|---|---|---|
| 94 SIMP commits | 94 | ~200–300 (2–3 functions per commit) | **~200–300** |
| ~350 feature commits | 350 | ~500–700 | **~500** |
| ~150 fix commits | 150 | ~150–200 (1 function per fix) | **~150** |
| WHERE branch (decomposed) | 1 squash | ~100 atomic | **~100** |
| **Total** | **~595** | **~950–1,300** | **~950–1,300** |

This gets us to the 1,300 target without any synthetic generation.

---

## Tools needed

| Tool | Purpose |
|---|---|
| `git` | Extract file versions from history |
| Ruby `parser` gem or Prism | Parse Ruby, find function/class boundaries |
| CodeQL CLI | Score every version for code health |
| DeepSeek API (v4 Flash) | Generate fix attempts (Dataset 4) |
| Qwen API (optional) | Additional fix attempts (Dataset 4) |