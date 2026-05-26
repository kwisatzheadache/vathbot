defmodule Vathbot.DataWriter do
  @moduledoc """
  Writes recorded data to local JSONL and Parquet files.

  JSONL is appended during live recording; Parquet is written on market close
  or via BTC daily compaction.
  """

  def data_root, do: Application.get_env(:vathbot, :data_root, "data")

  @doc """
  Writes a single JSON line to the given file path.
  Creates parent directories if they don't exist.
  """
  def append_jsonl(path, data) when is_map(data) do
    full_path = Path.join(data_root(), path)
    ensure_dir(full_path)

    line = Jason.encode!(data) <> "\n"
    File.write(full_path, line, [:append, :utf8])
  end

  @doc """
  Writes event metadata as a pretty-printed JSON file.
  """
  def write_event_metadata(slug, interval, data) do
    dir = interval_dir(interval)
    path = Path.join([data_root(), dir, slug, "event.json"])
    ensure_dir(path)
    File.write(path, Jason.encode!(data, pretty: true))
  end

  @doc """
  Returns the JSONL path for a market recorder.
  """
  def market_jsonl_path(slug, interval) do
    dir = interval_dir(interval)
    Path.join([dir, slug, "market.jsonl"])
  end

  @doc """
  Returns the JSONL path for BTC price data.
  """
  def btc_price_path(source, date \\ nil) do
    Path.join(["btc_prices", "#{source}_#{format_date(date)}.jsonl"])
  end

  @doc "Relative path to per-slug ticks parquet."
  def ticks_parquet_path(slug, interval) do
    dir = interval_dir(interval)
    Path.join([dir, slug, "ticks.parquet"])
  end

  @doc "Relative path to per-slug metadata parquet."
  def metadata_parquet_path(slug, interval) do
    dir = interval_dir(interval)
    Path.join([dir, slug, "metadata.parquet"])
  end

  @doc "Relative path to daily BTC parquet."
  def btc_parquet_path(source, date \\ nil) do
    Path.join(["btc_prices", "#{source}_#{format_date(date)}.parquet"])
  end

  @doc "Full path under data root."
  def full_path(relative_path), do: Path.join(data_root(), relative_path)

  @doc "Removes market.jsonl after successful parquet write."
  def remove_market_jsonl(slug, interval) do
    path = full_path(market_jsonl_path(slug, interval))

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Writes metadata.parquet from a normalized metadata map."
  def write_metadata_parquet(slug, interval, meta) do
    Vathbot.ParquetWriter.write_metadata(metadata_parquet_path(slug, interval), meta)
  end

  defp format_date(nil), do: Date.to_iso8601(Date.utc_today())
  defp format_date(%Date{} = d), do: Date.to_iso8601(d)
  defp format_date(s) when is_binary(s), do: s

  defp interval_dir(:five_min), do: "5m"
  defp interval_dir(:fifteen_min), do: "15m"
  defp interval_dir(_), do: "other"

  defp ensure_dir(file_path) do
    file_path |> Path.dirname() |> File.mkdir_p!()
  end
end
