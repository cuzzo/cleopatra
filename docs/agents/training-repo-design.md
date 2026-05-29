# Training Repo Structure & Task Decomposition Strategy

## The Problem

We have:
- **Pre-squash branches** with 10–50 individual commits that build toward a feature
- **Squashed commits on master** that collapse all that work into one commit
- Each pre-squash commit touches 1–5 functions in 1–3 files

We need to turn each pre-squash sequence into multiple well-scoped training tasks,
each with:
- A clear **ideal final state** (what the model should produce)
- The **intermediate steps** (pre-squash commits that led there)
- A **context variant** set (26 ways to present the surrounding code)
- A **path variant** set (21 ways to implement it, from buggy to ideal)

## Repo Structure

### Training Git Repo

```
~/cleopatra/training/
  .git/                              # Bare repo holds all decomposed versions
  tasks/                             # Symlinks or checkouts of task branches
  
  Branches:
    squashed/<original-sha>          # Reference: the original squashed commit
    decomposed/<original-sha>/task-1 # Task: break out functions A, B → ideal states
    decomposed/<original-sha>/task-2 # Task: break out function C → ideal state
    decomposed/<original-sha>/task-3 # Task: break out class X → ideal state
    ...
```

### Branch Structure for Each Task

Each task branch encodes the **evolution** of that code section:

```
decomposed/a1b2c3d4/task-1: Add UNION type support to MIR checker
  │
  ├── Commit 1: Add UnionType variant to Type enum
  ├── Commit 2: Add union_resolve! helper
  ├── Commit 3: Wire union resolution into type_check pass
  ├── Commit 4: Add test for union type-checking
  └── tip: The ideal final state for this task
```

Each commit is the **ground truth** — a real intermediate state from the
pre-squash history. The tip is the **reference solution** the model should learn
to produce.

## How to Decompose a Squashed Commit Sequence

### Step 1: Identify function-level changes

Given a sequence of pre-squash commits C₁, C₂, ..., Cₙ:

```ruby
# For each commit Cᵢ:
#   Extract which functions changed from Cᵢ⁻¹ to Cᵢ
#   Classify each change as:
#     :material      — function body/logic changed (high value for training)
#     :signature     — only the type signature changed (medium value)
#     :callsite      — calls to other functions updated (low value, skip for now)
#     :noise         — whitespace, comments, formatting (skip)
```

### Step 2: Group changes into tasks

Group by scope level:

```
Level 1: Single function refactor (ideal for 3B model)
  - A function whose body materially changed
  - Context: just that function + its direct type deps
  - Output: 1 function, ~20 lines

Level 2: Multi-function class refactor (ideal for 14B model)
  - 2–4 functions in the same class that changed together
  - Context: the class + relevant type deps
  - Output: 2–4 functions, ~80 lines

Level 3: Cross-class/module refactor (ideal for 30B model)
  - Functions across 2–3 classes that form a coherent feature
  - Context: the classes + their type deps
  - Output: 5–15 functions, ~200 lines
```

### Step 3: Filter out callsite-only changes

A refactor that changes `foo(x)` → `foo(x, default: true)` at 50 callsites
is **not a good training example** for the 3B model. The context would be
huge (50 callsites) and the change is trivial.

**Skip**: Any commit where >80% of the diff is callsite updates.
**Keep**: Any commit where the majority of the diff is material function changes.

For callsite-heavy refactors, create a **separate task type** later (lower priority).

### Step 4: Create the task branch

```ruby
def create_task_branch(pre_squash_commits, task_functions)
  # 1. Find the function's state before the first relevant commit
  # 2. Create a new branch starting from that state
  # 3. Cherry-pick or replay each commit that touches the task functions
  # 4. The tip is the ideal final state
  # 5. Tag the tip as "ideal"
end
```

## How to Store Everything Without Cluttering the Working Directory

### Option 1: Separate bare repo (recommended)

```
~/cleopatra/training.git/     # Bare git repo with all decomposed branches
~/cleopatra/data/training/    # JSON training examples (generated from branches)
```

The bare repo stores only git objects — no working tree. You can:
- List all tasks: `git --git-dir=training.git branch -l`
- Check out a task: `git --git-dir=training.git --work-tree=/tmp/task checkout decomposed/<sha>/task-1`
- Generate data: `git --git-dir=training.git log --oneline decomposed/<sha>/task-1`

Total size: tiny (~1MB for 1000 tasks with 10 commits each = 10,000 commits)

### Option 2: Git notes on original repo

```
~/cheat.git/                  # Original repo
  git notes add <sha> -m "task-1: functions A, B changed"
  git notes add <sha> -m "task-2: function C changed"
```

More discoverable but mixes concerns.

### Option 3: JSON manifest (simplest, most portable)

The JSON already stores the decomposed data. Git branches are reconstructed
on-demand from the JSON. No need to manage a separate repo until you need it.

## Creating the Training Repo

```bash
# Initialize bare repo
cd ~/cleopatra
git init --bare training.git

# Add a branch for each decomposed task
# (This is what the decompose.rb script will do)

# To verify tasks:
git --git-dir=training.git branch -l
# Output:
#   decomposed/291cb776c/task-1
#   decomposed/291cb776c/task-2
#   decomposed/291cb776c/task-3
#   ...
```

The decompose.rb script will:
1. Read triage results → identify pre-squash sequences
2. For each sequence, identify material function changes
3. Group into tasks by scope level (1-function, 2-4 function, 5-15 function)
4. Create a branch in `training.git` for each task
5. Each branch has the ideal state at its tip
6. Each intermediate commit is a step toward that ideal

## Priority for v0

1. **Single-function refactors** from SIMP + typed: commits
2. **Multi-function class refactors** from feature commits  
3. **Bug fix sequences** from fix chains (e.g., parking-lot loom 17-commit chain)
4. **Cross-file feature implementations** from backup branch sequences
5. Callsite-heavy refactors (later, lower priority)

The user's comment about functions vs callsites is spot on: we want
**material** changes (function logic, signatures) not **mechanical** changes
(callsite updates), because mechanical changes are easy and boring for the
model. The interesting training signal is in the material changes.