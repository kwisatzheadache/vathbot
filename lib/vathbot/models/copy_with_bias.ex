defmodule Vathbot.Models.CopyWithBias do
  @moduledoc """
  Copy-with-bias model — mirrors ``transform``'s ``copy_model.py`` at event start.

  At the first book update within 1s of ``event_start_time``:

  1. Compute ``start_bias`` from best bids (same as ``slug_summary.sql``):
     * ``up_bid > down_bid`` → UP
     * ``down_bid > up_bid`` → DOWN
     * equal → TIE (skip)
  2. Skip when ``|up_bid - 0.5| < MIN_BIAS`` (0.02).
  3. Buy $1 of the biased side at that side's best ask.

  Handles live ``book`` messages (one per token) and aggregated ``book_snapshot``
  messages (initial connect payload).
  """

  alias Vathbot.MarketDiscovery.BTCUpDownEvent
  alias Vathbot.MarketNormalize
  alias Vathbot.Types.Signal
  alias Vathbot.Types.SignalLog

  @min_bias 0.02
  @start_tolerance_ms 1_000

  # UTC hour ranges: inclusive start, exclusive end (same convention as 02:00–06:00).
  @live_trading_windows %{
    5 => {2, 6},
    15 => {23, 4}
  }

  defstruct [:meta, signal_emitted: false, start_triggered: false, latest_books: %{}]

  @type t :: %__MODULE__{
          meta: map(),
          signal_emitted: boolean(),
          start_triggered: boolean(),
          latest_books: %{String.t() => map()}
        }

  @type result ::
          {:ok, t()}
          | {:logs, [map()], t()}
          | {:signal, Signal.t(), t(), [map()]}

  def new(%BTCUpDownEvent{} = event) do
    case MarketNormalize.metadata_from_event(event) do
      {:ok, meta} -> {:ok, %__MODULE__{meta: meta}}
      {:error, _} = err -> err
    end
  end

  def handle_message(%__MODULE__{signal_emitted: true} = state, _message), do: {:ok, state}

  def handle_message(%__MODULE__{start_triggered: true} = state, _message), do: {:ok, state}

  def handle_message(%__MODULE__{} = state, %{"event_type" => "book_snapshot"} = message) do
    recorded_at = message["recorded_at"]
    books = message["books"] || []

    with event_ms when not is_nil(event_ms) <- snapshot_event_ms(books),
         true <- at_event_start?(state.meta, event_ms) do
      evaluate_at_start(state, books, recorded_at, event_ms)
    else
      _ -> {:ok, state}
    end
  end

  def handle_message(%__MODULE__{} = state, %{"event_type" => "book"} = message) do
    state = put_book(state, message)

    with {:ok, event_ms} <- parse_book_timestamp(message["timestamp"]),
         true <- at_event_start?(state.meta, event_ms),
         books when length(books) == 2 <- paired_books(state) do
      evaluate_at_start(state, books, message["recorded_at"], event_ms)
    else
      _ -> {:ok, state}
    end
  end

  def handle_message(state, _message), do: {:ok, state}

  def event_start_ms(%__MODULE__{meta: meta}) do
    DateTime.to_unix(meta.event_start_time, :millisecond)
  end

  @doc """
  Returns whether live order placement is allowed for this model at `utc_now`.

  * 5m events: 02:00–06:00 UTC
  * 15m events: 00:00–05:00 UTC
  """
  def live_trading_enabled?(%__MODULE__{meta: %{interval_minutes: minutes}}, utc_now \\ DateTime.utc_now()) do
    case Map.fetch(@live_trading_windows, minutes) do
      {:ok, {start_hour, end_hour}} -> in_live_trading_window?(utc_now, start_hour, end_hour)
      :error -> false
    end
  end

  @doc """
  Human-readable reason live trading was skipped (for logging).
  """
  def live_trading_skip_reason(%__MODULE__{meta: %{interval_minutes: minutes}}, _utc_now \\ DateTime.utc_now()) do
    case Map.fetch(@live_trading_windows, minutes) do
      {:ok, {start_hour, end_hour}} ->
        "live trading disabled outside #{format_hour_range(start_hour, end_hour)} UTC"

      :error ->
        "live trading disabled for #{minutes}m events"
    end
  end

  defp in_live_trading_window?(utc_now, start_hour, end_hour) do
    utc = ensure_utc(utc_now)
    utc.hour >= start_hour and utc.hour < end_hour
  end

  defp format_hour_range(start_hour, end_hour) do
    "#{pad_hour(start_hour)}:00–#{pad_hour(end_hour)}:00"
  end

  defp pad_hour(hour), do: hour |> Integer.to_string() |> String.pad_leading(2, "0")

  defp ensure_utc(%DateTime{time_zone: "Etc/UTC"} = dt), do: dt

  defp ensure_utc(%DateTime{} = dt), do: DateTime.shift_zone!(dt, "Etc/UTC")

  defp evaluate_at_start(state, books, recorded_at, event_ms) do
    {state, logs} = maybe_timestamp_match_log(state, recorded_at, event_ms)
    details = evaluation_details(books, state.meta)

    case evaluate_snapshot(books, state.meta) do
      nil ->
        reason = no_signal_reason(details)

        no_signal_log =
          SignalLog.no_signal(
            state.meta.slug,
            "copy_with_bias",
            recorded_at,
            reason,
            details
          )

        {:logs, logs ++ [no_signal_log], %{state | start_triggered: true}}

      %{outcome: outcome, best_ask: price, best_bid: best_bid, spread: spread} ->
        signal = %Signal{
          type: :buy,
          slug: state.meta.slug,
          outcome: outcome,
          amount_usd: 1.0,
          price: price,
          recorded_at: recorded_at,
          model: "copy_with_bias",
          best_bid: best_bid,
          spread: spread,
          ask_or_bid: :ask
        }

        {:signal, signal, %{state | signal_emitted: true, start_triggered: true}, logs}
    end
  end

  defp no_signal_reason(details) do
    case details do
      %{"start_bias" => "TIE"} -> "start_bias_tie"
      %{"passes_min_bias" => false} -> "insufficient_bias"
      _ -> "no_trade"
    end
  end

  defp put_book(state, %{"asset_id" => asset_id} = message) when is_binary(asset_id) do
    %{state | latest_books: Map.put(state.latest_books, asset_id, message)}
  end

  defp put_book(state, _message), do: state

  defp paired_books(%__MODULE__{latest_books: cache, meta: meta}) do
    up = Map.get(cache, meta.up_token_id)
    down = Map.get(cache, meta.down_token_id)

    case {up, down} do
      {%{} = u, %{} = d} -> [u, d]
      _ -> []
    end
  end

  defp maybe_timestamp_match_log(state, recorded_at, event_ms) do
    start_ms = event_start_ms(state)
    delta_ms = event_ms - start_ms

    log =
      SignalLog.timestamp_match(
        state.meta.slug,
        "copy_with_bias",
        recorded_at,
        event_ms,
        start_ms,
        delta_ms
      )

    {state, [log]}
  end

  defp at_event_start?(meta, event_ms) when is_integer(event_ms) do
    start_ms = DateTime.to_unix(meta.event_start_time, :millisecond)
    abs(event_ms - start_ms) <= @start_tolerance_ms
  end

  defp at_event_start?(_, _), do: false

  defp snapshot_event_ms(books) do
    Enum.find_value(books, fn book ->
      case parse_book_timestamp(book["timestamp"]) do
        {:ok, ms} -> ms
        :error -> nil
      end
    end)
  end

  defp parse_book_timestamp(val) when is_integer(val), do: {:ok, val}

  defp parse_book_timestamp(val) when is_binary(val) do
    case Integer.parse(val) do
      {ms, _} -> {:ok, ms}
      :error -> :error
    end
  end

  defp parse_book_timestamp(_), do: :error

  defp evaluation_details(books, meta) do
    with {:ok, up} <- quotes_for_outcome(books, meta, "Up"),
         {:ok, down} <- quotes_for_outcome(books, meta, "Down") do
      bias = start_bias(up.best_bid, down.best_bid)
      passes = passes_min_bias?(up.best_bid)

      %{
        "start_bid_up" => up.best_bid,
        "start_ask_up" => up.best_ask,
        "start_bid_down" => down.best_bid,
        "start_ask_down" => down.best_ask,
        "start_bias" => bias,
        "passes_min_bias" => passes,
        "min_bias" => @min_bias,
        "would_trade" => bias in ["UP", "DOWN"] and passes
      }
    else
      _ -> %{"start_bias" => "TIE", "passes_min_bias" => false}
    end
  end

  defp evaluate_snapshot(books, meta) do
    with {:ok, up} <- quotes_for_outcome(books, meta, "Up"),
         {:ok, down} <- quotes_for_outcome(books, meta, "Down"),
         true <- passes_min_bias?(up.best_bid) do
      case start_bias(up.best_bid, down.best_bid) do
        "UP" ->
          %{
            outcome: "Up",
            best_ask: up.best_ask,
            best_bid: up.best_bid,
            spread: up.best_ask - up.best_bid
          }

        "DOWN" ->
          %{
            outcome: "Down",
            best_ask: down.best_ask,
            best_bid: down.best_bid,
            spread: down.best_ask - down.best_bid
          }

        "TIE" ->
          nil
      end
    else
      _ -> nil
    end
  end

  # Same CASE as transform/src/sql/slug_summary.sql start_bias.
  defp start_bias(up_bid, down_bid) when up_bid > down_bid, do: "UP"
  defp start_bias(up_bid, down_bid) when down_bid > up_bid, do: "DOWN"
  defp start_bias(_, _), do: "TIE"

  # Same filter as transform/src/models/copy_model.py simulate().
  defp passes_min_bias?(up_bid), do: abs(up_bid - 0.5) >= @min_bias

  defp quotes_for_outcome(books, meta, outcome) do
    book =
      Enum.find(books, fn b ->
        token_to_outcome(b["asset_id"], meta) == outcome
      end)

    with %{} = book <- book,
         {:ok, best_bid} <- best_from_levels(book["bids"], :max),
         {:ok, best_ask} <- best_from_levels(book["asks"], :min) do
      {:ok, %{best_bid: best_bid, best_ask: best_ask}}
    else
      _ -> :error
    end
  end

  defp token_to_outcome(asset_id, meta) do
    cond do
      asset_id == meta.up_token_id -> "Up"
      asset_id == meta.down_token_id -> "Down"
      true -> nil
    end
  end

  defp best_from_levels(nil, _), do: :error
  defp best_from_levels([], _), do: :error

  defp best_from_levels(levels, op) do
    prices =
      for %{"price" => p} <- levels,
          {:ok, f} <- [parse_price(p)],
          do: f

    case prices do
      [] -> :error
      list -> {:ok, apply(Enum, op, [list])}
    end
  end

  defp parse_price(val) when is_number(val), do: {:ok, val * 1.0}

  defp parse_price(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> {:ok, f}
      :error -> :error
    end
  end

  defp parse_price(_), do: :error
end
