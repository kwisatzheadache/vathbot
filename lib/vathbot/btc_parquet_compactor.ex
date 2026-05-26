defmodule Vathbot.BtcParquetCompactor do
  @moduledoc """
  Periodically compacts BTC JSONL files to daily parquet.
  """

  use GenServer

  require Logger

  @interval_ms 5 * 60 * 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    send(self(), :compact)
    schedule_compact()
    {:ok, %{last_date: Date.utc_today()}}
  end

  @impl true
  def handle_info(:compact, state) do
    today = Date.utc_today()

    if state.last_date != today do
      Logger.info("BtcParquetCompactor: UTC date rolled to #{today}")
    end

    Vathbot.BtcNormalize.compact_recent()
    schedule_compact()
    {:noreply, %{state | last_date: today}}
  end

  defp schedule_compact do
    Process.send_after(self(), :compact, @interval_ms)
  end
end
