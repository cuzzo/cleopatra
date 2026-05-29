# Bug Generation & Tool-Calling Training Plan

This document specifies the full dataset pipeline for training a 3B GRAM model
to use `ctx` for context discovery during bug fixing across multiple
programming languages.

---

## 1. Dataset Allocation

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Total Dataset: 1,300 items                   │
│                                                                     │
│  ┌──────────────────────────────┐  ┌──────────────┐  ┌──────────┐  │
│  │  Ruby Active (800)           │  │  Held Back   │  │ Multilang│  │
│  │  ─────────                  │  │  ──────────  │  │ ──────── │  │
│  │  800 bugs × 5 trajectories  │  │  300 Ruby    │  │ 200 bugs │  │
│  │  = 4,000 training examples  │  │  (no paths,  │  │ (from    │  │
│  │                             │  │   no tool    │  │  existing│  │
│  │  3:1:1 ratio:               │  │   calls)     │  │  datasets)│  │
│  │  3 y_sloppy + 1 y_clean     │  │              │  │          │  │
│  │  + 1 y_broken pathways      │  │  Pure        │  │  NO_TOOL │  │
│  │                             │  │  evaluation  │  │  signal  │  │
│  └──────────────────────────────┘  └──────────────┘  └──────────┘  │
│                                                                     │
│  Training: 800 + 200 = 1,000 items  │  Evaluation: 300 items       │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.1 Ruby Active (800)

Bugs with full 5-trajectory tool-calling data. Used for GRAM training.
- 3:1:1 ratio across y_clean / y_sloppy / y_broken pathways
- Each trajectory: 1x y_clean (+10 reward), 1x y_sloppy_1 overcall (+2),
  1x y_sloppy_2 undercall (-5), 1x y_broken_grep (-5), 1x y_broken_dump (-5)
- Sources: synthetic mutants (70%), real bugs (15%), LLM-generated (15%)
- Prompt styles: randomly assigned from 6-style distribution (one per bug)

### 1.2 Held Back (300)

Ruby bugs held back for pure evaluation. **No paths, no tool-calling data.**
The model must generate its own tool calls and fixes from scratch.

Used to measure:
- **Tool-calling accuracy** — does the model call the right tool?
- **Context extraction** — does it find the right context?
- **Fix quality** — does the fix pass tests / reduce sloppiness?

**For statistical significance:**

```
If Qwen 3B baseline fix rate = 30%
  SE at N=300 = ±5.3%
  15% improvement → t ≈ 2.8 → p < 0.01 ✅

If effect size ≥ 12%, we can detect it at p < 0.05.
If effect size ≥ 15%, we can detect it at p < 0.01.
```

300 is the minimum for reliable significance at the effect sizes we expect
(GRAM + tool should produce 15-20% improvement over baseline).

### 1.3 Multilingual Negatives (200)

Bugs from **non-Ruby** languages (Rust, Go, C, Python) sampled from existing
datasets. **No tool-calling trajectories** — these use `[NO_TOOL_REQUIRED]`
as the anchor token during training.

| Language | Count | Source | Reasoning |
|----------|-------|--------|-----------|
| Rust | 60 | Rust bug datasets / known CVEs | Large ecosystem, good bugs |
| Go | 50 | Go bug datasets | Modern, growing ecosystem |
| C | 50 | CVE database / oss-fuzz | Root of most security bugs |
| Python | 40 | Python bug tracker samples | Largest language |
| **Total** | **200** | | |

**Sampling strategy (no generation needed):**

Each sample is a pre-existing bug from an open dataset:
- Code snippet showing the buggy and fixed version
- A simple prompt like "Fix the bug: [code snippet]"
- The fix is the corrected version
- No tool calls are relevant (different language, different toolchain)
- Training signal: model should output `[NO_TOOL_REQUIRED]` or proceed
  directly to analysis without invoking tools

**Why this works:**
The model is language-aware. A 3B coder model knows the difference between
Ruby and Rust at the syntax level. By exposing it to non-Ruby bugs where
tool calling is irrelevant, the GRAM layer learns to map `language != Ruby`
→ `[NO_TOOL_REQUIRED]`.

---

## 2. Bug Sources

### 2.0 Bundled Source Repos

Ruby bugs are generated from git bundles stored in `archives/`, not from live
developer checkouts. The default synthetic mutant source is:

