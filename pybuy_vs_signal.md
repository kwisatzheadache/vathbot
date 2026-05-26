# pybuy vs signals.jsonl — reconciliation report

Generated: 2026-05-24  
Sources: `data/signals.jsonl`, `pybuy/trade_history.py` (Polymarket data API, wallet activity since **2026-05-23 UTC**)

## Scope

This report compares what **copy_with_bias** logged in vathbot against what actually hit the wallet on-chain. Activity before **2026-05-23** is excluded from the wallet side (pre-vathbot manual/integration noise). All times UTC unless noted.

---

## Executive summary

| Metric | signals.jsonl | Wallet (May 24 BTC) |
|--------|---------------|---------------------|
| Events evaluated (`timestamp_match`) | 62 | — |
| Skipped (`no_signal`) | 27 | — |
| Buy signals (`trade`) | 35 | 25 BTC buys |
| Execution attempts (`execution`) | 31 | — |
| Fills (`execution success=true`) | **21** | ~21 vathbot buys (after 17:55) |
| Rejected (`execution success=false`) | **10** | 0 matching on-chain buys |
| Signals with no execution attempt | **4** | — |
| Sells | **0** | **2** (not vathbot) |

**Overall:** Once `VATHBOT_EXECUTE_TRADES=1` was enabled, the pipeline generally does the right thing — signal → pybuy FAK buy → wallet fill or explicit rejection log. Early-session gaps and non-vathbot wallet activity are the main sources of mismatch.

---

## Agreement (what matches)

### 1. Signal → execution → wallet chain works

For the 21 successful executions, wallet buys appear at the expected times with ~$1 notional, correct outcome (Up/Down), and fill prices close to the signal ask:

| Slug | Signal | Executed | Wallet ~price | Notes |
|------|--------|----------|---------------|-------|
| `btc-updown-5m-1779645300` | Up @ 0.53 | 0.530 | 0.53 @ 17:55 | First confirmed vathbot fill |
| `btc-updown-15m-1779645600` | Down @ 0.52 | 0.520 | 0.52 @ 18:00 | 5m sibling rejected; 15m filled |
| `btc-updown-5m-1779647700` | Up @ 0.53 | 0.530 | 0.53 @ 18:35 | |
| `btc-updown-5m-1779648300` | Up @ 0.54 | 0.540 | 0.54 @ 18:45 | |
| `btc-updown-5m-1779648600` | Up @ 0.55 | 0.550 | 0.55 @ 18:50 | |
| `btc-updown-5m-1779648900` | Up @ 0.53 | 0.520 | 0.52 @ 18:55 | 1¢ below signal |
| `btc-updown-15m-1779651000` | Up @ 0.54 | 0.530 | 0.53 @ 19:30 | |
| … | | | | (see full execution table below) |

Positions are held to **REDEEM** at resolution (no vathbot sells) — consistent with the Python backtest model.

### 2. Rejections correctly leave no wallet buy

All 10 failed executions have **no corresponding on-chain buy** for that slug/outcome. The `execution` log captures the FAK failure; wallet stays clean.

### 3. Model skip logic matches intent

27 `no_signal` events break down as:

| Reason | Count | Expected? |
|--------|-------|-----------|
| `insufficient_bias` (\|up_bid − 0.5\| < 0.02) | 23 | Yes — matches Python `copy_model.py` |
| `start_bias_tie` | 2 | Yes |
| `no_qualifying_outcome` (legacy ask/spread logic) | 2 | No — pre–Python-alignment model bug |

### 4. copy_with_bias does not sell

No sell path in `ModelRunner` / `OrderHandler`. Wallet sells on May 24 are from **integration test** or **manual pybuy**, not the live model.

---

## Divergence (what does not match)

### A. Signals logged but never sent to pybuy (4)

These `trade` rows have **no** `execution` entry — session was running **without** `VATHBOT_EXECUTE_TRADES=1`:

| Slug | Start | Outcome | Signal price |
|------|-------|---------|--------------|
| `btc-updown-5m-1779643800` | 17:30 | Up | 0.59 |
| `btc-updown-5m-1779644400` | 17:40 | Down | 0.52 |
| `btc-updown-5m-1779644700` | 17:45 | Down | 0.54 |
| `btc-updown-15m-1779644700` | 17:45 | Down | 0.52 |

**Action:** Always start live runs with `VATHBOT_EXECUTE_TRADES=1` if execution is intended.

### B. Wallet activity with no vathbot signal (pre-execution / non-vathbot)

