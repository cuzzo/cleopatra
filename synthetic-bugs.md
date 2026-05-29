# Synthetic Bugs Generation Plan

This document specifies how to generate synthetic bugs via mutation testing
across all CLEAR sub-projects for training the tool-calling model. The current
implemented generator, `mutant-bug-gen.rb`, produces the 1,200 Ruby code-bug
slice used for the Qwen ideal-context experiments.

## 0. Source Of Truth

Synthetic bugs are generated from the bundled CLEAR history stored inside this
repo, not from a live development checkout such as `~/cheat`.

Default source:

```bash
ruby mutant-bug-gen.rb \
  --bundle archives/cheat.bundle \
  --repo .eval/cheat \
  --ref refs/remotes/bundle/master \
  --out bugs.jsonl \
  --target 1200
```

The generator restores or reuses `.eval/cheat`, checks out the requested ref in
detached mode, hard-resets and cleans that worktree, and records provenance on
every bug:

```json
{
  "repo": {
    "bundle": "archives/cheat.bundle",
    "repo_path": "/home/yahn/cleopatra/.eval/cheat",
    "ref": "refs/remotes/bundle/master",
    "commit": "cde89fbfcdad68725f6bfa2d67697186bae647ea",
    "tree": "..."
  },
  "file": "src/mir/example.rb",
  "file_rel": "src/mir/example.rb"
}
```

`~/cheat` is not a valid data-generation input because it is an active
development checkout and can drift independently from the dataset.

For the current 50-bug Qwen control experiment, generation is intentionally
restricted to `src/`. Every accepted mutant must have at least one verified
failing spec file: the spec passes on the clean pinned checkout, then fails
after the mutation is applied.

---

## 1. Function Inventory

Functions suitable for mutation (3–80 lines, parseable by Prism):

| Sub-project | Functions | Files | % target | % actual |
|-------------|-----------|-------|----------|----------|
| `src/` (new compiler) | 2,918 | 110 | ≤66% | 55.2% |
| `gems/nil-kill/` | 1,005 | 50 | ≥33% combined | 19.0% |
| `examples/minivm/` | 522 | 12 | | 9.9% |
| `examples/puck/` | 461 | 47 | | 8.7% |
| `gems/decomplex/` | 307 | 35 | | 5.8% |
| `gems/slopcop/` | 42 | 8 | | 0.8% |
| `gems/boobytrap/` | 32 | 9 | | 0.6% |
| **Total** | **5,287** | **271** | | **100%** |

**Note:** The old VM (old-master branch — parser.rb, vm.rb, compiler.rb) is
excluded. Those files are Puck language code, not Ruby. The Puck language
evolution is captured in `examples/puck/` which contains 461 Ruby functions.

### 1.1 Test Coverage per Sub-Project

| Sub-project | Test directory | Test files | Has stack traces? |
|-------------|---------------|------------|-------------------|
| `src/` | `spec/` | 218 | ✅ Yes (RSpec) |
| `gems/nil-kill/` | `gems/nil-kill/spec/` | 17 | ✅ Yes (RSpec) |
| `gems/decomplex/` | `gems/decomplex/test/` | ~5 | ✅ Yes |
| `gems/slopcop/` | `gems/slopcop/test/` | ~3 | ✅ Yes |
| `gems/boobytrap/` | `gems/boobytrap/test/` | ~4 | ✅ Yes |
| `examples/minivm/` | `examples/minivm/run_tests.rb` | 1 | ⚠️ Custom harness |
| `examples/puck/` | None | 0 | ❌ No tests |

### 1.2 Sub-Projects with Limited Synthetic Bug Potential

| Sub-project | Issue | Mitigation |
|-------------|-------|------------|
| **slopcop** | Only 42 functions | Increase mutation rate to 10 per function |
| **boobytrap** | Only 32 functions | Increase mutation rate to 12 per function |
| **puck** | No test suite | Generate bugs by comparing version diffs (v3→v5 has known changes) |
| **minivm** | Custom test harness | Use `run_tests.rb` output for failure detection |

---

## 2. Bug Difficulty Distribution

```
Difficulty         How deep is the bug?                % of dataset  Count
─────────────────────────────────────────────────────────────────────────
Easy syntax        Obvious typo on crash line          10%            1,000
Trivial line       Mutant on the crashed line itself   20%            2,000
Trivial function   Mutant within the crashed function  20%            2,000
Stack trace 1-2    Bug in caller (1-2 levels up)       30%            3,000
Hard 2+ deep       Bug in caller's caller (2+ levels)  20%            2,000
─────────────────────────────────────────────────────────────────────────
Total                                                 100%           1,200
```