```bash
ruby src/mutant-bug-gen.rb \
  --bundle archives/cheat.bundle \
  --repo .eval/cheat \
  --ref refs/remotes/bundle/master \
  --out bugs.jsonl \
  --target 1200
```

Each generated bug stores `repo.bundle`, `repo.ref`, `repo.commit`, `repo.tree`,
`file_rel`, and `test_failures`. Evaluation must reconstruct or reset a
worktree from that bundle and check out `repo.commit` before applying a model
response.

Every accepted synthetic mutant must have at least one verified failing test
file. Verification means the test file passes on the clean pinned checkout,
then fails after applying the mutation. The evaluator runs only the stored
individual test commands.

### 2.1 Real Bugs (100 from triage)

From the triaged commits across sub-projects:
62 `src/` + 12 `minivm` + 2 `nil-kill` + remaining from multi-project commits
= **100 verified real bugs**.

Each real bug provides:
- Ground-truth before/after code (the fix)
- The actual commit message (a PROMPT VERSION)
- Actual stack trace (from test suite)
- Known functions that were changed (IDEAL CONTEXT)

### 2.2 LLM-Generated Alternate Bugs (150)

For each real bug, an LLM generates 5 similar bugs → 500 attempts → ~150 valid.

Each alternate bug:
- Different root cause, same symptom
- Structure different enough to avoid memorization
- Verified: `ruby -c` passes, at least one test fails, fix changes ≤3 functions

### 2.3 Synthetic Mutant Bugs (1,200)

From the mutation catalog, applied across all 7 sub-projects.
`mutant-bug-gen.rb` enforces the sub-project, difficulty, and prompt-style
distributions as quotas for the generated file.

| Sub-project | % target | Bug count |
|-------------|----------|-----------|
| `src/` | 55% | 660 |
| `gems/nil-kill/` | 19% | 228 |
| `examples/minivm/` | 10% | 120 |
| `examples/puck/` | 9% | 108 |
| `gems/decomplex/` | 5% | 60 |
| `gems/slopcop/` | 1% | 12 |
| `gems/boobytrap/` | 1% | 12 |
| **Total** | **100%** | **1,200** |

Each gets 5 trajectories → 6,000 trajectory examples.

Current scope: these 1,200 synthetic mutants are code bugs only. Test bugs are
planned separately because the present evaluator applies model-defined Ruby
functions back into source files, not test files.

### 2.3.1 Discovery Scenarios

Every synthetic mutant also receives a discovery scenario:

| Scenario | Share | What `ctx` reports |
|---|---:|---|
| `dirty_source_change` | 30% | Worktree dirty; target file dirty |
| `new_unit_test` | 30% | Worktree dirty; new failing test file added |
| `production_stack_trace` | 40% | Worktree clean; treat as existing/production bug |

For `dirty_source_change`, the dirty target file scope is split:

| Scope | Share within dirty-source bugs |
|---|---:|
| `whole_function_dirty` | 50% |
| `multi_line_dirty` | 25% |
| `exact_line_dirty` | 25% |

The generated bug stores this under `discovery`. Prompt generation uses it to
append the same worktree-state hint a real `ctx` tool call would expose.

### 2.4 Multilingual Negatives (200 sampled)

Sampled from existing bug datasets, NOT generated.

| Language | Dataset | Sample count | What we sample |
|----------|---------|-------------|----------------|
| Rust | `rust-lang/rust` issue tracker, CVE database | 60 | Buggy Rust code snippets with fixes |
| Go | Go issue tracker, golang/go CVEs | 50 | Buggy Go snippets with fixes |
| C | OSS-Fuzz, CVE database | 50 | Buggy C snippets with fixes |
| Python | Python bug tracker, CPython issues | 40 | Buggy Python snippets with fixes |

Each sample becomes a simple "Fix the bug: [code]" prompt with no tool calls.

---

## 3. Prompt Diversity Strategy

Each bug gets **exactly ONE** prompt style, randomly assigned:

| Style | % | Description |
|-------|---|-------------|
| stack_trace | 40% | Full Ruby stack trace from test failure |
| detailed | 20% | Stack trace + function context |
| vague | 15% | Just the function name + symptom |
| with_culprit | 10% | "I suspect the issue is in..." |
| spec_broken | 10% | "CI is failing on this test..." |
| minimal | 5% | "CI is broken. Fix it." |

