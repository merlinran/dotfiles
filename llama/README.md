# llama

Headless local LLM inference for Pi and other OpenAI-compatible clients, served
by [llama.cpp](https://github.com/ggml-org/llama.cpp) on Apple Silicon.

Primary use: an offline/zero-marginal-cost coding agent. It is **not** a
replacement for frontier hosted models on hard multi-file work — treat it as a
capable junior dev for well-scoped tasks.

## Hardware envelope

MacBook Pro 16" M1 Max — 10 CPU / 32 GPU cores, 64 GB unified, ~400 GB/s.

Two facts drive every decision here:

- **Decode is bandwidth-bound.** `tok/s ≈ 400 GB/s ÷ bytes read per token`.
  A Mixture-of-Experts model with ~3B active reads ~2 GB/token and is ~4-5x
  faster than a dense model of the same size. This is why the model choice is
  MoE-only.
- **Prefill dominates agent latency.** An agent loop re-sends the whole
  conversation each turn. Prefill runs at roughly 900 tok/s for this class of
  model, so a 32K context is ~35s *if computed from scratch*. Everything in the
  server config exists to avoid recomputing it — see prefix caching below.

## Model

`Qwen3.6-35B-A3B`, unsloth dynamic `UD-Q5_K_XL` (27.2 GB), from
`unsloth/Qwen3.6-35B-A3B-MTP-GGUF`.

35B total / ~3B active MoE. Chosen over the larger `Qwen3-Coder-Next`
(80B-A3B) despite it being bigger, because Coder-Next is half a generation older
and loses on every agentic metric:

| Benchmark | Qwen3-Coder-Next (80B-A3B) | **Qwen3.6-35B-A3B** |
|---|---|---|
| SWE-bench Verified | 70.6% | **73.4%** |
| SWE-bench Pro | 44.3% | **49.5%** |
| Terminal-Bench 2.0 | 36.2% | **51.5%** |

5-bit rather than 4-bit is deliberate: quantization error compounds over long
multi-turn tool-calling trajectories, which is exactly the workload here. If you
want more speed, `UD-Q4_K_XL` (22.9 GB) is ~19% faster to decode and ~4 GB
faster to download.

The `-MTP-GGUF` repo variant is used so the extra prediction heads are present,
which is what makes `--spec-type draft-mtp` do anything.

### Memory budget

| | GB |
|---|---|
| Total unified | 64 |
| Reserved for macOS + Xcode/Android builds | ~16 |
| Available for model + KV | ~48 |
| Weights (Q5_K_XL) | 27.2 |
| KV pool, 5 x 128K tokens, q8_0 | ~17 |
| Compute buffers | ~1-2 |

Measured with the current config (5 slots x 128K, unified KV, cache-ram 12288):

| | GB |
|---|---|
| llama-server resident, idle after load | **34.4** |
| Wired (GPU weights + committed KV pool) | **44.2** |
| Readily available (free + inactive + purgeable + speculative) | **13.1** |

The KV pool is committed at load, not grown as contexts fill. Startup logs
`--kv-unified-per-slot: sizing KV pool to n_parallel * kv_unified_per_slot =
5 * 131072 = 655360`, and wired was **44.6 GB at idle and 44.6 GB under a 5-way
concurrent load** — flat. So filling contexts does not move the needle; slot
count is what costs.

Cost is ~2.8 GB of available memory per slot:

| `-np` | Available |
|---|---|
| 2 | 21.6 GB (measured) |
| 3 | ~18.8 GB (interpolated) |
| 4 | ~16.0 GB (interpolated) |
| 5 | 13.1 GB (measured) |

At 5 slots, 13 GB available is workable alongside Xcode/Android builds but is
thinner than the ~16 GB this setup otherwise targets. Drop to 4 if builds start
swapping.

Note `ps -o rss` overstates the process: it counts the 27 GB mmap'd GGUF as
resident (`footprint -p <pid>` reports ~6 GB phys_footprint). The wired figure is
the one that constrains you, because `-ngl 999` puts the weights in
non-evictable GPU memory.

## Measured results

M1 Max 32-core, macOS 26.7.1, llama.cpp 0.5.0 (build 11146), `UD-Q5_K_XL`
(27.16 GB, ~26-30 GB resident).

| Context | Cold prefill | Cold TTFT | Warm prefill | Warm TTFT | Decode |
|---|---|---|---|---|---|
| 8.8K | 742 tok/s | 11.8s | 27 tok (8772 cached) | 0.4s | 39-82 tok/s |
| 31K | 581 tok/s | 53.3s | 27 tok (31008 cached) | 0.6s | 25-76 tok/s |
| 40K | 516 tok/s | 77.5s | 27 tok (40008 cached) | 0.9s | 24-90 tok/s |
| 110K | 290 tok/s | 382s | 16-23 tok | 1.3-3.8s | - |

MTP draft acceptance measured 58-100%, typically ~80-97% on natural text.

Note how cold prefill degrades with context: 742 tok/s at 8K down to 290 tok/s at
110K, because attention cost grows with sequence length. A cold 110K prompt costs
over six minutes. Warm turns stay at 1-4s regardless. Long context is affordable
**only** because the prefix stays cached.

**The warm column is the whole point.** A cold 31K prompt costs 53 seconds; every
turn after it costs about half a second, because only the delta is prefilled.

Verified against a real Pi agent session (~10K token context). Server log:

```
slot get_availabl: selected slot by LCP similarity, f_sim_best = 0.996
slot print_timing: prompt eval time = 244.85 ms / 34 tokens (7.20 ms/token)
slot      release: stop processing: n_tokens = 10119
```

34 tokens prefilled out of a 10,119-token context. Note that this is the
difference between a usable local agent and an unusable one, and it depends
entirely on the prompt prefix staying stable.

Reproduce with:

```sh
llama-restart                  # clear KV so the cold number is honest
./llama/benchmark.py --tokens 31000
```

### Diagnosing it yourself

The server log records the reuse decision for every request. This one-liner
shows, for the last requests, how much was prefilled versus reused and whether
the slot matched by prefix or fell back to LRU:

```sh
python3 - <<'EOF'
import re
log = open('/Users/dev/.local/state/llama/server.err.log', errors='replace').read().splitlines()
sel = None
for line in log:
    m = re.search(r'selected slot by (LCP similarity, f_sim_best = [\d.]+|LRU)', line)
    if m:
        sel = m.group(1)
    m = re.search(r'task (\d+) \| prompt eval time =\s*[\d.]+ ms /\s*(\d+) tokens', line)
    if m and sel:
        print(f"{sel:<42} prefilled={int(m.group(2)):>7}")
        sel = None
EOF
```

How to read it — the **prefilled count is the signal, not `f_sim`**. A middling
`f_sim` just means the context grew since the last turn, which is normal:

- small prefilled (tens to a few hundred) → reuse working. The turn cost only
  the new tokens, whatever `f_sim` says.
- prefilled ≈ the whole context → no reuse. Something changed before the end of
  the prompt, or the server restarted (`LRU` with `t_last = -1`).

Real examples from this machine, same server, same model:

```
LCP similarity, f_sim_best = 0.521   prefilled=   719    <- fine, append-only turn
LCP similarity, f_sim_best = 0.785   prefilled= 25501    <- bad, content shifted
LCP similarity, f_sim_best = 1.000   prefilled=     4    <- perfect
```

### Verified: `pi-timestamp` does not break the cache

An earlier concern was that an extension injecting a timestamp into early
context would change the prefix every turn and force a full 53s re-prefill.
`@hk_net/pi-timestamp` was checked and is safe: it hooks `agent_start` /
`ui_prompt_start` / `ui_prompt_end` for UI status lines only. Per its README,
and confirmed in source, nothing is appended to the session, so it never enters
LLM context.

Still, any extension that *does* write into the system prompt or early history
will silently destroy this. The server log is the place to check: a healthy
turn shows a small `prompt eval` token count, not the full context size.

### Thinking control

Qwen3.6 is a thinking model and defaults to **thinking on**, which puts output
in `reasoning_content` and can leave `content` empty if the token budget runs
out mid-thought. The server honours `chat_template_kwargs.enable_thinking`:

```sh
curl -s localhost:8080/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.6-35b-a3b",
       "messages":[{"role":"user","content":"hi"}],
       "chat_template_kwargs":{"enable_thinking":false}}'
```

Pi drives this through the `compat.thinkingFormat: "qwen-chat-template"` setting
in `models.json.symlink`, so `--thinking off|low|high` works as usual.

## Raft Computer

Raft agents that run on this machine use **Pi's engine**, and read the **same
config file**. No extra wiring is needed: `raft-computer`'s runtime resolves its
agent dir to `~/.pi/agent` (`raft-computer-sea-runtime` ships
`piConfig: null`, so it falls back to the `.pi` default), and it advertises the
resulting models to the Raft server. The `llama-local` provider therefore shows
up in Raft's model picker on its own.

Confirmed in `~/.slock/computer/servers/<id>/runner.log`:

```
[pi-driver] detect_models agentDir=/Users/dev/.pi/agent available=203 -> 204
[pi-driver] runtime_lifecycle {"kind":"model_resolved",
  "requestedModel":"qwen3.6-35b-a3b", "providerId":"llama-local",
  "configSource":"local_pi_config"}
[pi-driver] create_session resolved=llama-local/qwen3.6-35b-a3b
```

To use it: start the server (`llama-start`), then pick
`qwen3.6-35b-a3b` / `llama-local` as the model for an agent in Raft.

### Two failure modes to know about

**1. Context, not wiring, is the real limit.** A first attempt failed with:

```
compaction phase=failed reason=threshold failureReason=input_too_large
send_error: request (528190 tokens) exceeds the available context size
```

The wiring was fine — the request was 528K tokens. That agent had resumed a
10MB session dating to Sept 15, and its accumulated history alone exceeded any
local context. **Neither 128K nor any setting on this machine will fit a 528K
token request** (that is roughly 300GB of KV). Long-lived Raft sessions must be
reset or archived before a local model can drive them.

**2. Concurrency, timeouts, and queueing.** Raft runs up to 5 agents
concurrently (`max=5`; `active=3` observed) and its provider timeout defaults to
the SDK value. The server runs **5 slots**, matching Raft's limit, so agents
normally do not queue at all.

That combination originally produced repeated failures:

```
"providerId":"custom","phase":"failed"        <- no httpStatus
stop: cancel task, id_task = 39014              <- client gave up
```

One agent held the only slot while generating 1956 tokens at ~17.7 tok/s (110s),
every other agent queued past the timeout, retried, and hit the same wall. With
`deepseek` returning `httpStatus: 200` at the same moments, it was clearly
local-only.

Two fixes, both needed:

- **Slots** raised progressively as the bottleneck moved. 5 now, matching
  Raft's `max=5`.
- **Timeouts** in `~/.pi/agent/settings.json` — see
  [`pi-settings.timeouts.json`](./pi-settings.timeouts.json). `raft-computer`
  resolves its agent dir to `~/.pi/agent`, so Raft agents read this file too.
  `retry.provider.timeoutMs` 30 min covers a cold 128K prefill (~380s) plus
  queueing; `httpIdleTimeoutMs` is disabled because a long prefill streams
  *nothing*, so the 5-minute idle default could kill valid work mid-prefill.

Sizing note: raising `-np` alone is not the fix. `llama-server` splits `-c`
across slots, so `-np 4 -c 131072` would give 32K each. `--kv-unified` is what
makes multiple full-context slots possible, with the pool sized
`n_parallel * --kv-unified-per-slot`.

Verified: 3 concurrent requests completed in 155s total — the *slowest* request,
not the sum (366s). Two slots are observable processing simultaneously, with zero
client cancels.

### Slots cost memory, not speed

Measured with only `-np` varied, 3 runs each:

| `-np` | Single-stream decode | Resident | MTP draft acceptance |
|---|---|---|---|
| 1 | 70.7 tok/s | 27.3 GB | 0.71698 |
| 2 | 69.4 tok/s | 29.1 GB | 0.71698 |
| 3 | 68.9 tok/s | 30.8 GB | 0.71698 |

1 to 3 slots costs **2.5%** on a single agent, and speculative decoding is
untouched (identical draft acceptance at every slot count — worth checking,
because batching can disable speculation). So raise `--parallel` freely until
memory says stop. Do not raise it expecting per-agent speed.

What *does* degrade is simultaneous use. Aggregate decode is flat because it is
memory-bandwidth-bound — the weights get read once per token regardless of batch
size — so per-stream decode divides by concurrency:

| Concurrent streams | Aggregate | Per-stream |
|---|---|---|
| 1 | 68.3 tok/s | 68.3 tok/s |
| 2 | 81.9 tok/s | 41.0 tok/s |
| 3 | 76.0 tok/s | 25.3 tok/s |

Prefill is the opposite and matters more, since agent turns are prefill-heavy:
it is compute-bound and batches well (~2.3-3x aggregate at n=3).

Verified at 5 slots: 5 concurrent ~24K-token requests all ran without queueing,
total wall 224s — the slowest request, not the sum (883s) — with 0 client cancels.

### Local-only tool guidance (`local-web-guidance.ts`)

The local model intermittently confuses the two index spaces of
`get_search_content`. It wants the content of an individual source and passes
that as `queryIndex`, which indexes only *the user's 2-3 search queries*.
Observed in a real session:

```
web_search { queries: [q1, q2, q3] }  -> responseId, 30 sources
  get_search_content { queryIndex: 3 }  -> out of range (valid 0-2)
  get_search_content { queryIndex: 8 }  -> out of range
  get_search_content { queryIndex: 9 }  -> out of range
  fetch_content { url }                 -> recovers
```

The tool's own guidance is correct (it says "repeat with queryIndex 1 through
2") and its error messages are excellent, so this is a **model limitation, not a
tool bug**. Hosted models do not make this mistake. Note also that `urlIndex`
and `url` are only valid for `type === "fetch"` responseIds, never for search.

`home/pi/agent/extensions/local-web-guidance.ts` appends a short clarification
(~255 tokens) via `before_agent_start`, but **only when `ctx.model.provider` is
`llama-local`**. Verified: `APPEND` for llama-local, `skip` for cursor and
google.

Putting the same text in `~/.pi/agent/APPEND_SYSTEM.md` also fixes it, but that
taxes every request of every model — including hosted ones that never make the
error. Scoping is the whole point.

Two implementation notes worth keeping:

- Use `ctx.model` inside `before_agent_start`. Tracking the `model_select` event
  instead **silently fails for non-interactive runs** (`-p`): that event never
  fires, the provider stays unknown, and the extension becomes a no-op. This was
  caught by instrumentation, not by reading the docs.
- `PI_LOCAL_GUIDANCE_DEBUG=<path>` logs each decision (append/skip plus the
  provider it saw), which is how the scoping above was verified.

### Pi config and `.gitignore`

`home/pi/agent/` holds `models.json` and this extension. `.gitignore` excludes
`home/pi/*` — Pi's own state (sessions, auth, npm cache) churns constantly and
should not be committed — then re-includes exactly these two files.

The parent pattern deliberately is **not** `home/pi/`: git cannot re-include a
file whose parent directory is excluded, so the directory form would silently
keep these untracked.

### `SHELL_ENV_TIMEOUT`

`raft-computer status` warns that the Computer service could not import the
shell environment. This does **not** affect the model wiring, because
`models.json` is a file at a fixed path rather than an environment variable. It
does mean tools on your interactive `PATH` may be invisible to Raft agents.

## Serving

Single-model mode via launchd (`local.llama-server`), not the multi-model
router. Rationale: deterministic startup, no interactive load step, and swapping
models is a one-line plist edit. Router mode is the alternative if you want to
load/unload from inside Pi's `/llama` TUI.

Config lives in [`llama-server.plist`](./llama-server.plist);
`install.sh` substitutes `__HOME__`/`__MODEL__` and installs it to
`~/Library/LaunchAgents/`.

### Key server flags

| Flag | Why |
|---|---|
| `-ngl 999` | Offload every layer to the GPU. |
| `-fa on` | Flash attention — required for the KV savings to be real. |
| `--parallel 5` | Matches Raft's concurrent-agent limit so agents rarely queue. Costs ~2.8 GB available memory per slot, and essentially no speed. |
| `--kv-unified` | One shared KV pool across slots. Without it, `-c` is split per slot and each agent gets only `131072/n_parallel`. |
| `--kv-unified-per-slot 131072` | Full 128K per agent. Pool = `n_parallel * this`. |
| `--cache-ram 12288` | RAM budget for non-resident slot states. Must exceed one prompt state (~9.3 GB at 128K) or reuse silently breaks. |
| `--slot-save-path` | Where `llama-save`/`llama-restore` put slot KV state. `llama-stop`/`llama-start` call them. See "Warm start" below. |
| `--cache-reuse 256` | Intended to reuse KV chunks when the prefix shifts. **Measured no benefit** in shift/insertion tests; see below. |
| `-ctk q8_0 -ctv q8_0` | Halves KV memory at negligible quality cost. |
| `--spec-type draft-mtp --spec-draft-n-max 2` | MTP speculative decoding, ~28-59% faster generation. |

### Prefix caching: the whole game, and its hard limit

`llama-server` reuses the longest common prefix of a conversation per slot. With
`-np 1`, each turn only prefills *the delta* — new tool output and your message —
instead of the full context.

**It is strictly a prefix cache, not a content cache.** Reuse works only when the
new prompt is the old prompt plus an appended suffix. A single token changed
anywhere before the end invalidates everything after it, no matter how much of
the rest is identical. Measured, on ~18K and ~76K contexts:

| Change vs previous request | Prefilled | Wall |
|---|---|---|
| none (identical prompt) | 4 / 18034 | 0.4s |
| append to the last message | 519 / 21931 | 3.4s |
| **one token changed early in the system prompt** | **18034 / 18034** | **25.5s** |
| **line inserted mid-prompt** | **18019 / 18019** | **25.4s** |
| **content shifted position (sliding window)** | **25501 / 25501** | **41.3s** |

So "90% of the prefix is the same" buys nothing if the difference is early. This
is easy to misdiagnose as caching being broken; it is not, it is the definition
of a prefix cache.

`--cache-reuse 256` was tried and made **no measurable difference** in any of the
shift/insertion cases above. It is retained in the plist but should not be relied
on.

What this means practically:

- Anything volatile near the top of the prompt — a date, timestamp, session id,
  cwd, git status, or a dynamically generated tool list — costs a **full
  re-prefill on every single turn**. Audit what Pi puts first.
- Put volatile content in the *last* user message if you need it. That case still
  reuses (519 tokens prefilled out of 21,931).
- Pi's context compaction rewrites history, so it always forces a full re-prefill.
  This is inherent, and it is why the Raft compaction failure was so expensive.
- `@hk_net/pi-timestamp` was checked and is safe (display-only, never enters the
  prompt) — see below.

**High Power Mode** (System Settings → Battery) roughly doubles prompt
processing on this machine. Prefill is the dominant cost, so for agent work it is
worth leaving on while plugged in.

### Warm start: slot state across restarts

Prefix caching is per-process, so a restart normally throws away every warm
context. At 90–100K tokens a cold prefill is ~380s. Worse, concurrent cold
prefills starve each other: with a single 98K prefill in flight, a trivial
request measured **2.1 tok/s** and a 14s TTFT. The log bears this out — **84% of
all prompt tokens went to just 127 requests >10K**, while 87.5% of turns were
already warm (<1K prefilled).

So slot KV is saved to disk around restarts, with `--slot-save-path` pointing at
`~/.local/state/llama/slots` (in the plist):

- **`llama-stop`** saves every idle, non-empty slot to `slot-<id>.bin` *before*
  `launchctl bootout`, while the server is still up. Busy slots are skipped, so
  a save can never stall a stop. `llama-restart` calls `llama-stop` first, so
  both manual restarts and `brew upgrade llama.cpp` save.
- **`llama-start`** restores the files after `/health` comes up.
- `llama-save` / `llama-restore` do either half by hand.

There is deliberately **no wrapper process**. One was tried first: a script that
trapped SIGTERM to save, then ran the server. It fought launchd — launchd
SIGKILLed it mid-save after its ~20s default (orphaning `llama-server`), and
with `ExitTimeOut` raised, llama-server received launchd's group SIGTERM *and*
the wrapper's forwarded one, aborting in ggml-metal teardown
(`GGML_ASSERT([rsets->data count] == 0)`). Saving explicitly before `bootout`
is simpler and has neither problem.

The trade-off: a **reboot or logout cold-starts**, because launchd stops the job
without running `llama-stop`. Reboots are rare, so this is accepted; if it ever
matters, a periodic saver job is the way to cover it.

Measured disk cost is modest: ~11–19 KB/token, so ~1.5–2.4 GB for a full 128K
slot, not the ~9 GB of the in-RAM prompt cache entry.

#### It does not actually work on this model yet (upstream bug)

This is the important caveat, verified on this machine, not assumed:

`Qwen3.6-35B-A3B` is a **hybrid SSM + attention** model (`qwen35moe`: the GGUF
carries `ssm.state_size`, `ssm.conv_kernel`, `ssm.group_count`, and
`full_attention_interval = 4`). A recurrent state cannot be rewound, so reuse
across a prefix boundary requires a **context checkpoint**, not just the KV.
llama-server's on-disk save/restore does not persist `slot.prompt.checkpoints`,
and restore clears them, so the next request always hits "forcing full prompt
re-processing due to lack of cache data".

Measured here after a real restart + restore:

```
slot get_availabl: selected slot by LCP similarity, f_sim_best = 1.000, f_keep = 1.000
slot print_timing: prompt eval time = 9783.92 ms / 7632 tokens   <- full re-prefill
slot print_timing: graphs reused = 0
```

Restore reports success and `/slots` shows the right token count, but `cache_n`
is **0** — the feature is worth exactly nothing on this model. This is upstream
[ggml-org/llama.cpp#25913](https://github.com/ggml-org/llama.cpp/issues/25913),
reported against this same model and confirmed by ~10 users across backends. The
fix is [PR #26004](https://github.com/ggml-org/llama.cpp/pull/26004) (open at the
time of writing), which appends checkpoint blobs to the save file.

Homebrew's `llama.cpp 0.5.0` (build 11146, commit `7fe450e9`) does **not**
contain it. Until the server is built from a commit that does, the save is dead
weight (~seconds and a few GB per stop): drop `--slot-save-path` from the plist,
or do not call `llama-save`, to skip it. The plumbing is kept so it starts
working the moment llama.cpp is upgraded.

Other caveats, independent of the above:

- Save files are backend-specific and only portable within a build; a
  llama.cpp upgrade that changes the format makes restore fail, which is logged
  and treated as a cold start.
- A hard power loss skips the save. Use `llama-save` before that if it matters.

## Commands

Defined in `llama.zsh`, available in every new shell:

```
llama-start      # load the agent, restore slot state, wait until ready
llama-stop       # save slot state, then fully unload (frees ~27GB)
llama-restart    # save, reload, restore; use after editing the plist
llama-status     # pid, resident memory, loaded models, saved state
llama-save       # snapshot slot KV state now
llama-restore    # restore slot KV state now
llama-logs       # tail the server log
llama-ctx        # dump /props (context and server settings)
```

`./llama/benchmark.py --tokens N` measures cold and warm throughput at a given
context size. Use it after changing the quant, context size, or server flags.

`llama-stop` uses `launchctl bootout` rather than killing the process, because
`KeepAlive` would otherwise immediately restart it.

### Pi

```
pil              # pi against the local model (see functions/pil)
```

`pil` refuses to start if the server is down. Provider config is in
`home/pi/agent/models.json.symlink` → `~/.pi/agent/models.json`. The global
`defaultProvider` in `settings.json` is deliberately left on `cursor`, so local
inference is always an explicit choice.

## Swapping models

1. Download it (see below).
2. Point `__MODEL__` at the new path in `llama-server.plist`, and update
   `--alias` so the id Pi sees changes too.
3. Update the `id` in `models.json.symlink` to match the alias.
4. `llama-restart`.

## Downloading models

Measure first — the fastest source depends entirely on your network path, and
**a proxy config that helps Hugging Face can cripple a domestic `.cn` domain.**
Measured on this machine:

| Source | Throughput |
|---|---|
| huggingface.co via proxy | 5.25 MB/s |
| hf-mirror.com | 4.76 MB/s |
| modelscope.cn **via proxy** | 1.58 MB/s |
| modelscope.cn **direct** | 4.30 MB/s |
| modelscope.cn direct, 4 connections | ~6.1 MB/s |

ModelScope is the practical choice, but it must bypass the proxy **and** use
parallel connections. The `modelscope` CLI does neither well — it degraded from
3.2 MB/s to 0.32 MB/s (a 23-hour ETA) on this machine. [`fetch-model.sh`](./fetch-model.sh)
uses aria2 to do it properly:

```sh
./llama/fetch-model.sh
```

It is resumable, so re-running continues an interrupted download. Equivalently,
by hand:

```sh
env -u all_proxy -u http_proxy -u https_proxy \
  aria2c -x 8 -s 8 -k 32M -c --file-allocation=none \
    -d "$HOME/models/Qwen3.6-35B-A3B-MTP" \
    -o Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf \
    "https://www.modelscope.cn/models/unsloth/Qwen3.6-35B-A3B-MTP-GGUF/resolve/master/Qwen3.6-35B-A3B-UD-Q5_K_XL.gguf"
```

To use a different quant or mirror, override `MODEL_FILE` / `MIRROR`.

Do **not** rely on Pi's `/llama` downloader or `llama-server -hf` here: those use
llama.cpp's own HTTP client, which does not honour `all_proxy` the way `curl`
does, and they run inside the launchd environment where your shell's proxy
settings are absent anyway.

## Reproducing from scratch

```sh
brew bundle              # installs llama.cpp and aria2
script/uv-tools          # installs the huggingface-hub and modelscope-hub CLIs
./llama/fetch-model.sh   # downloads the GGUF (~27GB)
script/bootstrap         # symlinks models.json + the local-only extension
./llama/install.sh       # writes and bootstraps the launchd agent
llama-start
pil
```

One manual step: merge [`pi-settings.timeouts.json`](./pi-settings.timeouts.json)
into `~/.pi/agent/settings.json`. It is not symlinked because `~/.pi/agent/settings.json`
is deliberately untracked (Pi rewrites it constantly — see the `home/pi/` rule in
`.gitignore`). Without those two timeout keys, local Raft agents fail the moment
they have to queue for a slot.

### Known-unfixable

The 528K- and 273K-token sessions that keep retrying cannot work here. A 528K
token request needs roughly 300 GB of KV cache. Those agents need their session
history reset or archived; no server setting will accommodate them.
