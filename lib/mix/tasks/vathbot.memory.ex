defmodule Mix.Tasks.Vathbot.Memory do
  @shortdoc "Print BEAM memory and vathbot runtime stats"

  @moduledoc """
  Prints memory usage and runtime counters.

  On a running named node (daemon started with `--name vathbot@127.0.0.1`):

      mix vathbot.memory --node vathbot@127.0.0.1 --cookie vathbot

  Locally (starts app without runtime children):

      mix vathbot.memory
  """

  use Mix.Task

  @switches [node: :string, cookie: :string]
  @aliases [n: :node, c: :cookie]

  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    case Keyword.get(opts, :node) do
      nil ->
        Application.put_env(:vathbot, :start_runtime, false)
        Mix.Task.run("app.start")
        Vathbot.MemoryReport.print()

      node_str ->
        cookie_str = Keyword.get(opts, :cookie, "vathbot")
        node = String.to_atom(node_str)
        cookie = String.to_atom(cookie_str)

        ensure_local_node!(cookie)

        case Node.connect(node) do
          true ->
            case :rpc.call(node, Vathbot.MemoryReport, :report, []) do
              report when is_binary(report) -> IO.puts(report)
              {:badrpc, reason} -> Mix.raise("RPC failed: #{inspect(reason)}")
              other -> Mix.raise("Unexpected RPC result: #{inspect(other)}")
            end

          false ->
            Mix.raise(
              "Could not connect to #{node_str}. Is the daemon running with the same cookie (#{cookie_str})?"
            )
        end
    end
  end

  defp ensure_local_node!(cookie) do
    if Node.alive?() do
      Node.set_cookie(cookie)
    else
      local = :"vathbot_mem_#{System.unique_integer([:positive])}@127.0.0.1"

      case Node.start(local) do
        {:ok, _} ->
          Node.set_cookie(cookie)

        {:error, {:already_started, _}} ->
          Node.set_cookie(cookie)

        {:error, reason} ->
          Mix.raise("Could not start local node for RPC: #{inspect(reason)}")
      end
    end
  end
end
