defmodule Vathbot.BtcNormalizeTest do
  use ExUnit.Case, async: false

  @date "2026-05-19"

  setup do
    tmp = Path.join(System.tmp_dir!(), "vathbot_btc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "btc_prices"))
    jsonl = Path.join(tmp, "btc_prices/chainlink_#{@date}.jsonl")
    File.cp!(Path.join(__DIR__, "../fixtures/btc_sample.jsonl"), jsonl)
    prev = Application.get_env(:vathbot, :data_root)
    Application.put_env(:vathbot, :data_root, tmp)
    on_exit(fn ->
      File.rm_rf!(tmp)
      if prev, do: Application.put_env(:vathbot, :data_root, prev), else: Application.delete_env(:vathbot, :data_root)
    end)
    :ok
  end

  test "ticks_from_jsonl dedupes same event_ts keeping latest received" do
    assert {:ok, rows} = Vathbot.BtcNormalize.ticks_from_jsonl("chainlink", @date)
    target_ts = DateTime.from_unix!(1_779_148_799_000, :millisecond)
    by_ts = Enum.filter(rows, &(&1.event_ts == target_ts))
    assert length(by_ts) == 1
    assert hd(by_ts).price == 76946.0
  end

  test "includes subscribe bulk points" do
    assert {:ok, rows} = Vathbot.BtcNormalize.ticks_from_jsonl("chainlink", @date)
    assert length(rows) == 2
    assert Enum.any?(rows, &(&1.price == 50_000.0))
  end

  test "compact_day writes parquet" do
    assert {:ok, n} = Vathbot.BtcNormalize.compact_day("chainlink", @date, force: true)
    assert n >= 1
    pq = Vathbot.DataWriter.full_path(Vathbot.DataWriter.btc_parquet_path("chainlink", @date))
    assert File.exists?(pq)
    df = Explorer.DataFrame.from_parquet!(pq)
    assert Explorer.DataFrame.n_rows(df) == n
  end
end
