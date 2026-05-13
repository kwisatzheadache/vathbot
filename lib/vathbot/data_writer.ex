defmodule Vathbot.DataWriter do
  @moduledoc """
  Writes recorded data to local JSONL files.

  Handles directory creation, file rotation by date, and atomic line writes.
  """

  @data_root "data"

  def data_root, do: @data_root

  @doc """
  Writes a single JSON line to the given file path.
  Creates parent directories if they don't exist.
  """
  def append_jsonl(path, data) when is_map(data) do
    full_path = Path.join(@data_root, path)
    ensure_dir(full_path)

    line = Jason.encode!(data) <> "\n"
    File.write(full_path, line, [:append, :utf8])
  end

  @doc """
  Writes event metadata as a pretty-printed JSON file.
  """
  def write_event_metadata(slug, interval, data) do
    dir = interval_dir(interval)
    path = Path.join([@data_root, dir, slug, "event.json"])
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
    date_str = date || Date.to_iso8601(Date.utc_today())
    Path.join(["btc_prices", "#{source}_#{date_str}.jsonl"])
  end

  defp interval_dir(:five_min), do: "5m"
  defp interval_dir(:fifteen_min), do: "15m"
  defp interval_dir(_), do: "other"

  defp ensure_dir(file_path) do
    file_path |> Path.dirname() |> File.mkdir_p!()
  end
end
