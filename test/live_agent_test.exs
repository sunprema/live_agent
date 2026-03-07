defmodule LiveAgentTest do
  use ExUnit.Case
  doctest LiveAgent

  test "greets the world" do
    assert LiveAgent.hello() == :world
  end
end
