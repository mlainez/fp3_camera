defmodule Fp3Camera.Camera do
  @moduledoc """
  Which sensor sits in each slot, and the frame sizes it gives.

  The slots are fixed by the board: the rear camera hangs off CCI bus 0
  and the front one off CCI bus 1. What is fitted in them is not, so the
  sensor model comes from the device tree, which the kernel completes at
  boot with the parts it detected.

  The camera ISP takes sensor lines of at most 4288 pixels, so a mode
  wider than that, such as the front S5K3P9SP's full 4608x3456, is out of
  reach and that camera tops out at its binned mode. The sizes, read once
  per boot from the sensor's V4L2 subdevice:

    * `:width`, `:height` — the largest mode the ISP takes
    * `:binned` — `{width, height}` of the smallest one, which covers the
      same field of view at a fraction of the pixels
    * `:modes` — every mode the ISP takes, smallest first
    * `:pixel_array` — `{x, y, width, height}` of the sensor's active
      pixels
  """

  @cci "/proc/device-tree/soc@0/cci@1b0c000"
  @buses %{rear: 0, front: 1}

  # Widest sensor line the VFE pixel path takes
  @max_line 4288

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

  @doc "`sensor/1` plus the frame sizes."
  @spec info(camera()) :: {:ok, map()} | {:error, term()}
  def info(camera) do
    with {:ok, sensor} <- sensor(camera),
         {:ok, sizes} <- sizes(sensor.sensor) do
      {:ok, Map.merge(sensor, sizes)}
    end
  end

  defp sizes(model) do
    key = {__MODULE__, model}

    case :persistent_term.get(key, nil) do
      nil ->
        with {:ok, sizes} <- probe(model) do
          :persistent_term.put(key, sizes)
          {:ok, sizes}
        end

      sizes ->
        {:ok, sizes}
    end
  end

  defp probe(model) do
    with {:ok, dev} <- subdev(model) do
      {codes, _} = System.cmd("v4l2-ctl", ["-d", dev, "--list-subdev-mbus-codes", "pad=0"])

      modes =
        for [_, code] <- Regex.scan(~r/(0x[0-9a-f]+):/, codes),
            {sizes, 0} <- [list_sizes(dev, code)],
            [_, w, h] <- Regex.scan(~r/Size Range: (\d+)x(\d+)/, sizes),
            {w, h} = {String.to_integer(w), String.to_integer(h)},
            w <= @max_line,
            uniq: true,
            do: {w, h}

      case Enum.sort_by(modes, fn {w, h} -> w * h end) do
        [] ->
          {:error, {:no_isp_mode, model}}

        sorted ->
          {width, height} = List.last(sorted)

          {:ok,
           %{
             width: width,
             height: height,
             binned: hd(sorted),
             modes: sorted,
             pixel_array: pixel_array(dev)
           }}
      end
    end
  end

  # The sensor's active pixels {x, y, width, height}, which zoom crops into
  defp pixel_array(dev) do
    {out, _} =
      System.cmd("v4l2-ctl", ["-d", dev, "--get-subdev-selection", "pad=0,target=crop_bounds"])

    [_ | xywh] = Regex.run(~r/Left (\d+), Top (\d+), Width (\d+), Height (\d+)/, out)
    xywh |> Enum.map(&String.to_integer/1) |> List.to_tuple()
  end

  defp list_sizes(dev, code) do
    System.cmd("v4l2-ctl", ["-d", dev, "--list-subdev-framesizes", "pad=0,code=#{code}"])
  end

  # The sensor's subdevice, named "<model> <i2c bus>-<address>".
  defp subdev(model) do
    Path.wildcard("/sys/class/video4linux/v4l-subdev*")
    |> Enum.find(fn path -> match?({:ok, ^model <> " " <> _}, File.read("#{path}/name")) end)
    |> case do
      nil -> {:error, {:no_subdev, model}}
      path -> {:ok, "/dev/" <> Path.basename(path)}
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
end
