#!/usr/bin/env python3
"""LLMmap fingerprint — non-interactive driver for CI.

LLMmap ships main_interactive.py, which prints a query and waits for a human to
paste the app's response back. This does the same thing against an
OpenAI-compatible endpoint so it can run unattended.

LLMmap asks 8 fixed probe questions ("What LLM are you exactly?", a couple of
prompt injections, a refusal test), embeds the answers, and compares that
signature against templates for 52 known models.

Env:
  TARGET_URL    chat/completions endpoint            (required)
  TARGET_MODEL  model name to send in the request body
  LLMMAP_MODEL  path to pretrained model dir         (default ./data/pretrained_models/default)
  OUT           where to write JSON results          (default llmmap-results.json)
"""
import json
import os
import sys
import urllib.request

# Python puts THIS file's directory on sys.path, not the working directory — so
# importing LLMmap fails when the script lives outside the cloned repo, which is
# exactly how it is used here. Run from the LLMmap checkout and this finds it.
sys.path.insert(0, os.getcwd())

import torch  # noqa: E402

# LLMmap's pretrained model.pt was saved on a Mac, so its tensors carry an "mps"
# device tag. Their load_LLMmap() calls torch.load() without map_location, which
# then fails on any non-Apple machine with:
#   RuntimeError: Storage device not recognized: mps
# Default every load to CPU rather than patching their repo in place.
_torch_load = torch.load


def _load_on_cpu(*args, **kwargs):
    kwargs.setdefault("map_location", "cpu")
    return _torch_load(*args, **kwargs)


torch.load = _load_on_cpu

from LLMmap.inference import load_LLMmap  # noqa: E402

URL = os.environ["TARGET_URL"]
MODEL = os.environ.get("TARGET_MODEL", "")
MODEL_DIR = os.environ.get("LLMMAP_MODEL", "./data/pretrained_models/default")
OUT = os.environ.get("OUT", "llmmap-results.json")


def ask(query):
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role": "user", "content": query}],
        # LLMmap truncates at 650 chars; 100 tokens is what its own probes use.
        "max_tokens": 100,
    }).encode()
    req = urllib.request.Request(
        URL, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=180) as r:
        return json.load(r)["choices"][0]["message"]["content"]


inf = load_LLMmap(MODEL_DIR)

answers = []
for i, q in enumerate(inf.queries, 1):
    print(f"[{i}/{len(inf.queries)}] probing...", flush=True)
    answers.append(ask(q))

distances = inf(answers)
inf.print_result(distances)

# Rank every known model so the result is diffable between runs, not just
# printed. Lower distance = closer match.
ranked = sorted(
    ({"model": inf.label_map[i], "distance": float(d)}
     for i, d in enumerate(distances)),
    key=lambda r: r["distance"],
)

with open(OUT, "w") as f:
    json.dump({
        "target_url": URL,
        "target_model": MODEL,
        "closest_match": ranked[0]["model"],
        "closest_distance": ranked[0]["distance"],
        "ranking": ranked,
    }, f, indent=2)

print(f"\nClosest known model: {ranked[0]['model']} "
      f"(distance {ranked[0]['distance']:.4f})")
print(f"Wrote {OUT}")
