defmodule Direct.Supervisor do
  @moduledoc """
  The registry of running conversions and the supervisor of their workers.
  Put it in your application's tree:

      children = [Direct.Supervisor, …]
  """
  use Supervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Direct.Registry},
      {DynamicSupervisor, name: Direct.DynamicSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