No bug appears with multiple prompt styles. Each bug = one prompt.

---

## 4. Context Discovery Training (5 Trajectories)

Each bug generates 5 tool-calling trajectories:

| Variant | Tool calls | Context lines | Fix quality | Reward |
|---------|-----------|---------------|-------------|--------|
| **y_clean** (correct) | 3 | ~80 lines | Correct | **+10** |
| **y_sloppy_1** (over-call) | 7 | ~300 lines | Correct but slow | **+2** |
| **y_sloppy_2** (under-call) | 1 | ~20 lines | Misses context | **-5** |
| **y_broken_1** (grep/cat) | 2-3 | ~2000 lines | Wasted context | **-5** |
| **y_broken_2** (dump file) | 1-2 | ~4000 lines | Context overflow | **-5** |

### 3:1:1 Ratio

The named ratio describes the balance of training signal per bug:

```
3 = y_sloppy variants (over + under + grep/cat/dump)
      → "You used the tool but got the WRONG AMOUNT of context"
1 = y_clean
      → "You used the tool and got the RIGHT AMOUNT of context"  
1 = y_broken
      → "You used the WRONG tool (grep/cat) for context discovery"
```

The model must learn: `ctx` is the right tool, with the right number of
calls, to get precisely the context you need.

---

## 5. Training Directory Structure

```
~/cleopatra/bugs/
  ├── bugs.jsonl                  # Master file of all 1,500 bugs
  ├── train/
  │   ├── ruby_active/            # 800 bugs × 5 trajectories = 4,000 examples
  │   │   ├── synth-src-000001.json
  │   │   ├── synth-src-000002.json
  │   │   └── ...
  │   └── multilang_negative/     # 200 bugs, no tool trajectories
  │       ├── rust-0001.json
  │       ├── go-0001.json
  │       └── ...
  ├── validation/
  │   └── held_back/              # 300 Ruby bugs, no trajectories
  │       ├── held-000001.json
  │       ├── held-000002.json
  │       └── ...
  └── manifests/
      ├── train_manifest.json     # {id: filepath, ...}
      ├── val_manifest.json
      └── stats.json              # Distribution verification
```

### 5.1 Ruby Active Format (800)

```json
{
  "id": "synth-src-000001",
  "type": "bug_fix",
  "source": "synthetic_mutant",
  "repo": {
    "bundle": "archives/cheat.bundle",
    "ref": "refs/remotes/bundle/master",
    "commit": "...",
    "tree": "..."
  },
  "subproject": "src",
  "difficulty": "stack_1_2",
  "code_or_test": "code",
  "prompt_style": "stack_trace",
  "prompt": "Test failure:...",
  "file": "src/mir/escape_analysis.rb",
  "file_rel": "src/mir/escape_analysis.rb",
  "function": "EscapeAnalysis.apply!",
  "mutated_body": "...",
  "original_body": "...",
  "ideal_tool_calls": [
    {"tool": "ctx", "args": "src/mir/escape_analysis.rb#142"},
    {"tool": "ctx", "args": "src/mir/escape_analysis.rb:propagate_caller_sync! debug"},
    {"tool": "ctx", "args": "src/ast/scope.rb:SymbolEntry"}
  ],
  "trajectories": {
    "y_clean": {"label": "y_clean", "reward": 10, "steps": [...], "tool_calls": 3, "context_lines": 87},
    "y_sloppy_1": {"label": "y_sloppy_over", "reward": 2, "steps": [...], "tool_calls": 7, "context_lines": 290},
    "y_sloppy_2": {"label": "y_sloppy_under", "reward": -5, "steps": [...], "tool_calls": 1, "context_lines": 24},
    "y_broken_1": {"label": "y_broken_grep", "reward": -5, "steps": [...], "tool_calls": 2, "context_lines": 1850},
    "y_broken_2": {"label": "y_broken_dump", "reward": -5, "steps": [...], "tool_calls": 1, "context_lines": 8540}
  }
}
```

---

## 6. Evaluation Protocol

Evaluation is only valid when it uses the same source tree that created the bug.
For each bug:

