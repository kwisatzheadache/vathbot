defmodule Vathbot.MarketNormalizeTest do
  use ExUnit.Case, async: false

  alias Vathbot.MarketNormalize

  @slug "btc-updown-5m-test"
  @jsonl_rel "5m/#{@slug}/market.jsonl"

  setup do
    tmp = Path.join(System.tmp_dir!(), "vathbot_test_#{System.unique_integer([:positive])}")
    dir = Path.join(tmp, "5m/#{@slug}")
    File.mkdir_p!(dir)
    File.cp!(Path.join(__DIR__, "../fixtures/market_sample.jsonl"), Path.join(dir, "market.jsonl"))
    prev = Application.get_env(:vathbot, :data_root)
    Application.put_env(:vathbot, :data_root, tmp)
    on_exit(fn ->
      File.rm_rf!(tmp)
      if prev, do: Application.put_env(:vathbot, :data_root, prev), else: Application.delete_env(:vathbot, :data_root)
    end)
    {:ok, meta: sample_meta(), tmp: tmp}
  end

  test "metadata_from_event", %{} do
    assert {:ok, meta} = MarketNormalize.metadata_from_event(sample_event())
    assert meta.slug == "btc-updown-5m-1779225300"
    assert meta.interval_minutes == 5
    assert meta.up_token_id != ""
    assert meta.down_token_id != ""
    assert DateTime.compare(meta.event_start_time, meta.end_time) == :lt
  end

  test "ticks_from_jsonl", %{meta: meta} do
    assert {:ok, rows} = MarketNormalize.ticks_from_jsonl(@jsonl_rel, meta)
    assert length(rows) == 4
    assert Enum.count(rows, &(&1.event_type == "book_snapshot")) == 2
    assert Enum.count(rows, &(&1.event_type == "price_change")) == 2
    assert rows == Enum.sort_by(rows, fn r -> {DateTime.to_unix(r.event_ts, :microsecond), r.outcome} end)

    [first | _] = rows
    assert first.slug == @slug
    assert first.mid == (first.best_bid + first.best_ask) / 2.0
    assert_in_delta first.spread, first.best_ask - first.best_bid, 1.0e-9
  end

  test "write_ticks_parquet_from_jsonl streams to sorted parquet", %{meta: meta, tmp: tmp} do
    out = "5m/#{@slug}/ticks_stream.parquet"
    assert {:ok, 4} = MarketNormalize.write_ticks_parquet_from_jsonl(@jsonl_rel, out, meta, batch_size: 2)

    df = Explorer.DataFrame.from_parquet!(Path.join(tmp, out))
    assert Explorer.DataFrame.n_rows(df) == 4
  end

  defp sample_meta do
    {:ok, meta} = MarketNormalize.metadata_from_event(sample_event())
    %{meta | slug: @slug}
  end

  defp sample_event do
    raw =
      Path.join(__DIR__, "../fixtures/event.json")
      |> File.read!()
      |> Jason.decode!()

    market = hd(raw["markets"])

    %Vathbot.MarketDiscovery.BTCUpDownEvent{
      slug: "btc-updown-5m-1779225300",
      interval: :five_min,
      clob_token_ids: Jason.decode!(market["clobTokenIds"]),
      outcomes: Jason.decode!(market["outcomes"]),
      condition_id: market["conditionId"],
      start_time: nil,
      end_time: nil,
      raw: raw
    }
  end
end
