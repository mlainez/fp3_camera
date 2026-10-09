defmodule Fp3Camera.Camera do
  @moduledoc """
  Which sensor sits in each slot, and the frame sizes libcamera gives it.

  The slots are fixed by the board: the rear camera hangs off CCI bus 0
  and the front one off CCI bus 1. What is fitted in them is not, so the
  sensor model comes from the device tree, which the kernel completes at
  boot with the parts it detected.

  libcamera's software ISP trims a few pixels from each sensor mode, so
  the sizes it accepts are not the sensor's own. They are read once per
  boot from libcamera's log and cached:

    * `:width`, `:height` — the full-resolution mode
    * `:binned` — `{width, height}` of the smallest mode, which covers the
      same field of view at a fraction of the cost
  """

  @cci "/proc/device-tree/soc@0/cci@1b0c000"
  @buses %{rear: 0, front: 1}

  @type camera :: :rear | :front

  @doc "Sensor model and libcamera id of `camera`, without opening it."
  @spec sensor(camera()) :: {:ok, map()} | {:error, :not_fitted}
  def sensor(camera) when is_map_key(@buses, camera) do
    bus = "#{@cci}/i2c-bus@#{@buses[camera]}"

    case nodes(bus, "camera-sensor@") do
      [{node, model} | _] ->
        {:ok,
         %{
           camera: camera,
           sensor: model,
           id: "/base/soc@0/cci@1b0c000/i2c-bus@#{@buses[camera]}/#{node}",
           lens: with([{_, lens} | _] <- nodes(bus, "camera-lens@"), do: lens, else: (_ -> nil))
         }}

      [] ->
        {:error, :not_fitted}
    end
  end

  @doc "`sensor/1` plus the frame sizes, probing libcamera on first use."
  @spec info(camera()) :: {:ok, map()} | {:error, term()}
  def info(camera) do
    with {:ok, sensor} <- sensor(camera),
         {:ok, sizes} <- sizes(sensor.id) do
      {:ok, Map.merge(sensor, sizes)}
    end
  end

  defp sizes(id) do
    key = {__MODULE__, id}

    case :persistent_term.get(key, nil) do
      nil ->
        with {:ok, sizes} <- probe(id) do
          :persistent_term.put(key, sizes)
          {:ok, sizes}
        end

      sizes ->
        {:ok, sizes}
    end
  end

  # Configuring the camera for a tiny frame makes libcamera log every mode
  # it considered, as "Picked <raw> ... for max processed stream size <out>".
  defp probe(id) do
    args = ~w(-q libcamerasrc camera-name=#{id} ! video/x-raw,width=320,height=240
              ! identity eos-after=1 ! fakesink)

    {log, _status} =
      MuonTrap.cmd("gst-launch-1.0", args,
        env: [{"LIBCAMERA_LOG_LEVELS", "SimplePipeline:DEBUG"}],
        stderr_to_stdout: true,
        timeout: 20_000
      )

    picks =
      for [_, rw, rh, pw, ph] <-
            Regex.scan(
              ~r/Picked (\d+)x(\d+)-\S+ -> \S+ for max processed stream size (\d+)x(\d+)/,
              log
            ) do
        {{int(rw), int(rh)}, {int(pw), int(ph)}}
      end

    case Enum.max_by(picks, fn {_raw, {w, h}} -> w * h end, fn -> nil end) do
      nil ->
        {:error, {:probe_failed, String.slice(log, -500, 500)}}

      {{fw, fh}, {width, height}} ->
        {{bw, bh}, _} = Enum.min_by(picks, fn {{w, h}, _} -> w * h end)
        {:ok, %{width: width, height: height, binned: {bw - (fw - width), bh - (fh - height)}}}
    end
  end

  # [{node name, model}] of the enabled children of `bus` named `prefix*`.
  defp nodes(bus, prefix) do
    case File.ls(bus) do
      {:ok, names} ->
        for name <- Enum.sort(names),
            String.starts_with?(name, prefix),
            enabled?("#{bus}/#{name}"),
            {:ok, compatible} <- [File.read("#{bus}/#{name}/compatible")] do
          {name, compatible |> String.split(<<0>>) |> hd() |> String.split(",") |> List.last()}
        end

      {:error, _} ->
        []
    end
  end

  defp enabled?(node) do
    case File.read("#{node}/status") do
      {:ok, status} -> String.trim_trailing(status, <<0>>) in ["okay", "ok"]
      {:error, _} -> true
    end
  end

  defp int(s), do: String.to_integer(s)
end
