defmodule LiveAgent.KeyPathTest do
  use ExUnit.Case, async: true

  alias LiveAgent.KeyPath

  describe "get/2" do
    test "fetches a top-level string key" do
      assert {:ok, 5} = KeyPath.get(%{"count" => 5}, "count")
    end

    test "walks a nested dot-path (string keys)" do
      data = %{"alert" => %{"level" => "emergency"}}
      assert {:ok, "emergency"} = KeyPath.get(data, "alert.level")
    end

    test "matches atom keys via the existing-atom fallback" do
      data = %{alert: %{level: "yellow"}}
      assert {:ok, "yellow"} = KeyPath.get(data, "alert.level")
    end

    test "prefers a string key when both string and atom exist" do
      data = %{"k" => "string-wins", k: "atom"}
      assert {:ok, "string-wins"} = KeyPath.get(data, "k")
    end

    test "returns :not_found for a missing key" do
      assert :not_found = KeyPath.get(%{"a" => 1}, "b")
      assert :not_found = KeyPath.get(%{"a" => %{"b" => 1}}, "a.c")
    end

    test "returns :not_found when descending into a non-map" do
      assert :not_found = KeyPath.get(%{"a" => 5}, "a.b")
    end

    test "an unknown segment that is not an existing atom is :not_found, not a crash" do
      # the atom should never have been created by this lookup
      assert :not_found = KeyPath.get(%{a: 1}, "definitely_not_an_existing_atom_xyz.deep")
    end

    test "accepts a pre-split list of segments" do
      assert {:ok, 1} = KeyPath.get(%{"a" => %{"b" => 1}}, ["a", "b"])
    end

    test "empty path returns the whole value" do
      assert {:ok, %{"a" => 1}} = KeyPath.get(%{"a" => 1}, [])
    end

    test "nil values are returned as {:ok, nil}, distinct from :not_found" do
      assert {:ok, nil} = KeyPath.get(%{"a" => nil}, "a")
    end
  end
end
