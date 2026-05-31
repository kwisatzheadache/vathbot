defmodule Vathbot.MarketDiscovery do
  @moduledoc """
  Discovers upcoming crypto Up/Down markets on Polymarket.

  Generates event slugs from timestamp patterns (`{asset}-updown-{5m|15m}-{epoch}`)
  and fetches full event details (clobTokenIds, start time, outcomes, etc.) from
  the Gamma API.

  Configure assets via `:updown_assets` (default: all known Polymarket tickers).
  """

  require Logger

  @gamma_api "https://gamma-api.polymarket.com"

  @default_assets ~w(btc eth sol xrp doge bnb hype)
  @known_probe_assets ~w(
    btc eth sol xrp doge bnb hype ada avax link matic pol ltc bch trx shib pepe
    wif bonk ton sui apt arb op dot atom near fil inj sei tia wld ena pengu trump
  )

  defmodule BTCUpDownEvent do
    @moduledoc """
    Discovered Up/Down event (BTC, ETH, SOL, etc.).

    The struct name is historical; see `:asset` for the ticker prefix in the slug.
    """
    defstruct [
      :id,
      :slug,
      :asset,
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
  Asset tickers used for slug generation (e.g. `btc` → `btc-updown-5m-{epoch}`).
  """
  def updown_assets do
    Application.get_env(:vathbot, :updown_assets, @default_assets)
  end

  @doc """
  Configured discovery window in minutes (default 5).
  """
  def discovery_window_minutes do
    Application.get_env(:vathbot, :discovery_window_minutes, 5)
  end

  @doc """
  Returns upcoming events within a time window (default: `:discovery_window_minutes`).

  Fetches event details from the Gamma API for each computed slug.
  Returns only events that exist and are active/open.
  """
  def discover_upcoming(window_minutes \\ nil, from \\ nil) do
    window_minutes = window_minutes || discovery_window_minutes()
    now = from || DateTime.utc_now()
    epoch = DateTime.to_unix(now)
    window_end = epoch + window_minutes * 60

    timestamps_5m =
      next_aligned_timestamps(epoch, 300, div(window_minutes * 60, 300) + 1)
      |> Enum.filter(&(&1 <= window_end))

    timestamps_15m =
      next_aligned_timestamps(epoch, 900, div(window_minutes * 60, 900) + 1)
      |> Enum.filter(&(&1 <= window_end))

    slugs = build_slugs(updown_assets(), timestamps_5m, timestamps_15m)

    slugs
    |> Task.async_stream(&fetch_event/1, max_concurrency: 10, timeout: 15_000)
    |> Enum.reduce([], fn
      {:ok, {:ok, event}}, acc -> [event | acc]
      {:ok, {:error, reason}}, acc ->
        Logger.debug("Skipping event: #{inspect(reason)}")
        acc

      {:exit, reason}, acc ->
        Logger.warning("Event fetch crashed: #{inspect(reason)}")
        acc
    end)
    |> Enum.sort_by(fn event ->
      {event.start_time || ~U[1970-01-01 00:00:00Z], event.asset, event.slug}
    end)
  end

  @doc """
  Builds slug strings for the given assets and aligned epoch timestamps.
  """
  def build_slugs(assets, timestamps_5m, timestamps_15m) do
    for asset <- assets,
        {interval, timestamps} <- [{"5m", timestamps_5m}, {"15m", timestamps_15m}],
        ts <- timestamps do
      "#{asset}-updown-#{interval}-#{ts}"
    end
  end

  @doc """
  Probes Gamma for `{asset}-updown-{5m|15m}` at a single epoch.

  Returns a map `%{asset => %{interval => title | nil}}` for assets that exist.
  Useful when Polymarket adds new tickers.
  """
  def scan_updown_assets(epoch \\ nil, probe_assets \\ @known_probe_assets) do
    now = DateTime.to_unix(DateTime.utc_now())
    epoch_5m = epoch || next_aligned_timestamps(now, 300, 1) |> List.first()
    epoch_15m = next_aligned_timestamps(now, 900, 1) |> List.first()

    probe_assets
    |> Task.async_stream(
      fn asset ->
        intervals =
          %{"5m" => epoch_5m, "15m" => epoch_15m}
          |> Enum.reduce(%{}, fn {interval, ts}, acc ->
            slug = "#{asset}-updown-#{interval}-#{ts}"

            case fetch_event(slug) do
              {:ok, event} -> Map.put(acc, interval, event.title)
              _ -> acc
            end
          end)

        if map_size(intervals) > 0, do: {asset, intervals}, else: nil
      end,
      max_concurrency: 8,
      timeout: 15_000
    )
    |> Enum.reduce(%{}, fn
      {:ok, {asset, intervals}}, acc -> Map.put(acc, asset, intervals)
      _, acc -> acc
    end)
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

  @doc """
  Parses the asset ticker from a slug like `eth-updown-5m-1779837300`.
  """
  def asset_from_slug(slug) when is_binary(slug) do
    case String.split(slug, "-", parts: 4) do
      [asset, "updown", _interval, _epoch] -> asset
      _ -> nil
    end
  end

  defp parse_event(data, slug) do
    market = List.first(data["markets"] || []) || %{}
    metadata = data["eventMetadata"] || %{}

    clob_token_ids =
      case market["clobTokenIds"] do
        ids when is_binary(ids) -> Jason.decode!(ids)
        ids when is_list(ids) -> ids
        _ -> []
      end

    outcomes =
      case market["outcomes"] do
        o when is_binary(o) -> Jason.decode!(o)
        o when is_list(o) -> o
        _ -> []
      end

    interval =
      cond do
        String.contains?(slug, "-5m-") -> :five_min
        String.contains?(slug, "-15m-") -> :fifteen_min
        true -> :unknown
      end

    %BTCUpDownEvent{
      id: data["id"],
      slug: slug,
      asset: asset_from_slug(slug),
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
