defmodule Vathbot.MarketFinalizer do
  @moduledoc """
  Async market close jobs: JSONL → ticks.parquet (via Task.Supervisor).
  """

  require Logger

  @task_supervisor Vathbot.MarketFinalizer.TaskSupervisor

  def child_spec(opts) do
    %{
      id: @task_supervisor,
      start: {Task.Supervisor, :start_link, [[name: @task_supervisor, max_children: 3] ++ opts]},
      type: :supervisor
    }
  end

  @doc "Writes metadata.parquet from an event at recorder start."
  def write_metadata(%Vathbot.MarketDiscovery.BTCUpDownEvent{} = event) do
    case Vathbot.MarketNormalize.metadata_from_event(event) do
      {:ok, meta} ->
        Vathbot.DataWriter.write_metadata_parquet(event.slug, event.interval, meta)
        :ok

      {:error, reason} ->
        Logger.warning("MarketFinalizer: skip metadata for #{event.slug}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Schedules JSONL normalization and ticks.parquet write (non-blocking)."
  def finalize_market(slug, interval) do
    case Task.Supervisor.start_child(@task_supervisor, fn ->
           do_finalize(slug, interval)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, :max_children} ->
        Logger.warning("MarketFinalizer: queue full, retry later for #{slug}")
        {:error, :max_children}

      {:error, reason} ->
        Logger.error("MarketFinalizer: could not start task for #{slug}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Runs finalize synchronously (for backfill / scripts)."
  def finalize_market_sync(slug, interval), do: do_finalize(slug, interval)

  defp do_finalize(slug, interval) do
    t0 = System.monotonic_time(:millisecond)
    jsonl_path = Vathbot.DataWriter.market_jsonl_path(slug, interval)

    with {:ok, meta} <- metadata_for_slug(slug, interval),
         :ok <- write_metadata_parquet(slug, interval, meta),
         {:ok, rows} <- Vathbot.MarketNormalize.ticks_from_jsonl(jsonl_path, meta),
         {:ok, count} <-
           Vathbot.ParquetWriter.write_ticks(
             Vathbot.DataWriter.ticks_parquet_path(slug, interval),
             rows
           ),
         :ok <- Vathbot.DataWriter.remove_market_jsonl(slug, interval) do
      elapsed = System.monotonic_time(:millisecond) - t0
      Logger.info("MarketFinalizer #{slug}: #{count} ticks → parquet (#{elapsed}ms)")
      {:ok, count}
    else
      {:error, :enoent} ->
        Logger.warning("MarketFinalizer #{slug}: no market.jsonl, skipping parquet")
        {:error, :enoent}

      {:error, reason} = err ->
        Logger.error("MarketFinalizer #{slug}: failed #{inspect(reason)}")
        err
    end
  end

  defp write_metadata_parquet(slug, interval, meta) do
    Vathbot.DataWriter.write_metadata_parquet(slug, interval, meta)
    :ok
  end

  defp metadata_for_slug(slug, interval) do
    dir = interval_dir(interval)
    event_path = Vathbot.DataWriter.full_path(Path.join([dir, slug, "event.json"]))

    with {:ok, body} <- File.read(event_path),
         {:ok, data} <- Jason.decode(body),
         {:ok, event} <- event_from_json(data, slug, interval) do
      Vathbot.MarketNormalize.metadata_from_event(event)
    else
      {:error, :enoent} -> {:error, :no_event_json}
      {:error, reason} -> {:error, reason}
    end
  end

  defp event_from_json(data, slug, interval) do
    market = data |> Map.get("markets", []) |> List.first() || %{}

    {:ok,
     %Vathbot.MarketDiscovery.BTCUpDownEvent{
       slug: slug,
       interval: interval,
       clob_token_ids: decode_json_field(market["clobTokenIds"]),
       outcomes: decode_json_field(market["outcomes"]),
       condition_id: market["conditionId"],
       start_time: parse_dt(data["startTime"]),
       end_time: parse_dt(market["endDate"] || data["endDate"]),
       raw: data
     }}
  end

  defp decode_json_field(v) when is_binary(v), do: Jason.decode!(v)
  defp decode_json_field(v) when is_list(v), do: v
  defp decode_json_field(_), do: []

  defp parse_dt(nil), do: nil

  defp parse_dt(str) when is_binary(str) do
    case DateTime.from_iso8601(String.replace(str, "Z", "+00:00")) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp interval_dir(:five_min), do: "5m"
  defp interval_dir(:fifteen_min), do: "15m"
  defp interval_dir(_), do: "other"
end
