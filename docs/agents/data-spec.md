# Training Data Structure & Generation Specification

This document specifies the three core data generation dimensions that must be
produced for each training example to teach a 3B–14B model high-quality code
implementation via GRAM-style path exploration.

---

## Table of Contents

1. [Core Training Example Structure](#core-training-example-structure)
2. [Dimension 1: Context Exploration](#d-1-context-exploration)
3. [Dimension 2: Multiple Paths](#d-2-multiple-paths)
4. [Dimension 3: Composition](#d-3-composition)
5. [Generation Pipeline](#generation-pipeline)
6. [Implementation Notes](#implementation-notes)

---

## Core Training Example Structure

Every training example ultimately derives from a **real commit** in the CLEAR
codebase. The commit gives us:

- **Parent state** (P): The code before the change
- **Final state** (S): The code after the change
- **Diff** (Δ): What changed (ground truth)

From this single real commit, we generate a full training example with up to
**~50 context variants × ~20 paths × N chunks** — but each training file
only contains one context + one path + one chunk (the *tuple* the model sees).

### Single Tuple Structure

```json
{
  "id": "simp-043-chunk-1-ctx-ideal-path-ref",
  "source_commit": {
    "sha": "d14846a16c9...",
    "message": "Simplify escape ownership flow",
    "repo": "cheat", "branch": "origin/master"
  },
  "chunk": {
    "index": 1, "of": 3,
    "file": "src/mir/escape_analysis.rb",
    "lines": 45,
    "parent_sha": "e58b7cb59..."
  },
  "context": {
    "variant": "ideal",
    "lines": 85,
    "content": "... only the changed function + its direct type dependencies ..."
  },
  "prompt": "<code before change + context>",
  "target": {
    "reference": "<code after change - the ideal output>",
    "lines": 30
  },
  "path": {
    "label": "reference",
    "description": "The actual commit - correct implementation",
    "codeql_score": 78
  },
  "metadata": {
    "difficulty": "14B",
    "category": "simplification",
    "subcategory": "ownership_tightening"
  }
}
```

### Source-to-Examples Expansion

```
1 real commit
    ↓ (composition)
3 chunks (each a different function/module)
    ↓ (context exploration × paths)
3 chunks × 26 contexts × 21 paths = 1,638 training tuples
    ↓ (dedup & select best 50)
~50 training examples per real commit
```

---

## D.1: Context Exploration

For every **chunk** (a focused change to a specific function or module), we
generate 26+ context variants. Each variant is a different way of presenting
the surrounding code to the model.

### Layer Cake Model of Context

A chunk has layers of surrounding code that can be included or excluded:

```
Layer 0: The changed lines themselves (the target)
Layer 1: The containing function body
Layer 2: The function signature + types
Layer 3: Other functions in the same class/module
Layer 4: Constants, types, and helpers referenced by the function
Layer 5: Other files in the same directory
Layer 6: The entire project
```

Context variants select a subset of these layers.

### 10 Under-Context Variants (Not Enough)

These remove parts of the necessary context until the model cannot produce
the correct output. The goal is to teach the model to *recognize* when it
lacks context and request more.

```
All variants preserve the target area marker:  // <-- IMPLEMENT THIS

Variant  | Layer profile                          | Why it fails
---------|----------------------------------------|---------------------------
UC-1     | Function name only (empty body)        | No types, no parameters
UC-2     | Function signature only                | No body, no parameter meanings
UC-3     | Target lines only                      | No surrounding function context
UC-4     | Target + signature only                | No type definitions
UC-5     | Function body with types stripped      | All types → T.untyped
UC-6     | Function body with error paths removed | try/rescue → no error handling
UC-7     | Only the calling context               | Caller code, no callee defs
UC-8     | Only the diff summary                  | Just the commit message + line counts
UC-9     | Only the test for this function        | Test tells what but not how
UC-10    | Only the file's imports                | require statements, no body
```

**Generation algorithm:**

```python
def make_under_context(chunk, function_ast, dependency_graph):
    variants = []
    
    # UC-1: function name only
    variants.append(just_sig_with_empty_body(function_ast))
    
    # UC-2: signature only (no body)
    variants.append(just_signature(function_ast))
    
    # UC-3: just the changed lines (no containing function)
    variants.append(chunk.target_lines_only())
    
    # UC-4: target + signature (no types from imports)
    sig = function_ast.signature
    sig.strip_all_types()  # x: Int64 -> x, returns T.untyped
    variants.append(sig + chunk.target_lines())
    
    # UC-5: body with types stripped
    body = function_ast.body
    body.replace_types_with_untyped()
    variants.append(sig + body)
    
    # UC-6: body with error handling removed
    body = function_ast.body
    body.remove_rescue_blocks()
    body.remove_guard_clauses()
    variants.append(sig_full + body)
    
    # UC-7: only callers (not callees)
    callers = dependency_graph.callers_of(function_ast)
    variants.append(callers.source_code())
    
    # UC-8: just diff summary (no code)
    variants.append(f"Commit: {chunk.commit_message}\n"
                    f"Changed: {chunk.files}\n"
                    f"Δ: +{chunk.insertions}/-{chunk.deletions}")
    
    # UC-9: just the test
    variants.append(chunk.test_file.content())
    
    # UC-10: just imports from the file
    variants.append(chunk.file.imports_only())
    
    return variants
```

### 10 Over-Context Variants (Too Much)

These include so much irrelevant code that the model's limited context window
(2K tokens for 3B, 8K for 14B) is filled with noise. The goal is to teach
the model to *filter* and *ignore* irrelevant context.

```
Variant | Layer profile                          | Why it fails
--------|----------------------------------------|---------------------------
OC-1    | Entire source file (~3000 lines)       | Exceeds 3B context window
OC-2    | Entire directory (~10,000+ lines)      | Way too much
OC-3    | Entire file + all its spec files       | Test noise drowns signal
OC-4    | Entire file + git log for it           | 500+ commit messages
OC-5    | Entire file + transpiled Zig output    | Wrong language + full file
OC-6    | Entire file + all imports recursively  | Dependency explosion
OC-7    | Entire project's type annotations      | 1000+ sig declarations
OC-8    | Entire file + CodeQL report            | 500+ metric lines
OC-9    | Entire file with every function body   | No function boundaries
OC-10   | Random 200 lines from unrelated files  | Pure noise
```

**Generation algorithm:**

```python
def make_over_context(chunk, repo_path):
    variants = []
    file = chunk.file
    full_path = repo_path / file.filename
    
    # OC-1: entire source file
    variants.append(full_path.read_text())
    
    # OC-2: all .rb files in the same directory
    dir_files = list(full_path.parent.glob("*.rb"))
    variants.append("\n\n".join(f.read_text() for f in dir_files))
    
    # OC-3: file + all spec/test files for this module
    spec_dir = repo_path / "spec" / file.module_path
    spec_files = list(spec_dir.glob("*.rb"))
    variants.append(full_path.read_text() + "\n\n" +
                    "\n\n".join(f.read_text() for f in spec_files))
    
    # OC-4: file + git log for this file
    git_log = run(f"git log --oneline -- {file.filename}")
    variants.append(full_path.read_text() + "\n\n# History:\n" + git_log)
    
    # OC-5: file + transpiled output (Zig)
    zig_file = full_path.with_suffix(".zig")
    if zig_file.exists():
        variants.append(full_path.read_text() + "\n\n# Zig output:\n" + zig_file.read_text())
    
    # OC-6: file + all transitive requires
    deps_resolved = resolve_all_dependencies(file)
    dep_texts = [dep.read_text() if dep.exists() else "# missing" for dep in deps_resolved]
    variants.append(full_path.read_text() + "\n\n" + "\n\n".join(dep_texts))
    
    # OC-7: all sig declarations in the project
    all_sigs = extract_all_sigs(repo_path / "src")
    variants.append("\n".join(all_sigs))
    
    # OC-8: file + code quality report
    codeql = run(f"codeql analyze {full_path}")
    variants.append(full_path.read_text() + "\n\n# CodeQL:\n" + codeql)
    
    # OC-9: file with flattened functions (no def/end boundaries)
    content = full_path.read_text()
    flat = remove_all_function_boundaries(content)
    variants.append(flat)
    
    # OC-10: random snippets from unrelated files
    random_files = random_choose(list((repo_path / "examples").glob("*.rb")), 5)
    snippets = [extract_first_40_lines(f) for f in random_files]
    variants.append("\n\n".join(snippets))
    
    return variants
```

### 5–10 Close-to-Ideal Context Variants

These include most of what the model needs, but each misses one category of
information. The model should produce a *close* solution but miss some edge
cases. The gradient between "close" and "ideal" teaches what each piece of
context contributes.

```
Variant | Included (from dependency graph)      | Missing
--------|----------------------------------------|--------------------------
CC-1    | Function body + callee definitions     | Type definitions
CC-2    | Function body + type definitions        | Callee definitions
CC-3    | Function body + caller code             | Callee + type defs
CC-4    | Function body + constants used          | Function logic details
CC-5    | Function body + error handling paths    | Main logic path
CC-6    | Function body + 3 most-used types       | Less common types
CC-7    | Full class (all methods)                | Which method is the target
CC-8    | Function body + all type sigs in file   | Implementation details
```

**Generation algorithm:**

```python
def make_close_contexts(chunk, dep_graph):
    body = chunk.function_ast.body_text()
    sig = chunk.function_ast.signature_text()
    
    return [
        f"{sig}\n{body}\n\n# Types used:\n{dep_graph.format_types()}",
        f"{sig}\n{body}\n\n# Callees:\n{dep_graph.format_callees()}",
        f"{sig}\n{body}\n\n# Callers:\n{dep_graph.format_callers()}",
        f"{sig}\n{body}\n\n# Constants:\n{dep_graph.format_constants()}",
        f"{sig}\n{body}\n\n# Error paths:\n{dep_graph.format_error_paths()}",
        f"{sig}\n{body}\n\n# Top 3 types:\n{dep_graph.format_top_n_types(3)}",
        chunk.file.full_class_text(),
        f"# All sigs in {chunk.file.filename}:\n{all_sigs_in_file()}",
    ]
```

### 1 Ideal Context Variant

Just the changed function(s) with their direct type dependencies and relevant
constants. Nothing more. The model has everything it needs and nothing it
doesn't.

```python
def make_ideal_context(chunk, dep_graph):
    body = chunk.function_ast.body_text()
    sig = chunk.function_ast.signature_text()
    
    # Only the types that are actually used in this function
    used_types = dep_graph.types_referenced_by(chunk.function_ast)
    type_defs = "\n\n".join(f"# {t.name}:\n{t.short_definition()}" for t in used_types)
    
    # Only the constants that are actually used
    used_consts = dep_graph.constants_referenced_by(chunk.function_ast)
    const_defs = "\n".join(f"{c.name} = {c.value}" for c in used_consts)
    
    # Only the function signatures of callees (not their bodies)
    callee_sigs = dep_graph.callees_of(chunk.function_ast)
    callee_text = "\n".join(c.sig_line() for c in callee_sigs)
    
    return f"{sig}\n{body}\n\n# Types:\n{type_defs}\n\n# Constants:\n{const_defs}\n\n# Callee signatures:\n{callee_text}"
```

### Context Scoring

Each context variant is scored by:
1. **CodeQL score** of the resulting implementation when the model is given this context
2. **Token efficiency**: `ideal_codeql / actual_tokens_used`
3. **Signal ratio**: `lines_of_relevant_context / total_context_lines`

The model learns to predict which context variant will yield the best score.

---

## D.2: Multiple Paths — 5-Variant Approach

For every **ideal historical commit** (y_clean), we generate exactly 5 variants.
The model sees each variant and must learn to rank them by quality.

| Variant | Label | Count | Source | Description |
|---------|-------|-------|--------|-------------|
| **y_clean** | `ideal` | 1 | The actual squashed commit on master | Ground truth. Exactly what the author committed. Perfect CodeQL score. |
| **y_sloppy** | `sloppy_1..3` | 3 | Pre-squash intermediate commits from backup branches | Real intermediate states that worked but were suboptimal. Each is an actual commit the author made before reaching the ideal. |
| **y_broken** | `broken` | 1 | Systematic mutation of y_clean | The code looks plausible but has a specific bug: wrong condition, missing guard, swapped operand, etc. Does not compile, fails tests, or crashes. |
| **y_blind** | `blind` | 1 | y_clean implemented with wrong surrounding context | The code change is correct but the context it received was from a different module or function. The implementation doesn't match what the surrounding code expects. |

### Why 5, not 21

The 21-variant approach (10 buggy + 10 partial + 1 ideal) was over-engineered.
It required 20 different mutation algorithms, many of which would produce
unrealistic or easily-detectable errors. The 5-variant approach is:

1. **Grounded in real data** — y_sloppy variants ARE real commits from pre-squash
   history. They're not synthetic — they actually existed in the codebase.
2. **Teaches all three failure modes** — sloppy (works but worse), broken (doesn't
   work), blind (wrong context). These are the three ways real developers fail.
3. **Easier to implement** — y_sloppy falls out naturally from our backup branches.
   y_broken needs one mutation algorithm. y_blind needs a context swap.
4. **More signal per example** — each variant is distinct and meaningful.

### Source: y_sloppy from Pre-Squash History

For squashed commits with pre-squash backup branches:

```
Squashed commit on master: "feat: full BC backend"  (y_clean)
  │
  ├─ Pre-squash commit #17: "fix arithmetic overflow"  ──→ y_sloppy_1
  ├─ Pre-squash commit #23: "implement set operations"  ──→ y_sloppy_2
  └─ Pre-squash commit #31: "wire pipeline ops"         ──→ y_sloppy_3
```

Each pre-squash commit is chosen to be:
- **Different from y_clean** — not trivially close
- **Functionally working** — the code parsed and passed tests at the time
- **Demonstrably worse** — lower CodeQL score than y_clean

Selection strategy from a pre-squash sequence C₁, C₂, ..., Cₙ:

```python
def select_sloppy_paths(pre_squash_commits, ideal_commit):
    """
    Pick 3 sloppy paths from a pre-squash sequence.
    Prefers: (a) early commits (least complete),
             (b) middle commits with most different approach,
             (c) a commit that took a wrong turn (fix commit).
    """
    scores = []
    for commit in pre_squash_commits:
        codeql = score_codeql(commit)
        diff_from_ideal = diff_lines(commit, ideal_commit)
        scores.append((commit, codeql, diff_from_ideal))
    
    # Pick early commit (least complete)
    early = min(scores, key=lambda s: s[1])  # lowest CodeQL
    
    # Pick middle commit with most different approach
    middle = max(scores, key=lambda s: s[2])  # most different from ideal
    
    # Pick a fix/refactor commit
    fix = next((c for c in pre_squash_commits if "fix" in c.message.lower()), scores[-1])
    
    return [early, middle, fix]
```

For commits without pre-squash history, generate y_sloppy by:
1. Strip type annotations → still works, but Sorbet would complain
2. Remove one guard clause → still works for happy path, crash on edge case
3. Simplify error handling → works for success, swallows errors

### Source: y_broken from Mutation

y_broken must be **realistic** (a developer might write it) but **detectably wrong**
(CodeQL or Sorbet would flag it). Not random garbage.

#### Brokenness Levels

| Level | Type | Detectable by | Training value | Example |
|-------|------|---------------|----------------|---------|
| 1 | **Parse error** | `ruby -c` | Low — too easy | Missing `end`, `if x = y` instead of `==` |
| 2 | **Logic error in changed lines** | CodeQL / test failure | **High** | Wrong condition, off-by-one, **forgot a critical line** |
| 3 | **Logic error in unchanged lines** | Diff review / CodeQL | **High** | Model changed code/touched state it shouldn't have |
| 4 | **Control flow error** | CodeQL / test failure | **High** | Unnecessary branch, dead code path, wrong error handling |

**Note on Sorbet/type errors:** The CLEAR codebase uses Sorbet (`sig { ... }`),
but most Ruby code in the wild does not. We minimize type/sig mutations
because they'd teach the model to expect Sorbet checks that don't exist in
typical Ruby projects. Type errors are limited to cases where the code itself
has a clear type mismatch (e.g., passing a String to a method that expects
Integer) — not Sorbet sig annotation errors.

#### Generation Strategy

For each y_broken, pick by this distribution:

```python
def make_y_broken(y_clean, changed_lines, unchanged_lines):
    roll = random()
    
    if roll < 0.50:   # 50% — mutant in a CHANGED line (model got the right place wrong)
        return mutate_changed_line(y_clean, changed_lines)
    
    elif roll < 0.80: # 30% — mutant in an UNCHANGED nearby line (model touched what it shouldnt)
        return mutate_unchanged_line(y_clean, unchanged_lines)
    
    else:              # 20% — control flow error (unnecessary branch, dead path, wrong error)
        return mutate_control_flow(y_clean)
```

#### Mutant Catalog (Level 2 — changed lines)

```
select ONE mutation from:
  - Negate condition:          if a > b   → if a <= b
  - Off-by-one:                arr[i]     → arr[i + 1]
  - Wrong operator:            a + b      → a - b
  - Wrong boolean operator:    a && b     → a || b
  - Wrong comparison:          a > b      → a < b
  - Missing null guard:        delete `return if x.nil?`
  - Wrong variable:            result     → temp_result
  - Wrong constant:            MAX_SIZE   → DEFAULT_SIZE
  - Missing deinit:            delete `file.close`
  - Wrong error:               raise Err  → raise RuntimeError
  - Swallowed error:           wrap in `begin; ...; rescue; end`
  - Off-by-one in range:       (0..n)     → (0...n)
  - FORGOT A LINE:             delete one critical line from the change
                                (e.g., updating state A but not state B)
```

**Forgotten line mutation** is especially valuable. It simulates the most
common real bug: the developer made 2 of 3 required changes but forgot the
last one. Example:

```
# y_clean has:
  @cache[key] = value
  @size += 1
  @dirty = true

# y_broken forgot:
  @cache[key] = value
  @size += 1
  # @dirty = true  ← deleted — state tracking is now inconsistent
```

This teaches the model to check: "Did I make ALL the changes this function
needs, or did I forget one?"

#### Mutant Catalog (Level 3 — unchanged nearby lines)

These are more interesting for training because they teach the model
**boundary awareness** — don't touch what you weren't asked to:

```
select ONE mutation from:
  - Delete a guard clause that was already correct
  - Change a default parameter value:  def foo(x = 10) → def foo(x = 20)
  - Add a spurious log statement:      logger.debug("entered foo")
  - Add a redundant assignment:        x = x
  - Remove a comment that explains the logic
  - Add an unnecessary `nil?` check on something already guarded
  - Change an unrelated error message
  - Add a debug `puts` statement
  - UNNECESSARY STATE MUTATION: change an instance variable that should stay constant
                                  @counter += 1   (in a read-only method)
  - UNNECESSARY STATE MUTATION: write to a variable that nothing reads
                                  result = compute()  (but result is never used)
  - UNNECESSARY STATE MUTATION: mutate a frozen/constant value
                                  MAX_RETRIES = 5  →  MAX_RETRIES = 10
  - UNNECESSARY STATE MUTATION: modify a method parameter
                                  def foo(x) → x = x + 1; ... (side-effecting param)
```

**State mutation errors** simulate a model that doesn't understand which
variables are read-only vs mutable — a very common ML coding mistake.

#### Mutant Catalog (Level 4 — control flow errors)

```
select ONE mutation from:
  - Change `raise` → `return`           (error becomes silent failure)
  - Change `return` → `raise`           (success becomes error)
  - Wrap everything in `begin; ...; rescue; end`  (swallows all errors)
  - Remove the return value:  `return result` → `return nil`
  - Change side effect from update to delete
  - Call a different method with the same arity
  - ADD UNNECESSARY BRANCH: wrap body in `if true; ...; end`  (dead branch)
  - ADD UNNECESSARY BRANCH: add `else` clause that does nothing
  - ADD UNNECESSARY LOOP:   wrap body in `times do; ...; end`  (repeats N times)
  - ADD DEAD CODE PATH:     add `return nil if false` at the top
  - ADD DEAD CODE PATH:     add unreachable `else` branch
  - WRONG ERROR:            use a different error type (RuntimeError vs ArgumentError)
  - WRONG ERROR:            add `raise` where none was needed
  - DOUBLE OPERATION:       perform the same operation twice (e.g., two `push` calls)
```

Unnecessary control flow mutations teach the model to recognize when code
is doing work that doesn't affect the outcome — a subtle but common
real-world code quality issue.

#### Validation

After mutation, verify:
1. **The mutation is on a changed or nearby-unnecessary line** (not 50 lines away)
2. **The mutation is a single atomic change** (not a frankenstein of multiple bugs)
3. **The code still looks like Ruby** (no random character insertion)
4. **The mutation is NOT a trivial typo** (not "hte" instead of "the")

### Source: y_blind from Context Mismatch

y_blind takes the correct code implementation (same as y_clean) but pairs
it with the wrong surrounding context:

```
y_blind = y_clean's output + wrong_context

Wrong context is generated by:
  1. Pick a DIFFERENT function from the same file with a similar signature
  2. OR pick a function from a completely different file
  3. OR strip the imports/requires that the target function depends on
  4. OR include the test file instead of the implementation file

The model sees:
  Prompt: "Implement this function" + wrong_context
  Reference: y_clean's output
  The code is correct but DOES NOT FIT the given context
```

This teaches the model to check: "Does my implementation actually match the
surrounding code, or am I writing something that doesn't belong here?"

### Training Signal

For each of the 5 variants, record:

```json
{
  "y_clean":  { "codeql_score": 85, "parse": true, "type_check": true },
  "y_sloppy_1": { "codeql_score": 55, "parse": true, "type_check": true },
  "y_sloppy_2": { "codeql_score": 48, "parse": true, "type_check": true },
  "y_sloppy_3": { "codeql_score": 62, "parse": true, "type_check": true },
  "y_broken":  { "codeql_score": 15, "parse": false, "type_check": false },
  "y_blind":   { "codeql_score": 30, "parse": true, "type_check": false }
}
```

The model learns to rank: y_clean > y_sloppy > y_blind > y_broken

### Chunk → Training Example Pipeline (Updated)

```
Chunk (1 decomposed task with ideal state)
    │
    ├── generate_paths()
    │   └── 5 path variants (y_clean + 3×y_sloppy + y_broken + y_blind)
    │       └── each variant is a different "what the model outputs"
    │
    └── For each path variant:
        └── context_exploration()
            └── 10+ context variants (under/over/close/ideal)
                └── (context_variant, path_variant) = 1 training tuple
    
    For 1 chunk: 5 paths × 10 contexts = 50 training tuples
    For 1,626 chunks: ~81,300 training tuples
```
```

### Path Scoring

Each path is scored on:
1. **CodeQL score** (primary — higher is better)
2. **Parse check** (does the code parse? yes/no)
3. **Type check** (does Sorbet accept it? yes/no)
4. **Test pass rate** (if tests exist for this function)
5. **Diff from reference** (levenshtein distance — lower is closer)

The model sees all paths' scores after generating and learns to prefer
high-scoring paths.

---

## D.3: GRAM — Two-Component Strategy

GRAM has two distinct applications that should be tested independently:

### Component 1: Context Discovery via Tool Calling

The model calls tools to discover what context it needs. This solves the
context selection problem (D.1) actively instead of passively.

**Tool actions:**
```
find_type("EscapeGraph")          → definition + fields + methods
find_methods("EscapeGraph")       → method signatures only
find_usages("hoist_body!")        → all call sites of a function
find_imports("escape_analysis")   → requires/references
find_deps("hoist_body!")          → types + functions this function depends on
```

**Training trajectory:**
```
Prompt: "Implement hoist_body! in src/mir/hoist.rb"
  Step 1: find_type("Hoist")           → returns class definition
  Step 2: find_deps("hoist_body!")     → returns { types: [EscapeGraph, Type], ... }
  Step 3: find_methods("EscapeGraph")  → returns { methods: [apply!, ...] }
  Step 4: FIND ENOUGH CONTEXT          → model recognizes: "I have what I need"
  Step 5: implement hoist_body!        → generates correct code
```

**Reward signal:**
- Correct tool choice → correct context → correct code  (y_clean)
- Too many tools → correct but slow context gathering     (y_sloppy)
- Wrong tool → wrong context → wrong code                (y_broken)
- No tool call → no context → wrong code                  (y_blind)

Only the tool calls that produce NEW, USEFUL context are rewarded.
Repeated calls (asking for the same type twice) are penalized.

### Component 2: Sloppiness Avoidance via Path Exploration

The model generates multiple implementation attempts, evaluates them with
decomplex, and picks the least sloppy:

```
Prompt: "Implement hoist_body!"
  Path A: hoist_body! with T.untyped returns  →  decomplex score: 45  (sloppy)
  Path B: hoist_body! with 3 derived states  →  decomplex score: 30  (sloppier)  
  Path C: hoist_body! with clean code        →  decomplex score: 85  (clean)
  → Model learns to prefer Path C
```

**Training data**: The pre-squash backup branches ARE this. Each commit on a
backup branch is a different path toward the same goal, with known sloppiness
differences (earlier commits are sloppier).

### How the Two Components Combine

```
                    +------------------+
                    |  Initial Prompt  |
                    +--------+---------+
                             |
                    +--------v---------+
                    | Component 1:     |
                    | Context Discovery|
                    | (tool calls)     |
                    +--------+---------+
                             |
                    +--------v---------+
                    | Have context?    |──No──→ (loop)
                    +--------+---------+
                             | Yes
                    +--------v---------+
                    | Component 2:     |
                    | Path Exploration |
                    | (try, score,     |
                    |  iterate)        |
                    +--------+---------+
                             |
                    +--------v---------+
                    | Score good       |
                    | enough?          |──No──→ (loop)
                    +--------+---------+
                             | Yes
                    +--------v---------+
                    | Submit Final     |
                    +------------------+
```

Each component is trained separately, then combined during inference.
Component 1 action space: ~10 distinct tool calls (~50 tokens each).
Component 2 action space: implementation generation (~200 tokens).
Total: well within 3B context budget.

### Training Data for Tool Calling

Each training example is a trajectory of tool calls:

```json
{
  "id": "tool-traj-043",
  "task": "Implement hoist_body!",
  "function": "Hoist.hoist_body!",
  "file": "src/mir/hoist.rb",
  "ideal_context": {
    "types": ["EscapeGraph", "SymbolEntry"],
    "methods": ["apply!", "hoist!"],
    "lines": 45
  },
  "trajectories": [
    {
      "label": "y_clean",
      "description": "Called exactly the right tools",
      "steps": [
        {"tool": "find_type", "args": {"name": "EscapeGraph"}, "result": "{...}"},
        {"tool": "find_deps", "args": {"fn": "hoist_body!"}, "result": "{\"types\": [\"EscapeGraph\", \"SymbolEntry\"]}"},
        {"action": "decide", "decision": "enough_context"},
        {"action": "implement", "code": "...correct implementation..."}
      ],
      "decomplex_score": 85
    },
    {
      "label": "y_sloppy",
      "description": "Called too many tools (wasted calls)",
      "steps": [
        {"tool": "find_type", "args": {"name": "EscapeGraph"}, "result": "{...}"},
        {"tool": "find_type", "args": {"name": "EscapeGraph"}, "result": "{...}"},
        {"tool": "find_methods", "args": {"name": "EscapeGraph"}, "result": "{...}"},
        {"tool": "find_usages", "args": {"fn": "apply!"}, "result": "{...}"},
        {"action": "decide", "decision": "enough_context"},
        {"action": "implement", "code": "...correct but slow..."}
      ],
      "decomplex_score": 75
    },
    {
      "label": "y_broken",
      "description": "Called wrong tool, missed critical context",
      "steps": [
        {"tool": "find_type", "args": {"name": "WrongType"}, "result": "not_found"},
        {"action": "decide", "decision": "enough_context"},
        {"action": "implement", "code": "...missing type info, crashes..."}
      ],
      "decomplex_score": 20
    }
  ]
}
```

For each trajectory:
- The tool call response is the ACTUAL definition from the codebase
- The model sees the prompt + current context → decides what tool to call
- Training signal: did the tool call produce useful context?
- Final signal: decomplex score of the generated code

### How Many Tool Trajectories to Generate

From our 539 tasks with pre-squash history:
- 231 have backup commits → can generate tool-calling trajectories from the
  context differences between pre-squash and squashed versions
- 308 have ≥5 function versions → can mine context-discovery patterns

Each task produces ~3 trajectories (y_clean, y_sloppy, y_broken).
Total: ~1,600 tool-calling trajectories for Component 1 training.
Plus ~1,600 path-exploration trajectories for Component 2 training.

---

Many commits change 5–10K+ lines across 30+ files. A 3B model cannot handle
this in one pass. We break each large change into **composed chunks**, where
each chunk is a self-contained task with its own context exploration and path
exploration.

## D.4: Multi-Language Training

To prevent overfitting to Ruby syntax and coding patterns, we include training
examples from 7 additional languages. These come from two sources:

### Source A: Commits with git history (Ruby, Go, Rust, C, .cht)

These have pre-squash/backup history that can be decomposed into multiple paths:

| Language | Files | Clean commits | Decomposed tasks | % of total | Source |
|----------|-------|---------------|-----------------|------------|--------|
| **Ruby** | 110+ src/ | 735 classified + 891 decomposed | **1,626** | 93.5% | src/, gems/, examples/minivm/ |
| **Rust** | 29 | 113 → 35 best | ~100 | 2.0% | benchmarks/*/rust/ |
| **Go** | 24 | 22 → 17 best | ~50 | 1.0% | benchmarks/*/go/ |
| **C** | 17 | 46 → 35 best | ~70 | 2.0% | benchmarks/*/c/ |
| **.cht** | ~90 | 17 best (from benchmarks/) | ~35 | 1.0% | benchmarks/, examples/ (puck, footguns, etc.) |

Go, Rust, and C files are 50–300 lines with 1–10 functions each — meaningfully
decomposable at the function level. We add a language-specific function finder
to the decomposer (regex-based for Go `func`, Rust `fn`, C function headers).

### Source B: Individual files as "single-shot" examples (Python, Lua, JS, .cht)

These have no meaningful commit history (0–4 commits each), but the files
themselves can be used as training targets. We treat the file as y_clean and
generate y_sloppy/y_broken/y_blind variants programmatically:

| Language | Files | Training examples | % of total | Source |
|----------|-------|-------------------|------------|--------|
| **Python** | 20 | 20 (y_clean only, no paths) | 0.5% | benchmarks/vm/*.py |
| **Lua** | 21 | 21 (y_clean only, no paths) | 0.5% | benchmarks/vm/*.lua |
| **JavaScript** | 4 | 4 (y_clean only, no paths) | 0.1% | benchmarks/vm/*.js |
| **.cht** (extra) | ~40 | 40 (y_clean only, no paths) | 1.0% | examples/*.cht (footguns, mal, testing) |

These files are small (6–48 lines for Python/Lua/JS, 30–300 lines for .cht).
For each file, we fabricate y_sloppy variants by:
- Stripping type-like annotations
- Simplifying error handling
- Removing one edge case
- Introducing a subtle logic error (y_broken)

### Source C: examples/puck/ — Versioned Ruby Compiler

examples/puck/ contains 6 versions (v1, v3, v5, v6, v8, v10) of a Ruby → CLEAR
compiler. Each version is a complete, working compiler. The progression shows
real software evolution:

| Version | Files | Ruby lines | C lines | Compiler structure |
|---------|-------|------------|---------|-------------------|
| v1 | puck.rb | 148 | 0 | Monolithic single file |
| v3 | compiler.rb, parser.rb, vm.rb, tokenizer.rb | 398 | 0 | Split into modules |
| v5 | same structure | 466 | 0 | Tokenizer → Parser → Compiler → VM |
| v6 | same structure | 486 | 0 | Better module structure |
| v8 | + macro_expander.rb | 965 | 0 | Macro expansion added |
| v10 | compile.rb + vm.c | 88 | 637 | Backend rewritten in C |

**Training value**: Each version pair (vN → vN+2) is a natural y_clean → y_sloppy
pair. The earlier version IS the sloppy path. Use the diff between versions
as the decomposition.

**Examples from puck**:
- 5 version transitions × 3-4 files each = ~18 decomposed tasks
- Each task: "Transform tokenizer from v3 to v5 style"
- Context: the v3 tokenizer → Reference: the v5 tokenizer

### Total Training Corpus

| Source | Language | Tasks | R/P sloppy? | Training | Validation | % of total |
|--------|----------|-------|-------------|----------|------------|------------|
| Classified commits (decomposed) | Ruby | 735 | 14% real history | 625 | 110 | 32% |
| Too-large commits (decomposed) | Ruby | 540 | 50% real history | 459 | 81 | 23% |
| vm-fix-rewrite backup | Ruby | 123 | 100% real history | 123 | — | 5% |
| backup-pre-squash | Ruby | 416 | 100% real history | 416 | — | 18% |
| **Ruby subtotal** | | **1,814** | **30% real sloppy** | **1,623** | **191** | **78%** |
| Zig (runtime + lib) | Zig | ~150 | Real (backup branch) | ~143 | ~7 | 6% |
| Rust (benchmarks) | Rust | ~100 | Programmatic | ~95 | ~5 | 4% |
| C (benchmarks) | C | ~70 | Programmatic | ~67 | ~3 | 3% |
| Go (benchmarks) | Go | ~50 | Programmatic | ~48 | ~2 | 2% |
| .cht (benchmarks + examples) | CLEAR | ~75 | Mixed | ~71 | ~4 | 3% |
| Python (vm benchmarks) | Python | ~20 | Single-shot | ~19 | ~1 | 1% |
| Lua (vm benchmarks) | Lua | ~21 | Single-shot | ~20 | ~1 | 1% |
| JavaScript (vm benchmarks) | JS | ~4 | Single-shot | ~4 | — | <1% |
| examples/puck/ (version diffs) | Ruby/C | ~18 | Real (version pairs) | ~17 | ~1 | 1% |
| **Other subtotal** | | **~508** | | **~484** | **~24** | **22%** |
| **Grand total** | | **~2,322** | | **~2,107** | **~215** | **100%** |

**Validation strategy:**
- Ruby: hold back ~10% (191 tasks from the best-sourced commits)
- Other languages: hold back ~5% (24 tasks across 9 languages)
- Total validation: ~215 tasks (~9% of corpus)

**Test set:** The ~500 unique litedb commits form the hidden test set
(completely separate project, model never sees it during training).

**Training tuples (5 paths × 10 contexts per task):**
```
Training:   2,107 tasks × 50 tuples = 105,350 training tuples
Validation:   215 tasks × 50 tuples =  10,750 validation tuples
Test:         ~500 litedb commits (hidden)
```

### Chunking Strategy

```
A commit that:
  - Adds a new module (5 files, ~2000 lines total)
  - Modifies 3 existing modules (10 files, ~1000 lines)
  - Updates tests (5 files, ~500 lines)
  - Updates configuration (2 files, ~50 lines)

Gets decomposed into:

High-level module: New Feature X
├── Task A: Define data types (1 file, ~200 lines)
│   ├── Context exploration (26 variants)
│   └── Path exploration (21 variants)
├── Task B: Implement core logic (1 file, ~300 lines)
│   ├── Context exploration (26 variants)
│   └── Path exploration (21 variants)
├── Task C: Wire into existing module Z (2 files, ~150 lines)
│   ├── Context exploration (26 variants)
│   └── Path exploration (21 variants)
├── Task D: Add module Y integration (1 file, ~100 lines)
│   ├── Context exploration (26 variants)
│   └── Path exploration (21 variants)
├── Task E: Update existing module's type stubs (3 files, ~80 lines)
│   ├── Context exploration (26 variants)
│   └── Path exploration (21 variants)
├── Task F: Write tests for edge cases (3 files, ~200 lines)
│   ├── Context exploration (26 variants)
│   └── Path exploration (21 variants)
└── Task G: Update config defaults (2 files, ~50 lines)
    ├── Context exploration (26 variants)
    └── Path exploration (21 variants)
```

### Task Composition Cutoffs

These are the **hard limits** for how tasks should be composed from large commits.
Validated against the Qwen2.5-Coder-3B tokenizer on real Ruby code:

```
Tokenizer benchmark (real code):
  Simple code (few types):            ~7 tok/line
  Dense code (heavy Sorbet sigs):      ~16 tok/line
  Conservative average:                ~10 tok/line

16k tokens ≈ 1,600 lines of context (avg code)
32k tokens ≈ 3,200 lines (absolute max)
4 functions (avg 20 lines each) ≈ 760 tokens output
100 changed lines ≈ 950 tokens output
```

| Limit | 3B Target | 14B Target | 30B Target | Rationale |
|-------|-----------|------------|------------|-----------|
| **Max context** | 32k tokens | 64k tokens | 128k tokens | Hardware limit (Qwen2.5-Coder-3B = 32,768). 14B/30B models have larger windows. |
| **Ideal context** | 16k tokens | 32k tokens | 64k tokens | 50% of max — leaves room for prompt instructions + generated output. |
| **Max output functions** | 4 | 8 | 15 | A 3B model can reliably generate ~4 functions at once. Beyond that, quality degrades. |
| **Max output changed lines** | 100 | 250 | 500 | At 10 tok/line, 100 lines = 1,000 tokens (6% of 16k budget). Generous but safe. |
| **Max output tokens** | 4k (25%) | 8k (12.5%) | 16k (12.5%) | Output must not consume more than this fraction of the total budget. |

**Files are irrelevant for chunking.** GRAM's context grabbing must be smart
enough to navigate across files as easily as within a file. Chunks are defined
by **function boundaries**, not file boundaries. A single chunk may span
multiple files if the change spans multiple functions in different files.

#### Cutoff validation

```python
def satisfies_cutoffs(task, tier="3B"):
    """Check if a task fits within the model tier's limits."""
    cutoffs = {
        "3B":  {"ideal_ctx": 16000, "max_ctx": 32000,
                 "max_fns": 4, "max_lines": 100, "max_out": 4096},
        "14B": {"ideal_ctx": 32000, "max_ctx": 64000,
                 "max_fns": 8, "max_lines": 250, "max_out": 8192},
        "30B": {"ideal_ctx": 64000, "max_ctx": 128000,
                 "max_fns": 15, "max_lines": 500, "max_out": 16384},
    }
    c = cutoffs[tier]
    
    if task.ideal_context_tokens() > c["ideal_ctx"]:
        return False  # Too much context needed — split
    if task.max_context_tokens() > c["max_ctx"]:
        return False  # Exceeds hard limit — split
    
    out_fns = task.count_output_functions()
    out_lines = task.count_output_lines()
    out_tok = task.estimate_output_tokens()
    
    if out_fns > c["max_fns"] or out_lines > c["max_lines"] or out_tok > c["max_out"]:
        return False
    return True


def split_until_satisfied(task, tier="3B"):
    """Recursively split until all subtasks fit their tier."""
    if satisfies_cutoffs(task, tier):
        return [task]
    
    # Prefer function-level split (cleanest semantic boundary)
    if task.count_output_functions() > 1:
        return [split_until_satisfied(sub, tier)
                for sub in task.split_by_function()]
    
    # Single function still too large — split by control flow
    # (happy path vs error path, or first half vs second half)
    return [split_until_satisfied(sub, tier)
            for sub in task.split_by_control_flow()]
```

### Chunking Algorithm

Chunks are defined by **function boundaries**, not file boundaries.
A single chunk may span multiple files if those functions are interdependent.

```python
def compose(commit, tier="3B"):
    """
    Break a large commit into independently trainable chunks.
    Each chunk produces its own set of context variants + paths.
    """
    cutoffs = {
        "3B":  {"ideal_ctx": 16000, "max_fns": 4,  "max_lines": 100},
        "14B": {"ideal_ctx": 32000, "max_fns": 8,  "max_lines": 250},
        "30B": {"ideal_ctx": 64000, "max_fns": 15, "max_lines": 500},
    }[tier]
    
    # Phase 1: Extract all function-level changes from the diff
    diff = commit.diff()
    function_changes = extract_all_function_changes(diff)
    # Returns list of {file, fn_name, before_code, after_code, deps}
    
    # Phase 2: Build cross-file function dependency graph
    dep_graph = {}
    for fc in function_changes:
        dep_graph[fc.fn_id] = resolve_dependencies(fc.after_code)
    
    ordered_ids = topological_sort(dep_graph)
    
    # Phase 3: Greedy pack into tasks respecting cutoffs
    tasks = []
    current = empty_task()
    
    for fid in ordered_ids:
        fc = function_changes[fid]
        
        est_ctx = estimate_tokens(current.context + fc.after_code)
        est_fns = current.fn_count + 1
        est_lines = current.line_count + fc.after_lines()
        
        if (est_ctx <= cutoffs["ideal_ctx"] and
            est_fns <= cutoffs["max_fns"] and
            est_lines <= cutoffs["max_lines"]):
            current.add_function(fc)
        else:
            tasks.append(current)
            current = empty_task()
            current.add_function(fc)
    
    if current.fn_count > 0:
        tasks.append(current)
    
    # Phase 4: Split any task that still exceeds cutoffs
    return [split_until_satisfied(t, tier) for t in tasks]
```

### Chunk → Training Example Pipeline

Each chunk flows through the full generation pipeline:

```
Chunk (file:func change)
    │
    ├── context_exploration()
    │   └── 26 context variants (10 under + 10 over + 5 close + 1 ideal)
    │       └── each variant is a different "prompt prefix"
    │
    ├── path_exploration(reference_output)
    │   └── 5 path variants (1 ideal + 3 sloppy + 1 broken + 1 blind)
    │       └── each variant is a different "expected output"
    │
    └── combine()
        └── 10 × 5 = 50 (context,path) tuples per chunk
            └── each tuple is a training example
    
    For 1 chunk: 50 tuples
    For 1,626 chunks: 81,300 tuples
```

### Dependency Tracking Between Chunks

When tasks in the same commit are sequential (task B depends on task A):

```json
{
  "task": "B",
  "depends_on": ["A"],
  "prompt_context": {
    "file_state_before_task_A": "...",
    "file_state_after_task_A": "...",
    "problem_statement": "Now implement task B..."
  },
  "reference": "..."
}
```

This teaches the model to build on previous work — a skill essential for
multi-step implementation.

---

## Generation Pipeline

### Overall Architecture

```python
def generate_training_data(commit_shas, repos):
    """Main entry point: from commit SHAs to training JSON files."""
    all_examples = []
    
    for sha in commit_shas:
        for repo in repos:
            commit = load_commit(repo, sha)
            if not commit: continue
            
            # 1. COMPOSITION — break into tasks
            tasks = compose(commit, max_chunk_lines=200)
            
            for task in tasks:
                # Get before/after code for this task
                before_code = task.before_state()
                after_code = task.after_state()
                
                # 2. CONTEXT EXPLORATION — generate 26 context variants
                dep_graph = build_dependency_graph(task, before_code)
                contexts = generate_all_contexts(task, dep_graph)
                
                # 3. PATH EXPLORATION — generate 21 path variants
                paths = generate_all_paths(task, after_code)
                
                # 4. COMBINE into training tuples
                for ctx_key, ctx_content in contexts:
                    for path_key, path_code in paths:
                        example = {
                            "id": f"{sha[:8]}-{task.id}-{ctx_key}-{path_key}",
                            "prompt": ctx_content + "\n" + task.problem_statement(),
                            "target": path_code,
                            "context_variant": ctx_key,
                            "path_variant": path_key,
                            "codeql_score": score_code(path_code),
                            "metadata": {
                                "commit": sha,
                                "task": task.id,
                                "difficulty": task.difficulty
                            }
                        }
                        all_examples.append(example)
    
    return select_best_examples(all_examples, target_count=1300)
```

### Selection Criteria

Not all 546 tuples per chunk are equally valuable. We select the best:

```
Priority 1: ideal_context + ideal_path (the ground truth)
Priority 2: ideal_context + close_paths (teaches incremental improvement)
Priority 3: close_context + ideal_path (teaches context recognition)
Priority 4: under_context + all_paths (teaches context insufficiency detection)
Priority 5: over_context + buggy_paths (teaches noise filtering)
```

Each training epoch, we sample from all priorities with decreasing probability.

### Validation

For each training example, verify:
1. **The prompt parses** — `ruby -c` on the combined context + code
2. **The reference parses** — `ruby -c` on the target code
3. **Buggy paths don't parse** (or parse but fail tests) — they must be *demonstrably* worse
4. **Context variants are different** — no two context variants are identical
5. **Context size fits model** — under context budget for target model tier

---

## Implementation Notes

### Tool Dependencies

| Tool | Purpose |
|------|---------|
| `git` | Extract file versions at specific commits |
| Prism (Ruby parser) | Identify function/class/module boundaries |
| `ruby -c` | Validate syntax |
| Sorbet (`srb tc`) | Validate type annotations |
| CodeQL (or slopcop) | Score code quality |
| None of these need to be ready for v0 of the generator — start with git + Prism |

### v0 Scope (What to Build First)

For the initial generator, start simple:

1. **Only use Type A squashes** (backup branches with pre-squash history)
2. **Only compose at file level** (no function-level sub-chunking yet)
3. **Only generate 5 context variants per chunk** (1 under + 1 over + 2 close + 1 ideal)
4. **Only generate 5 path variants per chunk** (2 buggy + 2 partial + 1 ideal)
5. **Skip CodeQL scoring** — use a simple heuristic (lines of code, number of guard clauses, type coverage)

This gives ~25 tuples per chunk × ~5 chunks per commit × ~200 commits = ~25,000 examples.

### Ruby-Specific Notes

- **Function detection**: Use Prism or the `parser` gem to identify `def...end` blocks
- **Type detection**: Look for T.untyped, T.nilable, sig blocks (Sorbet syntax)
- **Import detection**: Look for `require`, `require_relative`, `require_relative` calls
- **Class/module detection**: Look for `class...end` and `module...end` blocks
- **Comment preservation**: Keep comments in context (they're useful signal) but strip from targets

### File Format

All training data is JSON Lines (`.jsonl`) — one JSON object per line.
This enables streaming reads during training without loading the full dataset.

```
data/training/simplifications.jsonl
data/training/features.jsonl
data/training/bugs.jsonl
data/validation/simplifications.jsonl
data/validation/features.jsonl
data/validation/bugs.jsonl
data/hidden_test/litedb.jsonl
```