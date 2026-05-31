defmodule Vathbot.MarketFinalizer.Coordinator do
  @moduledoc false

  use GenServer

  require Logger

  alias Vathbot.MarketFinalizer

  @default_task_supervisor Vathbot.MarketFinalizer.TaskSupervisor

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def enqueue(slug, interval) do
    GenServer.cast(__MODULE__, {:enqueue, slug, interval})
  end

  @impl true
  def init(opts) do
    max_concurrent = Keyword.get(opts, :max_concurrent, 2)
    task_supervisor = Keyword.get(opts, :task_supervisor, @default_task_supervisor)

    {:ok,
     %{
       max_concurrent: max_concurrent,
       task_supervisor: task_supervisor,
       queue: :queue.new(),
       pending: MapSet.new(),
       running: %{},
       completed: 0,
       failed: 0
     }}
  end

  @impl true
  def handle_cast({:enqueue, slug, interval}, state) do
    key = {slug, interval}

    if MapSet.member?(state.pending, key) do
      {:noreply, state}
    else
      state = %{
        state
        | queue: :queue.in(key, state.queue),
          pending: MapSet.put(state.pending, key)
      }

      {:noreply, drain(state)}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.running, ref) do
      {nil, _} ->
        {:noreply, state}

      {{slug, interval}, running} ->
        if reason not in [:normal, :shutdown] do
          Logger.warning(
            "MarketFinalizer #{slug}: task exited #{inspect(reason)} (queue=#{queue_depth(state)})"
          )
        end

        {completed, failed} =
          if reason == :normal do
            {state.completed + 1, state.failed}
          else
            {state.completed, state.failed + 1}
          end

        state = %{
          state
          | running: running,
            pending: MapSet.delete(state.pending, {slug, interval}),
            completed: completed,
            failed: failed
        }

        log_stats(state, slug, interval)
        {:noreply, drain(state)}
    end
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    {:noreply, state}
  end

  defp drain(%{running: running, max_concurrent: max} = state)
       when map_size(running) >= max do
    state
  end

  defp drain(%{queue: queue} = state) do
    if :queue.is_empty(queue) do
      state
    else
      {{:value, key}, queue} = :queue.out(queue)
      {slug, interval} = key
      state = %{state | queue: queue}

      case start_job(state, slug, interval) do
        {:ok, ref, pid} ->
          Process.monitor(pid)
          drain(%{state | running: Map.put(state.running, ref, key)})

        {:error, reason} ->
          Logger.error("MarketFinalizer #{slug}: could not start task #{inspect(reason)}")
          state = %{state | pending: MapSet.delete(state.pending, key), failed: state.failed + 1}
          drain(state)
      end
    end
  end

  defp start_job(%{task_supervisor: sup}, slug, interval) do
    case Task.Supervisor.async_nolink(sup, fn ->
           MarketFinalizer.run_finalize(slug, interval)
         end) do
      %Task{pid: pid} when is_pid(pid) ->
        ref = Process.monitor(pid)
        {:ok, ref, pid}

      other ->
        {:error, other}
    end
  end

  defp log_stats(state, slug, interval) do
    depth = queue_depth(state)

    if rem(state.completed + state.failed, 10) == 0 or depth > 0 do
      Logger.debug(
        "MarketFinalizer stats: queue=#{depth} running=#{map_size(state.running)} " <>
          "completed=#{state.completed} failed=#{state.failed} last=#{slug}/#{interval}"
      )
    end
  end

  defp queue_depth(state) do
    :queue.len(state.queue)
  end
end
