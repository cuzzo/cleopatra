# Context Size vs Quality vs Parameter Size

This note tracks the first before/after measurement for richer `-ctx` prompts.

## Change Tested

The original `-ctx` prompt mostly included the target function, selected related
functions, worktree state, and focused failing-test context.

The richer `-ctx` prompt adds general dependency context:

- constructor signatures for `SomeClass.new` calls, including cross-file
  constructors found under `src/**/*.rb`
- class/module constants referenced by the target function
- class/module constants for constant/class-name mutation evidence
- fallback from generated placeholder `flunk` tests to real recorded failing
  RSpec examples
- up to three focused failing test blocks instead of one

This is intentionally general. It is not keyed to individual bug IDs.

## Results

| Category | Model | Before richer ctx | After richer ctx | Delta |
|---|---|---:|---:|---:|
| `A1B-ctx` | `LiquidAI/LFM2.5-8B-A1B` | 17/50 | 11/50 | -6 |
| `3B-ctx` | `Qwen2.5-Coder-3B-Instruct` | 23/50 | 20/50 | -3 |
| `7B-ctx` | `Qwen2.5-Coder-7B-Instruct` | 27/50 | 27/50 | 0 |
| `32B-ctx` | `qwen/qwen3-32b` | 30/50 | 32/50 | +2 |
| `405B-ctx` | `nousresearch/hermes-3-llama-3.1-405b` | 36/50 | 39/50 | +3 |

All after-rerun response sets had 50 files and zero error markers. `3B-ctx`
and `7B-ctx` each had one Prism parse failure before evaluation, both on test
47. `A1B-ctx`, `32B-ctx`, and `405B-ctx` had zero Prism parse failures.

## Interpretation

The richer context helped the larger models, was neutral for 7B, and hurt A1B
and 3B. That suggests the added dependency context is useful, but smaller
models are more sensitive to prompt noise and may need a smaller ctx profile.

For larger models, the added context fixed likely context-tooling misses such as:

- `FunctionSignature.dup`: include `FunctionSignature.initialize` so `params:`
  is not dropped while removing the duplicate kwarg.
- `OwnershipGraph.declare`: include class constants such as `Node`.
- `AST.enum_entries`: include `ERROR_NAME_NONE` and `ERROR_TYPES`.
- `Parser.parse_fn_type_annotation`: include `Type.initialize` for `Type.new`.

For A1B, the better strategy is probably a smaller dependency budget or a
separate compact ctx mode that includes only the single most relevant added
artifact.

## Evaluation Logs

- A1B after richer ctx: `/tmp/cleopatra-a1b-ctx-newctx-eval.jsonl`
- 3B/7B after richer ctx: `/tmp/cleopatra-3b-7b-newctx-eval.jsonl`
- 32B/405B after richer ctx: `/tmp/cleopatra-32b-405b-newctx-eval.jsonl`
- Earlier 7B/32B/405B ctx run: `/tmp/cleopatra-param-ctx-eval.jsonl`
