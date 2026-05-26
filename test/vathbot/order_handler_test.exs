defmodule Vathbot.OrderHandlerTest do
  use ExUnit.Case, async: false

  alias Vathbot.Types.Signal

  setup do
    tmp = Path.join(System.tmp_dir!(), "vathbot_signals_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    log_path = "signals_test.jsonl"
    prev = Application.get_env(:vathbot, :data_root)
    Application.put_env(:vathbot, :data_root, tmp)

    {:ok, pid} =
      start_supervised(
        {Vathbot.OrderHandler, [name: nil, log_path: log_path]},
        restart: :temporary
      )

    on_exit(fn ->
      File.rm_rf!(tmp)
      if prev, do: Application.put_env(:vathbot, :data_root, prev), else: Application.delete_env(:vathbot, :data_root)
    end)

    {:ok, pid: pid, log_path: log_path, tmp: tmp}
  end

  test "appends signal to jsonl", %{pid: pid, log_path: log_path, tmp: tmp} do
    signal = %Signal{
      type: :buy,
      slug: "btc-updown-5m-test",
      outcome: "Up",
      amount_usd: 1.0,
      price: 0.53,
      recorded_at: 1_779_221_100_071,
      model: "copy_with_bias"
    }

    Vathbot.OrderHandler.log_signal(pid, signal)
    :ok = Vathbot.OrderHandler.flush(pid)

    full = Path.join(tmp, log_path)
    assert File.exists?(full)
    [line] = File.read!(full) |> String.split("\n", trim: true)
    decoded = Jason.decode!(line)
    assert decoded["kind"] == "signal"
    assert decoded["type"] == "buy"
    assert decoded["slug"] == "btc-updown-5m-test"
    assert decoded["outcome"] == "Up"
    assert decoded["amount_usd"] == 1.0
    assert decoded["logged_at_utc"] =~ ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/
    assert decoded["recorded_at_utc"] == "2026-05-19T20:05:00.071Z"
  end

  test "log_trade embeds books", %{pid: pid, log_path: log_path, tmp: tmp} do
    signal = %Signal{
      type: :buy,
      slug: "btc-updown-5m-test",
      outcome: "Up",
      amount_usd: 1.0,
      price: 0.53,
      recorded_at: 1_779_221_100_071,
      model: "copy_with_bias"
    }

    books = [%{"asset_id" => "token-up", "bids" => [], "asks" => [%{"price" => "0.53"}]}]

    Vathbot.OrderHandler.log_trade(pid, signal, books)
    :ok = Vathbot.OrderHandler.flush(pid)

    [line] =
      Path.join(tmp, log_path)
      |> File.read!()
      |> String.split("\n", trim: true)

    decoded = Jason.decode!(line)
    assert decoded["kind"] == "trade"
    assert decoded["books"] == books
    assert decoded["price"] == 0.53
  end

  test "log_trade with execute_trades appends execution", %{tmp: tmp} do
    log_path = "signals_exec.jsonl"

    record = %{
      "success" => true,
      "request" => %{"size_shares" => 1.88},
      "response" => %{"takingAmount" => "1.88", "makingAmount" => "1.0"},
      "error" => nil
    }

    custom_runner = fn args ->
      log = arg_value(args, "--log-file")
      File.write!(log, Jason.encode!(record) <> "\n")
      {0, ""}
    end

    prev_runner = Application.get_env(:vathbot, :trade_executor_runner)
    Application.put_env(:vathbot, :trade_executor_runner, custom_runner)

    on_exit(fn ->
      if prev_runner,
        do: Application.put_env(:vathbot, :trade_executor_runner, prev_runner),
        else: Application.delete_env(:vathbot, :trade_executor_runner)
    end)

    prev_root = Application.get_env(:vathbot, :data_root)
    Application.put_env(:vathbot, :data_root, tmp)

    on_exit(fn ->
      if prev_root, do: Application.put_env(:vathbot, :data_root, prev_root)
    end)

    {:ok, pid} =
      start_supervised(
        {Vathbot.OrderHandler, [name: nil, log_path: log_path, execute_trades: true]},
        id: {:order_handler, System.unique_integer([:positive])},
        restart: :temporary
      )

    signal = %Signal{
      type: :buy,
      slug: "btc-updown-5m-exec",
      outcome: "Up",
      amount_usd: 1.0,
      price: 0.53,
      recorded_at: 99,
      model: "copy_with_bias"
    }

    Vathbot.OrderHandler.log_trade(pid, signal, [])
    Process.sleep(300)
    :ok = Vathbot.OrderHandler.flush(pid)

    lines =
      Path.join(tmp, log_path)
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert Enum.any?(lines, &(&1["kind"] == "trade"))
    execution = Enum.find(lines, &(&1["kind"] == "execution"))
    assert execution["success"] == true
    assert execution["filled_shares"] == 1.88
  end

  test "log_trade with execute: false skips execution even when execute_trades is true", %{tmp: tmp} do
    log_path = "signals_no_exec.jsonl"

    custom_runner = fn _args ->
      flunk("TradeExecutor should not run when execute: false")
    end

    prev_runner = Application.get_env(:vathbot, :trade_executor_runner)
    Application.put_env(:vathbot, :trade_executor_runner, custom_runner)

    on_exit(fn ->
      if prev_runner,
        do: Application.put_env(:vathbot, :trade_executor_runner, prev_runner),
        else: Application.delete_env(:vathbot, :trade_executor_runner)
    end)

    prev_root = Application.get_env(:vathbot, :data_root)
    Application.put_env(:vathbot, :data_root, tmp)

    on_exit(fn ->
      if prev_root, do: Application.put_env(:vathbot, :data_root, prev_root)
    end)

    {:ok, pid} =
      start_supervised(
        {Vathbot.OrderHandler, [name: nil, log_path: log_path, execute_trades: true]},
        id: {:order_handler, System.unique_integer([:positive])},
        restart: :temporary
      )

    signal = %Signal{
      type: :buy,
      slug: "btc-updown-5m-no-exec",
      outcome: "Up",
      amount_usd: 1.0,
      price: 0.53,
      recorded_at: 99,
      model: "copy_with_bias"
    }

    Vathbot.OrderHandler.log_trade(pid, signal, [], execute: false)
    Process.sleep(100)
    :ok = Vathbot.OrderHandler.flush(pid)

    lines =
      Path.join(tmp, log_path)
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert Enum.any?(lines, &(&1["kind"] == "trade"))
    refute Enum.any?(lines, &(&1["kind"] == "execution"))
  end

  defp arg_value(args, flag) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> raise "missing #{flag} in #{inspect(args)}"
      idx -> Enum.at(args, idx + 1)
    end
  end

  test "appends monitor log entries", %{pid: pid, log_path: log_path, tmp: tmp} do
    Vathbot.OrderHandler.log_entry(pid, %{
      "kind" => "monitor_started",
      "slug" => "btc-updown-5m-test",
      "model" => "copy_with_bias"
    })

    :ok = Vathbot.OrderHandler.flush(pid)

    [line] =
      Path.join(tmp, log_path)
      |> File.read!()
      |> String.split("\n", trim: true)

    assert Jason.decode!(line)["kind"] == "monitor_started"
  end
end
