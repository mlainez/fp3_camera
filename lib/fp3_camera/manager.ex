defmodule Fp3Camera.Manager do
  @moduledoc false
  # Brings up the CAMSS media pipeline so the requested camera's raw Bayer
  # frames land on a /dev/videoN node, and reads back what was found.
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
  # The binaries also own the *geometry*: cam-snap re-runs fp3-cam-setup
  # (native resolution, or binned with --binned) and cam-stream re-runs
  # `fp3-cam-setup --binned` before every capture. So nothing here caches
  # which mode the pipeline is in — any cache would go stale the moment a
  # binary reconfigured it. setup/1 always runs the script (it is
  # idempotent and ~50 ms of media-ctl calls), and the conf file is the
  # single source of truth for what the pipeline is currently set to.
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

  alias Fp3Camera.Paths

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

  # fp3-cam-setup is ~50 ms when healthy; this is the ceiling for a
  # wedged media-ctl before the caller gets an exit instead of an answer.
  @setup_timeout 15_000

  # cam-stream's output frame: the largest Venus-aligned frame that fits
  # the binned source, capped at 1080p. Mirrors main() in cam-stream.c
  # (OUT_W/OUT_H, ENC_ALIGN_W/ENC_ALIGN_H); the Subscriber depends on it
  # to slice the NV12 byte stream into frames.
  @out_w 1920
  @out_h 1080
  @align_w 128
  @align_h 32

  @type camera :: :rear | :front

  ## Public API

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc """
  Static description of a camera slot: which CSIPHY, CSID, ISPIF and VFE
  RDI lane it is wired to, the media entity of its VFE video node, and
  the i2c address its sensor answers on.

  Deliberately no `/dev/videoN` here: CAMSS registers its video nodes
  alongside Venus and the numbers move between boots and between phones.
  """
  @spec slot(camera()) :: map() | nil
  def slot(camera), do: Map.get(@slots, camera)

  @doc """
  Everything known about a camera: its slot topology merged with what
  fp3-cam-setup last published for it. Sets the pipeline up first if it
  hasn't been since boot.
  """
  @spec info(camera()) :: {:ok, map()} | {:error, term()}
  def info(camera) when is_map_key(@slots, camera) do
    with {:ok, conf} <- resolved_or_setup(camera), do: {:ok, Map.merge(@slots[camera], conf)}
  end

  def info(camera), do: {:error, {:unknown_camera, camera}}

  defp resolved_or_setup(camera) do
    case resolved(camera) do
      {:error, :not_configured} ->
        with :ok <- setup(camera), do: resolved(camera)

      other ->
        other
    end
  end

  @doc """
  What fp3-cam-setup published for this slot: `:sensor`, `:width`,
  `:height`, `:bayer`, `:subdev`, `:video`, and `:lens` on the rear. A
  plain file read — no GenServer, no media-ctl.
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
  Configure `camera`'s pipeline at the sensor's native resolution — the
  mode cam-snap uses for stills.
  """
  @spec setup(camera()) :: :ok | {:error, term()}
  def setup(camera) do
    with {:ok, _conf} <- run_setup(camera, []), do: :ok
  end

  @doc """
  Configure `camera`'s pipeline exactly as cam-stream is about to (2x2
  binned), and return the conf plus the frame size cam-stream will emit
  as `:out_width`/`:out_height`.

  cam-stream runs `fp3-cam-setup --binned` itself, so doing it here first
  changes nothing on the device; it is what lets this side know the frame
  geometry before the first byte arrives.
  """
  @spec prepare_stream(camera()) :: {:ok, map()} | {:error, term()}
  def prepare_stream(camera) do
    with {:ok, conf} <- run_setup(camera, ["--binned"]) do
      {out_w, out_h} = stream_size(conf.width, conf.height)
      {:ok, Map.merge(conf, %{out_width: out_w, out_height: out_h})}
    end
  end

  @doc false
  # The frame size cam-stream derives from the binned sensor size. The
  # phase offset costs a pixel, hence the -1; the cap is rounded down to
  # the alignment too, which is why a "1080p" stream is 1056 lines.
  @spec stream_size(pos_integer(), pos_integer()) :: {non_neg_integer(), non_neg_integer()}
  def stream_size(w, h) do
    fit_w = Bitwise.band(w - 1, Bitwise.bnot(@align_w - 1))
    fit_h = Bitwise.band(h - 1, Bitwise.bnot(@align_h - 1))
    cap_w = Bitwise.band(@out_w, Bitwise.bnot(@align_w - 1))
    cap_h = Bitwise.band(@out_h, Bitwise.bnot(@align_h - 1))
    {if(fit_w < @out_w, do: fit_w, else: cap_w), if(fit_h < @out_h, do: fit_h, else: cap_h)}
  end

  defp run_setup(camera, flags) when is_map_key(@slots, camera) do
    GenServer.call(__MODULE__, {:setup, camera, flags}, @setup_timeout)
  end

  defp run_setup(camera, _flags), do: {:error, {:unknown_camera, camera}}

  ## GenServer
  #
  # The process exists only to serialise media-ctl: two fp3-cam-setup runs
  # interleaving their link and format calls would leave the graph in a
  # state neither asked for. It deliberately keeps no state.

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:setup, camera, flags}, _from, state) do
    {:reply, do_setup(camera, flags), state}
  end

  ## Internals

  defp do_setup(camera, flags) do
    args = flags ++ [to_string(camera)]

    with {:ok, bin} <- Paths.executable(:fp3_cam_setup) do
      case System.cmd(bin, args, stderr_to_stdout: true) do
        {_out, 0} ->
          case read_conf(camera) do
            {:ok, conf} ->
              Logger.debug(
                "Fp3Camera: #{camera} pipeline ready — #{conf.sensor} " <>
                  "#{conf.width}x#{conf.height} #{conf[:bayer]} on #{conf[:video]}"
              )

              {:ok, conf}

            :error ->
              # fp3-cam-setup reported success but left nothing behind.
              {:error, {:no_conf_written, Paths.conf_path(camera)}}
          end

        {out, rc} ->
          Logger.error("Fp3Camera: #{bin} #{Enum.join(args, " ")} failed (#{rc}): #{out}")
          {:error, {:setup_failed, rc, String.trim(out)}}
      end
    end
  rescue
    e in ErlangError -> {:error, {:setup_failed, Exception.message(e)}}
  end

  defp read_conf(camera) do
    with {:ok, body} <- File.read(Paths.conf_path(camera)),
         %{sensor: _, width: _, height: _} = conf <- parse_conf(body) do
      {:ok, conf}
    else
      _ -> :error
    end
  end

  @doc false
  # KEY=value lines as fp3-cam-setup writes them, the sensor name
  # single-quoted because it contains a space ("imx363 3-0010").
  # Unknown keys and malformed lines are ignored.
  @spec parse_conf(String.t()) :: map()
  def parse_conf(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> put_conf(acc, String.trim(key), unquote_value(value))
        _ -> acc
      end
    end)
  end

  defp unquote_value(value), do: value |> String.trim() |> String.trim("'")

  defp put_conf(acc, _key, ""), do: acc
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
      {n, _} when n > 0 -> Map.put(acc, key, n)
      _ -> acc
    end
  end
end
