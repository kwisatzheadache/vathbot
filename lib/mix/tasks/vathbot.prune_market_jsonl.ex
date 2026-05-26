defmodule Mix.Tasks.Vathbot.PruneMarketJsonl do
  @shortdoc "Delete market.jsonl when ticks + metadata parquet already exist"

  @moduledoc """
  One-off cleanup: removes `market.jsonl` for slugs that already have finalized parquet.

  Requires both `ticks.parquet` and `metadata.parquet` to exist and be readable
  (so live markets with only metadata from recorder start are not touched).

      mix vathbot.prune_market_jsonl
      mix vathbot.prune_market_jsonl --dry-run
      mix vathbot.prune_market_jsonl --interval 5m --limit 20

  Does not start recorders or schedulers (uses `--no-runtime` by default).
  """

  use Mix.Task

  @intervals %{
    "5m" => :five_min,
    "15m" => :fifteen_min
  }

  @switches [
    interval: :string,
    limit: :integer,
    dry_run: :boolean
  ]

  @aliases [i: :interval, n: :limit]

  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    dry_run? = Keyword.get(opts, :dry_run, false)
    limit = Keyword.get(opts, :limit)

    Application.put_env(:vathbot, :start_runtime, false)
    Mix.Task.run("app.start")

    intervals =
      case Keyword.get(opts, :interval) do
        nil -> @intervals
        label -> %{label => Map.fetch!(@intervals, label)}
      end

    candidates =
      intervals
      |> Enum.flat_map(&slugs_with_jsonl/1)
      |> maybe_limit(limit)

    total = length(candidates)
    IO.puts("Found #{total} market.jsonl file(s) under #{Vathbot.DataWriter.data_root()}")

    stats = Enum.reduce(candidates, %{deleted: 0, skipped: 0, failed: 0}, fn entry, acc ->
      process(entry, dry_run?, acc)
    end)

    action = if dry_run?, do: "would delete", else: "deleted"

    IO.puts("""
    Done: #{stats.deleted} #{action}, #{stats.skipped} skipped (no parquet), #{stats.failed} failed
    """)
  end

  defp slugs_with_jsonl({label, interval}) do
    data_dir = Path.join([Vathbot.DataWriter.data_root(), label])

    if File.dir?(data_dir) do
      for slug <- File.ls!(data_dir),
          jsonl = Path.join([data_dir, slug, "market.jsonl"]),
          File.regular?(jsonl) do
        {slug, interval, jsonl}
      end
    else
      []
    end
  end

  defp process({slug, interval, jsonl_path}, dry_run?, acc) do
    if parquet_ready?(slug, interval) do
      if dry_run? do
        IO.puts("  dry-run  #{slug}")
        %{acc | deleted: acc.deleted + 1}
      else
        case Vathbot.DataWriter.remove_market_jsonl(slug, interval) do
          :ok ->
            IO.puts("  deleted  #{slug}  (#{jsonl_path})")
            %{acc | deleted: acc.deleted + 1}

          {:error, reason} ->
            IO.puts("  fail     #{slug}  #{inspect(reason)}")
            %{acc | failed: acc.failed + 1}
        end
      end
    else
      %{acc | skipped: acc.skipped + 1}
    end
  end

  defp parquet_ready?(slug, interval) do
    ticks = Vathbot.DataWriter.ticks_parquet_path(slug, interval)
    meta = Vathbot.DataWriter.metadata_parquet_path(slug, interval)
    valid_parquet_file?(ticks) and valid_parquet_file?(meta)
  end

  defp valid_parquet_file?(relative_path) do
    full = Vathbot.DataWriter.full_path(relative_path)
    File.exists?(full) and File.stat!(full).size >= 8
  end

  defp maybe_limit(list, nil), do: list
  defp maybe_limit(list, n), do: Enum.take(list, n)
end
