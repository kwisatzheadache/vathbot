"""
Fetch full trade + settlement history from the Polymarket data API and produce a PnL report.

By default, events before 2026-05-23 UTC are excluded (pre-vathbot wallet activity).

Usage:
    python trade_history.py --secrets-file secrets.env.enc
    python trade_history.py --all --secrets-file secrets.env.enc
    python trade_history.py --csv
"""
from __future__ import annotations

import argparse
import csv
import os
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

import requests
from py_clob_client_v2 import BalanceAllowanceParams, AssetType

from place_order import ensure_credentials, get_clob_client

DATA_API = "https://data-api.polymarket.com"


# Ignore wallet activity before vathbot live trading began.
REPORT_SINCE_UTC = datetime(2026, 5, 23, 0, 0, 0, tzinfo=timezone.utc)


def filter_events_since(events: list[dict], since: datetime) -> list[dict]:
    since_ts = int(since.timestamp())
    return [e for e in events if int(e.get("timestamp", 0)) >= since_ts]


def fetch_activity(funder: str) -> list[dict]:
    print("Fetching activity from Polymarket data API...", flush=True)
    all_events: list[dict] = []
    offset = 0
    while True:
        r = requests.get(
            f"{DATA_API}/activity",
            params={"user": funder, "limit": 100, "offset": offset},
            timeout=15,
        )
        r.raise_for_status()
        batch = r.json()
        if not batch:
            break
        all_events.extend(batch)
        if len(batch) < 100:
            break
        offset += 100
    trades = [e for e in all_events if e["type"] == "TRADE" and e["side"] == "BUY"]
    sells  = [e for e in all_events if e["type"] == "TRADE" and e["side"] == "SELL"]
    redeems = [e for e in all_events if e["type"] == "REDEEM"]
    print(f"  {len(trades)} buys  |  {len(sells)} sells  |  {len(redeems)} redemptions\n")
    return all_events


def fetch_open_positions(funder: str) -> dict[str, float]:
    """Return {conditionId.lower(): current_value_usd}."""
    r = requests.get(f"{DATA_API}/positions", params={"user": funder}, timeout=15)
    r.raise_for_status()
    result: dict[str, float] = {}
    for p in r.json():
        cid = p.get("conditionId", "").lower()
        val = float(p.get("currentValue", 0))
        result[cid] = result.get(cid, 0.0) + val
    return result


def fetch_usdc_balance() -> float:
    result = get_clob_client().get_balance_allowance(
        params=BalanceAllowanceParams(asset_type=AssetType.COLLATERAL)
    )
    return int(result.get("balance", 0)) / 1_000_000


def build_positions(events: list[dict], open_values: dict[str, float]) -> list[dict]:
    cost: dict[str, float] = defaultdict(float)
    proceeds: dict[str, float] = defaultdict(float)
    titles: dict[str, str] = {}
    last_ts: dict[str, int] = {}
    active_cids: set[str] = set()

    for e in events:
        cid = e.get("conditionId", "").lower()
        if not cid:
            continue
        active_cids.add(cid)
        titles[cid] = e.get("title", cid)
        ts = int(e.get("timestamp", 0))
        last_ts[cid] = max(last_ts.get(cid, 0), ts)

        usd = float(e.get("usdcSize", 0))
        if e["type"] == "TRADE" and e["side"] == "BUY":
            cost[cid] += usd
        elif e["type"] == "TRADE" and e["side"] == "SELL":
            proceeds[cid] += usd
        elif e["type"] == "REDEEM":
            proceeds[cid] += usd

    all_cids = active_cids | {cid for cid, v in open_values.items() if v > 0.01}
    rows = []
    for cid in all_cids:
        c = cost.get(cid, 0.0)
        p = proceeds.get(cid, 0.0)
        v = open_values.get(cid, 0.0)
        pnl = p + v - c
        status = "open" if v > 0.01 else "closed"
        rows.append(
            {
                "conditionId": cid,
                "title": titles.get(cid, cid),
                "cost": round(c, 4),
                "value": round(p + v, 4),   # proceeds (sold/redeemed) + current open value
                "pnl": round(pnl, 4),
                "status": status,
                "last_activity": datetime.fromtimestamp(
                    last_ts.get(cid, 0), tz=timezone.utc
                ).strftime("%Y-%m-%d"),
            }
        )
    rows.sort(key=lambda r: r["pnl"])
    return rows


def build_trade_log(events: list[dict]) -> list[dict]:
    rows = []
    for e in sorted(events, key=lambda x: x.get("timestamp", 0)):
        ts = int(e.get("timestamp", 0))
        rows.append(
            {
                "timestamp": datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
                "type": e["type"],
                "side": e.get("side", ""),
                "title": e.get("title", e.get("conditionId", ""))[:55],
                "outcome": e.get("outcome", ""),
                "size": float(e.get("size", 0)),
                "price": float(e.get("price", 0)),
                "usd": float(e.get("usdcSize", 0)),
                "tx": e.get("transactionHash", ""),
            }
        )
    return rows