`mutant-bug-gen.rb` enforces these as exact quotas for the requested target
count. For the default 1,200-bug run: 120 easy syntax, 240 trivial line,
240 trivial function, 360 stack 1-2, and 240 hard 2+.

### 2.1 Easy Syntax (10% — 120 bugs)

These are typos and trivial mistakes. The model should instantly recognize
them without needing deep context. Used as a "warm-up" and to teach the
model to verify syntax before exploring deep context.

```
Mutations:
  - if x = y    → should be if x == y    (assignment in condition)
  - .size()     → should be .size        (method with wrong parens)
  - def foo     → def fooo               (typo in def name)
  - arr[i]      → arr[i, j]              (wrong number of args)
  - missing end keyword
  - extra end keyword
```

**Detection:** `ruby -c` fails immediately. Stack trace shows syntax error.
**Ideal tool call:** 0 — the error message tells you everything.

### 2.2 Trivial Line (20% — 240 bugs)

A single mutation on the EXACT line that fails. The bug is right there in
the stack trace. The model just needs to look at the failed line.

```
Mutations:
  - a > b       → a >= b                 (wrong comparison)
  - arr[i]      → arr[i + 1]             (off-by-one)
  - result + 1  → result - 1             (wrong operator)
  - true        → false                  (wrong boolean literal)
  - "foo"       → "bar"                  (wrong string constant)
  - 42          → 24                     (wrong numeric literal)
```

**Detection:** Test fails with clear stack trace pointing to exact line.
**Ideal tool call:** 1 — ctx on the crashed function to see context.

### 2.3 Trivial Function (20% — 240 bugs)

A mutation WITHIN the crashed function but NOT on the crashed line. The bug
is in the same function but a few lines earlier or later.

```
Mutations:
  - Delete a guard clause earlier in the function
  - Wrong variable assigned earlier → crashes later
  - Delete a line that initializes a variable
  - Swap the order of two function calls
  - Move a line inside/outside of an if block
```

**Detection:** Test fails. Stack trace points to the crash site, but the root
cause is in a nearby line in the same function.
**Ideal tool call:** 1-2 — ctx on the function + maybe one related function.

### 2.4 Stack Trace 1–2 Levels (30% — 360 bugs)

A mutation in the CALLER of the crashed function (1 level up) or the caller's
caller (2 levels up). The stack trace shows the crash in function C, but
the bug is in function B (which called C) or function A (which called B).

```
Mutations:
  - Caller passes wrong argument type
  - Caller passes nil instead of a value
  - Caller calls the wrong method
  - Caller has a wrong default parameter
  - Caller mutates a value that should be constant
```

**Detection:** Test fails. Stack trace shows C crashed, but the root cause
is B or A calling C incorrectly.
**Ideal tool call:** 3-5 — ctx on C, then walk up the stack trace to B, A.

### 2.5 Hard 2+ Deep (20% — 240 bugs)

A mutation 2+ levels deep in the stack trace, in surrounding lines within
those deeper functions. Requires the model to walk UP the stack trace and
then SIDEWAYS within the caller to find the root cause.

```
Mutations:
  - Function 3 levels up has wrong config/state
  - Function 2 levels up calls the right function but with wrong assumptions
  - Multiple functions interact in unexpected ways
  - The bug manifests only in specific input combinations
```

**Detection:** Test fails. Stack trace is long (5+ frames). Root cause is
in a function far from the crash site.
**Ideal tool call:** 5-7 — ctx walking up the entire stack trace.

---

## 3. Bug Location Distribution

### 3.1 Discovery Scenario Distribution

The generator assigns one discovery scenario to every bug. This controls what
`ctx` reports about worktree state and how the model should prioritize context.

| Scenario | Share | Worktree state | Intended lesson |
|---|---:|---|---|
| Dirty source change | 30% | Target source file dirty | Bug is probably in recently changed source lines |
| New unit test | 30% | New test file dirty | Test describes new expected behavior; source may be clean |
| Production stack trace | 40% | Clean tree | Existing/production bug slipped through tests |

Dirty source bugs are subdivided:

