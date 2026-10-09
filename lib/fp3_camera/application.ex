defmodule Fp3Camera.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Bring back whatever the last calibration session saved.
    Fp3Camera.Config.load()

    children = [
      # Stream pipelines and frame subscribers run here.
      {DynamicSupervisor, name: Fp3Camera.StreamSupervisor, strategy: :one_for_one},
      Fp3Camera.Streams
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: Fp3Camera.Supervisor)
  end
end
