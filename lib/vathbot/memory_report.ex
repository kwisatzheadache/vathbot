defmodule Vathbot.MemoryReport do
  @moduledoc """
  Prints BEAM memory and vathbot runtime stats.

      Vathbot.MemoryReport.print()

  From another terminal while the daemon runs on a named node:

      mix vathbot.memory --node vathbot@127.0.0.1 --cookie vathbot
  """

  @memory_keys ~w(total processes processes_used system atom atom_used binary code ets)a

  @doc "Returns a formatted multi-line report string."
  def report do
    [
      header_line(),
      "",
      "BEAM memory"
    ]
    |> Kernel.++(memory_section())
    |> Kernel.++([
      "",
      "System"
    ])
    |> Kernel.++(system_section())
    |> Kernel.++([
      "",
      "Vathbot runtime"
    ])
    |> Kernel.++(runtime_section())
    |> Enum.join("\n")
  end

  @doc "Prints `report/0` to standard output."
  def print do
    IO.puts(report())
  end

  defp header_line do
    node = Node.self() |> Atom.to_string()
    utc = DateTime.utc_now() |> DateTime.to_iso8601()
    "vathbot memory report  node=#{node}  at=#{utc}"
  end

  defp memory_section do
    memory = :erlang.memory()

    for key <- @memory_keys, bytes = memory[key] do
      label = key |> Atom.to_string() |> String.replace("_", " ")
      "  #{pad(label, 16)} #{format_bytes(bytes)}"
    end
  end

  defp system_section do
    [
      row("processes", :erlang.system_info(:process_count)),
      row("ports", :erlang.system_info(:port_count)),
      row("atoms", :erlang.system_info(:atom_count)),
      row("schedulers online", :erlang.system_info(:schedulers_online)),
      row("uptime", format_uptime(:erlang.statistics(:wall_clock)))
    ]
  end

  defp runtime_section do
    [
      row("active recorders", active_recorder_count()),
      finalizer_section(),
      scheduler_section()
    ]
    |> List.flatten()
  end

  defp finalizer_section do
    case Process.whereis(Vathbot.MarketFinalizer.Coordinator) do
      nil ->
        "  finalizer         (not running)"

      _pid ->
        state = :sys.get_state(Vathbot.MarketFinalizer.Coordinator)

        [
          row("finalizer queue", :queue.len(state.queue)),
          row("finalizer running", map_size(state.running)),
          row("finalizer completed", state.completed),
          row("finalizer failed", state.failed)
        ]
    end
  end

  defp scheduler_section do
    case Process.whereis(Vathbot.Scheduler) do
      nil ->
        "  scheduler slugs   (not running)"

      _pid ->
        %{active_slugs: slugs} = :sys.get_state(Vathbot.Scheduler)
        row("scheduler slugs", MapSet.size(slugs))
    end
  end

  defp active_recorder_count do
    if Process.whereis(Vathbot.EventSupervisor) do
      Vathbot.EventSupervisor.active_recorders()
      |> Enum.count(fn {_id, _pid, _type, _modules} -> true end)
    else
      "n/a"
    end
  end

  defp row(label, value) do
    "  #{pad(label, 16)} #{value}"
  end

  defp pad(str, width) when is_binary(str) do
    String.pad_trailing(str, width)
  end

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_073_741_824 do
    format_size(bytes / 1_073_741_824, "GB")
  end

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_048_576 do
    format_size(bytes / 1_048_576, "MB")
  end

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1024 do
    format_size(bytes / 1024, "KB")
  end

  defp format_bytes(bytes) when is_integer(bytes), do: "#{bytes} B"

  defp format_size(value, unit) do
    :erlang.float_to_binary(value * 1.0, decimals: 2) <> " " <> unit
  end

  defp format_uptime({_wall, ms}) do
    total_s = div(ms, 1000)
    h = div(total_s, 3600)
    m = div(rem(total_s, 3600), 60)
    s = rem(total_s, 60)
    "#{h}h #{m}m #{s}s"
  end
end