| Time | Side | Market | Likely source |
|------|------|--------|---------------|
| 17:09 | BUY ×2 | 1:10–1:15 PM ET Up | Manual / early pybuy test |
| 17:11 | BUY + **SELL** | 1:15–1:30 PM ET Up | **Integration test** (`trade_integration_test.exs` buy-then-sell) |
| 17:51 | BUY + **SELL** | 1:55–2:00 PM ET Up | Manual round-trip before vathbot signal at 17:54 |

These explain wallet PnL on markets vathbot never signalled.

### C. Buy rejections (10) — all FAK no-match

Every rejection uses the same error:

```
no orders found to match with FAK order. FAK orders are partially filled or killed if no match is found.
```

| Slug | Outcome | Signal price | When |
|------|---------|--------------|------|
| `btc-updown-5m-1779645600` | Down | 0.53 | 18:00 |
| `btc-updown-5m-1779646800` | Down | 0.55 | 18:20 |
| `btc-updown-5m-1779650700` | Down | 0.56 | 19:25 |
| `btc-updown-5m-1779652200` | Down | 0.55 | 19:50 |
| `btc-updown-5m-1779654000` | Down | 0.53 | 20:20 |
| `btc-updown-15m-1779655500` | Down | 0.50 | 20:45 |
| `btc-updown-5m-1779655800` | Down | 0.57 | 20:50 |
| `btc-updown-15m-1779656400` | Up | 0.53 | 21:00 |
| `btc-updown-5m-1779657300` | Down | 0.54 | 21:15 |
| `btc-updown-5m-1779657600` | Down | 0.69 | 21:20 |

**Pattern:** 9/10 are Down signals; most occur when the book moved between signal snapshot and pybuy submission (~2–4s later). Signal uses best ask at event-start book; FAK limit is placed at that ask — if liquidity is gone, order is killed.

**Action items:**
- Log book age / delta at execution time
- Consider FOK vs FAK tradeoff, or refresh ask immediately before submit
- Retry once with updated book on FAK kill (careful with double-buy)

### D. Fill price significantly worse than signal (6)

Threshold: ≥ $0.02 or ≥ 5% slippage vs signal/intended price.

| Slug | Signal | Executed | Slippage | Notes |
|------|--------|----------|----------|-------|
| `btc-updown-5m-1779652800` | 0.54 | **0.28** | −48% | FAK swept deep book; ~$1 spent, 3.57 shares |
| `btc-updown-15m-1779652800` | 0.54 | **0.44** | −19% | Same event window, 15m market |
| `btc-updown-5m-1779654300` | 0.55 | **0.50** | −9% | |
| `btc-updown-5m-1779652500` | 0.54 | **0.50** | −7% | |
| `btc-updown-5m-1779653400` | 0.66 | **0.62** | −6% | |
| `btc-updown-5m-1779654600` | 0.68 | **0.64** | −6% | |

The **0.28 fill on `1779652800`** is the worst case: execution "succeeded" but at a price far from the model's decision ask. pybuy uses FAK market-style USD orders; average fill can be much worse than top-of-book when thin liquidity exists below the signal price.

**15 of 21** successful fills were within $0.01 of signal price (acceptable).

### E. Logging gaps

| Issue | Detail |
|-------|--------|
| Empty books on `trade` | All `trade` entries have `"books": []` — decision-time order book not persisted |
| Legacy `no_signal` | 2 events used old ask/spread logic before Python model alignment |
| `pybuy/orders.jsonl` | Only 1 dry-run entry; live orders not centrally logged there (execution details are in `signals.jsonl`) |

### F. Integration test creates real orders + sells

`test/vathbot/trade_integration_test.exs` runs a real **buy then sell** when `POLYMARKET_INTEGRATION=1`. This is **not** copy_with_bias behaviour and pollutes wallet history. The 17:11 sell matches this pattern.

---

## Full execution log (signals.jsonl)

