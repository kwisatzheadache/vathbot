#!/usr/bin/env python3
"""
Standalone Polymarket CLOB order placement (CLOB V2).

Loads credentials from a .env file, resolves market slugs via the Gamma API,
and places limit buy/sell orders on the CLOB. Responses are appended to a JSONL log.

Usage:
    python place_order.py buy  --slug btc-updown-5m-123 --outcome Up --amount 1.0 --price 0.50
    python place_order.py sell --slug btc-updown-5m-123 --outcome Up --shares 2.0 --price 0.55
    python place_order.py buy  --signal '{"slug":"...","outcome":"Up","amount":1.0,"price":0.50}'
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path
from typing import Any, Literal

import requests
from dotenv import load_dotenv
from py_clob_client_v2 import (
    ClobClient,
    MarketOrderArgs,
    OrderArgs,
    OrderType,
    PartialCreateOrderOptions,
)
from py_clob_client_v2.order_utils.model import SideString

HOST = "https://clob.polymarket.com"
GAMMA_MARKETS = "https://gamma-api.polymarket.com/markets"
CHAIN_ID = 137

BUY = SideString.BUY
SELL = SideString.SELL

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_ENV_FILE = SCRIPT_DIR / ".env"
DEFAULT_LOG_FILE = SCRIPT_DIR / "orders.jsonl"

Outcome = Literal["Up", "Down", "Yes", "No"]
OrderMode = Literal["FOK", "FAK"]

log = logging.getLogger("place_order")


@dataclass
class BuySignal:
    slug: str
    outcome: str
    amount: float
    price: float

    def normalized_outcome(self) -> str:
        o = self.outcome.strip()
        if o.lower() in ("up", "down", "yes", "no"):
            return o[0].upper() + o[1:].lower()
        raise ValueError(f"Invalid outcome {self.outcome!r}; expected Up, Down, Yes, or No")


@dataclass
class OrderRecord:
    timestamp: str
    action: str
    slug: str
    outcome: str
    success: bool
    order_type: str
    request: dict[str, Any]
    response: dict[str, Any] | None
    error: str | None


_clob_client: ClobClient | None = None


def load_credentials(env_file: Path) -> None:
    if not env_file.is_file():
        raise FileNotFoundError(f"Env file not found: {env_file}")
    load_dotenv(env_file, override=True)
    for key in ("POLYMARKET_PRIVATE_KEY", "POLYMARKET_FUNDER", "POLYMARKET_SIGNATURE_TYPE"):
        if not os.environ.get(key):
            raise EnvironmentError(f"Missing required env var: {key}")


def get_clob_client() -> ClobClient:
    global _clob_client
    if _clob_client is None:
        key = os.environ["POLYMARKET_PRIVATE_KEY"]
        signature_type = int(os.environ["POLYMARKET_SIGNATURE_TYPE"])
        funder = os.environ["POLYMARKET_FUNDER"]

        bootstrap = ClobClient(
            HOST,
            chain_id=CHAIN_ID,
            key=key,
            signature_type=signature_type,
            funder=funder,
        )
        creds = bootstrap.create_or_derive_api_key()

        _clob_client = ClobClient(
            HOST,
            chain_id=CHAIN_ID,
            key=key,
            creds=creds,
            signature_type=signature_type,
            funder=funder,
        )
    return _clob_client


def _parse_jsonish(value: Any) -> list:
    if isinstance(value, str):
        return json.loads(value)
    return value


@lru_cache(maxsize=512)
def resolve_token_id(slug: str, outcome: str) -> str:
    """Resolve market slug + outcome name to a CLOB token ID."""
    r = requests.get(GAMMA_MARKETS, params={"slug": slug}, timeout=15)
    r.raise_for_status()
    markets = r.json()
    if not markets:
        raise ValueError(f"No market found for slug: {slug}")

    for market in markets:
        outcomes = _parse_jsonish(market.get("outcomes", []))
        token_ids = _parse_jsonish(market.get("clobTokenIds", []))
        if outcome in outcomes:
            return token_ids[outcomes.index(outcome)]

    raise ValueError(f"Outcome {outcome!r} not found for slug {slug!r}")


def _order_type(mode: OrderMode) -> OrderType:
    return OrderType.FAK if mode == "FAK" else OrderType.FOK


def _order_options(client: ClobClient, token_id: str) -> PartialCreateOrderOptions:
    return PartialCreateOrderOptions(
        tick_size=client.get_tick_size(token_id),
        neg_risk=client.get_neg_risk(token_id),
    )


def _as_dict(response: Any) -> dict[str, Any]:
    if response is None:
        return {}
    if isinstance(response, dict):
        return response
    if hasattr(response, "__dict__"):
        return dict(response.__dict__)
    return {"raw": str(response)}


def _post_limit_order(
    token_id: str,
    price: float,
    size: float,
    side: str,
    mode: OrderMode,
) -> dict[str, Any]:
    client = get_clob_client()
    order_type = _order_type(mode)
    response = client.create_and_post_order(
        OrderArgs(token_id=token_id, price=price, size=size, side=side),
        options=_order_options(client, token_id),
        order_type=order_type,
    )
    return _as_dict(response)


def _post_market_order(
    token_id: str,
    amount: float,
    side: str,
    mode: OrderMode,
    *,
    price: float | None = None,
) -> dict[str, Any]:
    client = get_clob_client()
    order_type = _order_type(mode)
    response = client.create_and_post_market_order(
        MarketOrderArgs(
            token_id=token_id,
            amount=amount,
            side=side,
            price=price or 0,
            order_type=order_type,
        ),
        options=_order_options(client, token_id),
        order_type=order_type,
    )
    return _as_dict(response)


def _book_bids(book: Any) -> list:
    if isinstance(book, dict):
        return book.get("bids") or []
    return getattr(book, "bids", None) or []


def _round_price(price: float, tick_size: str) -> float:
    tick = float(tick_size)
    decimals = max(0, len(tick_size.rstrip("0").split(".")[-1]) if "." in tick_size else 0)
    steps = round(price / tick)
    return round(steps * tick, decimals)


def _round_size(size: float) -> float:
    """CLOB allows at most 4 decimal places on share size."""
    return round(size, 4)


def _limit_buy_size(amount_usd: float, price: float, tick_size: str) -> tuple[float, float]:
    """Size/price rounded for CLOB limit orders (share size: 2 decimals for tick 0.01)."""
    rounded_price = _round_price(price, tick_size)
    # Match py-clob-client-v2 ROUNDING_CONFIG: size uses 2 decimal places for 0.01 tick.
    size = round(amount_usd / rounded_price, 2)
    if size <= 0:
        raise ValueError(f"Order size rounds to zero (amount={amount_usd}, price={rounded_price})")
    return rounded_price, size


def _is_success(response: dict[str, Any] | None) -> bool:
    if not response:
        return False
    if response.get("success") is True:
        return True
    if response.get("takingAmount") or response.get("makingAmount"):
        return True
    status = str(response.get("status", "")).lower()
    return status in ("matched", "filled", "live")


def record_response(record: OrderRecord, log_file: Path) -> None:
    log_file.parent.mkdir(parents=True, exist_ok=True)
    with log_file.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(asdict(record), default=str) + "\n")


def buy(
    signal: BuySignal,
    *,
    mode: OrderMode = "FOK",
    log_file: Path = DEFAULT_LOG_FILE,
    dry_run: bool = False,
) -> OrderRecord:
    """
    Place a limit BUY for `amount` USD at `price` per share (FOK or FAK).

    Share size is computed as amount / price.
    """
    outcome = signal.normalized_outcome()
    size = _round_size(signal.amount / signal.price)
    limit_price = signal.price
    request = {
        "slug": signal.slug,
        "outcome": outcome,
        "amount_usd": signal.amount,
        "price": signal.price,
        "size_shares": size,
        "mode": mode,
    }

    log.info(
        "BUY %s %s $%.2f @ $%.4f (%g shares, %s)",
        signal.slug,
        outcome,
        signal.amount,
        signal.price,
        size,
        mode,
    )

    if dry_run:
        record = OrderRecord(
            timestamp=datetime.now(timezone.utc).isoformat(),
            action="buy",
            slug=signal.slug,
            outcome=outcome,
            success=True,
            order_type=mode,
            request=request,
            response={"dry_run": True},
            error=None,
        )
        record_response(record, log_file)
        return record

    response: dict[str, Any] | None = None
    error: str | None = None
    try:
        token_id = resolve_token_id(signal.slug, outcome)
        client = get_clob_client()
        tick = client.get_tick_size(token_id)
        limit_price = _round_price(signal.price, tick)

        request["price"] = limit_price

        # FOK/FAK immediate fills use the market-order path (CLOB V2); min ~$1 notional.
        if mode in ("FOK", "FAK"):
            market_amount = max(signal.amount, 1.0)
            if market_amount > signal.amount:
                log.warning(
                    "FAK/FOK buy amount $%.2f raised to $1.00 (CLOB minimum for marketable buys)",
                    signal.amount,
                )
            request["order_style"] = "market_usd"
            request["market_amount_usd"] = market_amount
            response = _post_market_order(
                token_id, market_amount, BUY, mode, price=limit_price
            )
        else:
            limit_price, size = _limit_buy_size(signal.amount, limit_price, tick)
            request["size_shares"] = size
            response = _post_limit_order(token_id, limit_price, size, BUY, mode)
    except Exception as exc:
        error = str(exc)
        log.error("Buy failed: %s", exc)

    success = _is_success(response) if error is None else False
    record = OrderRecord(
        timestamp=datetime.now(timezone.utc).isoformat(),
        action="buy",
        slug=signal.slug,
        outcome=outcome,
        success=success,
        order_type=mode,
        request=request,
        response=response,
        error=error,
    )
    record_response(record, log_file)
    log.info("Buy %s — response: %s", "OK" if success else "FAILED", response or error)
    return record


def sell(
    slug: str,
    outcome: str,
    shares: float,
    *,
    price: float | None = None,
    mode: OrderMode = "FOK",
    log_file: Path = DEFAULT_LOG_FILE,
    dry_run: bool = False,
) -> OrderRecord:
    """
    Sell `shares` of `slug`/`outcome`.

    With `price`, posts a limit sell at that price. Without `price`, posts a
    market sell (still FOK/FAK per `mode`).
    """
    normalized = BuySignal(slug=slug, outcome=outcome, amount=0, price=0).normalized_outcome()
    request = {
        "slug": slug,
        "outcome": normalized,
        "shares": shares,
        "price": price,
        "mode": mode,
        "order_style": "limit" if price is not None else "market",
    }

    log.info(
        "SELL %s %s %.4f shares%s (%s)",
        slug,
        normalized,
        shares,
        f" @ ${price:.4f}" if price is not None else "",
        mode,
    )

    if dry_run:
        record = OrderRecord(
            timestamp=datetime.now(timezone.utc).isoformat(),
            action="sell",
            slug=slug,
            outcome=normalized,
            success=True,
            order_type=mode,
            request=request,
            response={"dry_run": True},
            error=None,
        )
        record_response(record, log_file)
        return record

    response: dict[str, Any] | None = None
    error: str | None = None
    try:
        token_id = resolve_token_id(slug, normalized)
        client = get_clob_client()

        sell_shares = _round_size(shares)
        if sell_shares <= 0:
            raise ValueError(f"Sell size rounds to zero: {shares}")

        if price is not None:
            tick = client.get_tick_size(token_id)
            limit_price = _round_price(price, tick)
            response = _post_limit_order(token_id, limit_price, sell_shares, SELL, mode)
        else:
            book = client.get_order_book(token_id)
            if not _book_bids(book):
                raise RuntimeError("No bids in order book — cannot market sell")
            response = _post_market_order(token_id, sell_shares, SELL, mode)

    except Exception as exc:
        error = str(exc)
        log.error("Sell failed: %s", exc)

    success = _is_success(response) if error is None else False
    record = OrderRecord(
        timestamp=datetime.now(timezone.utc).isoformat(),
        action="sell",
        slug=slug,
        outcome=normalized,
        success=success,
        order_type=mode,
        request=request,
        response=response,
        error=error,
    )
    record_response(record, log_file)
    log.info("Sell %s — response: %s", "OK" if success else "FAILED", response or error)
    return record


def _parse_signal(raw: str) -> BuySignal:
    data = json.loads(raw)
    amount = data.get("amount")
    if amount is None:
        amount = data.get("amount_usd")
    if amount is None:
        raise ValueError("signal JSON requires 'amount' or 'amount_usd'")
    return BuySignal(
        slug=data["slug"],
        outcome=data["outcome"],
        amount=float(amount),
        price=float(data["price"]),
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Place Polymarket CLOB buy/sell orders from a market slug.",
    )
    parser.add_argument(
        "--env-file",
        type=Path,
        default=DEFAULT_ENV_FILE,
        help=f"Path to .env with POLYMARKET_* credentials (default: {DEFAULT_ENV_FILE})",
    )
    parser.add_argument(
        "--log-file",
        type=Path,
        default=DEFAULT_LOG_FILE,
        help=f"JSONL file for order responses (default: {DEFAULT_LOG_FILE})",
    )
    parser.add_argument(
        "--fak",
        action="store_true",
        help="Use fill-and-kill (FAK). Default is fill-or-kill (FOK).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Validate inputs and log the planned order without posting.",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="Enable debug logging.",
    )

    sub = parser.add_subparsers(dest="command", required=True)

    buy_p = sub.add_parser("buy", help="Place a limit buy order")
    buy_p.add_argument("--slug", help="Market slug")
    buy_p.add_argument("--outcome", help="Up, Down, Yes, or No")
    buy_p.add_argument("--amount", type=float, help="USD amount to spend")
    buy_p.add_argument("--price", type=float, help="Limit price per share (0–1)")
    buy_p.add_argument(
        "--signal",
        help='JSON buy signal, e.g. \'{"slug":"...","outcome":"Up","amount":1.0,"price":0.50}\'',
    )

    sell_p = sub.add_parser("sell", help="Sell an open position")
    sell_p.add_argument("--slug", required=True, help="Market slug")
    sell_p.add_argument("--outcome", required=True, help="Up, Down, Yes, or No")
    sell_p.add_argument("--shares", type=float, required=True, help="Number of shares to sell")
    sell_p.add_argument(
        "--price",
        type=float,
        help="Limit sell price. Omit for a market sell against the book.",
    )

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    mode: OrderMode = "FAK" if args.fak else "FOK"

    try:
        load_credentials(args.env_file)
    except (FileNotFoundError, EnvironmentError) as exc:
        log.error("%s", exc)
        return 1

    if args.command == "buy":
        if args.signal:
            signal = _parse_signal(args.signal)
        else:
            missing = [name for name, val in (
                ("slug", args.slug),
                ("outcome", args.outcome),
                ("amount", args.amount),
                ("price", args.price),
            ) if val is None]
            if missing:
                parser.error(f"buy requires --signal or all of: {', '.join('--' + m for m in missing)}")
            signal = BuySignal(
                slug=args.slug,
                outcome=args.outcome,
                amount=args.amount,
                price=args.price,
            )

        record = buy(signal, mode=mode, log_file=args.log_file, dry_run=args.dry_run)
        return 0 if record.success else 1

    if args.command == "sell":
        record = sell(
            args.slug,
            args.outcome,
            args.shares,
            price=args.price,
            mode=mode,
            log_file=args.log_file,
            dry_run=args.dry_run,
        )
        return 0 if record.success else 1

    parser.error(f"Unknown command: {args.command}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
