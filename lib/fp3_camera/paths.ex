defmodule Fp3Camera.Paths do
  @moduledoc false
  # Where the system binaries and fp3-cam-setup's conf files live.
  #
  # The defaults are where nerves_system_fp3's fp3-camera-utils package
  # installs them. Both are overridable from the application environment,
  # mostly so the host test suite can stand in fakes:
  #
  #     config :fp3_camera, :binaries, cam_snap: "/path/to/cam-snap"
  #     config :fp3_camera, :conf_dir, "/tmp/fake-run"
  #
  # Note that cam-snap and cam-stream call /usr/bin/fp3-cam-setup and read
  # /run/fp3-cam-<camera>.conf themselves, so on a device these overrides
  # only change what *this library* runs and reads.

  @defaults [
    cam_snap: "/usr/bin/cam-snap",
    cam_stream: "/usr/bin/cam-stream",
    fp3_cam_setup: "/usr/bin/fp3-cam-setup"
  ]

  @type binary_name :: :cam_snap | :cam_stream | :fp3_cam_setup

  @spec binary(binary_name()) :: Path.t()
  def binary(name) when is_map_key(%{cam_snap: 1, cam_stream: 1, fp3_cam_setup: 1}, name) do
    :fp3_camera
    |> Application.get_env(:binaries, [])
    |> Keyword.get(name, Keyword.fetch!(@defaults, name))
  end

  @doc """
  `{:ok, path}` if the binary is present, `{:error, {:enoent, path}}` if
  not — so a system image without fp3-camera-utils yields an error tuple
  rather than an exception out of `System.cmd/3` or `Port.open/2`.
  """
  @spec executable(binary_name()) :: {:ok, Path.t()} | {:error, {:enoent, Path.t()}}
  def executable(name) do
    path = binary(name)
    if File.regular?(path), do: {:ok, path}, else: {:error, {:enoent, path}}
  end

  @spec conf_path(atom()) :: Path.t()
  def conf_path(camera) do
    :fp3_camera
    |> Application.get_env(:conf_dir, "/run")
    |> Path.join("fp3-cam-#{camera}.conf")
  end
end
