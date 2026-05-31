defmodule Vathbot.RtdsSymbolsTest do
  use ExUnit.Case, async: true

  alias Vathbot.RtdsSymbols

  setup do
    prev_assets = Application.get_env(:vathbot, :updown_assets)
    Application.put_env(:vathbot, :updown_assets, ~w(btc eth))

    on_exit(fn ->
      if prev_assets, do: Application.put_env(:vathbot, :updown_assets, prev_assets)
    end)

    :ok
  end

  test "subscriptions/0 includes binance and chainlink per asset" do
    subs = RtdsSymbols.subscriptions()

    assert length(subs) == 4

    assert Enum.any?(subs, fn s ->
             s.topic == "crypto_prices" and s.filters =~ "btcusdt"
           end)

    assert Enum.any?(subs, fn s ->
             s.topic == "crypto_prices_chainlink" and s.filters =~ "eth/usd"
           end)
  end
end
