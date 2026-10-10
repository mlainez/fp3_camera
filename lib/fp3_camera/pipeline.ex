defmodule Fp3Camera.Pipeline do
  @moduledoc """
  gst-launch-1.0 argument lists for stills, streams and raw frames.

  Every pipeline starts at libcamerasrc, whose software ISP turns the raw
  Bayer frames into RGB on the CPU. Smaller outputs are scaled from a full
  sensor mode, because libcamera crops rather than scales. An output with
  another aspect ratio than the sensor mode, such as 16:9 from a 4:3
  sensor, is cropped to that ratio first, as Android frames video.

  ## Picture settings

  These map onto libcamera controls. The neutral value of each is the one
  the tuning sliders in the Cameras notebook start at.

    * `:gamma` — tone curve, 2.2 is sRGB
    * `:contrast` — 0.35 is neutral, 0 is flat
    * `:saturation` — 1.5 is neutral, 0 is grey
    * `:brightness` — 1.0 is neutral, 0.0 to 2.0
    * `:sharpen` — `false` or a strength, 1.0 is normal
    * `:awb` — `true` for automatic white balance, `false` to hold it
    * `:wb` — `{r, g, b}` gains, which turns automatic white balance off
    * `:exposure` — `:auto`, or the exposure time in microseconds
    * `:gain` — `:auto`, or the analogue gain as a multiplier
    * `:focus` — `:auto`, or 0 (far) to 1023 (close) on the rear lens

  libcamera's software ISP ignores `:brightness`, `:sharpen` and `:focus`
  for now. `:denoise`, `:warm_bias` and `:lsc` are accepted and
  ignored: libcamera has no such controls.
  """

  @doc "A JPEG still of `size`, scaled to `out` when that differs."
  def still(info, size, out, opts) do
    source(info, size, opts) ++
      ~w(! identity eos-after=#{Keyword.get(opts, :frames, 30)}
         ! queue leaky=downstream max-size-buffers=1) ++
      scale(size, out, "") ++
      ~w(! jpegenc quality=#{Keyword.get(opts, :quality, 90)} ! fdsink fd=1)
  end

  @doc "An H.264 stream from Venus, served on a TCP port."
  def stream(info, out, opts) do
    fps = Keyword.get(opts, :framerate, 30)

    controls =
      "controls,video_gop_size=#{Keyword.get(opts, :gop, fps)}," <>
        "video_bitrate=#{Keyword.get(opts, :bitrate, 8_000_000)}"

    # Venus encodes libcamera's NV12 frames in place, laid out for it by
    # env/3. Scaled frames are copied into the encoder's own buffers
    # instead: writing them straight into those uncached buffers limits
    # the stream to 20 fps.
    #
    # If Venus stops returning frames, the watchdog fails the pipeline and
    # closing the session restarts the firmware.
    #
    # Each IDR frame carries SPS and PPS, so a viewer that joins mid-GOP
    # can decode from the next one. Holding new viewers back until a
    # keyframe (sync-method=*-keyframe) stalls this pipeline.
    {size, format} = nv12_source(sensor_mode(info, out), out)

    # The encoder budgets its bitrate for the frame rate it is given, and
    # libcamera only slows the sensor down to that rate within its mode.
    ["-e" | source(info, size, opts, fps, format)] ++
      ["!", "videorate", "drop-only=true", "max-rate=#{fps}"] ++
      to_nv12(size, out, format) ++
      encoder(size, out, format) ++
      ["extra-controls=#{controls}"] ++
      ~w(! watchdog timeout=4000 ! h264parse config-interval=-1
         ! tcpserversink host=0.0.0.0 port=#{Keyword.fetch!(opts, :port)} sync=false)
  end

  @doc "Raw NV12 frames on stdout."
  def frames(info, out, opts) do
    {size, format} = nv12_source(sensor_mode(info, out), out)

    source(info, size, opts, Keyword.get(opts, :framerate), format) ++
      to_nv12(size, out, format) ++ ~w(! fdsink fd=1)
  end

  @doc """
  Environment for gst-launch-1.0 running a pipeline of `out` from `info`:
  the libcamera configuration for its sensor mode, where full-resolution
  outputs get eight debayer threads instead of two. `:encoder` lays NV12
  frames out for Venus, for stream/3; other pipelines read them packed.
  """
  def env(info, out, use \\ :cpu) do
    mode = if sensor_mode(info, out) == info.binned, do: "binned", else: "full_resolution"
    config = if use == :encoder, do: mode <> "_encoder", else: mode

    [
      {"XDG_CONFIG_HOME", Application.app_dir(:fp3_camera, "priv/#{config}")},
      {"LIBCAMERA_LOG_LEVELS", "*:ERROR"}
    ]
  end

  # The binned mode unless the output is larger than it.
  defp sensor_mode(%{binned: {bw, bh}} = info, {w, h}) do
    if w <= bw and h <= bh, do: {bw, bh}, else: {info.width, info.height}
  end

  # libcamera debayers straight to NV12 when it crops the output out of the
  # sensor mode, which saves a conversion pass over every frame. A crop that
  # would cut more than a twentieth of the framed area is scaled from RGB
  # instead, to keep the field of view.
  defp nv12_source(mode, {w, h} = out) do
    {fw, fh} = framed(mode, out)

    if w <= fw and h <= fh and w * 20 >= fw * 19,
      do: {out, "format=NV12,"},
      else: {{fw, fh}, ""}
  end

  defp encoder(size, size, "format=NV12,"), do: ~w(! v4l2h264enc output-io-mode=dmabuf-import)
  defp encoder(_size, _out, _format), do: ~w(! identity drop-allocation=true ! v4l2h264enc)

  defp to_nv12(size, size, "format=NV12,"), do: []
  defp to_nv12(size, out, _format), do: scale(size, out, "format=NV12,")

  # The part of the sensor mode with the output's aspect ratio: its full
  # width for a wider output, its full height for a taller one.
  defp framed({mw, mh}, {w, h}) do
    if mw * h <= mh * w,
      do: {mw, 2 * div(round(mw * h / w), 2)},
      else: {8 * div(round(mh * w / h), 8), mh}
  end

  defp source(info, {w, h}, opts, fps \\ nil, format \\ "") do
    rate = if fps, do: ",framerate=#{fps}/1", else: ""

    # -f: a crash exits instead of waiting for a debugger to attach.
    ["-q", "-f", "libcamerasrc", "camera-name=#{info.id}" | controls(opts)] ++
      ["!", "video/x-raw,#{format}width=#{w},height=#{h}#{rate}"]
  end

  # Nearest-neighbour keeps up with the sensor; bilinear halves the rate.
  defp scale(size, size, ""), do: ~w(! videoconvert)

  defp scale(_size, {w, h}, format) do
    ~w(! videoconvertscale method=nearest-neighbour n-threads=4
       ! video/x-raw,#{format}width=#{w},height=#{h})
  end

  @doc "libcamerasrc properties for the picture settings in `opts`."
  def controls(opts) do
    {wb, opts} = Keyword.pop(opts, :wb)
    opts = if wb, do: Keyword.put(opts, :awb, {:gains, wb}), else: opts
    Enum.flat_map(opts, &control/1)
  end

  defp control({:gamma, g}) when is_number(g), do: ["gamma=#{num(g)}"]
  defp control({:contrast, c}) when is_number(c), do: ["contrast=#{num(c / 0.35)}"]
  defp control({:saturation, s}) when is_number(s), do: ["saturation=#{num(s / 1.5)}"]

  defp control({:brightness, b}) when is_number(b),
    do: ["brightness=#{num(min(max(b - 1.0, -1.0), 1.0))}"]

  defp control({:sharpen, false}), do: ["sharpness=0"]
  defp control({:sharpen, s}) when is_number(s), do: ["sharpness=#{num(s)}"]
  defp control({:awb, true}), do: ["awb-enable=true"]
  defp control({:awb, false}), do: ["awb-enable=false"]

  defp control({:awb, {:gains, {r, g, b}}}),
    do: ["awb-enable=false", "colour-gains=<#{num(r / g)},#{num(b / g)}>"]

  defp control({:exposure, us}) when is_integer(us),
    do: ["exposure-time-mode=manual", "exposure-time=#{us}"]

  defp control({:gain, g}) when is_number(g),
    do: ["analogue-gain-mode=manual", "analogue-gain=#{num(g)}"]

  defp control({:focus, :auto}), do: ["af-mode=continuous"]

  # LensPosition is in dioptres; 10 is a focus distance of 10 cm.
  defp control({:focus, n}) when is_integer(n),
    do: ["af-mode=manual", "lens-position=#{num(n / 1023 * 10)}"]

  defp control(_other), do: []

  defp num(x), do: :erlang.float_to_binary(x * 1.0, decimals: 4)
end
