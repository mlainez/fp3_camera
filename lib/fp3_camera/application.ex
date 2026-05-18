defmodule Fp3Camera.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Fp3Camera.Manager,
      Fp3Camera.Capture,
      # Supervises Fp3Camera.Subscriber processes — one per call to
      # Fp3Camera.subscribe/2. Crashes / subscriber exits clean up here.
      {DynamicSupervisor,
       name: Fp3Camera.StreamSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Fp3Camera.Supervisor)
  end
end
