# Training Data Generation Plan

Generate 1300+ training examples from the [CLEAR](https://github.com/ahn-ml/clear) codebase
at `~/cheat`.

**Core insight:** Instead of asking DeepSeek to generate synthetic alternative solutions,
we use **git history as ground truth**. Each commit represents a real alternative path —
a version of the code that actually existed at some point. Hundreds of versions per file
gives us a dense trajectory of sloppy→clean (and clean→sloppy) code.

| # | Dataset | Count | Source |
|---|---|---|---|
| 1 | Simplification commits | 200 | Git history — SIMP/refactor commits |
| 2 | Feature commits | 200 | Git history — feature/add commits |
| 3 | Synthetic feature requests | 400 | Delete functions/classes/files; reference is next version |
| 4 | Synthetic bugs (mutants) | 400 | Inject mutations; reference is original |
| 5 | Real bugs | 100 | Git history — bug/fix commits |

**For each example**, instead of generating 10 alternatives with DeepSeek, we have
**hundreds of real versions** of each file from git history. The model sees:

- Reference solution: the target version (cleaner, correct)
- Alternative paths: all intermediate versions between start and target
- CodeQL scores: computed for every version along the trajectory

---

## How historical versions replace DeepSeek generation

The top 20 most-changed files have ~2900 version/file pairs, with individual
files having 50–557 versions each. Each version is a real, working state of
the code.

### Example: `transpiler.rb` (415 versions)

```
Version 1:   898 lines  — early implementation
Version 50:  1552 lines — added features
Version 100: 1249 lines — simplified
Version 200: 2028 lines — rewrote for performance
Version 300: 3106 lines — added error propagation
Version 400: 4283 lines — MIR pipeline phase 6
```

For a training example targeting the simplification at version 100:

```
Prompt:  version 50  (1552 lines, sloppier)
Target:  version 100 (1249 lines, cleaner)
Alternatives: versions 51–99 (all intermediate attempts)
CodeQL:  scores for every version showing the improvement trajectory
```

This is better than DeepSeek alternatives because:
1. **Real code** — every alternative actually existed in the codebase
2. **Dense coverage** — 50 intermediate versions instead of 10 synthetic ones
3. **Ground truth** — the target is the version the author actually committed
4. **Free** — no API costs for generation

### When DeepSeek is still useful

DeepSeek is valuable for generating **tool calling data** (the process of
exploring solutions), not for generating the solutions themselves. We save
DeepSeek's tool calls during any generation we do, for future tool-calling
training in a more powerful model.

---

## Dataset 1: Simplification Commits (200)

### Source

Git commits tagged `SIMP` or containing "simplif", "cleanup", "reduce",
"collapse", "prune", "delete dead", "purge".

~94 SIMP-tagged commits + many more with related messages.

### Extraction

For each qualifying commit:

```
1. Identify the file(s) changed
2. Get the version N commits before  →  "before" (sloppier)
3. Get the version at the commit     →  "after"  (cleaner)
4. Collect all versions between them →  alternative paths
```

Only keep commits where:
- The diff touches ≤3 files (focused change)
- The diff is 5–200 lines
- The change is semantic (not whitespace/rename)

### Training Example Format

```
{
  "type": "simplification",
  "file": "src/mir/mir_lowering.rb",
  "commit_sha": "abc1234",
  "commit_msg": "SIMP-Plan-7: delete dead MIR::Drop fields",
  "prompt": "<version from N commits before commit>",
  "reference": "<version at the commit>",
  "alternatives": ["<version -1>", "<version -2>", ..., "<version -N>"],
  "codeql_scores": { ... }
}
```

---

## Dataset 2: Feature Commits (200)

### Source

Git commits matching "add", "implement", "feature", "feat".

### Extraction

Same pattern as Dataset 1. For each commit, extract the version just before
(the "before") and all intermediate versions as alternatives.

Keep commits where:
- The diff adds new functionality
- ≤3 files changed
- Diff is 5–200 lines

### Training Example Format

```
{
  "type": "feature",
  "file": "src/backends/transpiler.rb",
  "commit_sha": "def5678",
  "commit_msg": "feat: add CONCURRENT pipeline modifier",
  "prompt": "<version before feature was added>",
  "reference": "<version with feature added>",
  "alternatives": ["<version -1>", ..., "<version -N>"],
  "codeql_scores": { ... }
}
```

---

## Dataset 3: Synthetic Feature Requests (400)

### Generation

Programmatically delete code from a version, then use the next real commit
as the reference solution.

For each of 400 iterations:

1. **Pick a file** with many versions (≥20)
2. **Pick a target commit** — the "answer" version
3. **Pick a source** — a version N commits before the target
4. **Delete something** from the source:
   - Remove a function body (keep the signature)
   - Remove a class definition
   - Remove a file
5. **Prompt** — "Here is the code with a missing piece. Implement it."
6. **Reference** — the target version (what the author actually wrote)
7. **Alternatives** — all versions between source and target

### Stratification

| Type | Count | Example |
|---|---|---|
| Function body removal | 200 | Delete body of `def foo; ...; end`, keep signature |
| Class removal | 100 | Delete entire class definition |
| File removal | 100 | Delete `.rb` file, keep requires/imports |

### Implementation

Function boundaries are identified by parsing with `parser` gem (or Prism).
The deleted region is replaced with a `# TODO: implement` comment.

---

## Dataset 4: Synthetic Bugs via Mutation (400)

### Generation

Inject bugs into a known-good version of a file, using the original as
reference and intermediate versions as alternative fixes.

For each of 400 iterations:

1. **Pick a function** from a file with many versions
2. **Pick a version** where the function exists in a clean state
3. **Apply a mutation** (see types below)
4. **Prompt** — "The following code has a bug. Find and fix it:"
5. **Reference** — the unmutated version
6. **Alternatives** — if the function was ever reverted/fixed in history,
   those versions are real alternative fix attempts

### Mutation Types

| Mutation | Count | Example |
|---|---|---|
| Negate condition | 100 | `if a > b` → `if a <= b` |
| Swap operands | 50 | `a + b` → `b + a` |
| Remove null check | 50 | Delete `if x.nil?; return; end` |
| Off-by-one | 50 | `arr[i]` → `arr[i+1]` |
| Wrong operator | 50 | `&&` → `\|\|` |
| Delete line | 50 | Remove a single critical line |
| Wrong variable | 50 | `result` → `temp_result` |

Only keep mutations where the mutated code still parses and type-checks.

---

## Dataset 5: Real Bugs (100)

### Source

Git commits matching "fix", "bug", "crash", "error" (3543 candidates
in the repository).

### Extraction

Same as Datasets 1 & 2:

```
1. Pick a fix commit
2. Get the buggy version (commit^)
3. Get the fixed version (the commit)
4. Collect intermediate versions as alternative fix attempts
```

Prefer commits that:
- Are explicitly labeled as fixes (e.g., `fix(...)` prefix)
- Touch ≤2 files
- Diff is 5–100 lines (focused fix)

---

## CodeQL Scoring

Every version across all 5 datasets gets scored by CodeQL:

- Dead code detection
- Complexity metrics (cyclomatic, method length)
- Type safety
- Idiomatic Ruby linting
- Security linting

For each training example, the trajectory looks like:

```
Prompt version:  CodeQL score = 45/100
  ↓
Intermediate 1:  CodeQL score = 52/100
  ↓
Intermediate 2:  CodeQL score = 48/100  (worse try)
  ↓
Intermediate 3:  CodeQL score = 61/100
  ↓
Reference:       CodeQL score = 78/100  (best)
```

GRAM learns to explore these paths and pick the one leading to the highest
CodeQL score.

---

## Key Difference from Original Plan

| Aspect | Old plan | New plan |
|---|---|---|
| Alternative sources | DeepSeek generates 10 | Git history provides ~50+ real versions |
| Ground truth | Synthetic (DeepSeek, may hallucinate) | Real (author actually committed it) |
| Alternative quality | Unknown — DeepSeek may generate nonsense | Known — every version was working code |
| Cost | API calls for 13k generations | Free |
| Tool calling data | Saved from DeepSeek | Still usable for future training |

---

## Pipeline

```
MINE git history
  │
  ├── For each commit type (SIMP, fix, feat, add)
  │     ├── extract before/after versions
  │     └── collect intermediate versions as alternatives
  │
  ├── Generate synthetic deletions (Dataset 3)
  │     ├── parse Ruby AST for boundaries
  │     └── mask functions/classes/files
  │
  └── Generate synthetic mutants (Dataset 4)
        ├── apply mutation operators
        └── verify mutant still parses

SCORE everything with CodeQL
  │
  ├── every version gets a code health score
  └── score trajectory is the training signal

TRAIN GRAM
  │
  ├── prompt + reference + alternatives + scores
  └── GRAM learns to explore paths and pick the least sloppy
```