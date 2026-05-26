defmodule Vathbot.MarketFinalizerTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  setup do
    tmp = Path.join(System.tmp_dir!(), "vathbot_fin_#{System.unique_integer([:positive])}")
    slug = "btc-updown-5m-finalizer-test"
    dir = Path.join(tmp, "5m/#{slug}")
    File.mkdir_p!(dir)
    File.cp!(Path.join(__DIR__, "../fixtures/market_sample.jsonl"), Path.join(dir, "market.jsonl"))
    event =
      Path.join(__DIR__, "../fixtures/event.json")
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("slug", slug)
    File.write!(Path.join(dir, "event.json"), Jason.encode!(event, pretty: true))

    prev = Application.get_env(:vathbot, :data_root)
    Application.put_env(:vathbot, :data_root, tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      if prev, do: Application.put_env(:vathbot, :data_root, prev), else: Application.delete_env(:vathbot, :data_root)
    end)

    {:ok, slug: slug, tmp: tmp}
  end

  test "finalize_market writes ticks parquet and removes jsonl", %{slug: slug, tmp: tmp} do
    jsonl_path = Path.join(tmp, "5m/#{slug}/market.jsonl")
    assert File.exists?(jsonl_path)

    assert {:ok, 4} = Vathbot.MarketFinalizer.finalize_market_sync(slug, :five_min)

    ticks_rel = Vathbot.DataWriter.ticks_parquet_path(slug, :five_min)
    df = Explorer.DataFrame.from_parquet!(Vathbot.DataWriter.full_path(ticks_rel))
    assert Explorer.DataFrame.n_rows(df) == 4
    refute File.exists?(jsonl_path)
  end
end
