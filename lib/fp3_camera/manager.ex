defmodule Fp3Camera.Manager do
  @moduledoc false
  # Configures the CAMSS media pipeline so the requested camera's
  # raw Bayer frames land on a /dev/videoN node ready for GStreamer.
  #
  # The msm8953 CAMSS exposes a configurable middle (csiphy → csid →
  # ispif → vfe_rdi) with the sensor↔csiphy and vfe_rdi↔video links
  # pinned by the kernel. We pick a non-overlapping path per camera so
  # both can be wired simultaneously through VFE0's three RDI lanes
  # (VFE1 fails to start streaming on this SoC; we'd have to chase a
  # clock/regulator binding to use it).

  use GenServer
  require Logger

  @cameras %{
    rear: %{
      sensor: "s5kgm1sp 3-0010",
      csiphy: "msm_csiphy0",
      csid: "msm_csid0",
      ispif: "msm_ispif0",
      vfe_rdi: "msm_vfe0_rdi0",
      video: "/dev/video0",
      width: 4000,
      height: 3000,
      mbus_format: "SGRBG10_1X10"
    },
    front: %{
      sensor: "s5k3p9sp 4-0010",
      csiphy: "msm_csiphy2",
      csid: "msm_csid1",
      ispif: "msm_ispif1",
      vfe_rdi: "msm_vfe0_rdi1",
      video: "/dev/video1",
      width: 4608,
      height: 3456,
      mbus_format: "SGRBG10_1X10"
    }
  }

  @media_device "/dev/media0"

  ## Public API

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "Look up the static config for a camera."
  def info(camera) when is_map_key(@cameras, camera), do: Map.fetch!(@cameras, camera)

  @doc "Ensure the media-ctl pipeline for `camera` is configured."
  def setup(camera) when is_map_key(@cameras, camera) do
    GenServer.call(__MODULE__, {:setup, camera}, 10_000)
  end

  def setup(camera), do: {:error, {:unknown_camera, camera}}

  ## GenServer

  @impl true
  def init(_), do: {:ok, %{configured: MapSet.new()}}

  @impl true
  def handle_call({:setup, camera}, _from, state) do
    if MapSet.member?(state.configured, camera) do
      {:reply, :ok, state}
    else
      case do_setup(camera) do
        :ok ->
          {:reply, :ok, %{state | configured: MapSet.put(state.configured, camera)}}

        {:error, _} = err ->
          {:reply, err, state}
      end
    end
  end

  defp do_setup(camera) do
    cfg = @cameras[camera]
    fmt = "#{cfg.mbus_format}/#{cfg.width}x#{cfg.height}"

    cmds = [
      # subdev pad formats — propagate the sensor's mbus format down
      # the chain. csiphy:0 (sink) gets the format from the sensor's
      # immutable link, but we set it explicitly to be safe.
      pad_fmt(cfg.csiphy, 0, fmt),
      pad_fmt(cfg.csiphy, 1, fmt),
      link(cfg.csiphy, 1, cfg.csid, 0),
      pad_fmt(cfg.csid, 0, fmt),
      pad_fmt(cfg.csid, 1, fmt),
      link(cfg.csid, 1, cfg.ispif, 0),
      pad_fmt(cfg.ispif, 0, fmt),
      pad_fmt(cfg.ispif, 1, fmt),
      link(cfg.ispif, 1, cfg.vfe_rdi, 0),
      pad_fmt(cfg.vfe_rdi, 0, fmt),
      pad_fmt(cfg.vfe_rdi, 1, fmt)
    ]

    Enum.reduce_while(cmds, :ok, fn args, :ok ->
      case System.cmd("media-ctl", ["-d", @media_device | args], stderr_to_stdout: true) do
        {_, 0} ->
          {:cont, :ok}

        {out, rc} ->
          Logger.error("media-ctl #{inspect(args)} failed (#{rc}): #{out}")
          {:halt, {:error, {:media_ctl_failed, args, out}}}
      end
    end)
    |> case do
      :ok ->
        # Set the V4L2 pixel format on the video node to SGRBG10P (pgAA)
        # so userspace sees 10-bit packed Bayer at the sensor's resolution.
        case System.cmd(
               "v4l2-ctl",
               [
                 "--device",
                 cfg.video,
                 "--set-fmt-video=width=#{cfg.width},height=#{cfg.height},pixelformat=pgAA"
               ],
               stderr_to_stdout: true
             ) do
          {_, 0} ->
            Logger.info("Fp3Camera: #{camera} pipeline ready on #{cfg.video} @ #{cfg.width}x#{cfg.height}")
            :ok

          {out, rc} ->
            {:error, {:v4l2_set_fmt_failed, rc, out}}
        end

      err ->
        err
    end
  end

  defp pad_fmt(entity, pad, fmt), do: ["-V", ~s("#{entity}":#{pad}[fmt:#{fmt}])]
  defp link(src, src_pad, sink, sink_pad), do: ["-l", ~s("#{src}":#{src_pad} -> "#{sink}":#{sink_pad} [1])]
end
