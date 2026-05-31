defmodule Vathbot.MarketFinalizer do
  @moduledoc """
  Async market close jobs: JSONL → ticks.parquet via a queued coordinator.
  """

  require Logger

  alias Vathbot.MarketFinalizer.Coordinator

  @task_supervisor Vathbot.MarketFinalizer.TaskSupervisor

  def child_specs(opts \\ []) do
    max_concurrent = Keyword.get(opts, :max_concurrent, 2)

    [
      %{
        id: @task_supervisor,
        start: {Task.Supervisor, :start_link, [[name: @task_supervisor]]},
        type: :supervisor
      },
      {Coordinator, max_concurrent: max_concurrent}
    ]
  end

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      type: :supervisor,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__.Supervisor)
  end

  def init(opts) do
    Supervisor.init(child_specs(opts), strategy: :one_for_one)
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

  @doc "Enqueues JSONL normalization and ticks.parquet write (non-blocking)."
  def finalize_market(slug, interval) do
    Coordinator.enqueue(slug, interval)
    :ok
  end

  @doc "Runs finalize synchronously (for backfill / scripts)."
  def finalize_market_sync(slug, interval), do: do_finalize(slug, interval)

  @doc false
  def run_finalize(slug, interval), do: do_finalize(slug, interval)

  defp do_finalize(slug, interval) do
    if already_finalized?(slug, interval) do
      Logger.debug("MarketFinalizer #{slug}: already finalized, skipping")
      {:ok, :already_done}
    else
      do_finalize_work(slug, interval)
    end
  end

  defp do_finalize_work(slug, interval) do
    t0 = System.monotonic_time(:millisecond)
    jsonl_path = Vathbot.DataWriter.market_jsonl_path(slug, interval)
    ticks_path = Vathbot.DataWriter.ticks_parquet_path(slug, interval)

    with {:ok, meta} <- metadata_for_slug(slug, interval),
         :ok <- write_metadata_parquet(slug, interval, meta),
         {:ok, count} <-
           Vathbot.MarketNormalize.write_ticks_parquet_from_jsonl(jsonl_path, ticks_path, meta),
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

  defp already_finalized?(slug, interval) do
    jsonl = Vathbot.DataWriter.full_path(Vathbot.DataWriter.market_jsonl_path(slug, interval))
    parquet = Vathbot.DataWriter.full_path(Vathbot.DataWriter.ticks_parquet_path(slug, interval))

    not File.exists?(jsonl) and File.exists?(parquet)
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
       asset: Vathbot.MarketDiscovery.asset_from_slug(slug),
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
