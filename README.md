# Vathbot

Records Polymarket BTC Up/Down markets, runs the `copy_with_bias` model, and can execute buys via [`pybuy/place_order.py`](pybuy/place_order.py).

## Live trading

CopyWithBias signals are logged to `data/signals.jsonl` with full order books (`kind: "trade"`). To post real orders, set up encrypted credentials (see [pybuy/README.md](pybuy/README.md)), then:

```bash
VATHBOT_EXECUTE_TRADES=1 mix run --no-halt
```

You will be prompted once per session for the secrets password. Execution results append as `kind: "execution"` (fill price, shares, CLOB response).

Optional environment variables:

| Variable | Description |
|----------|-------------|
| `VATHBOT_EXECUTE_TRADES` | Set to `1` or `true` to enable live order posting |
| `VATHBOT_SECRETS_FILE` | Path to encrypted credentials (default: `pybuy/secrets.env.enc`) |

## Integration test (real ~$1)

Requires encrypted credentials at `pybuy/secrets.env.enc` and `pybuy/venv` with dependencies installed. CLOB FAK buys require at least ~$1 notional.

```bash
POLYMARKET_INTEGRATION=1 \
VATHBOT_INTEGRATION_PASSWORD=your-password \
mix test --only integration test/vathbot/trade_integration_test.exs
```

Or run interactively (prompts for password):

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
