defmodule Fp3Camera do
  @moduledoc """
  Stills + live video on the Fairphone 3 and 3+ rear and front cameras.

  The msm8953 CAMSS subsystem dumps raw 10-bit packed Bayer onto a
  `/dev/videoN` node; the proprietary phone-camera ISP that handles
  AE/AWB/AF lives on a Hexagon DSP firmware we don't ship. So images
  here come straight from the sensor through a NEON-accelerated Bayer
  demosaic — viewable and sharable, but not tuned like a phone-app
  capture.

  Two slots are supported, `:rear` and `:front`. What is *in* them is
  not fixed: the modules are user-replaceable with a #00 screwdriver and
  the Fairphone 3+ upgrade kit fits different silicon in each, so a given
  phone can carry any mix of the two generations.

  | Slot     | Fairphone 3               | Fairphone 3+              |
  | -------- | ------------------------- | ------------------------- |
  | `:rear`  | Sony IMX363, 4032×3024 RGGB | Samsung S5KGM1SP, 4000×3000 GRBG |
  | `:front` | Samsung S5K4H7YX, 3264×2448 GRBG | Samsung S5K3P9SP, 4608×3456 GRBG |

  Nothing here needs to know which one you have: `setup/1` asks
  `fp3-cam-setup` to identify the fitted module and configure the
  pipeline for it, and `info/1` reports what was found.

  ## Quick start

      iex> Fp3Camera.snap(:rear, "/tmp/photo.jpg")
      {:ok, "/tmp/photo.jpg"}

      iex> {:ok, stream} = Fp3Camera.start_stream(:rear, port: 8888)
      iex> # then, from another machine:
      iex> #   ffplay tcp://nerves.local:8888
      iex> # This is a raw H.264 stream over TCP, not HTTP -- a browser
      iex> # cannot open it.
      iex> Fp3Camera.stop_stream(stream)
      :ok
  """

  alias Fp3Camera.{Capture, Manager}

  @type camera :: :rear | :front

  @doc """
  Get the currently-active pipeline defaults — gamma/contrast/saturation
  /wb etc. — that are merged into every `snap/3` and `start_stream/2`
  call. Returns a keyword list.

  Empty by default — the binaries' own compile-time defaults (from
  `cam_pipeline.h`) apply when no overrides are set.
  """
  @spec get_defaults() :: keyword()
  def get_defaults(), do: Application.get_env(:fp3_camera, :defaults, [])

  @doc """
  Override pipeline defaults at runtime. Merges into existing defaults;
  pass a key with `nil` to clear it. The merged map is then used for
  every subsequent `snap/3` and `start_stream/2` (existing streams are
  unaffected — restart to apply).

  ## Example

      Fp3Camera.set_defaults(gamma: 1.8, saturation: 1.7, wb: {2.0, 1.0, 1.4})

  Keys honoured (same as per-call opts):
    * `:gamma`, `:contrast`, `:saturation` — tone curve
    * `:wb` — `{r, g, b}` floats; overrides per-camera WB defaults
    * `:exposure`, `:gain` — sensor controls
    * `:bitrate` — H.264 encode bitrate (streams only)
    * `:denoise`, `:frames`, `:phone_curve` — stills only
  """
  @spec set_defaults(keyword()) :: keyword()
  def set_defaults(opts) when is_list(opts) do
    current = get_defaults()
    merged =
      Keyword.merge(current, opts)
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    Application.put_env(:fp3_camera, :defaults, merged)
    merged
  end

  @doc "Reset all pipeline defaults back to the binary's compile-time values."
  @spec reset_defaults() :: :ok
  def reset_defaults() do
    Application.put_env(:fp3_camera, :defaults, [])
    :ok
  end

  @doc false
  def with_defaults(opts), do: Keyword.merge(get_defaults(), opts)

  @doc """
  Configure the media-ctl pipeline for `camera`. Called automatically
  by `snap/2` and `start_stream/2`; exposed in case you want to set up
  the pipeline early.

  `mode` is `:full` (sensor native resolution, what stills want) or
  `:binned` (2x2 binned — a quarter of the sensor-to-DRAM bandwidth and
  better SNR, what live video wants).
  """
  @spec setup(camera(), Manager.mode()) :: :ok | {:error, term()}
  def setup(camera, mode \\ :full), do: Manager.setup(camera, mode)

  @doc """
  Which module is actually fitted in `camera`, and how its pipeline is
  configured: `:sensor`, `:width`, `:height`, `:bayer`, `:subdev`, the
  `:lens` if it has one, plus the slot's static CSIPHY/CSID/ISPIF wiring.

  Returns `{:error, :not_configured}` until `setup/2` has run, since
  nothing looks at which module is present before then.

      iex> Fp3Camera.setup(:rear)
      :ok
      iex> {:ok, info} = Fp3Camera.info(:rear)
      iex> {info.sensor, info.width, info.height, info.bayer}
      {"imx363 3-0010", 4032, 3024, "rggb"}
  """
  @spec info(camera()) :: {:ok, map()} | {:error, term()}
  def info(camera), do: Manager.info(camera)

  @doc """
  Capture a single still and save it as JPEG at `path`.

  Returns `{:ok, path}` on success.

  ## Options

    * `:quality` — JPEG quality, 1..100 (default `90`)
    * `:width`, `:height` — output size; if omitted the sensor's
      native resolution is used (heavy: ~5 MB JPEG at full res). Set
      e.g. `width: 1280, height: 960` for a normal-sized photo.
  """
  @spec snap(camera(), Path.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def snap(camera, path, opts \\ []),
    do: Capture.snap(camera, path, with_defaults(opts))

  @doc """
  Capture a still and return the JPEG as a binary (no file).

  Convenient for downstream processing — Evision, Image, HTTP responses:

      {:ok, jpg} = Fp3Camera.snap_bytes(:rear, focus: :auto)
      mat = Evision.imdecode(jpg, Evision.Constant.cv_IMREAD_COLOR())
  """
  @spec snap_bytes(camera(), keyword()) :: {:ok, binary()} | {:error, term()}
  def snap_bytes(camera, opts \\ []),
    do: Capture.snap_bytes(camera, with_defaults(opts))

  @doc """
  Start a live H.264 stream from `camera`, served over TCP. Returns a
  reference you pass back to `stop_stream/1`.

  It is a raw H.264 elementary stream on a plain TCP socket — not MJPEG
  and not HTTP, so a browser cannot open it. View it with a player that
  can demux a bare stream:

      ffplay tcp://<device>:<port>
      mpv    tcp://<device>:<port>
      vlc --demux=h264 tcp://<device>:<port>

  The encoder is Venus H.264 at the sensor's binned resolution, capped
  at 1080p — 1920x1080 on the Fairphone 3+ and on the Fairphone 3's
  rear camera, less on its 1440x1080 front sensor.

  ## Options

    * `:port` — TCP port to listen on (default `8080`)
    * `:width`, `:height` — output frame size (default `1280×960`)
    * `:framerate` — target fps (default `15`)
    * `:quality` — JPEG quality, 1..100 (default `70`)
  """
  @spec start_stream(camera(), keyword()) :: {:ok, reference()} | {:error, term()}
  def start_stream(camera, opts \\ []),
    do: Capture.start_stream(camera, with_defaults(opts))

  @doc "Stop a stream previously started with `start_stream/2`."
  @spec stop_stream(reference()) :: :ok
  def stop_stream(ref), do: Capture.stop_stream(ref)

  @doc """
  Live-tune a running stream's color pipeline in-place — no restart, no
  dropped frames. Sends commands over cam-stream's control socket on
  port `(stream.port + 1)`.

  Honored keys (all match the corresponding `start_stream/2` options):

    * `:wb` — `{r_gain, g_gain, b_gain}` floats; G is implicit 1.0
    * `:gamma`, `:contrast`, `:saturation`, `:brightness` — floats
    * `:exposure`, `:gain` — integers; reprogrammed on the sensor subdev
    * `:focus` — integer 0..1023 (rear only; 0=∞, 1023=macro)

  ## Example

      {:ok, ref} = Fp3Camera.start_stream(:rear, port: 8888)
      # tweak while watching mpv:
      Fp3Camera.tune(ref, wb: {1.8, 1.0, 1.4}, gamma: 1.6)
  """
  @spec tune(reference(), keyword()) :: :ok | {:error, term()}
  def tune(ref, opts), do: Capture.tune(ref, opts)

  @doc "List active streams."
  @spec streams() :: [%{ref: reference(), camera: camera(), port: pos_integer()}]
  def streams, do: Capture.list_streams()

  @doc """
  Run the end-to-end self-test: detect, setup, still and live stream for
  every fitted camera, judged on bytes rather than on exit codes.

  Prints a table and returns the structured results.

      iex> Fp3Camera.selftest()

  See `Fp3Camera.Diagnostics` for options.
  """
  def selftest(opts \\ []), do: Fp3Camera.Diagnostics.run(opts)

  @doc """
  Capture, and return what cam-snap measured and decided.

  The raw per-channel means come straight off the sensor and the gains
  are what the pipeline applied, so white balance can be calibrated as a
  loop here instead of by copying JPEGs to a laptop:

      iex> {:ok, s} = Fp3Camera.snap_stats(:rear)
      iex> s.raw
      %{bayer: "rggb", r: 113.6, g: 146.0, b: 114.1}
      iex> Fp3Camera.snap_stats(:rear, wb: {s.raw.g / s.raw.r, 1.0, s.raw.g / s.raw.b})

  Accepts every option `snap/3` does, plus `:path`.
  """
  defdelegate snap_stats(camera, opts \\ []), to: Capture

  @doc """
  Subscribe to a live NV12 frame feed. Starts a supervised cam-stream
  in its `--out-nv12` mode and forwards each frame to the calling
  process as

      {:camera_frame, %{format: :nv12, width: 1920, height: 1080,
                        camera: :rear, data: <<3.1 MB binary>>}}

  Decode straight to an Evision Mat:

      def handle_info({:camera_frame, %{format: :nv12, width: w,
                                        height: h, data: nv12}}, state) do
        # NV12 is laid out as Y plane (h × w) + UV plane (h/2 × w),
        # which OpenCV sees as a single (h * 1.5) × w u8 Mat.
        mat = Evision.Mat.from_binary(nv12, {:u, 8}, div(h * 3, 2), w, 1)
        bgr = Evision.cvtColor(mat, Evision.Constant.cv_COLOR_YUV2BGR_NV12())
        # … run inference, save, whatever …
        {:noreply, state}
      end

  Returns `{:ok, pid}`. Pass that pid to `unsubscribe/1` to stop, or
  let your subscriber process exit — the Subscriber GenServer monitors
  the subscriber and shuts the cam-stream Port down automatically.

  Pipeline knobs (`:saturation`, `:gamma`, `:contrast`, `:brightness`,
  `:wb`, `:exposure`, `:gain`) work the same way as `start_stream/2`.
  """
  @spec subscribe(camera(), keyword()) :: {:ok, pid()} | {:error, term()}
  def subscribe(camera, opts \\ []) do
    with :ok <- Manager.setup(camera) do
      opts =
        with_defaults(opts)
        |> Keyword.put(:camera, camera)
        |> Keyword.put(:subscriber, self())

      DynamicSupervisor.start_child(
        Fp3Camera.StreamSupervisor,
        {Fp3Camera.Subscriber, opts}
      )
    end
  end

  @doc "Stop a frame subscription previously started with `subscribe/2`."
  @spec unsubscribe(pid()) :: :ok
  def unsubscribe(pid) when is_pid(pid), do: Fp3Camera.Subscriber.stop(pid)
end
