defmodule Fp3Camera.Config do
  @moduledoc """
  Per-sensor, per-mode capture defaults.

  Settings cannot live in one flat list, because two things vary
  independently. They vary by **fitted part** — the rear slot holds a
  Sony IMX363 on a Fairphone 3 and a Samsung S5KGM1SP on a 3+, the
  modules are sold separately, and a phone can carry any mix — and they
  vary by **mode**, because the stills and video paths are genuinely
  different pipelines. `cam-snap` demosaics with Malvar-He-Cutler at full
  resolution; `cam-stream` uses a cheaper bilinear pass on a 2x2-binned
  frame. The same sensor needs different white balance through each: on
  the IMX363, gains that render the still neutral leave the stream
  visibly green.

  Resolution order, later winning:

    1. `@builtin` below, chosen by sensor and mode
    2. `config :fp3_camera, :defaults, [...]` — applies to everything
    3. `config :fp3_camera, :sensor_defaults, %{"imx363" => [...]}`
    4. runtime `put/2`, optionally persisted with `save/0`
    5. options passed to the call itself

  So a calibration session is `put/2` until it looks right, then
  `save/0`, and it survives the reboot.
  """

  require Logger

  @store "/root/fp3-camera.config"

  # Measured, not guessed — but measured in *one* scene under *one* lamp,
  # which is exactly how much to trust them.
  #
  # The stream gains bring both rear cameras to R/G 1.00 and B/G 1.00 on
  # a white desk under a warm LED; the same scene reads R/G 0.79 / 0.85
  # on the IMX363 with the binary's own compile-time values. Real
  # calibration wants a known target under known illuminants, and an
  # earlier attempt at deriving per-part constants this way was wrong by
  # as much in the other direction once the light changed — so these are
  # a better starting point than a single table shared across four
  # sensors, and nothing more than that.
  #
  # Stills deliberately carry no wb here: cam-snap's own per-slot table
  # is already right for the S5KGM1SP and close for the rest, and
  # `awb: true` is the scene-adaptive alternative.
  @builtin %{
    "imx363" => %{
      snap: [exposure: :auto],
      stream: [wb: {1.90, 1.0, 1.53}]
    },
    "s5kgm1sp" => %{
      snap: [exposure: :auto],
      stream: [wb: {1.53, 1.0, 1.41}]
    },
    # Both front parts take awb rather than a fixed table. cam-snap's
    # front gains are 1.75/2.15, calibrated for neither of these: the
    # raw frames come off close to balanced already — S5K4H7YX read
    # R=130 G=133 B=131, S5K3P9SP R=81 G=86 B=84 — so those gains land
    # a heavy magenta on both, R/G 1.68 B/G 2.03 on the FP3. Gray-world
    # measured R/G 1.06 B/G 0.99 on the same scene, against an Android
    # reference of 1.01/1.03.
    "s5k4h7yx" => %{
      snap: [exposure: :auto, awb: true],
      stream: [wb: {1.37, 1.0, 1.24}]
    },
    # Full resolution works here now. It used to return pure noise: the
    # driver declared half this sensor's real link frequency for its
    # full-res mode only, which underclocked the VFE below the incoming
    # data rate. Fixed in the kernel (s5k3p9sp: full res runs at 732 MHz,
    # not 366), so the binned workaround that stood here is gone and this
    # camera gives its full 16 MP again.
    "s5k3p9sp" => %{
      snap: [exposure: :auto, awb: true],
      stream: [wb: {1.91, 1.0, 1.57}]
    }
  }

  @doc """
  The merged options for `camera` in `mode` (`:snap` or `:stream`),
  with `opts` from the call site winning over everything.
  """
  def resolve(camera, mode, opts \\ []) do
    sensor = sensor_for(camera)

    builtin =
      @builtin
      |> Map.get(sensor || "", %{})
      |> Map.get(mode, [])

    builtin
    |> merge(Application.get_env(:fp3_camera, :defaults, []))
    |> merge(sensor_config(sensor))
    |> merge(runtime(sensor, mode))
    |> merge(opts)
  end

  @doc """
  Override settings at runtime for a scope, which is one of:

    * `:all` — every camera and mode
    * `{sensor, mode}` — e.g. `{"imx363", :stream}`
    * `{camera, mode}` — e.g. `{:rear, :stream}`, resolved to the
      sensor currently fitted in that slot

  Merges into what is already set; a key with `nil` clears it.

      Fp3Camera.Config.put({:rear, :stream}, wb: {1.9, 1.0, 1.5})
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

  # The part actually fitted, from what fp3-cam-setup published. Keyed on
  # the bare model name, so the i2c address in the entity name — "imx363
  # 3-0010" — does not have to match.
  defp sensor_for(camera) do
    with {:ok, body} <- File.read("/run/fp3-cam-#{camera}.conf"),
         [_, value] <- Regex.run(~r/SENSOR='?([^'\n]+)'?/, body) do
      value |> String.split() |> List.first()
    else
      _ -> nil
    end
  end

  # Keyword.merge, but tolerant of the same key appearing twice on the
  # left, which Keyword.merge/2 would otherwise keep.
  defp merge(base, override) do
    Enum.reduce(override, base, fn {k, v}, acc -> Keyword.put(acc, k, v) end)
  end
end
