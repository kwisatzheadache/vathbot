defmodule Vathbot.Scheduler do
  @moduledoc """
  Periodically discovers upcoming BTC Up/Down markets and spawns
  MarketRecorder processes for events starting within the next ~70 minutes.

  Runs a discovery cycle every 60 seconds and tracks which events
  already have active recorders to avoid duplicates.
  """

  use GenServer

  require Logger

  @check_interval_ms 60_000
  @window_minutes 70

  defstruct active_slugs: MapSet.new()

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("Scheduler starting, first discovery in 5s...")
    Process.send_after(self(), :discover, 5_000)
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_info(:discover, state) do
    new_state = run_discovery(state)
    Process.send_after(self(), :discover, @check_interval_ms)
    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc false
  def run_discovery(state) do
    Logger.info("Scheduler: discovering upcoming events (window: #{@window_minutes}min)...")

    events = Vathbot.MarketDiscovery.discover_upcoming(@window_minutes)

    Logger.info("Scheduler: found #{length(events)} upcoming events")

    new_active =
      Enum.reduce(events, state.active_slugs, fn event, active ->
        if MapSet.member?(active, event.slug) do
          Logger.debug("Scheduler: #{event.slug} already tracked")
          active
        else
          if should_start_recording?(event) do
            case Vathbot.EventSupervisor.start_recorder(event) do
              {:ok, _pid} -> MapSet.put(active, event.slug)
              {:error, _} -> active
            end
          else
            Logger.debug("Scheduler: #{event.slug} not ready for recording yet")
            active
          end
        end
      end)

    # Clean up slugs for events no longer in the upcoming window
    current_slugs = MapSet.new(events, & &1.slug)
    cleaned = MapSet.intersection(new_active, MapSet.union(current_slugs, new_active))

    %{state | active_slugs: cleaned}
  end

  defp should_start_recording?(%{active: true, closed: false}), do: true
  defp should_start_recording?(%{active: true, closed: nil}), do: true
  defp should_start_recording?(_), do: false
end
