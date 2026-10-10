defmodule Fp3Camera.Pipeline do
  @moduledoc """
  gst-launch-1.0 argument lists for stills, streams and raw frames.

  Every pipeline starts at libcamerasrc, whose camss pipeline handler runs
  the frames through the camera ISP: the VFE debayers, white balances,
  colour corrects and gamma corrects them, scales the sensor mode down to
  the output and crops it to the output's aspect ratio, as Android frames
  video, and writes NV12. The CPU only encodes.

  ## Sizes

  An output is at most the camera's largest mode (`Fp3Camera.info/1`) and
  at least a sixteenth of it each way, the ISP's largest downscale. Its
  width is a multiple of 16 and its height even, as the ISP writes it.
  Anything else is refused by `check_size/2`. The sensor runs the
  smallest mode that covers the output:

  | Sensor   | Modes the ISP takes  | Frame rate |
  | -------- | -------------------- | ---------- |
  | S5KGM1SP | 2000x1500, 4000x3000 | 60, 30     |
  | S5K3P9SP | 2304x1728            | 30         |
  | IMX363   | 1920x1080, 2016x1512, 4032x3024 | 30 |
  | S5K4H7YX | 752x564, 816x612, 1440x1080, 3264x2448 | 30 |

  ## Picture settings

  These map onto libcamera controls.

    * `:awb` — `true` for automatic white balance, `false` to hold it
    * `:wb` — `{r, g, b}` gains, which turns automatic white balance off
    * `:exposure` — `:auto`, or the exposure time in microseconds
    * `:gain` — `:auto`, or the analogue gain as a multiplier, 1 to 16
    * `:focus` — 0 (far) to 1023 (close), on a camera with a focus motor;
      the lens stays where it is otherwise
    * `:zoom` — digital zoom from 1.0, the whole view, up to `max_zoom/2`

  Zoom runs the sensor's largest mode and has the ISP crop its middle and
  scale it down to the output. The ISP does not scale up, so zoom stops
  where that crop shrinks to the output's own size. It is set when the
  capture starts.

  `check_settings/4` refuses any other key, and values out of range.
  """

  # The ISP's largest downscale, and the alignment of its output lines
  @max_downscale 16
  @width_align 16

  # The fastest each sensor mode runs; the others reach 30
  @max_framerate %{{"s5kgm1sp", {2000, 1500}} => 60}

  @settings [:awb, :wb, :exposure, :gain, :focus, :zoom]

  # Output sizes offered besides each camera's own modes
  @presets [{3840, 2160}, {2560, 1440}, {1920, 1080}, {1280, 720}, {640, 480}]

  @doc "The picture settings `check_settings/4` takes."
  def settings, do: @settings

  @doc """
  The output sizes `info`'s camera produces from its full and binned
  modes and a few common video sizes, largest first.
  """
  @spec sizes(map()) :: [{pos_integer(), pos_integer()}]
  def sizes(info) do
    [{info.width, info.height}, info.binned | @presets]
    |> Enum.uniq()
    |> Enum.filter(&(check_size(info, &1) == :ok))
    |> Enum.sort_by(fn {w, h} -> -w * h end)
  end

  @doc "The largest `:zoom` for an `out` sized output of `info`'s camera."
  @spec max_zoom(map(), {pos_integer(), pos_integer()}) :: float()
  def max_zoom(%{width: mw, height: mh}, {w, h}), do: Float.floor(min(mw / w, mh / h), 2)

  @doc """
  `:ok` when every key of `opts` is a picture setting with a value
  `info`'s camera takes at an `out` sized output, or one of `options`,
  the call's own options. Otherwise `{:error, {:bad_setting, key, reason}}`.
  """
  @spec check_settings(map(), {pos_integer(), pos_integer()}, keyword(), [atom()]) ::
          :ok | {:error, term()}
  def check_settings(info, out, opts, options) do
    Enum.find_value(opts, :ok, fn {key, value} ->
      case check_setting(info, out, key, value, options) do
        :ok -> nil
        reason -> {:error, {:bad_setting, key, reason}}
      end
    end)
  end

  defp check_setting(_info, _out, :awb, value, _) when is_boolean(value), do: :ok

  defp check_setting(_info, _out, :wb, {r, g, b}, _)
       when is_number(r) and is_number(g) and is_number(b) and r > 0 and g > 0 and b > 0,
       do: :ok

  defp check_setting(_info, _out, :exposure, us, _)
       when us == :auto or (is_integer(us) and us > 0),
       do: :ok

  defp check_setting(_info, _out, :gain, g, _)
       when g == :auto or (is_number(g) and g >= 1 and g <= 16),
       do: :ok

  defp check_setting(%{lens: nil}, _out, :focus, _, _), do: "this camera has a fixed-focus lens"
  defp check_setting(_info, _out, :focus, n, _) when n in 0..1023, do: :ok

  defp check_setting(info, out, :zoom, z, _) when is_number(z) and z >= 1 do
    max = max_zoom(info, out)
    if z <= max, do: :ok, else: "at most #{max}x at #{elem(out, 0)}x#{elem(out, 1)}"
  end

  defp check_setting(_info, _out, key, _value, options) do
    cond do
      key in options -> :ok
      key in @settings -> "out of range"
      true -> "not a setting of this camera"
    end
  end

  @doc """
  `:ok` when the ISP can produce `{w, h}` from `info`'s camera, otherwise
  `{:error, {:unsupported_size, {w, h}, reason}}`.
  """
  @spec check_size(map(), {integer(), integer()}) :: :ok | {:error, term()}
  def check_size(%{width: mw, height: mh}, {w, h} = size) do
    cond do
      not (is_integer(w) and is_integer(h)) ->
        unsupported(size, "width and height must be integers")

      w > mw or h > mh ->
        unsupported(size, "the largest output of this camera is #{mw}x#{mh}")

      w * @max_downscale < mw or h * @max_downscale < mh ->
        unsupported(
          size,
          "the smallest output of this camera is " <>
            "#{div(mw, @max_downscale)}x#{div(mh, @max_downscale)}"
        )

      rem(w, @width_align) != 0 ->
        unsupported(size, "the width must be a multiple of #{@width_align}")

      rem(h, 2) != 0 ->
        unsupported(size, "the height must be even")

      true ->
        :ok
    end
  end

  defp unsupported(size, reason), do: {:error, {:unsupported_size, size, reason}}

  @doc """
  `:ok` when the sensor mode behind an `out` sized output runs at `fps`,
  otherwise `{:error, {:unsupported_framerate, fps, reason}}`.
  """
  @spec check_framerate(map(), {pos_integer(), pos_integer()}, term()) :: :ok | {:error, term()}
  def check_framerate(info, out, fps, zoom \\ 1) do
    max = Map.get(@max_framerate, {info.sensor, sensor_mode(info, out, zoom)}, 30)

    if is_integer(fps) and fps in 1..max,
      do: :ok,
      else: {:error, {:unsupported_framerate, fps, "1 to #{max} frames per second at this size"}}
  end

  # The smallest mode that covers the output, as the pipeline handler
  # picks, or the largest one to zoom into
  defp sensor_mode(info, {w, h}, zoom) do
    if zoom > 1,
      do: {info.width, info.height},
      else:
        Enum.find(info.modes, {info.width, info.height}, fn {mw, mh} -> mw >= w and mh >= h end)
  end

  @doc "A JPEG still of `out`."
  def still(info, out, opts) do
    source(info, out, opts) ++
      ~w(! identity eos-after=#{Keyword.get(opts, :frames, 10)}
         ! queue leaky=downstream max-size-buffers=1
         ! jpegenc quality=#{Keyword.get(opts, :quality, 90)} ! fdsink fd=1)
  end

  @doc "An H.264 stream from Venus, served on a TCP port."
  def stream(info, out, opts) do
    fps = Keyword.get(opts, :framerate, 30)

    controls =
      "controls,video_gop_size=#{Keyword.get(opts, :gop, fps)}," <>
        "video_bitrate=#{Keyword.get(opts, :bitrate, 8_000_000)}"

    # Venus encodes the camera's buffers in place when stream_env/2 has
    # them laid out for it, and copies each frame into its own otherwise.
    #
    # If Venus stops returning frames, the watchdog fails the pipeline and
    # closing the session restarts the firmware.
    #
    # Each IDR frame carries SPS and PPS, so a viewer that joins mid-GOP
    # can decode from the next one. Holding new viewers back until a
    # keyframe (sync-method=*-keyframe) stalls this pipeline.
    import = if in_place?(info, out, opts), do: ["output-io-mode=dmabuf-import"], else: []

    ["-e" | source(info, out, opts, fps)] ++
      ["!", "v4l2h264enc" | import] ++
      ~w(extra-controls=#{controls}
         ! watchdog timeout=4000 ! h264parse config-interval=-1
         ! tcpserversink host=0.0.0.0 port=#{Keyword.fetch!(opts, :port)} sync=false)
  end

  @doc """
  Environment for gst-launch-1.0 running stream/3: frames Venus can
  encode in place are laid out for it.
  """
  def stream_env(info, out, opts) do
    if in_place?(info, out, opts),
      do: [{"XDG_CONFIG_HOME", Application.app_dir(:fp3_camera, "priv/encoder")} | env()],
      else: env()
  end

  # Venus reads NV12 lines padded to 128 bytes and the chroma plane at
  # the luma height rounded up to 32 lines. The pipeline handler pads the
  # height when the sensor mode has the lines to spare; the width it
  # takes as it is.
  defp in_place?(info, {w, h} = out, opts) do
    {_mw, mh} = sensor_mode(info, out, Keyword.get(opts, :zoom, 1))
    rem(w, 128) == 0 and 32 * div(h + 31, 32) <= mh
  end

  @doc "Raw NV12 frames on stdout."
  def frames(info, out, opts) do
    source(info, out, opts, Keyword.get(opts, :framerate)) ++ ~w(! fdsink fd=1)
  end

  @doc "Environment for gst-launch-1.0."
  def env, do: [{"LIBCAMERA_LOG_LEVELS", "*:ERROR"}]

  defp source(info, {w, h}, opts, fps \\ nil) do
    rate = if fps, do: ",framerate=#{fps}/1", else: ""

    # -f: a crash exits instead of waiting for a debugger to attach.
    # v4l2h264enc only accepts caps that name the interlace mode, which
    # libcamerasrc leaves out.
    ["-q", "-f", "libcamerasrc", "camera-name=#{info.id}" | controls(opts) ++ zoom(info, opts)] ++
      ["!", "video/x-raw,format=NV12,width=#{w},height=#{h}#{rate},interlace-mode=progressive"]
  end

  # The largest mode, and a ScalerCrop of the middle of the pixel array
  defp zoom(info, opts) do
    case Keyword.get(opts, :zoom, 1) do
      z when z > 1 ->
        {x, y, w, h} = info.pixel_array
        {cw, ch} = {round(w / z), round(h / z)}

        [
          "sensor-config=sensor/config,width=#{info.width},height=#{info.height},depth=10",
          "scaler-crop=<#{x + div(w - cw, 2)},#{y + div(h - ch, 2)},#{cw},#{ch}>"
        ]

      _ ->
        []
    end
  end

  @doc "libcamerasrc properties for the picture settings in `opts`."
  def controls(opts) do
    {wb, opts} = Keyword.pop(opts, :wb)
    opts = if wb, do: Keyword.put(opts, :awb, {:gains, wb}), else: opts
    Enum.flat_map(opts, &control/1)
  end

  defp control({:awb, true}), do: ["awb-enable=true"]
  defp control({:awb, false}), do: ["awb-enable=false"]

  defp control({:awb, {:gains, {r, g, b}}}),
    do: ["awb-enable=false", "colour-gains=<#{num(r / g)},#{num(b / g)}>"]

  defp control({:exposure, us}) when is_integer(us),
    do: ["exposure-time-mode=manual", "exposure-time=#{us}"]

  defp control({:gain, g}) when is_number(g),
    do: ["analogue-gain-mode=manual", "analogue-gain=#{num(g)}"]

  # LensPosition is in dioptres; 10 is a focus distance of 10 cm.
  defp control({:focus, n}) when is_integer(n),
    do: ["af-mode=manual", "lens-position=#{num(n / 1023 * 10)}"]

  defp control(_other), do: []

  defp num(x), do: :erlang.float_to_binary(x * 1.0, decimals: 4)
end
