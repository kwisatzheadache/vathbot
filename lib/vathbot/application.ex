defmodule Vathbot.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Vathbot.EventSupervisor,
        Vathbot.MarketFinalizer.child_spec([])
      ] ++ runtime_children()

    opts = [strategy: :one_for_one, name: Vathbot.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp runtime_children do
    if Application.get_env(:vathbot, :start_runtime, true) do
      [
        Vathbot.OrderHandler,
        Vathbot.BtcParquetCompactor,
        Vathbot.BtcPriceRecorder,
        Vathbot.Scheduler
      ]
    else
      []
    end
  end
end
