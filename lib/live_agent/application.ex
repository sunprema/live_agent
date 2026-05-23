defmodule LiveAgent.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    children = [
      LiveAgent.BrowserStateStore,
      LiveAgent.EventStore,
      LiveAgent.StateTimeline,
      LiveAgent.AsyncInspector,
      LiveAgent.ComponentTreeStore,
      LiveAgent.WatchStore,
      LiveAgent.PanelStatus,
      LiveAgent.CommandQueue,
      LiveAgent.ErrorStore,
      LiveAgent.ConsoleLogStore
    ]
    Supervisor.start_link(children, strategy: :one_for_one, name: LiveAgent.Supervisor)
  end
end
