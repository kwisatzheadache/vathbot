defmodule Vathbot.BtcNormalize do
  @moduledoc """
  Normalizes BTC price JSONL into daily parquet (mirrors transform ingest_btc).
  """

  require Logger

  @sources ~w(binance chainlink)

  @type tick :: %{
          event_ts: DateTime.t(),
          received_ts: DateTime.t() | nil,
          source: String.t(),
          symbol: String.t() | nil,
          price: float()
        }

  @doc "All supported BTC sources."
  def sources, do: @sources

  @doc """
  Reads a day's JSONL and returns deduplicated rows (latest received_ts per event_ts+source).
  """
  def ticks_from_jsonl(source, date) do
    path = Vathbot.DataWriter.btc_price_path(source, date)
    full_path = Vathbot.DataWriter.full_path(path)

    if File.exists?(full_path) do
      rows =
        full_path
        |> File.stream!([], :line)
        |> Stream.map(&String.trim/1)
        |> Stream.reject(&(&1 == ""))
        |> Stream.flat_map(&lines_to_ticks(&1, source))
        |> Enum.to_list()
        |> dedupe_rows()

      {:ok, rows}
    else
      {:ok, []}
    end
  end

  @doc """
  Compacts one source/day JSONL to parquet if needed. Returns `{:ok, row_count}` or `:skipped`.
  """
  def compact_day(source, date, opts \\ []) do
    force = Keyword.get(opts, :force, false)
    jsonl_path = Vathbot.DataWriter.btc_price_path(source, date)
    parquet_path = Vathbot.DataWriter.btc_parquet_path(source, date)
    jsonl_full = Vathbot.DataWriter.full_path(jsonl_path)
    parquet_full = Vathbot.DataWriter.full_path(parquet_path)

    cond do
      not File.exists?(jsonl_full) ->
        :skipped

      not force and up_to_date?(jsonl_full, parquet_full) ->
        :skipped

      true ->
        with {:ok, rows} <- ticks_from_jsonl(source, date),
             {:ok, count} <- Vathbot.ParquetWriter.write_btc(parquet_path, rows) do
          Logger.info("BtcNormalize #{source}_#{date}: #{count} rows → parquet")
          {:ok, count}
        end
    end
  end

  @doc "Compact today and yesterday for all sources."
  def compact_recent(opts \\ []) do
    today = Date.utc_today()
    yesterday = Date.add(today, -1)

    for source <- @sources,
        date <- [yesterday, today],
        reduce: %{ok: 0, skipped: 0} do
      acc ->
        case compact_day(source, Date.to_iso8601(date), opts) do
          {:ok, _} -> %{acc | ok: acc.ok + 1}
          :skipped -> %{acc | skipped: acc.skipped + 1}
        end
    end
  end

  defp up_to_date?(jsonl_full, parquet_full) do
    File.exists?(parquet_full) and File.stat!(parquet_full).size >= 8 and
      File.stat!(parquet_full).mtime >= File.stat!(jsonl_full).mtime
  end

  defp lines_to_ticks(line, source) do
    case Jason.decode(line) do
      {:ok, record} -> ticks_from_record(record, source)
      {:error, _} -> []
    end
  end

  defp ticks_from_record(record, source) do
    payload = record["payload"] || %{}
    received_ts = ms_to_datetime(record["recorded_at"])

    cond do
      record["type"] == "subscribe" and is_list(payload["data"]) ->
        symbol = payload["symbol"]

        for point <- payload["data"],
            ts_ms = point["timestamp"],
            val = point["value"],
            ts_ms != nil,
            val != nil do
          %{
            event_ts: ms_to_datetime(ts_ms),
            received_ts: received_ts,
            source: source,
            symbol: symbol,
            price: val * 1.0
          }
        end

      true ->
        ts_ms = payload["timestamp"]
        val = payload["value"]

        if ts_ms != nil and val != nil do
          [
            %{
              event_ts: ms_to_datetime(ts_ms),
              received_ts: received_ts,
              source: source,
              symbol: payload["symbol"],
              price: val * 1.0
            }
          ]
        else
          []
        end
    end
  end

  defp dedupe_rows(rows) do
    rows
    |> Enum.group_by(fn r -> {r.event_ts, r.source} end)
    |> Enum.map(fn {_key, group} ->
      Enum.max_by(group, &received_sort_key/1, fn a, b -> a >= b end)
    end)
    |> Enum.sort_by(& &1.event_ts, DateTime)
  end

  defp ms_to_datetime(ms) when is_integer(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.shift_zone!("Etc/UTC")
  end

  defp ms_to_datetime(_), do: nil

  defp received_sort_key(%{received_ts: %DateTime{} = dt}), do: DateTime.to_unix(dt, :microsecond)
  defp received_sort_key(_), do: 0
end