1. Restore or reuse a local worktree from `repo.bundle`.
2. Check out `repo.commit` in detached mode.
3. Verify `git rev-parse HEAD^{tree}` equals `repo.tree`.
4. Read `file_rel` from that worktree.
5. Use Prism to locate the recorded function and rewrite that function with
   `mutated_body`.
6. Use Prism to parse the model response and collect all Ruby `def` nodes.
7. For each response function, replace the matching source function by full or
   short name; if no match exists, append it to the source file. Responses that
   contain instructions, partial diffs, or prose like "change this line" are
   marked `UNSUPPORTED_RESPONSE_FORMAT` for manual review.
8. Run `ruby -c` on the changed file.
9. Run each command stored in `test_failures`; do not fall back to a whole
   suite or syntax-only success.
10. Restore the worktree before the next bug, regardless of pass/fail/error.

The evaluator must write a JSONL failure ledger for manual inspection. Each
failure record should include:

```json
{
  "bug_id": "...",
  "category": "3B-ctx",
  "repo_commit": "...",
  "file_rel": "src/...",
  "response_path": "bugfix/3B-ctx/01.txt",
  "raw_response": "...",
  "status": "UNSUPPORTED_RESPONSE_FORMAT",
  "detail": "response describes a line edit instead of returning replacement code"
}
```

This ledger is required because some LLM responses are semantically useful but
not machine-applicable, for example "change this exact line". Those must not be
counted as evaluator errors or silent failures; they need explicit review.

### 5.2 Held Back Format (300)

```json
{
  "id": "held-src-000017",
  "type": "bug_fix",
  "source": "synthetic_mutant",
  "subproject": "src",
  "file": "src/annotator/annotator.rb",
  "function": "Annotator.hoist_body!",
  "prompt": "Test failure:...",
  "mutated_body": "...",
  "original_body": "...",
  "stack_trace": "...",
  "ideal_tool_calls": [{"tool": "ctx", "args": "..."}],
  "trajectories": null
}
```

No trajectories. Pure evaluation — model must generate everything from scratch.

### 5.3 Multilingual Negative Format (200)

```json
{
  "id": "neg-rust-00001",
  "type": "bug_fix",
  "language": "rust",
  "source": "rustc_issue_12345",
  "buggy_code": "...",
  "fixed_code": "...",
  "prompt": "Fix the bug in this Rust code:\n\n```rust\n...\n```",
  "anchor_token": "[NO_TOOL_REQUIRED]",
  "trajectories": null
}
```

---

## 6. Evaluation Pipeline

### 6.1 Baseline Measurement

Before training, measure Qwen 3B's baseline fix rate on the 300 held-back bugs:

```bash
# For each held-back bug, feed its prompt to Qwen 3B
# Measure:
#   1. Does the output code parse? (ruby -c)
#   2. Does the output fix match the original_body?
#   3. Decomplex score of the output

python evaluate_baseline.py \
  --model qwen2.5-coder-3b \
  --validation_dir bugs/validation/held_back/ \
  --output baseline_results.json
```

**Expected baseline:** Qwen 3B without GRAM or tool calling should fix
~20-35% of bugs (it can handle easy syntax + trivial line but struggles
with stack trace 1-2 and hard bugs).

### 6.2 Post-Training Evaluation

After GRAM training, run the same evaluation:

```bash
# Each held-back bug is fed to the trained model
# Model generates tool calls → gathers context → produces fix
# Compare against baseline

python evaluate_trained.py \
  --model qwen2.5-coder-3b-gram \
  --validation_dir bugs/validation/held_back/ \
  --output trained_results.json

# Compare:
#   Baseline fix rate vs GRAM fix rate
#   Baseline tool-call accuracy vs GRAM tool-call accuracy
#   Baseline context lines used vs GRAM context lines used
```

### 6.3 Pass/Fail Detection

A fix "passes" if:
```
1. ruby -c on the output → success (no parse errors)
2. grep for the bug pattern in output → not present (mutation is fixed)
   OR the test passes when run against the output
3. decomplex score ≥ 70 (code is not sloppy)
```

A fix "fails" if:
```
1. ruby -c fails (parse error)
2. The mutation is still present in the output
3. decomplex score < 40 (sloppy code)
```

### 6.4 Statistical Test