| Logged (UTC) | Slug | Outcome | Signal | Intended | Executed | Success |
|--------------|------|---------|--------|----------|----------|---------|
| 17:55:02 | `…5300` 5m | Up | 0.53 | 0.53 | 0.530 | ✓ |
| 18:00:01 | `…5600` 5m | Down | 0.53 | 0.53 | — | ✗ FAK |
| 18:00:03 | `…5600` 15m | Down | 0.52 | 0.52 | 0.520 | ✓ |
| 18:15:08 | `…6500` 5m | Down | 0.55 | 0.55 | 0.540 | ✓ |
| 18:15:08 | `…6500` 15m | Down | 0.55 | 0.55 | 0.550 | ✓ |
| 18:20:04 | `…6800` 5m | Down | 0.55 | 0.55 | — | ✗ FAK |
| 18:35:04 | `…7700` 5m | Up | 0.53 | 0.53 | 0.530 | ✓ |
| 18:45:01 | `…8300` 5m | Up | 0.54 | 0.54 | 0.540 | ✓ |
| 18:50:01 | `…8600` 5m | Up | 0.55 | 0.55 | 0.550 | ✓ |
| 18:55:01 | `…8900` 5m | Up | 0.53 | 0.53 | 0.520 | ✓ |
| 19:25:01 | `…0700` 5m | Down | 0.56 | 0.56 | — | ✗ FAK |
| 19:30:01 | `…1000` 15m | Up | 0.54 | 0.54 | 0.530 | ✓ |
| 19:45:04 | `…1900` 5m | Down | 0.52 | 0.52 | 0.520 | ✓ |
| 19:45:06 | `…1900` 15m | Down | 0.52 | 0.52 | 0.520 | ✓ |
| 19:50:03 | `…2200` 5m | Down | 0.55 | 0.55 | — | ✗ FAK |
| 19:55:03 | `…2500` 5m | Down | 0.54 | 0.54 | 0.500 | ✓ (slip) |
| 20:00:05 | `…2800` 5m | Down | 0.54 | 0.54 | 0.280 | ✓ (large slip) |
| 20:00:06 | `…2800` 15m | Down | 0.54 | 0.54 | 0.440 | ✓ (slip) |
| 20:05:03 | `…3100` 5m | Down | 0.52 | 0.52 | 0.520 | ✓ |
| 20:10:05 | `…3400` 5m | Down | 0.66 | 0.66 | 0.620 | ✓ (slip) |
| 20:15:04 | `…3700` 5m | Up | 0.66 | 0.66 | 0.650 | ✓ |
| 20:20:04 | `…4000` 5m | Down | 0.53 | 0.53 | — | ✗ FAK |
| 20:25:04 | `…4300` 5m | Up | 0.55 | 0.55 | 0.500 | ✓ (slip) |
| 20:30:04 | `…4600` 5m | Down | 0.68 | 0.68 | 0.640 | ✓ (slip) |
| 20:45:04 | `…5500` 15m | Down | 0.50 | 0.50 | — | ✗ FAK |
| 20:50:03 | `…5800` 5m | Down | 0.57 | 0.57 | — | ✗ FAK |
| 20:55:02 | `…6100` 5m | Up | 0.54 | 0.54 | 0.540 | ✓ |
| 21:00:04 | `…6400` 15m | Up | 0.53 | 0.53 | — | ✗ FAK |
| 21:05:02 | `…6700` 5m | Down | 0.61 | 0.61 | 0.610 | ✓ |
| 21:15:01 | `…7300` 5m | Down | 0.54 | 0.54 | — | ✗ FAK |
| 21:20:03 | `…7600` 5m | Down | 0.69 | 0.69 | — | ✗ FAK |

---

## Wallet PnL (May 24 BTC only, since 2026-05-23 filter)

From `trade_history.py` filtered report:

- **~$25.83** invested across May 24 BTC Up/Down markets
- Mix of wins (redemptions > cost) and losses (especially 1:10–1:15 and 1:55 round-trips from non-vathbot activity)
- **No open BTC positions** at report time (all redeemed or closed)
- **2 sells** on May 24 — both non-vathbot

---

## Future work

### High priority

1. **Integration test: buy-only or dry-run** — stop selling positions the model is meant to hold; use `--dry-run` or a dedicated test wallet.
2. **FAK rejection handling** — 32% rejection rate (10/31); refresh book before submit or cap max slippage; log rejection with book snapshot.
3. **Slippage guard** — abort or warn when executed price deviates > $0.02 from signal (especially the 0.28 fill case).
4. **Persist books on `trade`** — fix empty `books: []` in signal log (ModelRunner should pass paired Up/Down books at decision time).

### Medium priority

5. **Unified order log** — append all pybuy invocations to `pybuy/orders.jsonl`, not just temp files in `/tmp`.
6. **Automated reconciliation script** — join `signals.jsonl` executions to `trade_history.py` output by slug + timestamp; flag orphans on either side.
7. **Remove legacy no_signal path** — confirm no remaining ask/spread logic after Python model alignment.

### Low priority

8. **Document `REPORT_SINCE_UTC`** in README — currently hard-coded to 2026-05-23 in `trade_history.py`.
9. **Separate signal vs execution latency metric** — track ms from `timestamp_match` to `execution.logged_at`.

---

## How to regenerate

```bash
# Wallet report (since 2026-05-23)
cd pybuy && venv/bin/python trade_history.py

# Full wallet history
cd pybuy && venv/bin/python trade_history.py --all

# Signal summary
grep '"kind"' data/signals.jsonl | sed 's/.*"kind": "//;s/".*//' | sort | uniq -c
```
