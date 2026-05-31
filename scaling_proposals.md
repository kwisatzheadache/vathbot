# Vathbot scaling proposals

Proposed changes discussed for scaling from BTC-only to 7 coins (each with 5m and 15m windows), plus finalizer reliability improvements.

## Context

Current architecture per event:

1. `Scheduler` discovers events and spawns recorders via `EventSupervisor`
2. `MarketRecorder` (WebSockex) connects to Polymarket WS, appends raw messages to `market.jsonl`, forwards to `ModelRunner`
3. On terminate, `MarketFinalizer` async-converts JSONL → `ticks.parquet` and deletes JSONL

At 7× scale (~2,688 events/day), the main pressure points are Gamma API discovery load and dropped finalizer jobs — not disk I/O bandwidth.

---

## 1. Shrink discovery window (70 min → 5 min)

### Current behavior

- `Scheduler` uses `@window_minutes 70`
- Every 60s, `MarketDiscovery.discover_upcoming/1` computes all slug timestamps in the forward window and **fetches every one from Gamma**
- Recorders spawn immediately when `active: true` and not closed — no separate "start N minutes before event" gate

### Proposed change

- Reduce `@window_minutes` to **5** (consider **7–10** as a safety margin if Gamma availability is flaky)
- Optionally split concerns later: narrow spawn window vs wider metadata prefetch (not needed initially)

### Expected impact

| Metric | 70 min window (7 coins) | 5 min window (7 coins) |
|--------|-------------------------|------------------------|
| Gamma API calls / cycle | ~140 | ~21 |
| Gamma API calls / minute | ~140 | ~21 |
| Peak concurrent recorders | ~130 | ~35 |
| Peak open JSONL files | ~130 | ~35 |

~85% reduction in Gamma API load.

### Tradeoffs

**Fine for trading:** `CopyWithBias` only evaluates books within 1s of event start (`@start_tolerance_ms 1_000`). Connecting ~5 min early is sufficient.

**Research tradeoff:** Lose pre-event orderbook history (data before ~T−5min). Acceptable for 5m/15m markets unless studying pre-open liquidity.

**Risks to validate:**

- Events must be discoverable and `active: true` on Gamma at least ~5 min before start
- 60s discovery interval is adequate with a 5-min window, but a failed fetch cycle matters more
- 15m events: only 1 slug per discovery cycle in a 5-min window (sufficient for next event only)

### Files to change

- `lib/vathbot/scheduler.ex` — `@window_minutes`
- `lib/vathbot/market_discovery.ex` — default arg / moduledoc
- `lib/vathbot/trade_markets.ex` — if it hardcodes `discover_upcoming(70)`
- `memory.md` — update architecture notes

---

## 2. MarketFinalizer: concurrency 2 + explicit queue

### Current behavior

- `Task.Supervisor` with `max_children: 1`
- On `:max_children`, logs a warning and returns `{:error, :max_children}` — **no retry, job is dropped**
- JSONL remains on disk until manual backfill (`mix vathbot.backfill_parquet`)

### Proposed change

1. Set `Task.Supervisor` `max_children` to **2** (trial; bump to 4 if queue backs up)
2. Add a **GenServer coordinator** that owns a pending queue
3. `finalize_market/2` enqueues `{slug, interval}` and returns `:ok` immediately (non-blocking)
4. Coordinator drains queue up to 2 concurrent tasks; on task completion, starts next job

### Coordinator design

```
MarketRecorder.terminate
  → MarketFinalizer.enqueue(slug, interval)
      → dedupe in pending set
      → drain up to 2 running tasks

Task completes (Task.Supervisor.async_nolink + ref/DOWN)
  → coordinator dequeues next job
```

**Required behaviors:**

- Enqueue always succeeds (no max queue size initially)
- Dedupe pending `{slug, interval}` pairs
- Drain on completion — start next queued job when a slot frees
- Idempotent `do_finalize/2` — if `ticks.parquet` exists and `market.jsonl` is gone, treat as `:ok`

### Expected load

Worst-case burst (7 coins, 5m + 15m close together): **~14 jobs** enqueued at once.

At concurrency 2 and ~1–5s per job: drain in ~7–35 seconds. Fine for an in-memory queue.

### Metrics to watch during trial

| Metric | Healthy | Red flag |
|--------|---------|----------|
| Queue depth | Usually 0; brief spikes ~10–14 at 5m boundaries | Sustained depth >20 |
| Time-to-parquet | Seconds after market close | JSONL still present minutes later |
| Task duration | Existing elapsed ms logs | Jobs consistently >30s |
| Failures | Occasional `:enoent` | Repeated errors for same slug |

Log periodically: `queue_depth`, `running`, `completed`, `failed`.

### Files to change

- `lib/vathbot/market_finalizer.ex` — coordinator GenServer + queue logic
- `lib/vathbot/application.ex` — add coordinator to supervision tree
- `test/vathbot/market_finalizer_test.exs` — queue/dedupe/concurrency tests

---

## 3. What we're NOT changing (for now)

### JSONL → Parquet pipeline

Keep JSONL as live write-ahead log; batch to Parquet on close. At 7× scale:

- Aggregate write rate stays low (~300 KB/s–5 MB/s peak)
- Per-message `File.write(..., [:append])` syscall chatter is the mild hot-path concern, not disk bandwidth
- Revisit async/buffered writes only if WS handler latency spikes in profiling

### Per-event directory layout

Keep `data/{5m|15m}/{slug}/` for now (~2,700 dirs/day). Revisit time-partitioned layout if retention exceeds ~1 year or listing/backups become painful.

### Other known gaps (out of scope for this proposal)

- `ModelRunner` not supervised — may orphan when recorder exits
- `GenServer.cast` to model has no backpressure
- Price feeds: `BtcPriceRecorder` is BTC-only; 6 new coins need a feed strategy

---

## Implementation order

1. **Finalizer queue** — fixes data loss bug; do first
2. **Discovery window shrink** — reduces API/concurrency load before adding coins
3. **Add remaining 6 coins** — after 1 and 2 are validated
4. **Monitor trial period** — queue depth, finalize latency, missed events

---

## Success criteria

- [x] No dropped finalizations (coordinator queue + concurrency 2)
- [x] Gamma API calls ≤ ~25/min at 7 coins with 5-min window
- [x] Peak concurrent recorders ≤ ~40 (5-min window)
- [x] Finalizer queue drains under burst (Coordinator + max 2 workers)
- [ ] Zero missed event spawns over 24h trial (spot-check against Polymarket schedule)

## Implemented (2026-05-31)

- Merged `feature/multi-asset-updown-discovery` — `:updown_assets`, `build_slugs/3`, `scan_updown_markets`
- `discovery_window_minutes` config (default 5)
- `MarketFinalizer.Coordinator` queue with concurrency 2
- `:live_trading_assets ~w(btc)` — record all, trade BTC only
- `CryptoPriceRecorder` + `RtdsSymbols` for 7-asset RTDS feeds
- `BtcNormalize` dedupe key includes `symbol`