```python
from scipy.stats import chi2_contingency

# Contingency table
#          Baseline  GRAM+Tool
# Fix        a          b
# No fix     c          d

_, p, _, _ = chi2_contingency([[a, b], [c, d]])

if p < 0.01 and (b/(b+d) - a/(a+c)) > 0.10:
    print("HYPOTHESIS CONFIRMED: GRAM + tool calling beats baseline")
else:
    print("HYPOTHESIS NOT CONFIRMED")
```

---

## 7. Training Strategy (Gemini Framework)

### 7.1 Defining Triggers: Active vs Negative Optimization

For the GRAM layer to stay silent on non-Ruby code, it needs a distinct state:

- **Ruby bugs (Active):** Context contains a Ruby bug → GRAM isolates context
  to <16k tokens → base model generates `<call:ctx>{...}</call>`.
- **Multilingual negatives:** Context contains Rust/Go/C/Python bug → GRAM
  reads context → base model outputs `[NO_TOOL_REQUIRED]` without invoking tools.

### 7.2 Masked Loss (Zero-Loss Strategy)

Use Cross-Entropy Loss Masking to enforce the distinction:

```
[Ruby Bug Input Context]    → [Ideal Tool Call + Fix]       → Loss Weight: 1.0
[Rust Bug Input Context]    → [[NO_TOOL_REQUIRED] Token]    → Loss Weight: 1.0
                          └→ [All other Rust syntax]        → Loss Weight: 0.0
```

Implementation via PyTorch:

```python
import torch

def prepare_labels_for_batch(batch_inputs, is_ruby_path):
    """
    batch_inputs: Tokenized tensor of your inputs.
    is_ruby_path: Boolean array indicating if the row is a target Ruby path.
    """
    labels = batch_inputs.clone()

    if not is_ruby_path:
        for i in range(labels.size(0)):
            # Mask everything except the [NO_TOOL_REQUIRED] anchor token
            labels[i, :] = -100
            # Unmask only the anchor token positions
            # labels[i, target_anchor_indices] = batch_inputs[i, target_anchor_indices]

    return labels
```

### 7.3 Negative Sample Loss Weight Calibration

Since multilingual negatives are only 200 vs 800×5 = 4,000 Ruby active instances,
apply a loss multiplier of **2.0x to 3.0x** to the `[NO_TOOL_REQUIRED]` token
when multilingual samples appear in a batch. This prevents the network from
minimizing the negative instances too quickly.

### 7.4 Batch Mixing Strategy

During training, each batch should contain:
- 70% Ruby active samples (with trajectories)
- 20% Multilingual negatives (no trajectories, `[NO_TOOL_REQUIRED]`)
- 10% Held back (no trajectories — pedagogical value only, loss masked on fix)

This ensures the model sees both contexts consistently every step.

---

## 8. Final Summary

| Component | Count | With trajectories | Format |
|-----------|-------|-------------------|--------|
| Ruby bugs for training | 800 | 5 each → 4,000 examples | JSON with full trajectories |
| Ruby bugs held back | 300 | None | JSON, prompt + ideal_tool_calls only |
| Multilingual negatives | 200 | None | JSON, bug snippet + `[NO_TOOL_REQUIRED]` |
| **Total dataset** | **1,300** | | |

### 8.1 What's Missing if We Don't Hit 800 Ruby Bugs

If our Ruby bug generator produces fewer than 800 valid bugs:

| If we have | Training paths | Held back | Verdict |
|------------|----------------|-----------|---------|
| 800 Ruby | 4,000 | 300 | ✅ Ideal |
| 600 Ruby | 3,000 | 200 | ⚠️ Tight but workable — need larger effect size |
| 500 Ruby | 2,500 | 150 | ❌ Reduce statistical significance. Need >18% lift |
| 400 Ruby | 2,000 | 100 | ❌ Below detectable threshold at reasonable effect sizes |

### 8.2 Baseline Verification

```
If Qwen 3B fix rate on held-back set = 30%:
  SE = sqrt(0.3 * 0.7 / 300) = 2.64%
  95% CI: [24.7%, 35.3%]

If GRAM + tool fix rate = 45%:
  SE = sqrt(0.45 * 0.55 / 300) = 2.87%
  95% CI: [39.3%, 50.7%]

Difference: 15% (CI [6%, 24%] — non-overlapping ✅
```

At 300 held-back samples and a conservative 15% lift, we can confirm the
hypothesis with p < 0.01. This is the gold standard for the experiment.
