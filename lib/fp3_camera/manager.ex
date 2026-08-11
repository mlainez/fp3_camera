defmodule Fp3Camera.Manager do
  @moduledoc false
  # Brings up the CAMSS media pipeline so the requested camera's raw Bayer
  # frames land on a /dev/videoN node ready for GStreamer or cam-snap.
  #
  # The pipeline is configured by fp3-cam-setup, from the system's
  # fp3-camera-utils package, rather than by media-ctl calls made here.
  # That is deliberate. The camera modules are user-replaceable and the
  # Fairphone 3 and 3+ fit different silicon in the same slots, so the
  # sensor's entity name, native geometry and Bayer order all have to be
  # discovered at runtime — and this library is not the only thing that
  # needs them: cam-snap and cam-stream do too. Two implementations of
  # that lookup means two things to keep in step, and when this module
  # last carried its own copy it went stale: it hardcoded the Fairphone
  # 3+ sensors, so on a Fairphone 3 every media-ctl call silently missed
  # and VIDIOC_STREAMON failed with -EPIPE.
  #
  # So fp3-cam-setup owns the detection, and publishes what it found to
  # /run/fp3-cam-<camera>.conf for everyone else to read.
  #
  # What is genuinely static is the *slot topology* — which CSIPHY, CSID,
  # ISPIF and VFE RDI lane each slot is wired to, and which i2c address
  # its sensor answers on. That is a property of the mainboard, not of
  # the module plugged into it, so it stays here. Note that the /dev/videoN
  # path is NOT static and is deliberately absent: CAMSS registers those
  # nodes alongside Venus, so the numbering shifts between boots and
  # between phones. Only the entity name (msm_vfe0_videoN) is fixed. Rear and front take
  # non-overlapping paths through VFE0's three RDI lanes so both can be
  # wired simultaneously (VFE1 fails to start streaming on this SoC;
  # using it would mean chasing a clock/regulator binding).

  use GenServer
  require Logger

  @slots %{
    rear: %{
      i2c_address: "3-0010",
      csiphy: "msm_csiphy0",
      csid: "msm_csid0",
      ispif: "msm_ispif0",
      vfe_rdi: "msm_vfe0_rdi0",
      vfe_video: "msm_vfe0_video0"
    },
    front: %{
      i2c_address: "4-0010",
      csiphy: "msm_csiphy2",
      csid: "msm_csid1",
      ispif: "msm_ispif1",
      vfe_rdi: "msm_vfe0_rdi1",
      vfe_video: "msm_vfe0_video1"
    }
  }

  @setup_binary "fp3-cam-setup"

  @type camera :: :rear | :front
  @type mode :: :full | :binned

  ## Public API

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc """
  Static description of a camera slot: which CSIPHY, CSID, ISPIF and VFE
  RDI lane it is wired to, the media entity of its VFE video node, and
  the i2c address its sensor answers on.

  Deliberately no `/dev/videoN` here. CAMSS registers its video nodes
  alongside Venus and the numbers move between boots and between phones —
  the rear slot has been observed as `/dev/video0` and `/dev/video2` on
  the same hardware. Only the *entity* name is fixed; the device node has
  to be looked up, and `info/1` reports the one that was actually
  resolved.

  This also says nothing about which module is fitted. For that — the
  sensor, its native resolution and its Bayer order — use `resolved/1`.
  """
  @spec slot(camera()) :: map() | nil
  def slot(camera), do: Map.get(@slots, camera)

  @doc """
  Everything known about a camera: its slot topology merged with the
  sensor detected in it.

  Returns `{:error, :not_configured}` before `setup/1` has run for this
  camera, because until the pipeline is brought up nothing has looked at
  which module is present.
  """
  @spec info(camera()) :: {:ok, map()} | {:error, term()}
  def info(camera) when is_map_key(@slots, camera) do
    case resolved(camera) do
      {:ok, sensor} -> {:ok, Map.merge(@slots[camera], sensor)}
      {:error, _} = err -> err
    end
  end

  def info(camera), do: {:error, {:unknown_camera, camera}}

  @doc """
  What fp3-cam-setup found in this slot: `:sensor`, `:width`, `:height`,
  `:bayer`, `:subdev`, the `:video` node it resolved, and `:lens` if the
  module has one.

  `:video` and `:subdev` are looked up rather than assumed — neither
  numbering is stable across boots or across the two phone variants.
  """
  @spec resolved(camera()) :: {:ok, map()} | {:error, term()}
  def resolved(camera) when is_map_key(@slots, camera) do
    case read_conf(camera) do
      {:ok, conf} -> {:ok, conf}
      :error -> {:error, :not_configured}
    end
  end

  def resolved(camera), do: {:error, {:unknown_camera, camera}}

  @doc """
  Ensure the media-ctl pipeline for `camera` is configured.

  `:full` uses the sensor's native resolution and is what stills want;
  `:binned` uses its 2x2 binned mode, a quarter of the sensor-to-DRAM
  bandwidth and better SNR, which is what live video wants. Switching
  mode reconfigures even if the camera was already set up.
  """
  @spec setup(camera(), mode()) :: :ok | {:error, term()}
  def setup(camera, mode \\ :full)

  def setup(camera, mode) when is_map_key(@slots, camera) and mode in [:full, :binned] do
    GenServer.call(__MODULE__, {:setup, camera, mode}, 15_000)
  end

  def setup(camera, mode) when is_map_key(@slots, camera),
    do: {:error, {:unknown_mode, mode}}

  def setup(camera, _mode), do: {:error, {:unknown_camera, camera}}

  ## GenServer

  @impl true
  def init(_), do: {:ok, %{configured: %{}}}

  @impl true
  def handle_call({:setup, camera, mode}, _from, state) do
    if Map.get(state.configured, camera) == mode do
      {:reply, :ok, state}
    else
      case do_setup(camera, mode) do
        :ok ->
          {:reply, :ok, put_in(state.configured[camera], mode)}

        {:error, _} = err ->
          # Drop any cached mode: the pipeline is in an unknown state now,
          # so the next call must reconfigure rather than assume.
          {:reply, err, %{state | configured: Map.delete(state.configured, camera)}}
      end
    end
  end

  ## Internals

  defp do_setup(camera, mode) do
    args = if mode == :binned, do: ["--binned", to_string(camera)], else: [to_string(camera)]

    case System.cmd(@setup_binary, args, stderr_to_stdout: true) do
      {_out, 0} ->
        case read_conf(camera) do
          {:ok, conf} ->
            Logger.info(
              "Fp3Camera: #{camera} pipeline ready — #{conf.sensor} " <>
                "#{conf.width}x#{conf.height} #{conf.bayer} on #{conf.video}"
            )

            :ok

          :error ->
            # fp3-cam-setup reported success but left nothing behind. Treat
            # that as a failure rather than carrying on with no idea what
            # the pipeline was configured for.
            {:error, {:no_conf_written, conf_path(camera)}}
        end

      {out, rc} ->
        Logger.error("Fp3Camera: #{@setup_binary} #{Enum.join(args, " ")} failed (#{rc}): #{out}")
        {:error, {:setup_failed, rc, String.trim(out)}}
    end
  rescue
    e in ErlangError ->
      # System.cmd raises if the binary is missing, which means the system
      # image does not carry fp3-camera-utils.
      {:error, {:setup_binary_unavailable, @setup_binary, Exception.message(e)}}
  end

  defp conf_path(camera), do: "/run/fp3-cam-#{camera}.conf"

  # KEY=value, with the sensor name single-quoted because it contains a
  # space ("imx363 3-0010").
  defp read_conf(camera) do
    with {:ok, body} <- File.read(conf_path(camera)),
         %{} = conf <- parse_conf(body),
         true <- Map.has_key?(conf, :sensor) and Map.has_key?(conf, :width) do
      {:ok, conf}
    else
      _ -> :error
    end
  end

  defp parse_conf(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> put_conf(acc, String.trim(key), unquote_value(value))
        _ -> acc
      end
    end)
  end

  defp unquote_value(value) do
    value
    |> String.trim()
    |> String.trim("'")
  end

  defp put_conf(acc, "SENSOR", v), do: Map.put(acc, :sensor, v)
  defp put_conf(acc, "VIDEO", v), do: Map.put(acc, :video, v)
  defp put_conf(acc, "SUBDEV", v), do: Map.put(acc, :subdev, v)
  defp put_conf(acc, "LENS", v), do: Map.put(acc, :lens, v)
  defp put_conf(acc, "BAYER", v), do: Map.put(acc, :bayer, v)
  defp put_conf(acc, "WIDTH", v), do: put_integer(acc, :width, v)
  defp put_conf(acc, "HEIGHT", v), do: put_integer(acc, :height, v)
  defp put_conf(acc, _key, _v), do: acc

  defp put_integer(acc, key, value) do
    case Integer.parse(value) do
      {n, _} -> Map.put(acc, key, n)
      :error -> acc
    end
  end
end
