# Getting Started with Cleopatra

## Prerequisites

```bash
cd ~/cleopatra
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip

# Core ML
pip install torch --index-url https://download.pytorch.org/whl/cpu

# HuggingFace
pip install transformers datasets accelerate huggingface-hub 'huggingface_hub[hf_transfer]'

# Utilities
pip install sentencepiece protobuf tqdm numpy deepspeed einops

# Dataset generation
pip install "smart_open[s3]" boto3
```

## Download the base model

```bash
huggingface-cli download Qwen/Qwen2.5-Coder-3B --local-dir ./models/Qwen2.5-Coder-3B
```

## Generate training data

The training pipeline mines the [CLEAR](https://github.com/ahn-ml/clear) codebase
at `~/cheat` for 1300 training examples across 5 categories. See [PLAN.md](./PLAN.md)
for the full strategy.

```bash
# Activate venv
source .venv/bin/activate

# Run the data generation pipeline
python3 generate_training_data.py
```

> **Note:** The Stack v2, OpenCodeReasoning-2, TACO, and CodeNet datasets
> are no longer needed. The CLEAR codebase alone provides all training data
> through commit mining, mutation testing, and synthetic deletion.
> See [PLAN.md](./PLAN.md) for details.

## Verify

```bash
python3 -c "import torch; import transformers; import datasets; print('OK')"
ls ./models/Qwen2.5-Coder-3B/
```

## Package Reference

| Package | Purpose |
|---|---|
| `torch` | Tensor computation |
| `transformers` | Load Qwen2.5 model and tokenizer |
| `datasets` | HuggingFace dataset utilities |
| `accelerate` | Multi-device training |
| `huggingface-hub` | Download models from HuggingFace |
| `sentencepiece` | Qwen tokenizer backend |
| `einops` | Reshaping for MLA attention |
| `boto3` / `smart_open` | (Reserved for future Stack v2 use) |