| Dirty scope | Share of dirty source | Meaning |
|---|---:|---|
| Whole function dirty | 50% | The entire function should be treated as recently edited |
| Multi-line dirty | 25% | Several lines are dirty and one is the mutated bug line |
| Exact-line dirty | 25% | Only the mutated line is dirty; `ctx` should make this nearly obvious |

`mutant-bug-gen.rb` stores this in each bug's `discovery` block, including
`dirty_files`, line ranges, and synthetic new-test content when applicable.

### 3.2 Code Bugs

Bugs in the actual source code (`.rb` files in src/, gems/, examples/).
This is the currently implemented path. The default 1,200-bug dataset is
100% code bugs because the evaluator applies model-defined Ruby functions back
into source files.

### 3.3 Test Bugs (Planned)

Bugs in the test code itself. The test is wrong, not the implementation.

```
Test bug types:
  - Wrong expected value:  expect(result).to eq(42) → expect(result).to eq(43)
  - Wrong test setup:      let(:input) { "a" } → let(:input) { "b" }
  - Missing test fixture
  - Test calls wrong method
  - Test assertion is inverted (expect.to vs expect.not_to)
  - Test doesn't account for edge case
```

**Detection:** The test fails, but the implementation is actually correct.
The model needs to verify the implementation before concluding the test is wrong.
**Ideal tool call:** 0-1 — just read the test and compare with expected behavior.
**Challenge:** The model must determine WHEN the test is wrong vs the code is wrong.
This is a harder reasoning task — distinguishing test bugs from code bugs.

This category is not generated by `mutant-bug-gen.rb` yet. It needs a separate
evaluator path because the current evaluator uses Prism to replace or append
source functions named by the model response. Test bugs require rewriting test
files or accepting an explicit "test is wrong" response.

### 3.3 Sub-Project Distribution

Across 10,000 bugs:

| Sub-project | % of dataset | Bug count |
|-------------|-------------|-----------|
| `src/` (new compiler) | 55% | 5,500 |
| `gems/nil-kill/` | 19% | 1,900 |
| `examples/minivm/` | 10% | 1,000 |
| `examples/puck/` | 9% | 900 |
| `gems/decomplex/` | 5% | 500 |
| `gems/slopcop/` | 1% | 100 |
| `gems/boobytrap/` | 1% | 100 |
| **Total** | **100%** | **10,000** |

---

## 4. How to Identify Functions for Mutation

### 4.1 Step 1: Parse Source Files

For each `.rb` file in the sub-project:
1. Parse with Prism → extract all `def...end` blocks
2. Filter to functions with 3–80 lines (too small = no mutation surface, too large = context overload)
3. Record: function name, file path, start_line, end_line, body text

### 4.2 Step 2: Map Functions to Tests

For each function, find the test that exercises it:

```
Method 1 (preferred): grep the test directory for the function name
  → grep -r "function_name" spec/ gems/*/spec/ examples/minivm/

Method 2 (if not found): grep for the file name in test requires
  → grep -r "require.*escape_analysis" spec/

Method 3 (fallback for puck): use `ruby -c` only (no test suite available)
```

For each (function, test_file, test_line) triplet found, record the mapping.

### 4.3 Step 3: Generate Stack Traces for Bug Scenarios

For bugs at different depths, construct realistic stack traces:

```
Level 0 (crash site): 
  test_function_spec.rb:42:in `block (3 levels) in ...'
  src/mir/escape_analysis.rb:142:in `apply!'

Level 1 (one up):
  test_function_spec.rb:42:in `block (3 levels) in ...'
  src/mir/escape_analysis.rb:142:in `apply!'
  src/annotator/annotator.rb:89:in `propagate_caller_sync!'

Level 2 (two up):
  test_function_spec.rb:42:in `block (3 levels) in ...'
  src/mir/escape_analysis.rb:142:in `apply!'
  src/annotator/annotator.rb:89:in `propagate_caller_sync!'
  src/pipeline_generator.rb:234:in `generate!'
  spec/spec_helper.rb:15:in `run_test'
```

The stack trace is constructed by:
1. Reading the actual test file to get the test line and name
2. Walking the `require` chain to identify possible callers
3. Building a realistic call chain from the test → source code

For the planned test bug category:
1. Mutate the test assertion or setup
2. The test fails, but the source code is correct
3. The "stack trace" just shows the test failure, not a code crash

