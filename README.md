# Vathbot

Records Polymarket BTC Up/Down markets, runs the `copy_with_bias` model, and can execute buys via [`pybuy/place_order.py`](pybuy/place_order.py).

## Live trading

CopyWithBias signals are logged to `data/signals.jsonl` with full order books (`kind: "trade"`). To post real orders:

```bash
# pybuy credentials in pybuy/.env
VATHBOT_EXECUTE_TRADES=1 mix run --no-halt
```

Execution results append as `kind: "execution"` (fill price, shares, CLOB response).

## Integration test (real ~$1)

Requires `pybuy/.env` and `pybuy/venv` with dependencies installed. CLOB FAK buys require at least ~$1 notional.

```bash
POLYMARKET_INTEGRATION=1 mix test --only integration test/vathbot/trade_integration_test.exs
```

Discovers a pre-`event_start_time`, CLOB-listed market, buys $1, then market-sells.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `vathbot` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:vathbot, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/vathbot>.

