#!/usr/bin/env python3
"""Measure llama-server throughput at a given context size.

The two numbers that matter for an agent loop are TTFT and decode rate:

  TTFT    -- time to first token, dominated by prefill. A cold turn prefill the
             whole prompt; a warm turn reuses the cached KV prefix and only
             prefills the delta. Warm TTFT is what every turn after the first
             costs, so it is the number that predicts how the agent feels.
  decode  -- steady-state generation rate, bandwidth-bound.

Deliberately not reported: a single blended tok/s figure. The counter in an app
shows generation speed only, ignores prefill, and can overstate throughput by an
order of magnitude at long context.

Usage:
    ./benchmark.py --tokens 8000
    ./benchmark.py --tokens 32000
"""

import argparse
import json
import time
import urllib.request
import uuid

FILLER = "def compute_checksum(data, salt):\n    return sum(b ^ salt for b in data)\n"


def post(url, payload, timeout=1800):
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def tokenize(url, text, timeout=300):
    return post(f"{url}/tokenize", {"content": text}, timeout=timeout)["tokens"]


def build_prompt(url, target_tokens, max_tokens):
    """Build a prompt of exactly target_tokens, measured not estimated.

    Guessing a chars-per-token ratio overshoots badly enough to trip the
    context limit, so count real tokens via /tokenize and trim until it fits.
    """
    # A unique nonce at the very front guarantees this prompt shares no prefix
    # with the previous benchmark run, so the "cold" number is genuinely cold
    # rather than silently served from the slot's retained KV cache.
    nonce = f"session-{int(time.time() * 1000)}-{uuid.uuid4().hex}\n"
    header = "Here is a module. Reply with one short sentence.\n\n"

    body = FILLER * max(1, (target_tokens * 4) // len(FILLER))
    text = nonce + header + body
    tokens = tokenize(url, text)

    # Trim by characters; each token is at least ~3 chars here, so removing
    # 3 chars per excess token cannot overshoot. Converges in a few passes.
    for _ in range(32):
        excess = len(tokens) - target_tokens
        if excess <= 0:
            break
        text = text[: max(len(nonce), len(text) - excess * 3)]
        tokens = tokenize(url, text)

    return text, len(tokens)


def report(label, data, wall):
    t = data.get("timings", {})
    pn = t.get("prompt_n", 0)
    gen = t.get("predicted_n", 0)
    draft_n = t.get("draft_n", 0)
    accepted = t.get("draft_n_accepted", 0)

    # TTFT is what an agent turn actually costs before the user sees anything,
    # and prefill dominates it. Report it directly rather than hiding it inside
    # a blended tok/s figure, which is meaningless when generation is short.
    ttft = t.get("prompt_ms", 0) / 1000
    if t.get("cache_n"):
        print(f"  cache   : {t['cache_n']} prompt tokens reused from KV")
    if pn:
        print(f"  prefill : {pn:>6} tok in {ttft:>6.1f}s "
              f"= {t.get('prompt_per_second', 0):>7.1f} tok/s")
    print(f"  TTFT    : {ttft:.1f}s to first token")
    print(f"  decode  : {gen:>6} tok in {t.get('predicted_ms', 0) / 1000:>6.1f}s "
          f"= {t.get('predicted_per_second', 0):>7.1f} tok/s")
    if draft_n:
        print(f"  MTP     : {accepted}/{draft_n} drafts accepted "
              f"({100.0 * accepted / draft_n:.0f}%)")
    print(f"  total   : {wall:.1f}s wall-clock")
    print(f"  {label}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8080")
    ap.add_argument("--model", default="qwen3.6-35b-a3b")
    ap.add_argument("--tokens", type=int, default=8000,
                    help="approximate prompt size (~4 chars/token)")
    ap.add_argument("--max-tokens", type=int, default=128)
    ap.add_argument("--thinking", action="store_true",
                    help="leave thinking enabled (default: disabled)")
    args = ap.parse_args()

    prompt, prompt_tokens = build_prompt(args.url, args.tokens, args.max_tokens)

    base = {
        "model": args.model,
        "max_tokens": args.max_tokens,
        "temperature": 0.2,
        "stream": False,
        "chat_template_kwargs": {"enable_thinking": args.thinking},
    }

    print(f"\n=== {prompt_tokens} token prompt, thinking="
          f"{'on' if args.thinking else 'off'}, "
          f"max_tokens={args.max_tokens} ===")

    print("\n[1] COLD turn (full prefill)")
    payload = dict(base, messages=[{"role": "user", "content": prompt}])
    t0 = time.time()
    data = post(f"{args.url}/v1/chat/completions", payload)
    wall = time.time() - t0
    report("cold turn complete", data, wall)

    print("\n[2] WARM turn (same conversation + short follow-up)")
    msgs = payload["messages"] + [
        {"role": "assistant", "content": "Acknowledged."},
        {"role": "user", "content": "Now reply with exactly: OK"},
    ]
    payload2 = dict(base, messages=msgs, max_tokens=16)
    t0 = time.time()
    data2 = post(f"{args.url}/v1/chat/completions", payload2)
    wall2 = time.time() - t0
    report("warm turn complete", data2, wall2)
    print()


if __name__ == "__main__":
    main()
