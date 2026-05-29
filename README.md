# Cleopatra

This project will explore if [1.58-bit](https://en.wikipedia.org/wiki/1.58-bit_large_language_model) + [MLA](https://machinelearningmastery.com/a-gentle-introduction-to-multi-head-latent-attention-mla/) + [MoE](https://en.wikipedia.org/wiki/Mixture_of_experts) + [GRAM](https://ahn-ml.github.io/gram-website/#) can:

 1. Substantially improve LLMs for *implementation* at coding tasks.
 2. Make near SOTA implementation possible on local models on MacBook M5 base hardware at 30+ Tok/s.

Ultimatley, I believe both of these will happen within 2 years.  The question is:

 1. Is GRAM a good solution?
 2. Can it happen even sooner?

## Reasoning

Yann LeCun states both that:

 1. LLMs are a dead end because they can't understand the consequences of their actions before they act.
 2. LLMs are specifically great where language IS the substrate of knowledge (coding & math).

GRAM does something *somewhat* tangential to LeCun's World Model JEPA, in that it explores many paths and picks the best one.

## The Biggest Problems LLMs have in Coding

LLMs are good at getting something to *sort of* work.

The problem is their implementations are *sloppy*, or overly complex, have bad architecture.

## How GRAM *might* help

We want to explore two paths where GRAM *might* help:

 1. Using CodeQL style metrics to score solutions based on how sloppy they are to improve quality.
 2. Using tool calling to fit better quality context into a smaller window.

GRAM can explore many paths simultaneously and chose the one with the best context or the least sloppy solution and choose the winners.

GRAM improved reasoning by 5000 - 10,000x.

If it can *only* improve tool calling by *only* 10x, or *only* local reasoning for bugs by 10x - either of those on their own would be huge.  If the two compound, it would be incredible.

## How to test it

Qwen2.5-Coder-3B is not particularly good at implementation - especially compared to fronteir models like Claude Opus 4.7.

Qwen2.5-Coder-3B is *highly* unlikely to match frontier model performance on non-trivial implementation tasks.

However, if GRAM is a viable solution to significantly improving performance, we should be able to easily see that on a Qwen2.5 model quickly and cheaply.

**The goal:** get Qwen2.5-Coder-3B to outperform a 7B model on a mix of implementation tasks (and ideally better than 14B).

## The Real Solution

If the Qwen results are successful, we should be able to get Phi 3.8B MoE to run locally on MacBook M5s at 30+ Tok/s.

If the test is successful, it is *realistic* to belive a model Phi 3.8B MoE size could perform competitively with Opus 4.7 for implementation, and for context sizes <32k tokens (implementation tasks), it should be able to run smoothly on a MacBook M5 base hardware.

## The training set

We want to validate or invalidate the hypothesis as quickly and cheaply as possible.

Existing training methods *likely* work better than the approach we want to try.  But, we want to try something *somewhat* like JEPA.

Idea:

 1. Take the [CLEAR](https://github.com/cuzzo/clear) codebase.
 2. Similar to JEPA, we want to randomly hide functions and classes at different points in time in the repository and tell the model to fill in the blanks.  It will *likely* choose many paths that don't work, or are worse than the one chosen.
 3. We will use a version of mutant testing to generate synthetic bugs, and then tell the code to model to fix the bugs.  Most of the time it will *likely* fail.

The goal is to generate:

 1. 200 simplification commits from history.
 2. 200 feature request commits from history.
 3. 100 real bugs from CLEAR.
 4. 400 synthetic feature requests by deleting functions, classes, files and telling the model to fix it.
 5. 400 synthetic trivial bugs introduced via mutant tests.

For #1, #2, #4 #5 - we will generate permutations of partial implementations throughout history that are less ideal versions to train our model.

For #3:

 * We will have other models (DeepSeek v4 Flash, Qwen Coder 30B, Phi 3.8B MoE, etc) generate solutions (which will likely be sloppier than the solution chosen from history).
 * We will save their tool calling, etc, to improve tool calling in a more powerful model later, if this method turns out to be viable.

## The obvious hurdles

Let's *assume* that GRAM can make a model 2000x better at local reasoning.

The problem is that most feature requests are non-local.  A larger model has a massively unfair advantage against a smarter model on a huge context (most code).

GRAM / JEPA *theoretically* can help here.  Our model can explore many different paths of what it should include in it's context.

If it can be 2000x smarter at selectively including data in its context, it may be able to perform tasks a model of its size cannot currently be expected to peform.

 * SOTA 3B models cannot reliably make changes across several files, or non-greenfield changes over 20+ lines.
 * SOTA 14B models can.

A 3B model isn't *that* helpful if it's as good as a 14B model, but still limited in use to only fixing single, small function problems reliably.

A 16B MoE model isn't *that* helpful if it can only make small architectural changes reliably - but if it can perform like a 50B model, those SOTA models *can* make those changes.

## The goal

 1. We want to take a task a model *can* perform - like single function changes for a 3B model - and make it perform as well as models 10x larger.
 2. We want to expand the scope of a model to be able to perform tasks a model 2-4x larger can perform.

## Order of operations

It is easiest to validate the tool calling hypothesis, since we can easily generate tons of synthetic data for this.  We will start there. 

## Stage 1:

Eventually, we want to test how effectively Qwen2.5 can be trained with GRAM to use a custom tool to get far better context.

> See [Context Is What You Need](https://doi.org/10.48550/arxiv.2509.21361) & [Context Length Alone Hurts LLM Performance Despite Perfect Retrieval](https://doi.org/10.48550/arxiv.2510.05381) for why.

### The test

We fed Qwen2.5 the context we *want* it to learn to extract from our tool.

### Current Verified Bugfix Evaluation

The current control-gated benchmark uses 50 `src/` synthetic mutant bugs from
bundled CLEAR `master` (`cde89fb`). Each bug stores the individual spec files
that pass before mutation and fail after mutation; evaluation applies model
responses with Prism and runs only those recorded specs.

| Model / prompt | Passed | Failed tests | Apply / parse errors | Pass rate |
|---|---:|---:|---:|---:|
| Control solutions | 50 | 0 | 0 | 100% |
| Qwen2.5-Coder-3B blind | 3 | 46 | 1 | 6% |
| Qwen2.5-Coder-3B ideal context | 18 | 30 | 2 | 36% |
| Qwen2.5-Coder-7B blind | 1 | 47 | 2 | 2% |
| Qwen2.5-Coder-32B blind | 4 | 42 | 4 | 8% |

### In progress

 - [x] Test against Qwen2.5-Coder-32B blind.
 - [ ] Test against a ~300B model (less apples to apples since Qwen does not have a 300B model).

## Stage 2:

Next, we will test how effectively the original model can learn to use a tool.

Then, we will compare a GRAM-based version of it.

Finally, we will compare that to a 7B version.

Since training is expensive, we will extrapolate learning based on performance scaling - to *estimate* how effectively a 30B model would likely learn to use our tool.

### Goal

We *hope* that GRAM can help the model learn to use the tool 100-1000x better than without GRAM.

If this is the case, even if GRAM does not help with local reasoning in coding at all - purely the context boost could make the model perform 10x+ better.

## Stage 3:

If GRAM does not improve tool calling ability by impressive margins, we are skeptical it will improve coding local reasoning.

However, we will try it regardless.
