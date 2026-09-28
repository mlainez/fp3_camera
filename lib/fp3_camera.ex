defmodule Fp3Camera do
  @moduledoc """
  Stills and live video from the Fairphone 3 and 3+ rear and front
  cameras, under Nerves.

  The msm8953 CAMSS subsystem delivers raw 10-bit packed Bayer on a
  `/dev/videoN` node; the phone's hardware ISP (AE/AWB/AF) is not driven.
  Images here come straight from the sensor through a software demosaic
  in the `cam-snap` and `cam-stream` tools shipped by
  [nerves_system_fp3](https://github.com/mlainez/nerves_system_fp3) —
  viewable and shareable, but not tuned like a phone-app capture.

  Two slots are supported, `:rear` and `:front`. What is *in* them is
  not fixed: the modules are user-replaceable and the Fairphone 3+
  upgrade kit fits different silicon in each, so a given phone can carry
  any mix of the two generations.

  | Slot     | Fairphone 3                      | Fairphone 3+                     |
  | -------- | -------------------------------- | -------------------------------- |
  | `:rear`  | Sony IMX363, 4032×3024 RGGB      | Samsung S5KGM1SP, 4000×3000 GRBG |
  | `:front` | Samsung S5K4H7YX, 3264×2448 GRBG | Samsung S5K3P9SP, 4608×3456 GRBG |

  Nothing here needs to know which one you have: `fp3-cam-setup`
  identifies the fitted module and configures the pipeline for it, and
  `info/1` reports what was found.

  ## Quick start

      Fp3Camera.snap(:rear, "/root/photo.jpg")
      #=> {:ok, "/root/photo.jpg"}

      {:ok, ref} = Fp3Camera.start_stream(:rear)
      # from another machine — raw H.264 over TCP, not HTTP:
      #   ffplay tcp://nerves.local:8888
      Fp3Camera.stop_stream(ref)

  Every function that touches the hardware returns `{:error, reason}`
  rather than raising when the system binaries are missing, e.g.
  `{:error, {:enoent, "/usr/bin/fp3-cam-setup"}}` on a host or on a
  system image without fp3-camera-utils.
  """

  alias Fp3Camera.{Capture, Config, Manager, Paths}

  @type camera :: :rear | :front

  @doc """
  Override capture settings at runtime for a scope — `:all`,
  `{camera, mode}` or `{sensor, mode}`, with `mode` `:snap` or `:stream`.
  See `Fp3Camera.Config` for the resolution order.

      Fp3Camera.configure(:all, gamma: 1.8)
      Fp3Camera.configure({:rear, :stream}, wb: {1.9, 1.0, 1.53})
      Fp3Camera.save_config()      # survives the reboot
  """
  defdelegate configure(scope, opts), to: Config, as: :put

  @doc "Everything set at runtime, by scope. See `Fp3Camera.Config`."
  defdelegate config(), to: Config, as: :get

  @doc "Persist runtime settings to `/root/fp3-camera.config`; reloaded at boot."
  defdelegate save_config(), to: Config, as: :save

  @doc "Drop runtime settings for a scope, or `:all` of them."
  defdelegate reset_config(scope \\ :all), to: Config, as: :reset

  @doc """
  Configure the media pipeline for `camera` at the sensor's native
  resolution by running `fp3-cam-setup`. You never need to call this:
  `cam-snap` and `cam-stream` configure the pipeline themselves before
  every capture, and every function here that captures calls it first.
  It is useful to make `info/1` answer, or to check the module is found.
  """
  @spec setup(camera()) :: :ok | {:error, term()}
  def setup(camera), do: Manager.setup(camera)

  @doc """
  Which module is fitted in `camera`, as `fp3-cam-setup` last published
  it to `/run/fp3-cam-<camera>.conf`: `:sensor`, `:width`, `:height`,
  `:bayer`, `:video`, `:subdev`, `:lens` (rear only), plus the slot's
  static CSIPHY/CSID/ISPIF/VFE wiring.

  `:width`/`:height` are the pipeline's *current* geometry: native after
  `setup/1` or a still, 2x2-binned once a stream or subscription has
  started. Sets the pipeline up first if it hasn't been since boot.

      {:ok, info} = Fp3Camera.info(:rear)
      {info.sensor, info.width, info.height, info.bayer}
      #=> {"imx363 3-0010", 4032, 3024, "rggb"}
  """
  @spec info(camera()) :: {:ok, map()} | {:error, term()}
  def info(camera), do: Manager.info(camera)

  @doc """
  Capture a single still with `cam-snap` and save it as JPEG at `path`.
  Returns `{:ok, path}`.

  The still is always the sensor's full native resolution (a 12–48 MP
  JPEG) unless `binned: true`. Options are merged with the configured
  defaults (see `Fp3Camera.Config`); by default every built-in sensor
  profile meters first (`exposure: :auto`), which costs a few extra
  captures.

  ## Options

  Sensor

    * `:exposure` — `:auto` (meter with `Fp3Camera.AutoExposure`) or a
      raw `V4L2_CID_EXPOSURE` value
    * `:gain` — raw `V4L2_CID_ANALOGUE_GAIN` value
    * `:focus` — `:auto` (contrast-detect sweep) or a 0..1023 VCM value,
      0 = infinity, 1023 = macro. Rear only; the front modules are
      fixed-focus.
    * `:binned` — `true` captures from the sensor's 2x2-binned mode: a
      quarter of the pixels and four times the light per pixel
    * `:frames` — average N frames (1..9)
    * `:bayer` — override the Bayer order (`"rggb"`, `"grbg"`, `"bggr"`,
      `"gbrg"`) that `fp3-cam-setup` detected. A debugging aid; a wrong
      value gives wrong colours or a failed capture.

  White balance

    * `:awb` — `true` for gray-world from the frame, `false` for
      cam-snap's built-in per-slot gains
    * `:wb` — `{r, g, b}` explicit gains; overrides `:awb`
    * `:warm_bias` — extra R multiplier on top of AWB (cam-snap default 1.05)

  Tone and detail

    * `:gamma`, `:contrast`, `:saturation` — floats
    * `:brightness` — pre-gamma RGB multiplier (cam-snap `--exposure-boost`)
    * `:sharpen` — `false`, `true`, or a float amount
    * `:denoise` — bilateral strength, `0` disables (cam-snap default 4)
    * `:lsc` — lens shading correction amount, `0` disables
    * `:auto_levels` — `false`, or `{lo, hi}` percentile stretch
    * `:phone_curve` (`true`), `:ccm` (`true`), `:mhc` (`false` falls
      back from Malvar-He-Cutler to bilinear demosaic)
    * `:quality` — JPEG quality 1..100 (cam-snap default 90)

  Escape hatch

    * `:args` — a list of strings appended verbatim to cam-snap's argv
  """
  @spec snap(camera(), Path.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def snap(camera, path, opts \\ []), do: Capture.snap(camera, path, opts)

  @doc """
  Capture a still and return the JPEG as a binary (no file kept). Takes
  the same options as `snap/3`.

      {:ok, jpg} = Fp3Camera.snap_bytes(:rear, focus: :auto)
  """
  @spec snap_bytes(camera(), keyword()) :: {:ok, binary()} | {:error, term()}
  def snap_bytes(camera, opts \\ []), do: Capture.snap_bytes(camera, opts)

  @doc """
  Capture, and return what cam-snap measured and decided: `:sensor`,
  `:raw` (per-channel means straight off the sensor), `:gains` (the white
  balance applied), `:path` of the JPEG and cam-snap's full `:output`.

  Unlike `snap/3` this ignores `Fp3Camera.Config` — it is the
  measurement the defaults are derived from — so white balance can be
  calibrated as a loop on the device:

      {:ok, s} = Fp3Camera.snap_stats(:rear)
      s.raw
      #=> %{bayer: "rggb", r: 113.6, g: 146.0, b: 114.1}
      Fp3Camera.snap_stats(:rear, wb: {s.raw.g / s.raw.r, 1.0, s.raw.g / s.raw.b})

  Accepts the `snap/3` options (`exposure: :auto` excepted — pass
  numbers), plus `:path`.
  """
  @spec snap_stats(camera(), keyword()) :: {:ok, map()} | {:error, term()}
  def snap_stats(camera, opts \\ []), do: Capture.snap_stats(camera, opts)

  @doc """
  Start a live H.264 stream from `camera`, served over TCP by
  `cam-stream`. Returns `{:ok, ref}` once the child has bound its socket;
  pass `ref` to `stop_stream/1` and `tune/2`.

  It is a raw H.264 elementary stream on a plain TCP socket — not MJPEG
  and not HTTP, so a browser cannot open it:

      ffplay tcp://<device>:8888
      mpv    tcp://<device>:8888
      vlc --demux=h264 tcp://<device>:8888

  The server takes one client at a time; when it disconnects, cam-stream
  is restarted to listen again. Each stream also uses `port + 1` for its
  control socket (see `tune/2`). A camera can serve one stream at a time.

  The frame is the sensor's 2x2-binned output, centre-cropped (not
  scaled) to 1920×1056 — 1408×1056 on the Fairphone 3 front camera. See
  `streams/0` for the actual size of a running stream.

  ## Options

    * `:port` — TCP port (default `8888` for `:rear`, `8890` for `:front`)
    * `:bitrate` — H.264 bitrate in bit/s (cam-stream default: 4_000_000
      rear, 2_000_000 front)
    * `:fps` — target frame rate (cam-stream default 30)
    * `:focus` — `:auto` (one-shot sweep, unreliable when binned) or
      0..1023; rear only, default infinity
    * `:exposure`, `:gain` — integers
    * `:wb` — `{r, g, b}`; `:gamma`, `:contrast`, `:saturation`,
      `:brightness` — floats
    * `:args` — strings appended verbatim to cam-stream's argv

  Options are merged with `Fp3Camera.Config` in `:stream` mode.
  """
  @spec start_stream(camera(), keyword()) :: {:ok, reference()} | {:error, term()}
  def start_stream(camera, opts \\ []), do: Capture.start_stream(camera, opts)

  @doc "Stop a stream started with `start_stream/2`."
  @spec stop_stream(reference()) :: :ok | {:error, :not_found}
  def stop_stream(ref), do: Capture.stop_stream(ref)

  @doc """
  Live-tune a running stream's colour pipeline in place — no restart.
  Sends commands to cam-stream's control socket on `port + 1`.

    * `:wb` — `{r, g, b}` floats (G is implicitly 1.0)
    * `:gamma`, `:contrast`, `:saturation`, `:brightness` — numbers
    * `:exposure`, `:gain` — integers, reprogrammed on the sensor
    * `:focus` — integer 0..1023 (rear only; 0 = infinity, 1023 = macro)

  Other keys are ignored. Returns `:ok`, `{:error, :not_found}` for an
  unknown ref, or the socket error.

      {:ok, ref} = Fp3Camera.start_stream(:rear)
      Fp3Camera.tune(ref, wb: {1.8, 1.0, 1.4}, gamma: 1.6)
  """
  @spec tune(reference(), keyword()) :: :ok | {:error, term()}
  def tune(ref, opts), do: Capture.tune(ref, opts)

  @doc "Active streams: `:ref`, `:camera`, `:port`, `:width`, `:height`, `:uptime_ms`."
  @spec streams() :: [map()]
  def streams, do: Capture.list_streams()

  @doc """
  Subscribe the calling process to a live NV12 frame feed. Starts a
  supervised `cam-stream --out-nv12` and sends each frame as

      {:camera_frame, %{format: :nv12, width: w, height: h,
                        camera: :rear, data: binary}}

  `w`×`h` follow the same rule as `start_stream/2` — 1920×1056, or
  1408×1056 on the Fairphone 3 front camera — and `data` is
  `w * h * 3 / 2` bytes: the Y plane followed by the interleaved UV
  plane. With Evision:

      def handle_info({:camera_frame, %{format: :nv12, width: w, height: h, data: nv12}}, state) do
        mat = Evision.Mat.from_binary(nv12, {:u, 8}, div(h * 3, 2), w, 1)
        bgr = Evision.cvtColor(mat, Evision.Constant.cv_COLOR_YUV2BGR_NV12())
        {:noreply, state}
      end

  Returns `{:ok, pid}`. Stop with `unsubscribe/1`, or just exit: the feed
  follows the subscriber down. It also ends if cam-stream exits (e.g.
  the camera is already in use by a stream); monitor `pid` to notice.

  Options: `:exposure`, `:gain`, `:focus` (integer), `:wb`, `:gamma`,
  `:contrast`, `:saturation`, `:brightness`, `:args` — as for
  `start_stream/2`, and merged with `Fp3Camera.Config` in `:stream`
  mode. There is no frame pacing and no live tuning in this mode.
  """
  @spec subscribe(camera(), keyword()) :: {:ok, pid()} | {:error, term()}
  def subscribe(camera, opts \\ []) do
    with {:ok, geom} <- Manager.prepare_stream(camera),
         {:ok, bin} <- Paths.executable(:cam_stream) do
      DynamicSupervisor.start_child(
        Fp3Camera.StreamSupervisor,
        {Fp3Camera.Subscriber,
         camera: camera,
         subscriber: self(),
         binary: bin,
         width: geom.out_width,
         height: geom.out_height,
         pipeline: Config.resolve(camera, :stream, opts)}
      )
    end
  end

  @doc "Stop a frame subscription started with `subscribe/2`."
  @spec unsubscribe(pid()) :: :ok
  def unsubscribe(pid) when is_pid(pid) do
    Fp3Camera.Subscriber.stop(pid)
  catch
    # Already gone — cam-stream exited, or the subscriber did.
    :exit, _ -> :ok
  end

  @doc """
  Run the end-to-end self-test on the device: setup, detect, still and
  live stream for every fitted camera, judged on bytes rather than exit
  codes. Prints a table and returns the per-camera results. See
  `Fp3Camera.Diagnostics` for options.
  """
  def selftest(opts \\ []), do: Fp3Camera.Diagnostics.run(opts)
end
