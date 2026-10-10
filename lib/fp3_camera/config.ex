defmodule Fp3Camera.Config do
  @moduledoc """
  Per-sensor, per-mode capture defaults.

  Settings vary by **fitted part** — the modules are sold separately and
  a phone can carry any mix of the Fairphone 3 and 3+ sensors — and by
  **mode**, stills (`:snap`) or video (`:stream`), so they are kept per
  sensor and mode.

  Resolution order, later winning:

    1. `config :fp3_camera, :defaults, [...]` — applies to everything
    2. `config :fp3_camera, :sensor_defaults, %{"s5kgm1sp" => [...]}`
    3. runtime `put/2`, optionally persisted with `save/0`
    4. options passed to the call itself

  So a calibration session is `put/2` until it looks right, then
  `save/0`, and it survives the reboot.
  """

  @store "/root/fp3-camera.config"

  # What a saved file keeps; settings older versions took are dropped
  @kept Fp3Camera.Pipeline.settings() ++
          [:binned, :width, :height, :quality, :frames, :framerate, :bitrate, :gop]

  @doc """
  The merged options for `camera` in `mode` (`:snap` or `:stream`),
  with `opts` from the call site winning over everything.
  """
  def resolve(camera, mode, opts \\ []) do
    sensor = sensor_for(camera)

    Application.get_env(:fp3_camera, :defaults, [])
    |> merge(sensor_config(sensor))
    |> merge(runtime(sensor, mode))
    |> merge(opts)
  end

  @doc """
  Override settings at runtime for a scope, which is one of:

    * `:all` — every camera and mode
    * `{sensor, mode}` — e.g. `{"s5kgm1sp", :stream}`
    * `{camera, mode}` — e.g. `{:rear, :stream}`, resolved to the
      sensor currently fitted in that slot

  Merges into what is already set; a key with `nil` clears it.

      Fp3Camera.Config.put({:rear, :snap}, exposure: 20_000, gain: 2.0)
  """
  def put(scope, opts) when is_list(opts) do
    key = normalise(scope)
    all = runtime_all()
    merged = all |> Map.get(key, []) |> merge(opts) |> Enum.reject(&match?({_, nil}, &1))
    Application.put_env(:fp3_camera, :runtime_config, Map.put(all, key, merged))
    merged
  end

  @doc "Everything currently set at runtime, by scope."
  def get, do: runtime_all()

  @doc "Drop runtime overrides — for one scope, or all of them."
  def reset(scope \\ :all)

  def reset(:all) do
    Application.put_env(:fp3_camera, :runtime_config, %{})
    :ok
  end

  def reset(scope) do
    Application.put_env(:fp3_camera, :runtime_config, Map.delete(runtime_all(), normalise(scope)))
    :ok
  end

  @doc """
  Persist the runtime overrides to #{@store} so they outlive a reboot.
  Loaded automatically at application start.
  """
  def save(path \\ @store) do
    File.write(path, :erlang.term_to_binary(runtime_all()))
  end

  @doc "Load persisted overrides. Missing or corrupt file is not an error."
  def load(path \\ @store) do
    with {:ok, bin} <- File.read(path),
         {:ok, map} <- safe_decode(bin) do
      map = Map.new(map, fn {scope, opts} -> {scope, Keyword.take(opts, @kept)} end)
      Application.put_env(:fp3_camera, :runtime_config, map)
      {:ok, map}
    else
      _ -> {:ok, %{}}
    end
  end

  ## Internals

  defp safe_decode(bin) do
    {:ok, :erlang.binary_to_term(bin, [:safe])}
  rescue
    # A truncated or foreign file should not stop the camera from working.
    _ -> :error
  end

  defp runtime_all, do: Application.get_env(:fp3_camera, :runtime_config, %{})

  defp runtime(sensor, mode) do
    all = runtime_all()

    Map.get(all, :all, [])
    |> merge(Map.get(all, {sensor, mode}, []))
  end

  defp sensor_config(nil), do: []

  defp sensor_config(sensor) do
    Application.get_env(:fp3_camera, :sensor_defaults, %{})
    |> Map.get(sensor, [])
  end

  defp normalise({camera, mode}) when camera in [:rear, :front],
    do: {sensor_for(camera), mode}

  defp normalise(other), do: other

  defp sensor_for(camera) do
    case Fp3Camera.Camera.sensor(camera) do
      {:ok, %{sensor: sensor}} -> sensor
      {:error, _} -> nil
    end
  end

  # Keyword.merge, but tolerant of the same key appearing twice on the
  # left, which Keyword.merge/2 would otherwise keep.
  defp merge(base, override) do
    Enum.reduce(override, base, fn {k, v}, acc -> Keyword.put(acc, k, v) end)
  end
end
