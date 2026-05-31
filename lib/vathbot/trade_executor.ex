defmodule Vathbot.TradeExecutor do
  @moduledoc """
  Executes Polymarket orders by invoking `pybuy/place_order.py` and reading its JSONL log.

  Elixir is the orchestrator; Python is only the CLOB subprocess.
  """

  require Logger

  alias Vathbot.Types.Signal

  @type execution_result :: %{
          success: boolean(),
          exit_code: integer(),
          record: map() | nil,
          intended_price: float() | nil,
          executed_price: float() | nil,
          filled_shares: float() | nil,
          error: String.t() | nil
        }

  @doc """
  Places a limit buy via pybuy. Accepts a `%Signal{}` or a map with
  `:slug`, `:outcome`, `:amount` (USD), and `:price`.
  """
  def execute_buy(signal_or_map, opts \\ []) do
    payload = buy_payload(signal_or_map)
    log_file = Keyword.get(opts, :log_file, temp_log_file("buy"))

    args =
      script_args() ++ global_flags(log_file) ++ ["buy", "--signal", Jason.encode!(payload)]

    run_and_parse(args, log_file, payload["price"])
  end

  @doc """
  Sells shares (market sell when `price` is nil).
  """
  def execute_sell(slug, outcome, shares, opts \\ []) do
    log_file = Keyword.get(opts, :log_file, temp_log_file("sell"))
    price = Keyword.get(opts, :price)

    args =
      script_args() ++
        global_flags(log_file) ++
        [
          "sell",
          "--slug",
          slug,
          "--outcome",
          outcome,
          "--shares",
          to_string(shares)
        ] ++ price_args(price)

    run_and_parse(args, log_file, price)
  end

  @doc """
  Reads the last JSON object from a pybuy orders JSONL file.
  """
  def read_last_record(path) when is_binary(path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> List.last()
      |> case do
        nil -> {:error, :empty_log}
        line -> Jason.decode(line)
      end
    else
      {:error, :enoent}
    end
  end

  @doc false
  def buy_payload(%Signal{} = signal) do
    %{
      "slug" => signal.slug,
      "outcome" => signal.outcome,
      "amount" => signal.amount_usd,
      "price" => signal.price
    }
  end

  def buy_payload(%{slug: slug, outcome: outcome, amount: amount, price: price}) do
    %{"slug" => slug, "outcome" => outcome, "amount" => amount, "price" => price}
  end

  defp run_and_parse(args, log_file, intended_price) do
    {exit_code, output} = runner().(args)

    with {:ok, record} <- read_last_record(log_file) do
      success = exit_code == 0 and record["success"] == true
      filled = filled_shares(record)
      executed = executed_price(record, filled)

      result = %{
        success: success,
        exit_code: exit_code,
        record: record,
        intended_price: intended_price,
        executed_price: executed,
        filled_shares: filled,
        error: record["error"]
      }

      if output != "" do
        Logger.debug("TradeExecutor output: #{String.trim(output)}")
      end

      {:ok, result}
    else
      {:error, reason} ->
        {:ok,
         %{
           success: false,
           exit_code: exit_code,
           record: nil,
           intended_price: intended_price,
           executed_price: nil,
           filled_shares: nil,
           error: "failed to read order log: #{inspect(reason)}"
         }}
    end
  end

  defp filled_shares(%{"response" => response, "request" => request})
       when is_map(response) and is_map(request) do
    cond do
      present?(response["takingAmount"]) ->
        parse_float(response["takingAmount"])

      present?(request["size_shares"]) ->
        parse_float(request["size_shares"])

      true ->
        nil
    end
  end

  defp filled_shares(_), do: nil

  defp executed_price(%{"response" => response}, filled_shares)
       when is_map(response) and is_number(filled_shares) and filled_shares > 0 do
    making = parse_float(response["makingAmount"])
    taking = parse_float(response["takingAmount"])

    cond do
      making && taking && taking > 0 ->
        making / taking

      true ->
        nil
    end
  end

  defp executed_price(_, _), do: nil

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true

  defp parse_float(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_float(val) when is_number(val), do: val * 1.0
  defp parse_float(_), do: nil

  defp global_flags(log_file) do
    ["--fak", "--log-file", log_file]
  end

  defp price_args(nil), do: []
  defp price_args(price), do: ["--price", to_string(price)]

  defp script_args do
    [script_path()]
  end

  defp script_path do
    Path.join(pybuy_dir(), "place_order.py")
  end

  defp pybuy_dir do
    Application.get_env(:vathbot, :pybuy_dir) ||
      Path.expand("../../pybuy", __DIR__)
  end

  defp python_executable do
    Application.get_env(:vathbot, :pybuy_python, "python3")
  end

  defp temp_log_file(prefix) do
    Path.join(
      System.tmp_dir!(),
      "vathbot_#{prefix}_#{System.unique_integer([:positive])}.jsonl"
    )
  end

  defp runner do
    Application.get_env(:vathbot, :trade_executor_runner, &default_runner/1)
  end

  defp default_runner(args) do
    [script | rest] = args
    python = python_executable()
    cd = pybuy_dir()

    case System.cmd(python, [script | rest],
           cd: cd,
           stderr_to_stdout: true,
           env: subprocess_env()
         ) do
      {output, 0} -> {0, output}
      {output, code} -> {code, output}
    end
  end

  defp subprocess_env do
    base = Map.new(System.get_env())

    case Vathbot.Secrets.credentials() do
      {:ok, creds} ->
        creds
        |> Map.take([
          "POLYMARKET_PRIVATE_KEY",
          "POLYMARKET_FUNDER",
          "POLYMARKET_SIGNATURE_TYPE"
        ])
        |> Map.merge(base)

      {:error, :locked} ->
        base
    end
  end
end
