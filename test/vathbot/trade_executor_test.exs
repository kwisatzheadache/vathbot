defmodule Vathbot.TradeExecutorTest do
  use ExUnit.Case, async: true

  alias Vathbot.TradeExecutor
  alias Vathbot.Types.Signal

  test "buy_payload maps Signal amount_usd to amount" do
    signal = %Signal{
      type: :buy,
      slug: "btc-updown-5m-1",
      outcome: "Up",
      amount_usd: 1.0,
      price: 0.53,
      recorded_at: 1,
      model: "copy_with_bias"
    }

    assert TradeExecutor.buy_payload(signal) == %{
             "slug" => "btc-updown-5m-1",
             "outcome" => "Up",
             "amount" => 1.0,
             "price" => 0.53
           }
  end

  test "read_last_record returns last JSON line" do
    path = Path.join(System.tmp_dir!(), "vathbot_exec_#{System.unique_integer([:positive])}.jsonl")

    File.write!(path, ~s({"success":true}\n{"success":false,"action":"sell"}\n))

    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{"success" => false, "action" => "sell"}} = TradeExecutor.read_last_record(path)
  end

  test "execute_buy uses runner and parses log" do
    log_file = Path.join(System.tmp_dir!(), "vathbot_buy_#{System.unique_integer([:positive])}.jsonl")

    record = %{
      "success" => true,
      "action" => "buy",
      "request" => %{"size_shares" => 0.04, "price" => 0.5},
      "response" => %{"takingAmount" => "0.04", "makingAmount" => "0.02"},
      "error" => nil
    }

    runner = fn _args ->
      File.write!(log_file, Jason.encode!(record) <> "\n")
      {0, ""}
    end

    prev = Application.get_env(:vathbot, :trade_executor_runner)
    Application.put_env(:vathbot, :trade_executor_runner, runner)

    on_exit(fn ->
      File.rm(log_file)
      if prev, do: Application.put_env(:vathbot, :trade_executor_runner, prev)
    end)

    assert {:ok, result} =
             TradeExecutor.execute_buy(%{
               slug: "btc-updown-5m-test",
               outcome: "Up",
               amount: 0.02,
               price: 0.5
             }, log_file: log_file)

    assert result.success == true
    assert_in_delta result.filled_shares, 0.04, 0.0001
    assert_in_delta result.executed_price, 0.5, 0.01
  end
end
