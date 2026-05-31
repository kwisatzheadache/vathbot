defmodule Vathbot.CryptoPriceRecorder do
  @moduledoc """
  Long-lived WebSocket client that streams crypto price data from the
  Polymarket RTDS and writes it to daily-rotated JSONL files.

  Subscribes to Binance (`crypto_prices`) and Chainlink (`crypto_prices_chainlink`)
  feeds for all configured `:updown_assets`.
  """

  use WebSockex

  require Logger

  alias Vathbot.RtdsSymbols

  @rtds_url "wss://ws-live-data.polymarket.com"
  @ping_interval_ms 5_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Logger.info("CryptoPriceRecorder starting, connecting to RTDS...")

    state = %{
      ping_timer: nil,
      message_count: 0
    }

    WebSockex.start_link(@rtds_url, __MODULE__, state, name: name, handle_initial_conn_failure: true)
  end

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("CryptoPriceRecorder connected to RTDS")
    send(self(), :subscribe)
    timer = Process.send_after(self(), :ping, @ping_interval_ms)
    {:ok, %{state | ping_timer: timer}}
  end

  @impl true
  def handle_info(:subscribe, state) do
    subscriptions = RtdsSymbols.subscriptions()
    assets = Vathbot.MarketDiscovery.updown_assets()

    subscribe_msg =
      Jason.encode!(%{
        action: "subscribe",
        subscriptions: subscriptions
      })

    Logger.info(
      "CryptoPriceRecorder subscribing to #{length(subscriptions)} feeds for #{inspect(assets)}"
    )

    {:reply, {:text, subscribe_msg}, state}
  end

  def handle_info(:ping, state) do
    timer = Process.send_after(self(), :ping, @ping_interval_ms)
    {:reply, {:text, "PING"}, %{state | ping_timer: timer}}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def handle_frame({:text, "PONG"}, state), do: {:ok, state}
  def handle_frame({:text, ""}, state), do: {:ok, state}

  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, %{"topic" => topic} = data} ->
        source = source_from_topic(topic)
        record = Map.put(data, "recorded_at", System.system_time(:millisecond))

        path = Vathbot.DataWriter.btc_price_path(source)
        Vathbot.DataWriter.append_jsonl(path, record)

        new_count = state.message_count + 1

        if rem(new_count, 100) == 0 do
          Logger.info("CryptoPriceRecorder: #{new_count} messages recorded")
        end

        {:ok, %{state | message_count: new_count}}

      {:ok, _other} ->
        {:ok, state}

      {:error, _} ->
        Logger.debug("CryptoPriceRecorder: non-JSON frame: #{String.slice(msg, 0, 100)}")
        {:ok, state}
    end
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    Logger.warning("CryptoPriceRecorder disconnected: #{inspect(reason)}, reconnecting in 3s...")
    Process.sleep(3_000)
    {:reconnect, state}
  end

  defp source_from_topic("crypto_prices"), do: "binance"
  defp source_from_topic("crypto_prices_chainlink"), do: "chainlink"
  defp source_from_topic(other), do: other
end
