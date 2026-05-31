import Config

config :vathbot, :data_root, "data"
config :vathbot, :start_runtime, true

# Polymarket crypto Up/Down tickers (slug prefix: `{asset}-updown-{5m|15m}-{epoch}`)
config :vathbot, :updown_assets, ~w(btc eth sol xrp doge bnb hype)

# How far ahead (minutes) to probe Gamma for upcoming events
config :vathbot, :discovery_window_minutes, 5

# Assets allowed to place live orders (others record + log signals only)
config :vathbot, :live_trading_assets, ~w(btc)

pybuy_dir = Path.expand("../pybuy", __DIR__)
venv_python = Path.join(pybuy_dir, "venv/bin/python")

config :vathbot, :pybuy_dir, pybuy_dir

config :vathbot, :pybuy_python,
         System.get_env("VATHBOT_PYTHON") ||
           if(File.exists?(venv_python), do: venv_python, else: "python3")

import_config "#{config_env()}.exs"
