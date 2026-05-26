# Vathbot - Project Memory

## What this is
Elixir OTP application that collects Polymarket BTC Up/Down prediction market data for later analysis. Streams orderbook data and BTC prices via WebSockets, writes JSONL during recording, and normalizes to Parquet on market close (compatible with the `~/code/transform` DuckDB pipeline).

## Architecture

### Modules
- `Vathbot.Application` — top-level supervisor (EventSupervisor, MarketFinalizer tasks, BtcParquetCompactor, BtcPriceRecorder, Scheduler)
- `Vathbot.Scheduler` — every 60s discovers upcoming 5m/15m BTC events in a 70-min window, spawns MarketRecorders via EventSupervisor
- `Vathbot.MarketDiscovery` — computes event slugs from timestamp alignment, fetches details from Gamma API (`https://gamma-api.polymarket.com/events?slug=...`)
- `Vathbot.MarketDiscovery.BTCUpDownEvent` — struct for BTC up/down event data (slug, clob_token_ids, start/end times, price_to_beat, etc.)
- `Vathbot.EventSupervisor` — DynamicSupervisor managing per-event MarketRecorder processes
- `Vathbot.MarketRecorder` — per-event WebSocket client on Market Channel (`wss://ws-subscriptions-clob.polymarket.com/ws/market`), records to JSONL; writes `metadata.parquet` at start and schedules `ticks.parquet` on close
- `Vathbot.BtcPriceRecorder` — long-lived WebSocket client on RTDS (`wss://ws-live-data.polymarket.com`), subscribes to Binance btcusdt and Chainlink btc/usd feeds
- `Vathbot.DataWriter` — JSONL append, path helpers, `data_root` config
- `Vathbot.MarketNormalize` — JSONL → normalized tick rows + metadata (ports transform `ingest_markets`)
- `Vathbot.BtcNormalize` — JSONL → daily BTC parquet (ports transform `ingest_btc`)
- `Vathbot.ParquetWriter` — ZSTD parquet via Explorer
- `Vathbot.MarketFinalizer` — Task.Supervisor for async market close jobs
- `Vathbot.BtcParquetCompactor` — every 5 min compacts today/yesterday BTC JSONL → parquet
- `Vathbot.HTTP` — thin wrapper around `:httpc` with proper SSL config

### Data layout
```
data/
  btc_prices/
    binance_YYYY-MM-DD.jsonl
    chainlink_YYYY-MM-DD.jsonl
    binance_YYYY-MM-DD.parquet      # ZSTD, from JSONL compaction
    chainlink_YYYY-MM-DD.parquet
  5m/
    btc-updown-5m-{epoch}/
      event.json           # API metadata snapshot (debug)
      market.jsonl         # raw WS messages (live append)
      metadata.parquet     # slug, tokens, start/end, etc.
      ticks.parquet        # normalized book_snapshot + price_change rows
  15m/
    btc-updown-15m-{epoch}/
      event.json
      market.jsonl
      metadata.parquet
      ticks.parquet
```

**Ticks schema:** `event_ts`, `received_ts`, `slug`, `outcome` (Up/Down), `best_bid`, `best_ask`, `mid`, `spread`, `event_type`

**BTC schema:** `event_ts`, `received_ts`, `source`, `symbol`, `price` (deduped on event_ts+source)

### Event slug pattern
- 5-minute: `btc-updown-5m-{unix_epoch}` (epoch aligned to 300s boundaries)
- 15-minute: `btc-updown-15m-{unix_epoch}` (epoch aligned to 900s boundaries)
- Example URL: `https://polymarket.com/event/btc-updown-5m-1778673300`

## Transform pipeline
New recordings no longer require Python `ingest_markets` / `ingest_btc` for vathbot `data/`. Point transform at vathbot `data/` (or symlink) and run from **validate** onward:

```bash
cd ~/code/transform && python run_pipeline.py --skip-btc --skip-markets
```

Historical slugs (JSONL only): `mix vathbot.backfill_parquet`

## Dependencies
- `websockex ~> 0.4` — WebSocket client
- `jason ~> 1.4` — JSON
- `explorer ~> 0.10` — Parquet read/write (precompiled NIFs)
- Uses built-in `:httpc` (not Req) due to Elixir 1.14 compatibility constraint

## How to run
```bash
mix run --no-halt    # run as daemon
iex -S mix           # run with REPL
mix vathbot.backfill_parquet   # parquet for existing JSONL dirs (default: 1 slug at a time)
mix vathbot.backfill_parquet --concurrency 2   # only if RAM allows
mix test
```

## What's next
- Port transform `validate`, `duckdb_build`, `copy_model` to Elixir (long-term)
- Optional: drop JSONL once parquet-on-close is proven in production