### 4.4 Step 4: Generate Ideal Tool-Call Sequence

For each bug, compute the ideal sequence of `ctx` calls:

```
Bug depth 0 (crash site):    1 call  — ctx on the crashed function
Bug depth 1 (one up):        3 calls — crashed fn → caller → caller's types
Bug depth 2+ (hard):         5 calls — walk up the full stack trace
Test bug:                    0-1 calls — check the test, confirm code is right
```

The ideal sequence is computed from the function-to-test mapping and the
dependency graph (which functions call which other functions).

---

## 5. Generation Pipeline

```
For each sub-project:
  │
  ├── Step 1: Parse all .rb files → extract 5,287 mutatable functions
  │
  ├── Step 2: Map each function to its test file + test line
  │     └── grep function_name across test directories
  │
  ├── Step 3: For each function:
  │     │
  │     ├── For each mutation type in the catalog:
  │     │     ├── Apply mutation to function body
  │     │     ├── Validate: substituted file still parses? (ruby -c)
  │     │     ├── Determine bug depth
  │     │     ├── Construct stack trace
  │     │     ├── Compute ideal tool-call sequence
  │     │     └── Generate 4 trajectory variants (clean/sloppy/broken/blind)
  │     │
  │     └── Continue until we have the target count for this sub-project
  │
  └── Output: JSON training examples
```

### 5.1 Validation Gate

Before including a synthetic bug in the training set:

1. **Pinned source check** — the bug records the bundle, ref, commit, and tree.
2. **Relative path check** — the bug stores `file_rel`; absolute development paths are not used.
3. **Replacement check** — `original_body` exists in the pinned source file.
4. **Parse check** — replacing `original_body` with `mutated_body` still passes `ruby -c`.
5. **Not too obvious** — the mutation changes ≥1 semantic token (not just whitespace)
6. **Not impossible** — a human developer might plausibly write this
7. **Detectable** — the existing test (or a heuristic) would flag this as wrong
8. **Tool-callable** — there exists at least one `ctx` call that provides useful context
9. **Prompt-diverse** — assigned to a prompt style based on the distribution

Generation skips are written to `bug_generation_failures.jsonl` with enough
metadata to inspect why a candidate was rejected, for example
`mutated_file_does_not_parse` or `original_body_not_found`.

### 5.2 Realistic Yield

From 5,287 functions with ~7 mutations each:
- 36,900 raw mutations attempted
- ~25,800 pass parse check (70%)
- ~12,900 pass test detection (50%)
- ~10,000 selected for training (most diverse + highest quality)

---

## 6. Output Format

Each synthetic bug follows the `tool-call-training.md` format:

```json
{
  "id": "synth-gems-nil-kill-043-op-001",
  "type": "bug_fix",
  "source": "synthetic",
  "repo": {
    "bundle": "archives/cheat.bundle",
    "ref": "refs/remotes/bundle/master",
    "commit": "...",
    "tree": "..."
  },
  "subproject": "nil-kill",
  "difficulty": "stack_trace_1_2",
  "bug_depth": "one_level_up",
  "mutation": "wrong_operator",
  "test_failures": [
    {
      "file_rel": "spec/use_after_move_dataflow_spec.rb",
      "line": 42,
      "command": ["bundle", "exec", "rspec", "spec/use_after_move_dataflow_spec.rb"],
      "failure_excerpt": "..."
    }
  ],
  "code_or_test": "code",
  "file": "gems/nil-kill/lib/nil_kill/apply.rb",
  "file_rel": "gems/nil-kill/lib/nil_kill/apply.rb",
  "function": "NilKill::Apply.baseline_reachable?",
  "prompt": {
    "style": "stack_trace",
    "text": "..."
  },
  "trajectories": { "y_clean": {...}, "y_sloppy": {...}, "y_broken": {...}, "y_blind": {...} },
  "ideal_tool_calls": [...],
  "reference_fix": { "before": "...", "after": "..." }
}
```

---

## 7. Schedule

| Phase | What | Output |
|-------|------|--------|
| **Phase 1** | Parse all files + mutation catalog | Function DB with 5,287 entries |
| **Phase 2** | Generate 10,000 bugs + validate | JSON training set |
| **Phase 3** | Generate tool-call trajectories | 40,000 trajectory examples |
| **Phase 4** | Curate + format for training | Final 15,000 trajectories (12k train + 2k val + 1k test) |
