# Vathbot - Project Memory

## What this is
Elixir OTP application that collects Polymarket crypto Up/Down prediction market data for later analysis. Streams orderbook data and multi-asset crypto prices via WebSockets, writes JSONL during recording, and normalizes to Parquet on market close (compatible with the `~/code/transform` DuckDB pipeline).

## Architecture

### Modules
- `Vathbot.Application` — top-level supervisor (EventSupervisor, MarketFinalizer, CryptoPriceRecorder, Scheduler)
- `Vathbot.Scheduler` — every 60s discovers upcoming 5m/15m events in a configurable window (default 5 min), spawns MarketRecorders via EventSupervisor
- `Vathbot.MarketDiscovery` — multi-asset slug generation (`{asset}-updown-{5m|15m}-{epoch}`), Gamma API fetch; `:updown_assets` config
- `Vathbot.MarketDiscovery.BTCUpDownEvent` — discovered event struct (historical name; `:asset` field holds ticker)
- `Vathbot.EventSupervisor` — DynamicSupervisor managing per-event MarketRecorder processes
- `Vathbot.MarketRecorder` — per-event WebSocket client on Market Channel, records to JSONL, forwards to ModelRunner
- `Vathbot.CryptoPriceRecorder` — RTDS WebSocket for Binance + Chainlink prices for all `:updown_assets`
- `Vathbot.RtdsSymbols` — asset → RTDS symbol map
- `Vathbot.DataWriter` — JSONL append, path helpers, `data_root` config
- `Vathbot.MarketNormalize` — JSONL → normalized tick rows + metadata
- `Vathbot.BtcNormalize` — JSONL → daily price parquet (multi-symbol; dedupe on event_ts+source+symbol)
- `Vathbot.ParquetWriter` — ZSTD parquet via Explorer
- `Vathbot.MarketFinalizer` — queued async JSONL → parquet on market close (`Coordinator`, concurrency 2)
- `Vathbot.BtcParquetCompactor` — every 5 min compacts today/yesterday price JSONL → parquet
- `Vathbot.ModelRunner` / `CopyWithBias` — per-event model; live orders gated by `:live_trading_assets`

### Config
```elixir
config :vathbot, :updown_assets, ~w(btc eth sol xrp doge bnb hype)
config :vathbot, :discovery_window_minutes, 5
config :vathbot, :live_trading_assets, ~w(btc)   # record all; trade BTC only
```

### Data layout
```
data/
  btc_prices/                    # multi-asset rows (symbol column distinguishes)
    binance_YYYY-MM-DD.jsonl
    chainlink_YYYY-MM-DD.jsonl
    binance_YYYY-MM-DD.parquet
    chainlink_YYYY-MM-DD.parquet
  5m/
    {asset}-updown-5m-{epoch}/
      event.json
      market.jsonl               # ephemeral; removed after parquet
      metadata.parquet
      ticks.parquet
  15m/
    {asset}-updown-15m-{epoch}/
      ...
```

**Ticks schema:** `event_ts`, `received_ts`, `slug`, `outcome`, `best_bid`, `best_ask`, `mid`, `spread`, `event_type`

**Price schema:** `event_ts`, `received_ts`, `source`, `symbol`, `price` (deduped on event_ts+source+symbol)

### Event slug pattern
- 5-minute: `{asset}-updown-5m-{unix_epoch}` (300s alignment)
- 15-minute: `{asset}-updown-15m-{unix_epoch}` (900s alignment)
- Example: `https://polymarket.com/event/eth-updown-5m-1778673300`

### Tools
```bash
mix vathbot.scan_updown_markets          # probe Gamma for asset tickers
mix vathbot.backfill_parquet             # parquet for existing JSONL dirs
mix run --no-halt                        # daemon
mix test
```

## Transform pipeline
Point transform at vathbot `data/` and run from **validate** onward:

```bash
cd ~/code/transform && python run_pipeline.py --skip-btc --skip-markets
```

## Dependencies
- `websockex ~> 0.4`, `jason ~> 1.4`, `explorer ~> 0.10`
- Uses built-in `:httpc` (Elixir 1.14 compatibility)

## What's next
- Port transform validate/duckdb_build/copy_model to Elixir
- ModelRunner supervision / backpressure
- Per-asset live trading windows
