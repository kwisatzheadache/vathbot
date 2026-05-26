defmodule Vathbot.Types.SignalLog do
  @moduledoc """
  Structured entries appended to the signals log for model monitoring and review.
  """

  alias Vathbot.Types.Signal

  @type entry :: map()

  def monitor_started(slug, model, event_start_ms) do
    base(slug, model, "monitor_started", %{
      "event_start_ms" => event_start_ms,
      "event_start_utc" => ms_to_utc_iso(event_start_ms)
    })
  end

  def timestamp_match(slug, model, recorded_at, event_ms, event_start_ms, delta_ms) do
    base(slug, model, "timestamp_match", %{
      "recorded_at" => recorded_at,
      "recorded_at_utc" => ms_to_utc_iso(recorded_at),
      "event_ms" => event_ms,
      "event_utc" => ms_to_utc_iso(event_ms),
      "event_start_ms" => event_start_ms,
      "event_start_utc" => ms_to_utc_iso(event_start_ms),
      "delta_ms" => delta_ms,
      "tolerance_ms" => 1_000
    })
  end

  def no_signal(slug, model, recorded_at, reason, details \\ %{}) do
    base(slug, model, "no_signal", %{
      "recorded_at" => recorded_at,
      "recorded_at_utc" => ms_to_utc_iso(recorded_at),
      "reason" => reason,
      "details" => details
    })
  end

  def signal(%Signal{} = signal) do
    logged_at = System.system_time(:millisecond)

    signal
    |> Signal.to_map()
    |> Map.merge(%{
      "kind" => "signal",
      "logged_at" => logged_at,
      "logged_at_utc" => ms_to_utc_iso(logged_at),
      "recorded_at_utc" => ms_to_utc_iso(signal.recorded_at)
    })
  end

  @doc """
  Buy signal plus full order book snapshot at decision time.
  """
  def trade(%Signal{} = signal, books) when is_list(books) do
    logged_at = System.system_time(:millisecond)

    signal
    |> Signal.to_map()
    |> Map.merge(%{
      "kind" => "trade",
      "books" => books,
      "logged_at" => logged_at,
      "logged_at_utc" => ms_to_utc_iso(logged_at),
      "recorded_at_utc" => ms_to_utc_iso(signal.recorded_at)
    })
  end

  @doc """
  Result of invoking pybuy after a trade signal.
  """
  def execution(%Signal{} = signal, result) when is_map(result) do
    logged_at = System.system_time(:millisecond)

    %{
      "kind" => "execution",
      "slug" => signal.slug,
      "model" => signal.model,
      "recorded_at" => signal.recorded_at,
      "recorded_at_utc" => ms_to_utc_iso(signal.recorded_at),
      "logged_at" => logged_at,
      "logged_at_utc" => ms_to_utc_iso(logged_at),
      "success" => Map.get(result, :success, false),
      "intended_price" => result[:intended_price],
      "executed_price" => result[:executed_price],
      "filled_shares" => result[:filled_shares],
      "exit_code" => result[:exit_code],
      "error" => result[:error],
      "clob_response" => get_in(result, [:record, "response"]),
      "clob_request" => get_in(result, [:record, "request"])
    }
  end

  defp base(slug, model, kind, fields) do
    logged_at = System.system_time(:millisecond)

    Map.merge(
      %{
        "kind" => kind,
        "slug" => slug,
        "model" => model,
        "logged_at" => logged_at,
        "logged_at_utc" => ms_to_utc_iso(logged_at)
      },
      fields
    )
  end

  defp ms_to_utc_iso(ms) when is_integer(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  end
end
