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

  test "finalize_market_sync writes ticks parquet and removes jsonl", %{slug: slug, tmp: tmp} do
    jsonl_path = Path.join(tmp, "5m/#{slug}/market.jsonl")
    assert File.exists?(jsonl_path)

    assert {:ok, 4} = Vathbot.MarketFinalizer.finalize_market_sync(slug, :five_min)

    ticks_rel = Vathbot.DataWriter.ticks_parquet_path(slug, :five_min)
    df = Explorer.DataFrame.from_parquet!(Vathbot.DataWriter.full_path(ticks_rel))
    assert Explorer.DataFrame.n_rows(df) == 4
    refute File.exists?(jsonl_path)
  end

  test "finalize_market_sync is idempotent when parquet exists and jsonl is gone", %{slug: slug} do
    assert {:ok, 4} = Vathbot.MarketFinalizer.finalize_market_sync(slug, :five_min)
    assert {:ok, :already_done} = Vathbot.MarketFinalizer.finalize_market_sync(slug, :five_min)
  end

  describe "coordinator queue" do
    setup context do
      sup_name = :"finalizer_test_sup_#{System.unique_integer([:positive])}"
      coord_name = :"finalizer_test_coord_#{System.unique_integer([:positive])}"

      {:ok, _sup} = Task.Supervisor.start_link(name: sup_name)

      {:ok, _coord} =
        GenServer.start_link(
          Vathbot.MarketFinalizer.Coordinator,
          [max_concurrent: 2, task_supervisor: sup_name],
          name: coord_name
        )

      on_exit(fn ->
        for name <- [coord_name, sup_name] do
          case Process.whereis(name) do
            nil -> :ok
            pid -> try do GenServer.stop(pid) catch _, _ -> :ok end
          end
        end
      end)

      Map.put(context, :coord, coord_name)
    end

    test "drains queued jobs", %{slug: slug, coord: coord} do
      slugs =
        for i <- 0..2 do
          s = "#{slug}-q#{i}"
          dir = Path.join(Application.get_env(:vathbot, :data_root), "5m/#{s}")
          File.mkdir_p!(dir)
          File.cp!(Path.join(__DIR__, "../fixtures/market_sample.jsonl"), Path.join(dir, "market.jsonl"))

          event =
            Path.join(__DIR__, "../fixtures/event.json")
            |> File.read!()
            |> Jason.decode!()
            |> Map.put("slug", s)

          File.write!(Path.join(dir, "event.json"), Jason.encode!(event, pretty: true))
          s
        end

      Enum.each(slugs, fn s ->
        GenServer.cast(coord, {:enqueue, s, :five_min})
      end)

      wait_for(fn ->
        Enum.all?(slugs, fn s ->
          parquet = Vathbot.DataWriter.full_path(Vathbot.DataWriter.ticks_parquet_path(s, :five_min))
          File.exists?(parquet)
        end)
      end)

      state = :sys.get_state(coord)
      assert :queue.len(state.queue) == 0
      assert map_size(state.running) == 0
    end
  end

  defp wait_for(fun, attempts \\ 50) do
    if fun.() or attempts <= 0 do
      :ok
    else
      Process.sleep(100)
      wait_for(fun, attempts - 1)
    end
  end
end
