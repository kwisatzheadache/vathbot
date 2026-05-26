defmodule Vathbot.ParquetWriter do
  @moduledoc """
  Writes normalized data to ZSTD-compressed Parquet files via Explorer.
  """

  @parquet_opts [compression: :zstd, streaming: false]

  @doc """
  Writes a single-row market metadata map to parquet.
  """
  def write_metadata(path, meta) when is_map(meta) do
    full_path = full_path(path)
    ensure_dir(full_path)

    df =
      Explorer.DataFrame.new([
        %{
          "slug" => meta.slug,
          "interval_minutes" => meta.interval_minutes,
          "event_start_time" => meta.event_start_time,
          "end_time" => meta.end_time,
          "up_token_id" => meta.up_token_id,
          "down_token_id" => meta.down_token_id,
          "condition_id" => meta.condition_id,
          "market_id" => meta.market_id,
          "question" => meta.question,
          "resolution_source" => meta.resolution_source
        }
      ])

    Explorer.DataFrame.to_parquet!(df, full_path, @parquet_opts)
    :ok
  end

  @doc """
  Writes normalized tick rows to parquet. Returns `{:ok, row_count}`.
  """
  def write_ticks(path, rows) when is_list(rows) do
    full_path = full_path(path)
    ensure_dir(full_path)

    if rows == [] do
      write_empty_ticks(full_path)
      {:ok, 0}
    else
      df = ticks_dataframe(rows)
      Explorer.DataFrame.to_parquet!(df, full_path, @parquet_opts)
      {:ok, length(rows)}
    end
  end

  @doc """
  Writes deduplicated BTC price rows to parquet. Returns `{:ok, row_count}`.
  """
  def write_btc(path, rows) when is_list(rows) do
    full_path = full_path(path)
    ensure_dir(full_path)

    if rows == [] do
      File.rm(full_path)
      {:ok, 0}
    else
      df = btc_dataframe(rows)
      Explorer.DataFrame.to_parquet!(df, full_path, @parquet_opts)
      {:ok, length(rows)}
    end
  end

  @doc "Returns row count if parquet exists and is readable."
  def row_count(path) do
    full_path = full_path(path)

    if File.exists?(full_path) and File.stat!(full_path).size >= 8 do
      full_path
      |> Explorer.DataFrame.from_parquet!()
      |> Explorer.DataFrame.n_rows()
    else
      0
    end
  rescue
    _ -> 0
  end

  defp ticks_dataframe(rows) do
    rows
    |> Enum.map(fn r ->
      %{
        "event_ts" => r.event_ts,
        "received_ts" => r.received_ts,
        "slug" => r.slug,
        "outcome" => r.outcome,
        "best_bid" => r.best_bid,
        "best_ask" => r.best_ask,
        "mid" => r.mid,
        "spread" => r.spread,
        "event_type" => r.event_type
      }
    end)
    |> Explorer.DataFrame.new()
  end

  defp write_empty_ticks(full_path) do
    []
    |> ticks_dataframe()
    |> Explorer.DataFrame.to_parquet!(full_path, @parquet_opts)
  end

  defp btc_dataframe(rows) do
    rows
    |> Enum.map(fn r ->
      %{
        "event_ts" => r.event_ts,
        "received_ts" => r.received_ts,
        "source" => r.source,
        "symbol" => r.symbol,
        "price" => r.price
      }
    end)
    |> Explorer.DataFrame.new()
  end

  defp full_path(path), do: Path.join(Vathbot.DataWriter.data_root(), path)

  defp ensure_dir(file_path) do
    file_path |> Path.dirname() |> File.mkdir_p!()
  end
end
