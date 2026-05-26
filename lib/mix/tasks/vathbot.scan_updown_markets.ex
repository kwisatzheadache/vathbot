defmodule Mix.Tasks.Vathbot.ScanUpdownMarkets do
  @shortdoc "Probe Gamma for crypto Up/Down 5m/15m markets by asset"

  @moduledoc """
  Scans Polymarket Gamma for recurring crypto Up/Down events.

  Slugs follow `{asset}-updown-{5m|15m}-{unix_epoch}`. Use this when adding
  assets to `:updown_assets` in config.

      mix vathbot.scan_updown_markets
      mix vathbot.scan_updown_markets --epoch 1779837300

  Does not start recorders or schedulers.
  """

  use Mix.Task

  @switches [epoch: :integer]
  @aliases [e: :epoch]

  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)
    epoch = Keyword.get(opts, :epoch)

    Application.put_env(:vathbot, :start_runtime, false)
    Mix.Task.run("app.start")

    results = Vathbot.MarketDiscovery.scan_updown_assets(epoch)

    if map_size(results) == 0 do
      Mix.shell().info("No up/down markets found at probe epoch.")
    else
      Mix.shell().info("Asset   5m                              15m")
      Mix.shell().info("------  ------------------------------  ------------------------------")

      for {asset, intervals} <- Enum.sort_by(results, fn {a, _} -> a end) do
        t5 = Map.get(intervals, "5m", "—")
        t15 = Map.get(intervals, "15m", "—")
        Mix.shell().info("#{String.pad_trailing(asset, 6)}  #{truncate(t5, 30)}  #{truncate(t15, 30)}")
      end

      Mix.shell().info("")
      Mix.shell().info("Configured :updown_assets: #{inspect(Vathbot.MarketDiscovery.updown_assets())}")
    end
  end

  defp truncate(title, max) when is_binary(title) do
    if String.length(title) > max do
      String.slice(title, 0, max - 1) <> "…"
    else
      title
    end
  end

  defp truncate(_, _), do: "—"
end
