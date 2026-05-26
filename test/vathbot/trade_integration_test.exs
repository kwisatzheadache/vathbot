defmodule Vathbot.TradeIntegrationTest do
  @moduledoc """
  Live pybuy round-trip (~$1 notional; CLOB minimum for FAK buys). Requires credentials:

      POLYMARKET_INTEGRATION=1 mix test --only integration test/vathbot/trade_integration_test.exs
  """
  use ExUnit.Case, async: false

  alias Vathbot.TradeExecutor
  alias Vathbot.TradeMarkets

  @buy_amount_usd 1.0

  @tag :integration
  @tag timeout: 120_000
  test "buy then sell on pre-event_start market" do
    unless System.get_env("POLYMARKET_INTEGRATION") == "1" do
      raise "Set POLYMARKET_INTEGRATION=1 to run this test"
    end

    env_file = Path.join(Application.get_env(:vathbot, :pybuy_dir), ".env")

    unless File.exists?(env_file) do
      flunk("Missing pybuy/.env at #{env_file}")
    end

    assert {:ok, _event, meta} = TradeMarkets.discover_pre_start_event(120)
    {outcome, price} = TradeMarkets.integration_buy_params(meta)

    IO.puts(
      "Integration trade: #{meta.slug} #{outcome} $#{@buy_amount_usd} @ #{price} (starts #{meta.event_start_time})"
    )

    assert {:ok, buy_result} =
             TradeExecutor.execute_buy(%{
               slug: meta.slug,
               outcome: outcome,
               amount: @buy_amount_usd,
               price: price
             })

    assert buy_result.success,
           "buy failed: #{inspect(buy_result.error)} exit=#{buy_result.exit_code}"

    shares = buy_result.filled_shares
    assert shares && shares > 0, "no shares filled: #{inspect(buy_result.record)}"

    assert {:ok, sell_result} = TradeExecutor.execute_sell(meta.slug, outcome, shares)
    assert sell_result.success,
           "sell failed: #{inspect(sell_result.error)} exit=#{sell_result.exit_code}"

    IO.puts("Integration OK: bought #{shares} shares, sell success")
  end
end
