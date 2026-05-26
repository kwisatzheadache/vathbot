defmodule VathbotTest do
  use ExUnit.Case

  test "application module loads" do
    assert Code.ensure_loaded?(Vathbot.Application)
  end
end
