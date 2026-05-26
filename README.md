# Cleopatra

This project will explore if [MLA](https://machinelearningmastery.com/a-gentle-introduction-to-multi-head-latent-attention-mla/) + [MoE](https://en.wikipedia.org/wiki/Mixture_of_experts) + [GRAM](https://ahn-ml.github.io/gram-website/#) can:

 1. Substantially improve LLMs for *implementation* at coding tasks.
 2. Make near SOTA implementation possible on local models on MacBook M5 base hardware at 30+ Tok/s.

Ultimatley, I believe both of these will happen within 2 years.  The question is:

 1. Is GRAM a good solution?
 2. Can it happen even sooner?

## Reasoning

Yan LeCun states both that:

 1. LLMs are a dead end because they can't understand the consequences of their actions before they act.
 2. LLMs are specifically great where language IS the substrate of knowledge (coding & math).

GRAM does something *somewhat* tangential to LeCun's World Model JEPA, in that it explores many paths and picks the best one.

## The Biggest Problems LLMs have in Coding

LLMs are good at getting something to *sort of* work.

The problem is their implementations are *sloppy*, or overly complex, have bad architecture.

## How GRAM *might* help

The goal of this model is to score solutions based on how sloppy they are based on a number of CodeQL static analysis / code health metrics.

GRAM can explore many paths simultaneously and chose the least sloppy working path, not just the a path that works.

That is the goal, time will tell if it works.

## How to test it

Qwen2.5-Coder-3B is not particularly good at implementation - especially compared to fronteir models like Claude Opus 4.7.

Qwen2.5-Coder-3B is *highly* unlikely to match frontier model performance on non-trivial implementation tasks.

However, if GRAM is a viable solution to significantly improving performance, we should be able to easily see that on a Qwen2.5 model quickly and cheaply.

**The goal:** get Qwen2.5-Coder-3B to outperform a 7B model on a mix of implementation tasks (and ideally better than 13B).

## The Real Solution

If the Qwen results are successful, we should be able to get Phi 3.8B MoE to run locally on MacBook M5s at 30+ Tok/s.

If the test is successful, it is *realistic* to belive a model Phi 3.8B MoE size could perform as well as Opus for implementation, and for context sizes <32k tokens (implementation tasks), it should be able to run smoothly on a MacBook M5 base hardware.

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
 3. 400 synthetic feature requests by deleting functions, classes, files and telling the model to fix it.
 4. 400 synthetic trivial bugs introduced via mutant tests
 5. 100 real bugs from CLEAR.
    
For each of these:

 * We will have DeepSeek v4 Flash generate possible *working* solutions - they will *likely* be sloppier than the true implementation (these will be the alternative paths to train GRAM).
 * We will save DeepSeek's tool calling, etc, to improve tool calling in a more powerful model later, if this method turns out to be viable.