def print_report(
    positions: list[dict], trade_log: list[dict], balance: float, *, period_label: str
) -> None:
    # ── Trade log ──────────────────────────────────────────────────────────
    print("=" * 115)
    print(f"TRADE HISTORY — REAL WALLET ({period_label})")
    print("=" * 115)
    print(f"{'Timestamp':17} {'Type':6} {'Side':4} {'Market':55} {'Outcome':22} {'Shares':>7} {'Price':>6} {'USD':>7}")
    print("-" * 115)
    for r in trade_log:
        print(
            f"{r['timestamp']:17} {r['type']:6} {r['side']:4} {r['title']:55}"
            f" {r['outcome'][:22]:22} {r['size']:>7.2f} {r['price']:>6.4f} {r['usd']:>7.4f}"
        )

    # ── Per-market PnL ─────────────────────────────────────────────────────
    print("\n" + "=" * 100)
    print("PnL SUMMARY — BY MARKET")
    print("=" * 100)
    print(f"{'Market':60} {'Cost':>8} {'Value':>8} {'PnL':>9}  {'Status':7} {'Last Activity'}")
    print("-" * 100)
    for p in positions:
        pnl_str = f"${p['pnl']:+.2f}"
        print(
            f"{p['title'][:60]:60}"
            f" ${p['cost']:>7.2f} ${p['value']:>7.2f} {pnl_str:>9}  {p['status']:7} {p['last_activity']}"
        )

    total_cost  = sum(p["cost"] for p in positions)
    total_value = sum(p["value"] for p in positions)
    total_open  = sum(p["value"] for p in positions if p["status"] == "open")
    total_pnl   = total_value - total_cost

    print("-" * 100)
    print(f"\n{'Total invested:':30} ${total_cost:.2f}")
    print(f"{'Total value out:':30} ${total_value:.2f}")
    print(f"{'Open position value:':30} ${total_open:.2f}")
    print(f"{'USDC cash balance:':30} ${balance:.2f}")
    print(f"{'Net PnL (realised + unrealised):':30} ${total_pnl:+.2f}")
    print(f"{'Total account value:':30} ${total_open + balance:.2f}")


def write_csv(trade_log: list[dict], path: str) -> None:
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=trade_log[0].keys())
        w.writeheader()
        w.writerows(trade_log)
    print(f"\nCSV written to {path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", action="store_true", help="Also write trade_history.csv")
    parser.add_argument(
        "--all",
        action="store_true",
        help="Include full wallet history (default: since 2026-05-23 UTC)",
    )
    parser.add_argument(
        "--secrets-file",
        type=Path,
        default=None,
        help="Password-encrypted credentials file (prompts for password)",
    )
    parser.add_argument(
        "--env-file",
        type=Path,
        default=None,
        help="Plaintext .env file (requires --allow-plaintext)",
    )
    parser.add_argument(
        "--allow-plaintext",
        action="store_true",
        help="Allow loading credentials from --env-file (unsafe)",
    )
    args = parser.parse_args()

    try:
        ensure_credentials(
            secrets_file=args.secrets_file,
            env_file=args.env_file,
            allow_plaintext=args.allow_plaintext,
        )
    except (FileNotFoundError, EnvironmentError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc

    funder = os.environ["POLYMARKET_FUNDER"]

    all_events = fetch_activity(funder)
    open_values = fetch_open_positions(funder)
    balance = fetch_usdc_balance()

    if args.all:
        events = all_events
        period_label = "all time"
    else:
        events = filter_events_since(all_events, REPORT_SINCE_UTC)
        period_label = f"since {REPORT_SINCE_UTC.strftime('%Y-%m-%d')} UTC"
        skipped = len(all_events) - len(events)
        print(
            f"Filtered to {len(events)} events since {REPORT_SINCE_UTC.date()} "
            f"({skipped} older events excluded). Use --all for full history.\n",
            flush=True,
        )

    # Only attribute open position value to markets touched in this period.
    if not args.all:
        active_cids = {e.get("conditionId", "").lower() for e in events} - {""}
        open_values = {cid: v for cid, v in open_values.items() if cid in active_cids}

    positions = build_positions(events, open_values)
    trade_log = build_trade_log(events)

    print_report(positions, trade_log, balance, period_label=period_label)

    if args.csv:
        if not trade_log:
            print("\nNo trades to write.")
        else:
            write_csv(trade_log, "trade_history.csv")


if __name__ == "__main__":
    main()
