defmodule Vathbot.Models.CopyWithBiasTest do
  use ExUnit.Case, async: true

  alias Vathbot.Models.CopyWithBias
  alias Vathbot.Types.Signal

  setup do
    model = new_model!(sample_event())
    start_ms = DateTime.to_unix(model.meta.event_start_time, :millisecond)
    {:ok, model: model, start_ms: start_ms}
  end

  test "no signal when up_bid is within MIN_BIAS of 0.5", %{model: model, start_ms: start_ms} do
    message =
      book_snapshot(start_ms + 71,
        up_bid: "0.51",
        down_bid: "0.49",
        up_ask: "0.52",
        down_ask: "0.50"
      )

    assert {:logs, entries, _} = CopyWithBias.handle_message(model, message)
    assert Enum.any?(entries, &(&1["kind"] == "timestamp_match"))

    no_signal = Enum.find(entries, &(&1["kind"] == "no_signal"))
    assert no_signal["reason"] == "insufficient_bias"
    assert no_signal["logged_at_utc"] =~ ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/
    assert no_signal["recorded_at_utc"] =~ ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/
    assert no_signal["details"]["start_bias"] == "UP"
    refute no_signal["details"]["passes_min_bias"]
  end

  test "no signal on start_bias tie", %{model: model, start_ms: start_ms} do
    message =
      book_snapshot(start_ms + 71,
        up_bid: "0.53",
        down_bid: "0.53",
        up_ask: "0.54",
        down_ask: "0.54"
      )

    assert {:logs, entries, _} = CopyWithBias.handle_message(model, message)
    no_signal = Enum.find(entries, &(&1["kind"] == "no_signal"))
    assert no_signal["reason"] == "start_bias_tie"
  end

  test "emits buy Up when start_bias is UP", %{model: model, start_ms: start_ms} do
    message =
      book_snapshot(start_ms + 71,
        up_bid: "0.53",
        down_bid: "0.51",
        up_ask: "0.54",
        down_ask: "0.52"
      )

    assert {:signal, %Signal{} = signal, updated, entries} =
             CopyWithBias.handle_message(model, message)

    assert Enum.any?(entries, &(&1["kind"] == "timestamp_match"))
    assert signal.outcome == "Up"
    assert signal.amount_usd == 1.0
    assert_in_delta signal.price, 0.54, 1.0e-9
    assert signal.slug == "btc-updown-5m-1779225300"
    assert updated.signal_emitted
  end

  test "emits buy Down when start_bias is DOWN", %{model: model, start_ms: start_ms} do
    message =
      book_snapshot(start_ms + 71,
        up_bid: "0.47",
        down_bid: "0.52",
        up_ask: "0.48",
        down_ask: "0.53"
      )

    assert {:signal, %Signal{outcome: "Down", price: price}, _, _} =
             CopyWithBias.handle_message(model, message)

    assert_in_delta price, 0.53, 1.0e-9
  end

  test "only one signal per event", %{model: model, start_ms: start_ms} do
    message =
      book_snapshot(start_ms + 71, up_bid: "0.53", down_bid: "0.51", up_ask: "0.54", down_ask: "0.52")

    assert {:signal, _, model, _} = CopyWithBias.handle_message(model, message)
    assert {:ok, _} = CopyWithBias.handle_message(model, message)
  end

  test "ignores snapshots outside 1s of event start", %{model: model, start_ms: start_ms} do
    message =
      book_snapshot(start_ms - 2_000, up_bid: "0.53", down_bid: "0.51", up_ask: "0.54", down_ask: "0.52")

    assert {:ok, _} = CopyWithBias.handle_message(model, message)
  end

  test "triggers within 1s before event start", %{model: model, start_ms: start_ms} do
    message =
      book_snapshot(start_ms - 500, up_bid: "0.53", down_bid: "0.51", up_ask: "0.54", down_ask: "0.52")

    assert {:signal, _, _, entries} = CopyWithBias.handle_message(model, message)
    assert Enum.any?(entries, &(&1["kind"] == "timestamp_match"))
  end

  test "ignores snapshots more than 1s after event start", %{model: model, start_ms: start_ms} do
    message =
      book_snapshot(start_ms + 2_000, up_bid: "0.53", down_bid: "0.51", up_ask: "0.54", down_ask: "0.52")

    assert {:ok, _} = CopyWithBias.handle_message(model, message)
  end

  test "evaluates on live stream book messages near event start", %{model: model, start_ms: start_ms} do
    ts = Integer.to_string(start_ms - 542)
    up_id = model.meta.up_token_id
    down_id = model.meta.down_token_id

    up_book = %{
      "event_type" => "book",
      "asset_id" => up_id,
      "timestamp" => ts,
      "recorded_at" => start_ms - 555,
      "asks" => [%{"price" => "0.48", "size" => "100"}],
      "bids" => [%{"price" => "0.47", "size" => "100"}]
    }

    down_book = %{
      "event_type" => "book",
      "asset_id" => down_id,
      "timestamp" => ts,
      "recorded_at" => start_ms - 554,
      "asks" => [%{"price" => "0.53", "size" => "100"}],
      "bids" => [%{"price" => "0.52", "size" => "100"}]
    }

    assert {:ok, model} = CopyWithBias.handle_message(model, up_book)

    assert {:signal, %Signal{outcome: "Down"}, _, entries} =
             CopyWithBias.handle_message(model, down_book)

    assert Enum.any?(entries, &(&1["kind"] == "timestamp_match"))
  end

  test "caches book messages outside window then evaluates at start", %{model: model, start_ms: start_ms} do
    up_id = model.meta.up_token_id
    down_id = model.meta.down_token_id

    early_up = %{
      "event_type" => "book",
      "asset_id" => up_id,
      "timestamp" => Integer.to_string(start_ms - 5_000),
      "recorded_at" => start_ms - 5_000,
      "asks" => [%{"price" => "0.48", "size" => "100"}],
      "bids" => [%{"price" => "0.47", "size" => "100"}]
    }

    in_window_down = %{
      "event_type" => "book",
      "asset_id" => down_id,
      "timestamp" => Integer.to_string(start_ms - 100),
      "recorded_at" => start_ms - 100,
      "asks" => [%{"price" => "0.53", "size" => "100"}],
      "bids" => [%{"price" => "0.52", "size" => "100"}]
    }

    assert {:ok, model} = CopyWithBias.handle_message(model, early_up)

    assert {:signal, %Signal{outcome: "Down"}, _, entries} =
             CopyWithBias.handle_message(model, in_window_down)

    assert Enum.any?(entries, &(&1["kind"] == "timestamp_match"))
  end

  test "uses book timestamp not recorded_at for start window", %{model: model, start_ms: start_ms} do
    message =
      book_snapshot(start_ms + 5_000,
        up_bid: "0.53",
        down_bid: "0.51",
        up_ask: "0.54",
        down_ask: "0.52"
      )
      |> put_in(["books", Access.at(0), "timestamp"], Integer.to_string(start_ms + 71))
      |> put_in(["books", Access.at(1), "timestamp"], Integer.to_string(start_ms + 71))

    assert {:signal, _, _, entries} = CopyWithBias.handle_message(model, message)
    match = Enum.find(entries, &(&1["kind"] == "timestamp_match"))
    assert match["event_ms"] == start_ms + 71
    assert match["delta_ms"] == 71
  end

  test "trades when abs(up_bid - 0.5) equals MIN_BIAS exactly", %{model: model, start_ms: start_ms} do
    message =
      book_snapshot(start_ms + 71,
        up_bid: "0.52",
        down_bid: "0.50",
        up_ask: "0.53",
        down_ask: "0.51"
      )

    assert {:signal, %Signal{outcome: "Up"}, _, _} = CopyWithBias.handle_message(model, message)
  end

  describe "live_trading_enabled?/2" do
    test "enabled for 5m events during 02:00–05:59 UTC", %{model: model} do
      assert CopyWithBias.live_trading_enabled?(model, ~U[2026-05-25 02:00:00Z])
      assert CopyWithBias.live_trading_enabled?(model, ~U[2026-05-25 04:30:00Z])
      assert CopyWithBias.live_trading_enabled?(model, ~U[2026-05-25 05:59:59Z])
    end

    test "disabled for 5m events outside 02:00–06:00 UTC", %{model: model} do
      refute CopyWithBias.live_trading_enabled?(model, ~U[2026-05-25 01:59:59Z])
      refute CopyWithBias.live_trading_enabled?(model, ~U[2026-05-25 06:00:00Z])
      refute CopyWithBias.live_trading_enabled?(model, ~U[2026-05-25 23:00:00Z])
    end

    test "enabled for 15m events during 00:00–04:59 UTC" do
      event_15m = %{sample_event() | interval: :fifteen_min, slug: "btc-updown-15m-1779225300"}
      model_15m = new_model!(event_15m)

      assert CopyWithBias.live_trading_enabled?(model_15m, ~U[2026-05-25 00:00:00Z])
      assert CopyWithBias.live_trading_enabled?(model_15m, ~U[2026-05-25 04:30:00Z])
      assert CopyWithBias.live_trading_enabled?(model_15m, ~U[2026-05-25 04:59:59Z])
    end

    test "disabled for 15m events outside 00:00–05:00 UTC" do
      event_15m = %{sample_event() | interval: :fifteen_min, slug: "btc-updown-15m-1779225300"}
      model_15m = new_model!(event_15m)

      refute CopyWithBias.live_trading_enabled?(model_15m, ~U[2026-05-25 05:00:00Z])
      refute CopyWithBias.live_trading_enabled?(model_15m, ~U[2026-05-25 23:00:00Z])
    end

    test "5m and 15m windows differ at 01:00 UTC", %{model: model} do
      event_15m = %{sample_event() | interval: :fifteen_min, slug: "btc-updown-15m-1779225300"}
      model_15m = new_model!(event_15m)
      at_01 = ~U[2026-05-25 01:30:00Z]

      refute CopyWithBias.live_trading_enabled?(model, at_01)
      assert CopyWithBias.live_trading_enabled?(model_15m, at_01)
    end

    test "disabled for non-live-trading assets even in time window", %{model: _model} do
      event_eth = %{sample_event() | slug: "eth-updown-5m-1779225300"}
      model_eth = new_model!(event_eth)
      in_window = ~U[2026-05-25 04:30:00Z]

      refute CopyWithBias.live_trading_enabled?(model_eth, in_window)
      assert CopyWithBias.live_trading_skip_reason(model_eth, in_window) =~ "eth"
    end
  end

  defp new_model!(event) do
    {:ok, model} = CopyWithBias.new(event)
    model
  end

  defp sample_event do
    raw =
      Path.join(__DIR__, "../../fixtures/event.json")
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

  defp book_snapshot(recorded_at_ms, opts) do
    up_ask = Keyword.get(opts, :up_ask, "0.51")
    down_ask = Keyword.get(opts, :down_ask, "0.50")
    down_bid = Keyword.get(opts, :down_bid, "0.51")
    up_bid = Keyword.get(opts, :up_bid, "0.52")
    ts = Integer.to_string(recorded_at_ms)

    %{
      "event_type" => "book_snapshot",
      "recorded_at" => recorded_at_ms,
      "books" => [
        %{
          "asset_id" => "100535788273037192096679297787678443651387221019721763293954558367106318543737",
          "asks" => [%{"price" => up_ask, "size" => "100"}],
          "bids" => [%{"price" => up_bid, "size" => "100"}],
          "timestamp" => ts
        },
        %{
          "asset_id" => "41387220538561275025131545804502245232730126565556128904196143457449813744094",
          "asks" => [%{"price" => down_ask, "size" => "100"}],
          "bids" => [%{"price" => down_bid, "size" => "100"}],
          "timestamp" => ts
        }
      ]
    }
  end
end
