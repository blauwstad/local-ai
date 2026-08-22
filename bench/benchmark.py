#!/usr/bin/env python3
"""
Benchmark the local MLX engine through the containerized gateway.

Measures, per prompt category (chat / code / math):
  TTFT       - time to first streamed token (prefill-dominated)
  decode t/s - completion tokens / (total - ttft)   <- the number people quote
  e2e  t/s   - completion tokens / total elapsed

Streaming is used so TTFT and decode are separable. Each config is run
`--trials` times and the MEDIAN is reported, matching mlx-dspark's method.
"""
import argparse, json, os, statistics, sys, time
import httpx

PROMPTS = {
    "chat": "Explain how rainbows form, in three short paragraphs.",
    "code": "Write a Python function that does an iterative binary search over a sorted list, with docstring and edge-case handling.",
    "math": "A train leaves at 60 km/h. Another leaves 90 minutes later at 100 km/h on the same track. Work through, step by step, where and when the second catches the first.",
}


def run_once(client, base, model, prompt, max_tokens, temperature):
    body = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": temperature,
        "stream": True,
        "stream_options": {"include_usage": True},
    }
    t0 = time.perf_counter()
    ttft = None
    completion = 0
    usage = None
    text = []

    with client.stream("POST", f"{base}/chat/completions", json=body) as r:
        r.raise_for_status()
        for line in r.iter_lines():
            if not line or not line.startswith("data: "):
                continue
            data = line[6:]
            if data.strip() == "[DONE]":
                break
            try:
                chunk = json.loads(data)
            except json.JSONDecodeError:
                continue
            if chunk.get("usage"):
                usage = chunk["usage"]
            for ch in chunk.get("choices", []):
                piece = (ch.get("delta") or {}).get("content") or ""
                # reasoning models stream thinking separately; count it, it's real work
                piece += (ch.get("delta") or {}).get("reasoning_content") or ""
                if piece:
                    if ttft is None:
                        ttft = time.perf_counter() - t0
                    completion += 1
                    text.append(piece)
    total = time.perf_counter() - t0

    # Prefer server-reported token counts; fall back to streamed chunk count.
    if usage and usage.get("completion_tokens"):
        completion = usage["completion_tokens"]
    if ttft is None:
        ttft = total
    decode_window = max(total - ttft, 1e-6)
    return {
        "ttft": ttft,
        "total": total,
        "completion_tokens": completion,
        "decode_tps": completion / decode_window,
        "e2e_tps": completion / total,
        "prompt_tokens": (usage or {}).get("prompt_tokens"),
        "sample": "".join(text)[:160],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", default=os.environ.get("BASE_URL", "http://gateway:8080/v1"))
    ap.add_argument("--model", default=os.environ.get("MODEL", "qwen3.8-27b"))
    ap.add_argument("--trials", type=int, default=3)
    ap.add_argument("--max-tokens", type=int, default=200)
    ap.add_argument("--temperature", type=float, default=0.0)
    ap.add_argument("--label", default="run")
    ap.add_argument("--out", default="/results/bench.json")
    args = ap.parse_args()

    client = httpx.Client(timeout=httpx.Timeout(3600.0, connect=30.0))

    # Warm the engine: first call pays model load + this machine's draft-cap
    # calibration (~5s, cached by mlx-dspark). Never include it in medians.
    print(f"[warmup] {args.base_url} model={args.model}", flush=True)
    try:
        w = run_once(client, args.base_url, args.model, "Say OK.", 16, 0.0)
        print(f"[warmup] ok  ttft={w['ttft']:.2f}s  {w['completion_tokens']} tok", flush=True)
    except Exception as e:
        print(f"[warmup] FAILED: {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(1)

    results = {}
    for name, prompt in PROMPTS.items():
        runs = []
        for i in range(args.trials):
            r = run_once(client, args.base_url, args.model, prompt,
                         args.max_tokens, args.temperature)
            runs.append(r)
            print(f"  {name} trial{i+1}: {r['decode_tps']:6.2f} tok/s decode | "
                  f"ttft {r['ttft']*1000:7.1f} ms | {r['completion_tokens']} tok", flush=True)
        med = lambda k: statistics.median(x[k] for x in runs)
        results[name] = {
            "decode_tps": med("decode_tps"),
            "e2e_tps": med("e2e_tps"),
            "ttft_ms": med("ttft") * 1000,
            "completion_tokens": med("completion_tokens"),
            "prompt_tokens": runs[0]["prompt_tokens"],
            "trials": runs,
        }
        print(f"  {name} MEDIAN: {results[name]['decode_tps']:.2f} tok/s decode, "
              f"ttft {results[name]['ttft_ms']:.0f} ms\n", flush=True)

    decode_vals = [v["decode_tps"] for v in results.values()]
    summary = {
        "label": args.label,
        "model": args.model,
        "base_url": args.base_url,
        "trials": args.trials,
        "max_tokens": args.max_tokens,
        "temperature": args.temperature,
        "per_prompt": results,
        "mean_decode_tps": statistics.mean(decode_vals),
    }

    print("=" * 62)
    print(f"{args.label}: mean decode {summary['mean_decode_tps']:.2f} tok/s")
    for k, v in results.items():
        print(f"  {k:5s} {v['decode_tps']:6.2f} tok/s   ttft {v['ttft_ms']:7.1f} ms")
    print("=" * 62)

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    prev = []
    if os.path.exists(args.out):
        try:
            prev = json.load(open(args.out))
        except Exception:
            prev = []
    if not isinstance(prev, list):
        prev = [prev]
    prev.append(summary)
    json.dump(prev, open(args.out, "w"), indent=2)
    print(f"appended -> {args.out}")


if __name__ == "__main__":
    main()
