defmodule LiveAgent.BaselineStoreTest do
  use ExUnit.Case, async: false

  alias LiveAgent.BaselineStore

  # 1x1 transparent PNG.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
       )

  setup do
    original = File.cwd!()
    tmp = Path.join(System.tmp_dir!(), "la_baseline_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.cd!(tmp)

    on_exit(fn ->
      File.cd!(original)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  describe "validate_name/1" do
    test "accepts filename-safe names" do
      assert {:ok, "cart"} = BaselineStore.validate_name("cart")
      assert {:ok, "cart-v2.1_final"} = BaselineStore.validate_name("cart-v2.1_final")
    end

    test "rejects empty, traversal, and unsafe characters" do
      assert {:error, _} = BaselineStore.validate_name("")
      assert {:error, _} = BaselineStore.validate_name("../etc/passwd")
      assert {:error, _} = BaselineStore.validate_name("a/b")
      assert {:error, _} = BaselineStore.validate_name("has space")
      assert {:error, _} = BaselineStore.validate_name(123)
    end
  end

  describe "put/get/list" do
    test "round-trips bytes and lists names" do
      assert {:ok, path} = BaselineStore.put("cart", @png)
      assert String.ends_with?(path, "screenshots/baselines/cart.png")
      assert File.exists?(path)

      assert {:ok, @png} = BaselineStore.get("cart")
      assert "cart" in BaselineStore.list()
    end

    test "get returns :not_found for a missing baseline" do
      assert {:error, :not_found} = BaselineStore.get("nope")
    end

    test "put overwrites an existing baseline" do
      assert {:ok, _} = BaselineStore.put("x", @png)
      assert {:ok, _} = BaselineStore.put("x", <<1, 2, 3>>)
      assert {:ok, <<1, 2, 3>>} = BaselineStore.get("x")
    end

    test "rejects unsafe names before touching disk" do
      assert {:error, _} = BaselineStore.put("../escape", @png)
    end
  end

  describe "put_diff/2" do
    test "writes under the diffs directory" do
      assert {:ok, path} = BaselineStore.put_diff("cart", @png)
      assert String.ends_with?(path, "screenshots/diffs/cart.png")
      assert File.exists?(path)
    end
  end
end
