defmodule Vathbot.MarketDiscovery do
  @moduledoc """
  Discovers upcoming BTC Up/Down markets on Polymarket.

  Generates event slugs from timestamp patterns and fetches full event
  details (clobTokenIds, start time, outcomes, etc.) from the Gamma API.
  """

  require Logger

  @gamma_api "https://gamma-api.polymarket.com"

  defmodule BTCUpDownEvent do
    @moduledoc false
    defstruct [
      :id,
      :slug,
      :title,
      :interval,
      :start_time,
      :end_time,
      :clob_token_ids,
      :condition_id,
      :outcomes,
      :price_to_beat,
      :final_price,
      :active,
      :closed,
      :raw
    ]
  end

  @doc """
  Returns upcoming events within a time window (default: next 70 minutes).

  Fetches event details from the Gamma API for each computed slug.
  Returns only events that exist and are active/open.
  """
  def discover_upcoming(window_minutes \\ 70, from \\ nil) do
    now = from || DateTime.utc_now()
    epoch = DateTime.to_unix(now)
    window_end = epoch + window_minutes * 60

    timestamps_5m = next_aligned_timestamps(epoch, 300, div(window_minutes * 60, 300) + 1)
                    |> Enum.filter(&(&1 <= window_end))

    timestamps_15m = next_aligned_timestamps(epoch, 900, div(window_minutes * 60, 900) + 1)
                     |> Enum.filter(&(&1 <= window_end))

    slugs = Enum.map(timestamps_5m, &"btc-updown-5m-#{&1}") ++
            Enum.map(timestamps_15m, &"btc-updown-15m-#{&1}")

    slugs
    |> Task.async_stream(&fetch_event/1, max_concurrency: 5, timeout: 15_000)
    |> Enum.reduce([], fn
      {:ok, {:ok, event}}, acc -> [event | acc]
      {:ok, {:error, reason}}, acc ->
        Logger.debug("Skipping event: #{inspect(reason)}")
        acc
      {:exit, reason}, acc ->
        Logger.warning("Event fetch crashed: #{inspect(reason)}")
        acc
    end)
    |> Enum.sort_by(& &1.start_time, DateTime)
  end

  @doc """
  Fetches a single event by slug from the Gamma API.
  """
  def fetch_event(slug) do
    url = ~c"#{@gamma_api}/events?slug=#{slug}"

    case Vathbot.HTTP.get(url) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        case Jason.decode(body) do
          {:ok, [event_data | _]} ->
            {:ok, parse_event(event_data, slug)}

          {:ok, []} ->
            {:error, {:not_found, slug}}

          {:error, reason} ->
            {:error, {:json_error, reason, slug}}
        end

      {:ok, {{_, status, _}, _headers, _body}} ->
        {:error, {:http_error, status, slug}}

      {:error, reason} ->
        {:error, {:request_failed, reason, slug}}
    end
  end

  defp parse_event(data, slug) do
    market = List.first(data["markets"] || []) || %{}
    metadata = data["eventMetadata"] || %{}

    clob_token_ids = case market["clobTokenIds"] do
      ids when is_binary(ids) -> Jason.decode!(ids)
      ids when is_list(ids) -> ids
      _ -> []
    end

    outcomes = case market["outcomes"] do
      o when is_binary(o) -> Jason.decode!(o)
      o when is_list(o) -> o
      _ -> []
    end

    interval = cond do
      String.contains?(slug, "-5m-") -> :five_min
      String.contains?(slug, "-15m-") -> :fifteen_min
      true -> :unknown
    end

    %BTCUpDownEvent{
      id: data["id"],
      slug: slug,
      title: data["title"],
      interval: interval,
      start_time: parse_datetime(data["startTime"]),
      end_time: parse_datetime(data["endDate"] || market["endDate"]),
      clob_token_ids: clob_token_ids,
      condition_id: market["conditionId"],
      outcomes: outcomes,
      price_to_beat: metadata["priceToBeat"],
      final_price: metadata["finalPrice"],
      active: data["active"],
      closed: data["closed"],
      raw: data
    }
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  @doc """
  Returns the next `count` timestamps aligned to `interval_seconds` boundaries,
  starting from the first boundary after `epoch`.
  """
  def next_aligned_timestamps(epoch, interval_seconds, count) do
    next = epoch - rem(epoch, interval_seconds) + interval_seconds

    for i <- 0..(count - 1) do
      next + i * interval_seconds
    end
  end
end
