defmodule Fp3Camera do
  @moduledoc """
  Stills and live video from the Fairphone 3 and 3+ rear and front cameras.

  Frames come from libcamera, whose software ISP turns the sensors' raw
  Bayer data into RGB on the CPU; streams are encoded to H.264 by the
  Venus hardware encoder. Everything runs as `gst-launch-1.0` pipelines.

  Two slots are supported, `:rear` and `:front`. What is *in* them is
  not fixed: the modules are user-replaceable and the Fairphone 3+ kit
  fits different sensors, so a phone can carry any mix of them.

  | Slot     | Fairphone 3      | Fairphone 3+ |
  | -------- | ---------------- | ------------ |
  | `:rear`  | Sony IMX363      | Samsung S5KGM1SP |
  | `:front` | Samsung S5K4H7YX | Samsung S5K3P9SP |

  `info/1` reports what is fitted.

  ## Quick start

      iex> Fp3Camera.snap(:rear, "/tmp/photo.jpg")
      {:ok, "/tmp/photo.jpg"}

      iex> {:ok, stream} = Fp3Camera.start_stream(:rear)
      iex> # then, from another machine:
      iex> #   ffplay tcp://nerves.local:8888
      iex> Fp3Camera.stop_stream(stream)
      :ok

  A camera serves one stream, subscription or still at a time; asking for
  a busy one returns `{:error, :busy}`.
  """

  alias Fp3Camera.{Camera, Still, Streams}

  @type camera :: :rear | :front

  @doc """
  Per-sensor, per-mode capture settings. See `Fp3Camera.Config`.

      Fp3Camera.configure({:rear, :snap}, gamma: 2.0)
      Fp3Camera.save_config()      # survives the reboot
  """
  defdelegate configure(scope, opts), to: Fp3Camera.Config, as: :put

  @doc "Everything set at runtime, by scope. See `Fp3Camera.Config`."
  defdelegate config(), to: Fp3Camera.Config, as: :get

  @doc "Persist runtime settings so they outlive a reboot."
  defdelegate save_config(), to: Fp3Camera.Config, as: :save

  @doc "Drop runtime settings for a scope, or `:all` of them."
  defdelegate reset_config(scope \\ :all), to: Fp3Camera.Config, as: :reset

  @doc "Settings applied to every camera and mode, under any per-sensor ones."
  @spec get_defaults() :: keyword()
  def get_defaults(), do: Application.get_env(:fp3_camera, :defaults, [])

  @doc """
  Merge into the settings applied to every camera and mode. A key set to
  `nil` is cleared. Running streams keep the settings they started with.

      Fp3Camera.set_defaults(gamma: 1.8, saturation: 1.7)
  """
  @spec set_defaults(keyword()) :: keyword()
  def set_defaults(opts) when is_list(opts) do
    merged = get_defaults() |> Keyword.merge(opts) |> Enum.reject(fn {_, v} -> is_nil(v) end)
    Application.put_env(:fp3_camera, :defaults, merged)
    merged
  end

  @doc "Clear the settings set with `set_defaults/1`."
  @spec reset_defaults() :: :ok
  def reset_defaults() do
    Application.put_env(:fp3_camera, :defaults, [])
    :ok
  end

  @doc """
  Which sensor is fitted in `camera` and the frame sizes it gives:
  `:sensor`, `:lens` (or `nil`), `:width` and `:height` at full
  resolution, `:binned` as `{width, height}` and libcamera's `:id`.

  The first call per camera opens it for about a second to read the
  sizes; later calls are free.

      iex> Fp3Camera.info(:rear)
      {:ok, %{camera: :rear, sensor: "s5kgm1sp", lens: "dw9800w",
              width: 3992, height: 3000, binned: {1992, 1500}, id: "/base/..."}}
  """
  @spec info(camera()) :: {:ok, map()} | {:error, term()}
  def info(camera), do: Camera.info(camera)

  @doc """
  Capture a still and save it as JPEG at `path`. Returns `{:ok, path}`.

  ## Options

    * `:binned` — use the sensor's binned mode: the same field of view at
      a quarter of the pixels, much faster (default `false`)
    * `:width`, `:height` — scale to this size; giving one keeps the
      aspect ratio
    * `:quality` — JPEG quality, 1..100 (default `90`)
    * `:frames` — frames to let auto exposure settle before the one
      that is kept (default `30`)
    * picture settings, see `Fp3Camera.Pipeline`
  """
  @spec snap(camera(), Path.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def snap(camera, path, opts \\ []), do: Still.snap(camera, path, opts)

  @doc """
  Capture a still and return the JPEG as a binary. Takes the options of
  `snap/3`.

      {:ok, jpg} = Fp3Camera.snap_bytes(:rear, binned: true)
  """
  @spec snap_bytes(camera(), keyword()) :: {:ok, binary()} | {:error, term()}
  def snap_bytes(camera, opts \\ []), do: Still.snap_bytes(camera, opts)

  @doc """
  Start a live H.264 stream from `camera`, served over TCP. Returns a
  reference for `stop_stream/1`.

  It is a raw H.264 stream on a plain TCP socket, not HTTP, so a browser
  cannot open it. View it with

      ffplay tcp://<device>:<port>
      mpv    tcp://<device>:<port>

  A viewer can connect at any time: every second starts with a keyframe.

  ## Options

    * `:port` — TCP port (default `8888` for `:rear`, `8890` for `:front`)
    * `:width`, `:height` — frame size (default `1280×960`), scaled from
      the binned sensor mode
    * `:framerate` — frames per second asked of the sensor (default `30`)
    * picture settings, see `Fp3Camera.Pipeline`
  """
  @spec start_stream(camera(), keyword()) :: {:ok, reference()} | {:error, term()}
  def start_stream(camera, opts \\ []), do: Streams.start(camera, opts)

  @doc "Stop a stream started with `start_stream/2`."
  @spec stop_stream(reference()) :: :ok
  def stop_stream(ref), do: Streams.stop(ref)

  @doc "List active streams."
  @spec streams() :: [%{ref: reference(), camera: camera(), port: pos_integer()}]
  def streams, do: Streams.list()

  @doc """
  Subscribe to a live NV12 frame feed. Each frame is sent to the calling
  process as

      {:camera_frame, %{format: :nv12, width: 1280, height: 960,
                        camera: :rear, data: <<1_843_200 bytes>>}}

  Decode straight to an Evision Mat:

      def handle_info({:camera_frame, %{format: :nv12, width: w,
                                        height: h, data: nv12}}, state) do
        # NV12 is a Y plane (h × w) followed by a UV plane (h/2 × w),
        # which OpenCV sees as a single (h * 1.5) × w u8 Mat.
        mat = Evision.Mat.from_binary(nv12, {:u, 8}, div(h * 3, 2), w, 1)
        bgr = Evision.cvtColor(mat, Evision.Constant.cv_COLOR_YUV2BGR_NV12())
        {:noreply, state}
      end

  Returns `{:ok, pid}`. Pass the pid to `unsubscribe/1`, or let the
  calling process exit. Takes the options of `start_stream/2` except
  `:port`.
  """
  @spec subscribe(camera(), keyword()) :: {:ok, pid()} | {:error, term()}
  def subscribe(camera, opts \\ []) do
    opts = opts |> Keyword.put(:camera, camera) |> Keyword.put(:subscriber, self())
    DynamicSupervisor.start_child(Fp3Camera.StreamSupervisor, {Fp3Camera.Subscriber, opts})
  end

  @doc "Stop a frame subscription started with `subscribe/2`."
  @spec unsubscribe(pid()) :: :ok
  def unsubscribe(pid) when is_pid(pid), do: Fp3Camera.Subscriber.stop(pid)
end
