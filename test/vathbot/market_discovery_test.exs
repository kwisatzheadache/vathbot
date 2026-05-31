defmodule Vathbot.MarketDiscoveryTest do
  use ExUnit.Case, async: true

  alias Vathbot.MarketDiscovery

  describe "build_slugs/3" do
    test "generates slugs for each asset and interval" do
      slugs =
        MarketDiscovery.build_slugs(["btc", "eth"], [1_000, 1_300], [2_700])

      assert "btc-updown-5m-1000" in slugs
      assert "btc-updown-15m-2700" in slugs
      assert "eth-updown-5m-1300" in slugs
      assert "eth-updown-15m-2700" in slugs
      assert length(slugs) == 6
    end
  end

  describe "asset_from_slug/1" do
    test "parses asset from slug" do
      assert MarketDiscovery.asset_from_slug("eth-updown-5m-1779837300") == "eth"
      assert MarketDiscovery.asset_from_slug("btc-updown-15m-1779837300") == "btc"
      assert MarketDiscovery.asset_from_slug("invalid") == nil
    end
  end

  describe "next_aligned_timestamps/3" do
    test "aligns to interval boundary after epoch" do
      # epoch 1779837123, 5m interval → next boundary 1779837300
      assert MarketDiscovery.next_aligned_timestamps(1_779_837_123, 300, 2) ==
               [1_779_837_300, 1_779_837_600]
    end
  end

  describe "discovery_window_minutes/0" do
    test "reads from application env" do
      prev = Application.get_env(:vathbot, :discovery_window_minutes)
      Application.put_env(:vathbot, :discovery_window_minutes, 7)
      assert MarketDiscovery.discovery_window_minutes() == 7
      Application.put_env(:vathbot, :discovery_window_minutes, prev)
    end
  end
end
