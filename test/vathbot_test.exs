defmodule VathbotTest do
  use ExUnit.Case
  doctest Vathbot

  test "greets the world" do
    assert Vathbot.hello() == :world
  end
end
