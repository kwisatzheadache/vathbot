# pybuy — Polymarket order script

Self-contained script for placing buy and sell orders on Polymarket **CLOB V2** via `py-clob-client-v2`.

## Setup

```bash
cd pybuy
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
cp .env.example secrets.env
# Edit secrets.env with your credentials (use a dedicated bot wallet)
python manage_secrets.py encrypt secrets.env secrets.env.enc
rm -f secrets.env .env
```

The encrypted file `secrets.env.enc` is local-only (chmod 600, gitignored). Plaintext `.env` is no longer read at runtime.

### Required environment variables

| Variable | Description |
|----------|-------------|
| `POLYMARKET_PRIVATE_KEY` | Wallet private key |
| `POLYMARKET_FUNDER` | Proxy/funder address |
| `POLYMARKET_SIGNATURE_TYPE` | Signature type (`1` for proxy wallet) |

When invoked from vathbot with live trading enabled, these are passed via subprocess environment after password unlock. For standalone CLI use, provide `--secrets-file` or set the variables in your shell.

## Buy signal

A buy signal has four fields:

| Field | Description |
|-------|-------------|
| `slug` | Market slug (e.g. `btc-updown-5m-1710000000`) |
| `outcome` | `Up`, `Down`, `Yes`, or `No` |
| `amount` | USD to spend |
| `price` | Limit price per share (0–1) |

Share size is computed as `amount / price`.

## Order types

- **FOK (default)** — Fill-or-kill. The full order must fill immediately or it is cancelled.
- **FAK (`--fak`)** — Fill-and-kill. Fills whatever is available at or better than your limit price and cancels the rest.

Both modes use **limit orders** at the price you specify.

## Usage

### Buy (CLI flags)

```bash
python place_order.py --secrets-file secrets.env.enc buy \
  --slug btc-updown-5m-1710000000 \
  --outcome Up \
  --amount 1.00 \
  --price 0.50
```

### Buy (JSON signal)

```bash
python place_order.py --secrets-file secrets.env.enc \
  buy --signal '{"slug":"btc-updown-5m-1710000000","outcome":"Up","amount":1.0,"price":0.50}'
```

### Buy with fill-and-kill

```bash
python place_order.py --secrets-file secrets.env.enc \
  buy --slug my-market-slug --outcome Yes --amount 5.0 --price 0.42 --fak
```

### Sell (limit)

```bash
python place_order.py --secrets-file secrets.env.enc sell \
  --slug btc-updown-5m-1710000000 \
  --outcome Up \
  --shares 2.0 \
  --price 0.55
```

### Sell (market — hits best bid)

```bash
python place_order.py --secrets-file secrets.env.enc sell \
  --slug btc-updown-5m-1710000000 \
  --outcome Up \
  --shares 2.0
```

### Dry run

Dry run does not require credentials or a password:

```bash
python place_order.py buy --slug my-slug --outcome Up --amount 1.0 --price 0.50 --dry-run
```

### Options

| Flag | Description |
|------|-------------|
| `--secrets-file PATH` | Password-encrypted credentials file |
| `--env-file PATH` | Plaintext credentials (requires `--allow-plaintext`) |
| `--allow-plaintext` | Allow unsafe plaintext env file loading |
| `--log-file PATH` | JSONL response log (default: `pybuy/orders.jsonl`) |
| `--fak` | Use fill-and-kill instead of fill-or-kill |
| `--dry-run` | Plan the order without posting |
| `-v` | Verbose / debug logging |

## Secrets management

```bash
python manage_secrets.py encrypt secrets.env secrets.env.enc
python manage_secrets.py decrypt secrets.env.enc   # prints to stdout
python manage_secrets.py verify secrets.env.enc    # checks password only
```

## Trade history

```bash
python trade_history.py --secrets-file secrets.env.enc
python trade_history.py --all --secrets-file secrets.env.enc --csv
```

## Response log

Every buy or sell appends one JSON line to `orders.jsonl`:

```json
{
  "timestamp": "2026-05-24T12:00:00+00:00",
  "action": "buy",
  "slug": "btc-updown-5m-1710000000",
  "outcome": "Up",
  "success": true,
  "order_type": "FOK",
  "request": {"slug": "...", "amount_usd": 1.0, "price": 0.5, "size_shares": 2.0, "mode": "FOK"},
  "response": {"success": true, "takingAmount": "2", "makingAmount": "1"},
  "error": null
}
```

Exit code is `0` on success, `1` on failure.

## Programmatic use

```python
import os
from place_order import BuySignal, buy, sell, ensure_credentials

os.environ["POLYMARKET_PRIVATE_KEY"] = "..."
os.environ["POLYMARKET_FUNDER"] = "..."
os.environ["POLYMARKET_SIGNATURE_TYPE"] = "2"
ensure_credentials()

signal = BuySignal(slug="my-slug", outcome="Up", amount=1.0, price=0.50)
record = buy(signal)  # FOK limit buy

record = sell("my-slug", "Up", shares=2.0, price=0.55)  # FOK limit sell
record = sell("my-slug", "Up", shares=2.0)              # FOK market sell
```

## Notes

- Uses **CLOB V2** via `py-clob-client-v2` (the legacy `py-clob-client` package returns `order_version_mismatch`).
- Slugs are resolved via `https://gamma-api.polymarket.com/markets?slug=...`.
- Orders are posted to `https://clob.polymarket.com`.
- FOK/FAK buys use the market-order path (minimum ~$1 notional on the CLOB).
- Limit prices must match the market tick size (typically `$0.01` or `$0.001`).
- Real orders spend real USDC. Use `--dry-run` first to validate inputs.
