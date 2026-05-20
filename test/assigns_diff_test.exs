defmodule LiveAgent.AssignsDiffTest do
  use ExUnit.Case, async: true

  alias LiveAgent.AssignsDiff

  describe "diff/2" do
    test "empty when nothing changed" do
      d = AssignsDiff.diff(%{a: 1, b: 2}, %{a: 1, b: 2})
      assert AssignsDiff.empty?(d)
    end

    test "captures changed values with before/after" do
      d = AssignsDiff.diff(%{a: 1}, %{a: 2})
      assert d.changed == %{a: %{before: 1, after: 2}}
      assert d.added == %{}
      assert d.removed == %{}
    end

    test "captures added and removed keys" do
      d = AssignsDiff.diff(%{a: 1}, %{b: 2})
      assert d.added == %{b: 2}
      assert d.removed == %{a: 1}
    end

    test "truncates binaries over 256 bytes" do
      big = String.duplicate("x", 1000)
      d = AssignsDiff.diff(%{}, %{k: big})
      assert %{truncated: true, byte_size: 1000} = d.added.k
    end

    test "summarises lists over 50 elements" do
      list = Enum.to_list(1..100)
      d = AssignsDiff.diff(%{}, %{k: list})
      assert %{summary: true, count: 100, kind: "list"} = d.added.k
    end

    test "summarises maps over 50 keys" do
      big_map = for i <- 1..100, into: %{}, do: {i, i}
      d = AssignsDiff.diff(%{}, %{k: big_map})
      assert %{summary: true, count: 100, kind: "map"} = d.added.k
    end

    test "leaves small collections intact" do
      d = AssignsDiff.diff(%{}, %{k: [1, 2, 3]})
      assert d.added.k == [1, 2, 3]
    end
  end

  describe "bound_size/2" do
    test "passes through small diffs" do
      d = AssignsDiff.diff(%{}, %{a: 1})
      assert AssignsDiff.bound_size(d, 16_000) == d
    end

    test "replaces oversize diff with a summary" do
      big = String.duplicate("a", 50_000)
      d = %{
        changed: %{},
        added: %{a: big, b: big, c: big},
        removed: %{}
      }

      bounded = AssignsDiff.bound_size(d, 1_000)
      assert bounded.oversize == true
      assert :a in bounded.summary.added
      assert :b in bounded.summary.added
    end
  end
end
