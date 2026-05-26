defmodule Vathbot.ParquetWriterTest do
  use ExUnit.Case, async: false

  setup do
    tmp = Path.join(System.tmp_dir!(), "vathbot_pq_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    prev = Application.get_env(:vathbot, :data_root)
    Application.put_env(:vathbot, :data_root, tmp)
    on_exit(fn ->
      File.rm_rf!(tmp)
      if prev, do: Application.put_env(:vathbot, :data_root, prev), else: Application.delete_env(:vathbot, :data_root)
    end)
    {:ok, tmp: tmp}
  end

  test "write and read ticks parquet" do
    ts = ~U[2026-05-19 21:15:00.123456Z]

    rows = [
      %{
        event_ts: ts,
        received_ts: ts,
        slug: "test-slug",
        outcome: "Up",
        best_bid: 0.5,
        best_ask: 0.51,
        mid: 0.505,
        spread: 0.01,
        event_type: "price_change"
      }
    ]

    path = "5m/test-slug/ticks.parquet"
    assert {:ok, 1} = Vathbot.ParquetWriter.write_ticks(path, rows)

    full = Vathbot.DataWriter.full_path(path)
    assert File.exists?(full)
    df = Explorer.DataFrame.from_parquet!(full)
    assert Explorer.DataFrame.n_rows(df) == 1
    assert Explorer.DataFrame.names(df) |> Enum.sort() ==
             ~w(best_ask best_bid event_ts event_type mid outcome received_ts slug spread)
  end

  test "write metadata parquet" do
    meta = %{
      slug: "test-slug",
      interval_minutes: 5,
      event_start_time: ~U[2026-05-19 21:15:00Z],
      end_time: ~U[2026-05-19 21:20:00Z],
      up_token_id: "up",
      down_token_id: "down",
      condition_id: "0xabc",
      market_id: "1",
      question: "q",
      resolution_source: "chainlink"
    }

    path = "5m/test-slug/metadata.parquet"
    :ok = Vathbot.ParquetWriter.write_metadata(path, meta)
    assert File.exists?(Vathbot.DataWriter.full_path(path))
  end
end
