defmodule LiveAgent.ScopeInspectorTest do
  use ExUnit.Case, async: false

  alias LiveAgent.ScopeInspector

  # Stand-in structs mirroring real Ash app shapes.
  defmodule User do
    defstruct [:id, :email, :name]
  end

  defmodule Org do
    defstruct [:id, :name]
  end

  defmodule Scope do
    defstruct [:actor, :tenant, :context]
  end

  setup do
    # Reset the persistent_term config between tests that touch overrides.
    on_exit(fn -> :persistent_term.erase({LiveAgent.Config, :tools}) end)
    :ok
  end

  describe "extract_scope/1" do
    test "reads a current_scope struct: actor, tenant, context, source_keys" do
      scope = %Scope{
        actor: %User{id: "u1", email: "doc@example.com"},
        tenant: "org_abc",
        context: %{request_id: "req-9"}
      }

      result = ScopeInspector.extract_scope(%{current_scope: scope, count: 3})

      assert result.raw_present
      assert result.source_keys == ["current_scope"]
      assert result.tenant == "org_abc"
      assert result.actor.module =~ "User"
      assert result.actor.id == "u1"
      assert result.actor.summary == "doc@example.com"
      assert result.context == %{"request_id" => "req-9"}
    end

    test "falls back to current_user + __tenant__ pair" do
      result =
        ScopeInspector.extract_scope(%{
          current_user: %User{id: 42, name: "Surgeon"},
          __tenant__: "org_b"
        })

      assert result.raw_present
      assert result.actor.id == "42"
      assert result.actor.summary == "Surgeon"
      assert result.tenant == "org_b"
      assert "current_user" in result.source_keys
      assert "__tenant__" in result.source_keys
    end

    test "summarizes a struct tenant (organization record)" do
      result =
        ScopeInspector.extract_scope(%{
          current_user: %User{id: 1, email: "a@b.c"},
          current_organization: %Org{id: "o7", name: "Acme"}
        })

      assert result.tenant.module =~ "Org"
      assert result.tenant.id == "o7"
      assert result.tenant.summary == "Acme"
    end

    test "tenant-only assign yields actor: nil" do
      result = ScopeInspector.extract_scope(%{current_organization: "org_c"})
      assert result.raw_present
      assert result.actor == nil
      assert result.tenant == "org_c"
    end

    test "raw_present: false when no scope-like assign exists" do
      result = ScopeInspector.extract_scope(%{count: 1, page: "home"})
      refute result.raw_present
      assert result.actor == nil
      assert result.tenant == nil
      assert result.source_keys == []
    end

    test "Ash.NotLoaded actor is treated as absent" do
      scope = %Scope{actor: %Ash.NotLoaded{}, tenant: "org_x"}
      result = ScopeInspector.extract_scope(%{current_scope: scope})
      assert result.actor == nil
      assert result.tenant == "org_x"
    end

    test "actor with no summary field falls back to id=" do
      result = ScopeInspector.extract_scope(%{current_user: %User{id: "only-id"}})
      assert result.actor.summary == "id=only-id"
    end

    test "honors scope_assign_keys config override" do
      :persistent_term.put({LiveAgent.Config, :tools}, %{scope_assign_keys: [:my_scope]})

      scope = %Scope{actor: %User{id: "z", email: "z@z.z"}, tenant: "t"}
      result = ScopeInspector.extract_scope(%{my_scope: scope})

      assert result.source_keys == ["my_scope"]
      assert result.actor.id == "z"
    end

    test "caps oversized context" do
      big = for i <- 1..2000, into: %{}, do: {"k#{i}", String.duplicate("x", 50)}
      scope = %Scope{actor: %User{id: "1"}, context: big}

      result = ScopeInspector.extract_scope(%{current_scope: scope})
      assert result.context["__truncated__"] == true
      assert result.context["byte_size"] > 4_000
    end
  end
end
