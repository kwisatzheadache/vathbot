defmodule Vathbot.RtdsSymbols do
  @moduledoc """
  Maps Up/Down asset tickers to Polymarket RTDS Binance and Chainlink symbols.
  """

  @default_symbols %{
    "btc" => %{binance: "btcusdt", chainlink: "btc/usd"},
    "eth" => %{binance: "ethusdt", chainlink: "eth/usd"},
    "sol" => %{binance: "solusdt", chainlink: "sol/usd"},
    "xrp" => %{binance: "xrpusdt", chainlink: "xrp/usd"},
    "doge" => %{binance: "dogeusdt", chainlink: "doge/usd"},
    "bnb" => %{binance: "bnbusdt", chainlink: "bnb/usd"},
    "hype" => %{binance: "hypeusdt", chainlink: "hype/usd"}
  }

  @doc "RTDS symbol map for configured `:updown_assets`."
  def for_updown_assets do
    assets = Vathbot.MarketDiscovery.updown_assets()
    symbols = Application.get_env(:vathbot, :rtds_symbols, @default_symbols)

    Map.take(symbols, assets)
  end

  @doc "Builds RTDS subscribe payload subscriptions list for all configured assets."
  def subscriptions do
    for_updown_assets()
    |> Enum.flat_map(fn {_asset, %{binance: binance, chainlink: chainlink}} ->
      [
        %{topic: "crypto_prices", type: "update", filters: ~s({"symbol":"#{binance}"})},
        %{topic: "crypto_prices_chainlink", type: "*", filters: ~s({"symbol":"#{chainlink}"})}
      ]
    end)
  end
end
