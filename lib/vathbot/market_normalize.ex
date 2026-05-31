defmodule Vathbot.MarketNormalize do
  @moduledoc """
  Normalizes raw market JSONL into tick rows and metadata matching the transform pipeline.
  """

  require Logger

  @type tick :: %{
          event_ts: DateTime.t(),
          received_ts: DateTime.t(),
          slug: String.t(),
          outcome: String.t(),
          best_bid: float(),
          best_ask: float(),
          mid: float(),
          spread: float(),
          event_type: String.t()
        }

  @type metadata :: %{
          slug: String.t(),
          interval_minutes: integer(),
          event_start_time: DateTime.t(),
          end_time: DateTime.t(),
          up_token_id: String.t(),
          down_token_id: String.t(),
          condition_id: String.t(),
          market_id: String.t(),
          question: String.t(),
          resolution_source: String.t()
        }

  @doc """
  Builds metadata from a discovered event (mirrors transform ingest_markets._parse_event_json).
  """
  def metadata_from_event(%Vathbot.MarketDiscovery.BTCUpDownEvent{} = event) do
    market = event.raw |> Map.get("markets", []) |> List.first() || %{}

    tokens = zip_tokens(event.clob_token_ids, event.outcomes)

    with {:ok, up_token} <- Map.fetch(tokens, "Up"),
         {:ok, down_token} <- Map.fetch(tokens, "Down"),
         {:ok, start} <- event_start_time(market, event),
         interval_minutes when interval_minutes in [5, 15] <- interval_minutes(event.interval) do
      end_time = end_time(market, start, interval_minutes, event.end_time)

      {:ok,
       %{
         slug: event.slug,
         interval_minutes: interval_minutes,
         event_start_time: start,
         end_time: end_time,
         up_token_id: up_token,
         down_token_id: down_token,
         condition_id: event.condition_id || "",
         market_id: to_string(market["id"] || ""),
         question: market["question"] || "",
         resolution_source: market["resolutionSource"] || ""
       }}
    else
      :error -> {:error, :invalid_tokens}
      {:error, _} = err -> err
      _ -> {:error, :invalid_interval}
    end
  end

  @doc """
  Lazy stream of normalized ticks from a market JSONL file (one line at a time).
  """
  def jsonl_tick_stream(jsonl_relative_path, %{} = meta) do
    full_path = Vathbot.DataWriter.full_path(jsonl_relative_path)

    if File.exists?(full_path) do
      stream =
        full_path
        |> File.stream!([], :line)
        |> Stream.map(&String.trim/1)
        |> Stream.reject(&(&1 == ""))
        |> Stream.flat_map(&lines_to_ticks(&1, meta))

      {:ok, stream}
    else
      {:error, :enoent}
    end
  end

  @doc """
  Streams JSONL → sorted ticks.parquet without loading the full file into memory.
  """
  def write_ticks_parquet_from_jsonl(jsonl_relative_path, parquet_relative_path, %{} = meta, opts \\ []) do
    with {:ok, stream} <- jsonl_tick_stream(jsonl_relative_path, meta) do
      Vathbot.ParquetWriter.write_ticks_stream(parquet_relative_path, stream, opts)
    end
  end

  @doc """
  Reads market JSONL and returns normalized tick rows sorted by event_ts, outcome.

  Prefer `write_ticks_parquet_from_jsonl/4` for large files.
  """
  def ticks_from_jsonl(jsonl_relative_path, %{} = meta) do
    with {:ok, stream} <- jsonl_tick_stream(jsonl_relative_path, meta) do
      rows =
        stream
        |> Enum.to_list()
        |> Enum.sort_by(fn t -> {DateTime.to_unix(t.event_ts, :microsecond), t.outcome} end)

      {:ok, rows}
    end
  end

  defp lines_to_ticks(line, meta) do
    case Jason.decode(line) do
      {:ok, %{"event_type" => "price_change"} = data} ->
        price_change_ticks(data, meta)

      {:ok, %{"event_type" => "book_snapshot"} = data} ->
        book_snapshot_ticks(data, meta)

      {:ok, _} ->
        []

      {:error, _} ->
        []
    end
  end

  defp price_change_ticks(data, meta) do
    cond_id = meta.condition_id
    market = data["market"]

    if market != cond_id do
      []
    else
      received_ts = ms_to_datetime(data["recorded_at"])
      event_ts = ms_to_datetime(parse_timestamp(data["timestamp"]))

      for pc <- data["price_changes"] || [],
          pc["best_bid"] != nil,
          pc["asset_id"] in [meta.up_token_id, meta.down_token_id],
          {:ok, best_bid} <- [parse_price(pc["best_bid"])],
          {:ok, best_ask} <- [parse_price(pc["best_ask"])],
          outcome = token_to_outcome(pc["asset_id"], meta),
          not is_nil(outcome) do
        mid = (best_bid + best_ask) / 2.0
        spread = best_ask - best_bid

        %{
          event_ts: event_ts,
          received_ts: received_ts,
          slug: meta.slug,
          outcome: outcome,
          best_bid: best_bid,
          best_ask: best_ask,
          mid: mid,
          spread: spread,
          event_type: "price_change"
        }
      end
    end
  end

  defp book_snapshot_ticks(data, meta) do
    received_ts = ms_to_datetime(data["recorded_at"])

    for book <- data["books"] || [],
        book["asset_id"] in [meta.up_token_id, meta.down_token_id],
        outcome = token_to_outcome(book["asset_id"], meta),
        not is_nil(outcome),
        {:ok, best_bid} <- [best_from_levels(book["bids"], :max)],
        {:ok, best_ask} <- [best_from_levels(book["asks"], :min)] do
      event_ts = ms_to_datetime(parse_timestamp(book["timestamp"]))
      mid = (best_bid + best_ask) / 2.0
      spread = best_ask - best_bid

      %{
        event_ts: event_ts,
        received_ts: received_ts,
        slug: meta.slug,
        outcome: outcome,
        best_bid: best_bid,
        best_ask: best_ask,
        mid: mid,
        spread: spread,
        event_type: "book_snapshot"
      }
    end
  end

  defp zip_tokens(ids, outcomes) do
    ids
    |> Enum.zip(outcomes)
    |> Map.new(fn {token_id, outcome} -> {outcome, token_id} end)
  end

  defp token_to_outcome(asset_id, meta) do
    cond do
      asset_id == meta.up_token_id -> "Up"
      asset_id == meta.down_token_id -> "Down"
      true -> nil
    end
  end

  defp interval_minutes(:five_min), do: 5
  defp interval_minutes(:fifteen_min), do: 15
  defp interval_minutes(_), do: :error

  defp event_start_time(market, event) do
    start_raw = market["eventStartTime"] || market["startDate"]

    cond do
      is_binary(start_raw) ->
        parse_iso_datetime(start_raw)

      event.start_time ->
        {:ok, ensure_utc(event.start_time)}

      true ->
        {:error, :no_start_time}
    end
  end

  defp end_time(market, start, interval_minutes, event_end_time) do
    default_end = DateTime.add(start, interval_minutes * 60, :second)

    case market["endDate"] do
      end_raw when is_binary(end_raw) ->
        case parse_iso_datetime(end_raw) do
          {:ok, parsed} ->
            if abs(DateTime.diff(parsed, default_end, :second)) > 120 do
              parsed
            else
              default_end
            end

          :error ->
            default_end
        end

      _ ->
        case event_end_time do
          %DateTime{} = dt -> ensure_utc(dt)
          _ -> default_end
        end
    end
  end

  defp parse_iso_datetime(str) do
    str = String.replace(str, "Z", "+00:00")

    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> {:ok, ensure_utc(dt)}
      _ -> {:error, :invalid_datetime}
    end
  end

  defp ensure_utc(%DateTime{} = dt) do
    case dt.time_zone do
      "Etc/UTC" -> dt
      _ -> DateTime.shift_zone!(dt, "Etc/UTC")
    end
  end

  defp parse_timestamp(ts) when is_integer(ts), do: ts

  defp parse_timestamp(ts) when is_binary(ts) do
    case Integer.parse(ts) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_timestamp(_), do: 0

  defp ms_to_datetime(ms) when is_integer(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> ensure_utc()
  end

  defp ms_to_datetime(_), do: ~U[1970-01-01 00:00:00.000000Z]

  defp parse_price(val) when is_number(val), do: {:ok, val * 1.0}

  defp parse_price(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> {:ok, f}
      :error -> :error
    end
  end

  defp parse_price(_), do: :error

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
end
