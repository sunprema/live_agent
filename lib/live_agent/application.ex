defmodule LiveAgent.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    children = [LiveAgent.BrowserStateStore, LiveAgent.EventStore]
    Supervisor.start_link(children, strategy: :one_for_one, name: LiveAgent.Supervisor)
  end
end
