# Context Size vs Quality vs Parameter Size

This note tracks how context size/quality interacts with model size. The
current benchmark has two intentional `-ctx` profiles:

- compact ctx: the default context profile for smaller local models.
- full ctx: the cleaned larger-context profile, exposed by `ctx --full` /
  `ctx --large` and generated with `*-full-ctx` categories.

## Change Tested

The original `-ctx` prompt mostly included the target function, selected related
functions, worktree state, and focused failing-test context.

The richer `-ctx` prompt added general dependency context:

- constructor signatures for `SomeClass.new` calls, including cross-file
  constructors found under `src/**/*.rb`
- class/module constants referenced by the target function
- class/module constants for constant/class-name mutation evidence
- fallback from generated placeholder `flunk` tests to real recorded failing
  RSpec examples
- up to three focused failing test blocks instead of one

This is intentionally general. It is not keyed to individual bug IDs.

After the first measurement, this was split into two modes:

- compact mode is the default for `ctx` and for `A1B-ctx`, `3B-ctx`, and
  `7B-ctx`. It keeps the target function, selected related functions, worktree
  state, stack trace/failing test context, and debug metadata, but omits
  constructor/class-level metadata.
- large mode is used for `32B-ctx` and `405B-ctx`, and is available in the CLI
  with `ctx --large` or `ctx --full`. It is also used by the ablation
  categories `A1B-full-ctx`, `3B-full-ctx`, and `7B-full-ctx`. It adds only
  signature-style dependency metadata when mutation/test evidence makes that
  metadata likely useful: constructor signatures for
  argument/keyword/renamed-variable/off-by-one cases, and class constant
  signatures for constant/NameError cases.

Large mode intentionally does not include full constructor bodies or full class
bodies. Every function shown in the prompt is still shown with its full body;
class-level metadata is signature-only.

## Richer Context Results

These are the earlier results before compact/full profiles were separated.

| Category | Model | Compact/before richer ctx | Noisy richer ctx | Delta |
|---|---|---:|---:|---:|
| `A1B-ctx` | `LiquidAI/LFM2.5-8B-A1B` | 17/50 | 11/50 | -6 |
| `3B-ctx` | `Qwen2.5-Coder-3B-Instruct` | 23/50 | 20/50 | -3 |
| `7B-ctx` | `Qwen2.5-Coder-7B-Instruct` | 27/50 | 27/50 | 0 |
| `32B-ctx` | `qwen/qwen3-32b` | 30/50 | 32/50 | +2 |
| `405B-ctx` | `nousresearch/hermes-3-llama-3.1-405b` | 36/50 | 39/50 | +3 |

All after-rerun response sets had 50 files and zero error markers. `3B-ctx`
and `7B-ctx` each had one Prism parse failure before evaluation, both on test
47. `A1B-ctx`, `32B-ctx`, and `405B-ctx` had zero Prism parse failures.

## Compact vs Full Context

These are the current cleaned full-context ablations. For local small models,
`*-ctx` is compact and `*-full-ctx` uses the cleaned full profile. For larger
models, `32B-ctx` and `405B-ctx` already use the cleaned full profile.

| Model | `-blind` | `-ctx-compact` | `-ctx-full` |
|---|---:|---:|---:|
| A1B active | Not run | 17/50 (0 errors) | 12/50 (6 errors) |
| 3B | 17/50 (7 errors) | 23/50 (1 error) | 21/50 (1 error) |
| 7B | 27/50 (0 errors) | 27/50 (1 error) | 28/50 (1 error) |
| 32B | 34/50 (3 errors) | 30/50 (artifact incomplete) | 32/50 (0 errors) |
| 405B | 35/50 (1 error) | 36/50 (artifact missing) | 39/50 (0 errors) |

Prompt sizes by profile:

| Profile | Categories | Avg prompt bytes |
|---|---|---:|
| `-blind` local | `3B-blind`, `7B-blind` | 7,866 |
| `-blind` 32B | `32B-blind` | 46,792 |
| `-blind` 405B | `405B-blind` | 61,547 |
| `-ctx-compact` | `A1B-ctx`, `3B-ctx`, `7B-ctx` | 4,189 |
| `-ctx-full` | `A1B-full-ctx`, `3B-full-ctx`, `7B-full-ctx`, `32B-ctx`, `405B-ctx` | 5,185 |

