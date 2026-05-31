defmodule Vathbot.TradeMarkets do
  @moduledoc """
  Helpers for selecting tradeable Up/Down events (used by integration tests).
  """

  alias Vathbot.MarketDiscovery
  alias Vathbot.MarketNormalize

  @doc """
  Returns the first upcoming event whose `event_start_time` is at least
  `min_lead_seconds` in the future.
  """
  def discover_pre_start_event(min_lead_seconds \\ 120) do
    cutoff = DateTime.add(DateTime.utc_now(), min_lead_seconds, :second)

    MarketDiscovery.discover_upcoming(MarketDiscovery.discovery_window_minutes())
    |> Enum.find_value(fn event ->
      with true <- event_active?(event),
           true <- market_listed?(event.slug),
           {:ok, meta} <- MarketNormalize.metadata_from_event(event),
           :gt <- DateTime.compare(meta.event_start_time, cutoff) do
        {:ok, event, meta}
      else
        _ -> nil
      end
    end)
  end

  @doc """
  Returns true when pybuy can resolve the slug via Gamma `/markets` (CLOB-listed).
  """
  def market_listed?(slug) when is_binary(slug) do
    url = "https://gamma-api.polymarket.com/markets?slug=#{URI.encode(slug)}"

    case Vathbot.HTTP.get(url) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        case Jason.decode(body) do
          {:ok, [_ | _]} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  @doc """
  Picks an outcome and limit buy price for a small integration buy.

  Uses the Up token's best ask when available; otherwise `0.99` + FAK.
  """
  def integration_buy_params(%{up_token_id: up_token}) do
    outcome = "Up"

    case Vathbot.ClobBook.best_ask(up_token) do
      {:ok, ask} -> {outcome, ask}
      _ -> {outcome, 0.99}
    end
  end

  defp event_active?(%{active: true, closed: false}), do: true
  defp event_active?(%{active: true, closed: nil}), do: true
  defp event_active?(_), do: false
end
