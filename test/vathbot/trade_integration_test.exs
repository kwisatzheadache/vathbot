defmodule Vathbot.TradeIntegrationTest do
  @moduledoc """
  Live pybuy round-trip (~$1 notional; CLOB minimum for FAK buys).

  Requires encrypted credentials and password:

      POLYMARKET_INTEGRATION=1 \\
      VATHBOT_INTEGRATION_PASSWORD=your-password \\
      mix test --only integration test/vathbot/trade_integration_test.exs

  Or run interactively (prompts for password):

      POLYMARKET_INTEGRATION=1 mix test --only integration test/vathbot/trade_integration_test.exs
  """
  use ExUnit.Case, async: false

  alias Vathbot.Secrets
  alias Vathbot.TradeExecutor
  alias Vathbot.TradeMarkets

  @buy_amount_usd 1.0

  setup do
    unless System.get_env("POLYMARKET_INTEGRATION") == "1" do
      :ok
    else
      secrets_file =
        Application.get_env(:vathbot, :secrets_file, "pybuy/secrets.env.enc")
        |> Path.expand()

      unless File.exists?(secrets_file) do
        flunk("Missing encrypted secrets at #{secrets_file}")
      end

      Application.put_env(:vathbot, :secrets_file, secrets_file)

      unless Process.whereis(Secrets) do
        {:ok, _pid} = Secrets.start_link()
      end

      password =
        System.get_env("VATHBOT_INTEGRATION_PASSWORD") ||
          getpass("Integration test password: ")

      case Secrets.unlock(password) do
        :ok ->
          on_exit(fn ->
            if Process.whereis(Secrets), do: GenServer.stop(Secrets, :normal, :infinity)
          end)

          :ok

        {:error, reason} ->
          flunk("Failed to unlock secrets: #{inspect(reason)}")
      end
    end
  end

  @tag :integration
  @tag timeout: 120_000
  test "buy then sell on pre-event_start market" do
    unless System.get_env("POLYMARKET_INTEGRATION") == "1" do
      raise "Set POLYMARKET_INTEGRATION=1 to run this test"
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

  @tag :integration
  test "dry-run mode does not require unlocked secrets" do
    unless System.get_env("POLYMARKET_INTEGRATION") == "1" do
      raise "Set POLYMARKET_INTEGRATION=1 to run this test"
    end

    log_file = Path.join(System.tmp_dir!(), "vathbot_dry_#{System.unique_integer([:positive])}.jsonl")
    on_exit(fn -> File.rm(log_file) end)

    pybuy_dir = Application.get_env(:vathbot, :pybuy_dir)
    python = Application.get_env(:vathbot, :pybuy_python, "python3")
    script = Path.join(pybuy_dir, "place_order.py")

    {output, exit_code} =
      System.cmd(
        python,
        [
          script,
          "--dry-run",
          "--fak",
          "--log-file",
          log_file,
          "buy",
          "--signal",
          ~s({"slug":"btc-updown-5m-test","outcome":"Up","amount":1.0,"price":0.50})
        ],
        cd: pybuy_dir,
        stderr_to_stdout: true
      )

    assert exit_code == 0, "dry-run failed: #{output}"
    assert File.exists?(log_file)
  end

  defp getpass(prompt) do
    IO.write(:stdio, prompt)

    case :io.setopts(:stdio, echo: false) do
      :ok ->
        password =
          case :io.get_line(:stdio, "") do
            :eof -> ""
            line -> String.trim_trailing(line, "\n")
          end

        :io.setopts(:stdio, echo: true)
        IO.write("\n")
        password

      _ ->
        IO.gets("") |> String.trim()
    end
  end
end
