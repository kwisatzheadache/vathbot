defmodule Vathbot.ModelRunner do
  @moduledoc """
  Per-event GenServer that runs a trading model on stream messages forwarded
  from MarketRecorder.

  Forwards buy signals to OrderHandler.
  """

  use GenServer

  require Logger

  alias Vathbot.MarketDiscovery.BTCUpDownEvent
  alias Vathbot.Models.CopyWithBias
  alias Vathbot.Types.SignalLog

  def start_link(%BTCUpDownEvent{} = event, opts \\ []) do
    GenServer.start_link(__MODULE__, {event, opts})
  end

  @impl true
  def init({%BTCUpDownEvent{} = event, opts}) do
    order_handler = Keyword.get(opts, :order_handler, Vathbot.OrderHandler)

    case CopyWithBias.new(event) do
      {:ok, model} ->
        entry =
          SignalLog.monitor_started(
            event.slug,
            "copy_with_bias",
            CopyWithBias.event_start_ms(model)
          )

        Vathbot.OrderHandler.log_entry(order_handler, entry)

        Logger.info("ModelRunner started for #{event.slug} (copy_with_bias)")
        {:ok, %{slug: event.slug, model: model, order_handler: order_handler}}

      {:error, reason} ->
        Logger.warning("ModelRunner skipping #{event.slug}: #{inspect(reason)}")
        :ignore
    end
  end

  @impl true
  def handle_cast({:stream_message, message}, state) do
    case CopyWithBias.handle_message(state.model, message) do
      {:ok, model} ->
        {:noreply, %{state | model: model}}

      {:logs, entries, model} ->
        log_entries(state.order_handler, entries)
        {:noreply, %{state | model: model}}

      {:signal, signal, model, entries} ->
        log_entries(state.order_handler, entries)
        books = Map.get(message, "books", [])

        live? = CopyWithBias.live_trading_enabled?(model)
        Vathbot.OrderHandler.log_trade(state.order_handler, signal, books, execute: live?)

        if live? do
          Logger.info(
            "ModelRunner #{state.slug}: buy $#{signal.amount_usd} #{signal.outcome} @ #{signal.price}"
          )
        else
          reason = CopyWithBias.live_trading_skip_reason(model)

          Logger.info(
            "ModelRunner #{state.slug}: signal logged (#{reason}) " <>
              "$#{signal.amount_usd} #{signal.outcome} @ #{signal.price}"
          )
        end

        {:noreply, %{state | model: model}}
    end
  end

  def handle_cast(_msg, state), do: {:noreply, state}

  defp log_entries(order_handler, entries) do
    Enum.each(entries, &Vathbot.OrderHandler.log_entry(order_handler, &1))
  end
end
