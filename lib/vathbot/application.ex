defmodule Vathbot.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    core_children = [
      Vathbot.Secrets,
      Vathbot.EventSupervisor,
      Vathbot.MarketFinalizer.child_spec(max_concurrent: 2)
    ]

    opts = [strategy: :one_for_one, name: Vathbot.Supervisor]

    with {:ok, sup} <- Supervisor.start_link(core_children, opts),
         :ok <- maybe_unlock_secrets!(),
         :ok <- start_runtime_children(sup) do
      {:ok, sup}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_runtime_children(sup) do
    if Application.get_env(:vathbot, :start_runtime, true) do
      Enum.each(runtime_children(), fn child ->
        case Supervisor.start_child(sup, child) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, reason} -> throw({:runtime_child_start_failed, child, reason})
        end
      end)
    end

    :ok
  catch
    :throw, {:runtime_child_start_failed, child, reason} ->
      {:error, {:runtime_child_start_failed, child, reason}}
  end

  defp runtime_children do
    [
      Vathbot.OrderHandler,
      Vathbot.BtcParquetCompactor,
      Vathbot.CryptoPriceRecorder,
      Vathbot.Scheduler
    ]
  end

  defp maybe_unlock_secrets! do
    if execute_trades_enabled?() do
      password = live_trading_password()

      case Vathbot.Secrets.unlock(password) do
        :ok ->
          :ok

        {:error, reason} ->
          raise "Failed to unlock live trading secrets: #{inspect(reason)}"
      end
    else
      :ok
    end
  end

  defp execute_trades_enabled? do
    case System.get_env("VATHBOT_EXECUTE_TRADES") do
      val when val in ["1", "true"] -> true
      _ -> Application.get_env(:vathbot, :execute_trades, false)
    end
  end

  defp live_trading_password do
    case System.get_env("VATHBOT_INTEGRATION_PASSWORD") do
      nil -> getpass("Live trading password: ")
      password -> password
    end
  end

  defp getpass(prompt) do
    IO.write(:stdio, prompt)

    case :io.setopts(:stdio, echo: false) do
      :ok ->
        password =
          case :io.get_line(:stdio, "") do
            :eof -> ""
            line -> String.trim_trailing(line, "\n")
          end

        :io.setopts(:stdio, echo: true)
        IO.write("\n")
        password

      _ ->
        IO.gets("") |> String.trim()
    end
  end
end