For A1B and 3B, the cleaned full profile recovered some of the loss from the
earlier noisy richer profile, but still underperformed compact. For 7B, cleaned
full context slightly improved performance.

The blind scores use the current saved blind response directories and were
rechecked with `src/synthetic-bugs/evaluate.rb` on May 30, 2026. They are not
directly comparable to `A1B`, since the A1B experiment has no saved blind run.

The compact/before-richer scores for 32B and 405B are recorded in the earlier
results table, but the artifact status is uneven:

| Model | Compact score recorded | Compact prompt artifacts saved | Compact response artifacts saved |
|---|---:|---|---|
| 32B | 30/50 | No | Partially, in git history at `91fc89a:bugfix/32B-ctx` |
| 405B | 36/50 | No | No clean saved compact response directory found |

If artifact-level comparisons are needed, regenerate explicit
`32B-compact-ctx` and `405B-compact-ctx` categories instead of reusing
`32B-ctx` / `405B-ctx`, since those names now refer to the cleaned full profile.

## Interpretation

The current result suggests a capacity threshold: A1B and 3B are still better
with compact context, while 7B starts to benefit slightly from the cleaned full
profile. The larger OpenRouter-backed models benefited more from the same
family of dependency metadata.

For larger models, the added context fixed likely context-tooling misses such as:

- `FunctionSignature.dup`: include `FunctionSignature.initialize` so `params:`
  is not dropped while removing the duplicate kwarg.
- `OwnershipGraph.declare`: include class constants such as `Node`.
- `AST.enum_entries`: include `ERROR_NAME_NONE` and `ERROR_TYPES`.
- `Parser.parse_fn_type_annotation`: include `Type.initialize` for `Type.new`.

For A1B and 3B, compact context should remain the default benchmark profile.
For 7B, both compact and full are worth tracking because the full-profile gain
is only +1/50 and may not be stable at this sample size.

## Current Prompt Profiles

After splitting modes, prompt regeneration with `--dry-run-prompts` produced:

| Category | Mode | Avg prompt bytes | Added constructor/constant signature blocks |
|---|---|---:|---:|
| `A1B-ctx` | compact | 4,189 | 0 |
| `A1B-full-ctx` | full | 5,185 | 19 |
| `3B-ctx` | compact | 4,189 | 0 |
| `3B-full-ctx` | full | 5,185 | 19 |
| `7B-ctx` | compact | 4,189 | 0 |
| `7B-full-ctx` | full | 5,185 | 19 |
| `32B-ctx` | large | 5,185 | 19 |
| `405B-ctx` | large | 5,185 | 19 |

The 19 large-mode blocks appear on 10/50 bugs. They correspond to stored
mutation evidence for constant swaps, renamed variables in constructor calls,
or off-by-one constructor arguments. The previous richer prompts had 33 blocks
per large-model category and included several constructor signatures for
condition/boolean bugs where the constructor was incidental.

## Evaluation Logs

- A1B after richer ctx: `/tmp/cleopatra-a1b-ctx-newctx-eval.jsonl`
- A1B cleaned full ctx: `/tmp/cleopatra-a1b-full-ctx-eval.jsonl`
- 3B cleaned full ctx: `/tmp/cleopatra-3b-full-ctx-eval.jsonl`
- 7B cleaned full ctx: `/tmp/cleopatra-7b-full-ctx-eval.jsonl`
- Blind baseline recheck: `/tmp/cleopatra-blind-check.jsonl`
- 3B/7B after richer ctx: `/tmp/cleopatra-3b-7b-newctx-eval.jsonl`
- 32B/405B after richer ctx: `/tmp/cleopatra-32b-405b-newctx-eval.jsonl`
- Earlier 7B/32B/405B ctx run: `/tmp/cleopatra-param-ctx-eval.jsonl`
