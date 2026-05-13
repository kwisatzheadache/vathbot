defmodule Vathbot.MarketRecorder do
  @moduledoc """
  Per-event WebSocket client that streams orderbook data from the
  Polymarket Market Channel and writes it to a JSONL file.

  Subscribes using the event's clobTokenIds and records all message types:
  book, price_change, best_bid_ask, last_trade_price, market_resolved.

  Self-terminates after receiving market_resolved or a timeout.
  """

  use WebSockex

  require Logger

  @market_ws_url "wss://ws-subscriptions-clob.polymarket.com/ws/market"
  @ping_interval_ms 10_000

  defstruct [
    :slug,
    :interval,
    :clob_token_ids,
    :condition_id,
    :jsonl_path,
    :start_time,
    :end_time,
    :ping_timer,
    :timeout_timer,
    message_count: 0,
    resolved: false
  ]

  def start_link(%Vathbot.MarketDiscovery.BTCUpDownEvent{} = event) do
    Logger.info("MarketRecorder starting for #{event.slug}")

    Vathbot.DataWriter.write_event_metadata(event.slug, event.interval, event.raw)

    state = %__MODULE__{
      slug: event.slug,
      interval: event.interval,
      clob_token_ids: event.clob_token_ids,
      condition_id: event.condition_id,
      jsonl_path: Vathbot.DataWriter.market_jsonl_path(event.slug, event.interval),
      start_time: event.start_time,
      end_time: event.end_time
    }

    WebSockex.start_link(@market_ws_url, __MODULE__, state, handle_initial_conn_failure: true)
  end

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("MarketRecorder connected for #{state.slug}")
    send(self(), :subscribe)
    ping_timer = Process.send_after(self(), :ping, @ping_interval_ms)

    timeout_ms = compute_timeout_ms(state.end_time)
    timeout_timer = Process.send_after(self(), :timeout, timeout_ms)

    {:ok, %{state | ping_timer: ping_timer, timeout_timer: timeout_timer}}
  end

  @impl true
  def handle_info(:subscribe, state) do
    subscribe_msg = Jason.encode!(%{
      assets_ids: state.clob_token_ids,
      type: "market",
      custom_feature_enabled: true
    })

    {:reply, {:text, subscribe_msg}, state}
  end

  def handle_info(:ping, state) do
    timer = Process.send_after(self(), :ping, @ping_interval_ms)
    {:reply, {:text, "PING"}, %{state | ping_timer: timer}}
  end

  def handle_info(:timeout, state) do
    Logger.info("MarketRecorder timeout for #{state.slug}, shutting down (#{state.message_count} messages recorded)")
    {:close, state}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def handle_frame({:text, "PONG"}, state), do: {:ok, state}

  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, data} ->
        {new_count, resolved} = record_message(data, state)

        if resolved do
          Logger.info("MarketRecorder #{state.slug}: market resolved! (#{new_count} total messages)")
          {:close, %{state | message_count: new_count, resolved: true}}
        else
          {:ok, %{state | message_count: new_count}}
        end

      {:error, _} ->
        Logger.debug("MarketRecorder #{state.slug}: non-JSON frame")
        {:ok, state}
    end
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_disconnect(%{reason: _reason}, %{resolved: true} = state) do
    Logger.info("MarketRecorder #{state.slug}: cleanly disconnected after resolution")
    {:ok, state}
  end

  def handle_disconnect(%{reason: reason}, state) do
    Logger.warning("MarketRecorder #{state.slug} disconnected: #{inspect(reason)}, reconnecting in 3s...")
    Process.sleep(3_000)
    {:reconnect, state}
  end

  defp record_message(data_list, state) when is_list(data_list) do
    ts = System.system_time(:millisecond)
    record = %{"event_type" => "book_snapshot", "books" => data_list, "recorded_at" => ts}
    Vathbot.DataWriter.append_jsonl(state.jsonl_path, record)

    new_count = state.message_count + 1
    if rem(new_count, 50) == 0 do
      Logger.info("MarketRecorder #{state.slug}: #{new_count} messages")
    end

    {new_count, false}
  end

  defp record_message(data, state) when is_map(data) do
    event_type = data["event_type"]
    record = Map.put(data, "recorded_at", System.system_time(:millisecond))
    Vathbot.DataWriter.append_jsonl(state.jsonl_path, record)

    new_count = state.message_count + 1
    if rem(new_count, 50) == 0 do
      Logger.info("MarketRecorder #{state.slug}: #{new_count} messages")
    end

    {new_count, event_type == "market_resolved"}
  end

  defp compute_timeout_ms(nil) do
    # Default: 30 minutes if no end time known
    30 * 60 * 1_000
  end

  defp compute_timeout_ms(end_time) do
    # Add 5 minutes buffer after the expected end time
    diff = DateTime.diff(end_time, DateTime.utc_now(), :millisecond) + 5 * 60 * 1_000
    max(diff, 60_000)
  end
end
