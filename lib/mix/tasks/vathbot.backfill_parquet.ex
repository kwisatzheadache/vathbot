defmodule Mix.Tasks.Vathbot.BackfillParquet do
  @shortdoc "Write ticks.parquet + metadata.parquet for existing market JSONL dirs"

  @moduledoc """
  Walks `data/{5m,15m}/*/market.jsonl` and writes parquet for each slug.

      mix vathbot.backfill_parquet
      mix vathbot.backfill_parquet --interval 5m --limit 10
      mix vathbot.backfill_parquet --no-runtime
      mix vathbot.backfill_parquet --concurrency 2   # only if you have headroom

  Each slug loads its full `market.jsonl` into memory before writing parquet.
  Default concurrency is **1** to keep RAM predictable on large files.
  """

  use Mix.Task

  @intervals %{
    "5m" => :five_min,
    "15m" => :fifteen_min
  }

  @switches [
    interval: :string,
    limit: :integer,
    force: :boolean,
    no_runtime: :boolean,
    concurrency: :integer
  ]

  @aliases [i: :interval, n: :limit, f: :force]

  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    if opts[:no_runtime] do
      Application.put_env(:vathbot, :start_runtime, false)
    end

    Mix.Task.run("app.start")

    intervals =
      case Keyword.get(opts, :interval) do
        nil -> @intervals
        label -> %{label => Map.fetch!(@intervals, label)}
      end

    limit = Keyword.get(opts, :limit)
    force = Keyword.get(opts, :force, false)
    concurrency = Keyword.get(opts, :concurrency, 1)

    slugs =
      intervals
      |> Enum.flat_map(fn {label, interval} ->
        data_dir = Path.join([Vathbot.DataWriter.data_root(), label])

        if File.dir?(data_dir) do
          data_dir
          |> File.ls!()
          |> Enum.filter(fn name ->
            File.regular?(Path.join([data_dir, name, "market.jsonl"]))
          end)
          |> maybe_limit(limit)
          |> Enum.map(fn slug -> {slug, interval} end)
        else
          []
        end
      end)

    total = length(slugs)
    IO.puts("Backfilling #{total} slug(s) (concurrency #{concurrency})...")

    stats = %{ok: 0, skipped: 0, failed: 0, ticks: 0}

    stats =
      slugs
      |> Task.async_stream(
        fn {slug, interval} ->
          maybe_remove_parquets(slug, interval, force)
          {slug, Vathbot.MarketFinalizer.finalize_market_sync(slug, interval)}
        end,
        max_concurrency: concurrency,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.reduce(stats, fn
        {:ok, {slug, {:ok, count}}}, acc ->
          IO.write("\r  ok #{acc.ok + 1}/#{total}  #{slug}                    ")
          %{acc | ok: acc.ok + 1, ticks: acc.ticks + count}

        {:ok, {slug, {:error, :enoent}}}, acc ->
          IO.write("\r  skip #{acc.skipped + 1}/#{total} #{slug} (no jsonl)     ")
          %{acc | skipped: acc.skipped + 1}

        {:ok, {slug, {:error, _}}}, acc ->
          IO.write("\r  fail #{acc.failed + 1}/#{total} #{slug}               ")
          %{acc | failed: acc.failed + 1}

        {:exit, reason}, acc ->
          IO.puts("\n  task crashed: #{inspect(reason)}")
          %{acc | failed: acc.failed + 1}
      end)

    IO.puts("""

    Done: #{stats.ok} parquet(s) written (#{stats.ticks} tick rows), #{stats.skipped} skipped, #{stats.failed} failed
    """)
  end

  defp maybe_remove_parquets(slug, interval, true) do
    for path <- [
          Vathbot.DataWriter.ticks_parquet_path(slug, interval),
          Vathbot.DataWriter.metadata_parquet_path(slug, interval)
        ] do
      full = Vathbot.DataWriter.full_path(path)
      if File.exists?(full), do: File.rm!(full)
    end
  end

  defp maybe_remove_parquets(_slug, _interval, false), do: :ok

  defp maybe_limit(list, nil), do: list
  defp maybe_limit(list, n), do: Enum.take(list, n)
end
