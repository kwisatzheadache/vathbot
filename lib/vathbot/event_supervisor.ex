defmodule Vathbot.EventSupervisor do
  @moduledoc """
  DynamicSupervisor that manages per-event MarketRecorder processes.

  Each child is a MarketRecorder WebSocket client that records data for a
  single BTC Up/Down event and terminates when the market resolves.
  """

  use DynamicSupervisor

  require Logger

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a MarketRecorder for the given event under this supervisor.
  """
  def start_recorder(%Vathbot.MarketDiscovery.BTCUpDownEvent{} = event) do
    spec = %{
      id: event.slug,
      start: {Vathbot.MarketRecorder, :start_link, [event]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} ->
        Logger.info("Started MarketRecorder for #{event.slug} (pid: #{inspect(pid)})")
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.debug("MarketRecorder for #{event.slug} already running")
        {:ok, pid}

      {:error, reason} = error ->
        Logger.error("Failed to start MarketRecorder for #{event.slug}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Returns the list of currently active recorder pids and their info.
  """
  def active_recorders do
    DynamicSupervisor.which_children(__MODULE__)
  end
end
