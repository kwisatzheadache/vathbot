defmodule Vathbot.OrderHandler do
  @moduledoc """
  Receives trading signals from model runners, logs them (with books at decision
  time), and optionally executes buys via `Vathbot.TradeExecutor` / pybuy.
  """

  use GenServer

  require Logger

  alias Vathbot.Types.Signal
  alias Vathbot.Types.SignalLog

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Appends a buy signal to the log file (async via cast).
  """
  def log_signal(server \\ __MODULE__, %Signal{} = signal) do
    log_entry(server, SignalLog.signal(signal))
  end

  @doc """
  Logs a trade signal with the triggering order books and optionally executes a buy.
  """
  def log_trade(server \\ __MODULE__, %Signal{} = signal, books, opts \\ [])
      when is_list(books) do
    GenServer.cast(server, {:trade, signal, books, opts})
  end

  @doc """
  Appends a structured log entry (monitor events, timestamp match, no_signal, etc.).
  """
  def log_entry(server \\ __MODULE__, entry) when is_map(entry) do
    GenServer.cast(server, {:entry, entry})
  end

  @doc false
  def flush(server \\ __MODULE__) do
    GenServer.call(server, :flush)
  end

  @impl true
  def init(opts) do
    log_path = Keyword.get(opts, :log_path, default_log_path())
    execute? = Keyword.get(opts, :execute_trades, execute_trades?())
    {:ok, %{log_path: log_path, execute_trades: execute?}}
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_cast({:entry, entry}, state) do
    write_entry(state.log_path, entry)
    {:noreply, state}
  end

  def handle_cast({:trade, signal, books, opts}, state) do
    write_entry(state.log_path, SignalLog.trade(signal, books))

    if state.execute_trades and Keyword.get(opts, :execute, true) do
      parent = self()
      log_path = state.log_path

      Task.start(fn ->
        {:ok, result} = Vathbot.TradeExecutor.execute_buy(signal)
        send(parent, {:execution_done, signal, result, log_path})
      end)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:execution_done, signal, result, log_path}, state) do
    write_entry(log_path, SignalLog.execution(signal, result))

    if result[:success] do
      Logger.info(
        "OrderHandler: executed buy #{signal.slug} #{signal.outcome} " <>
          "@ #{result[:executed_price] || signal.price}"
      )
    else
      Logger.warning(
        "OrderHandler: buy failed #{signal.slug} — #{result[:error] || "unknown"}"
      )
    end

    {:noreply, state}
  end

  defp write_entry(log_path, entry) do
    Vathbot.DataWriter.append_jsonl(log_path, entry)
    Logger.info("OrderHandler: #{entry["kind"]} #{entry["slug"]}")
  end

  defp default_log_path, do: "signals.jsonl"

  defp execute_trades? do
    Application.get_env(:vathbot, :execute_trades, false)
  end
end
