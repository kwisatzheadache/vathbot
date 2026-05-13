defmodule Vathbot.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Vathbot.EventSupervisor,
      Vathbot.BtcPriceRecorder,
      Vathbot.Scheduler
    ]

    opts = [strategy: :one_for_one, name: Vathbot.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
