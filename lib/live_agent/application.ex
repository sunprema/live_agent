defmodule LiveAgent.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    children = [LiveAgent.BrowserStateStore]
    Supervisor.start_link(children, strategy: :one_for_one, name: LiveAgent.Supervisor)
  end
end
