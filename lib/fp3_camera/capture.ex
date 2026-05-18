defmodule Fp3Camera.Capture do
  @moduledoc false
  # Stills + live H.264 streaming via the cam-snap and cam-stream
  # binaries baked into the nerves_system_fp3 rootfs. Both binaries
  # do V4L2 bayer capture → NEON-accelerated demosaic + WB + gamma →
  # JPEG (cam-snap) or Venus H.264 m2m (cam-stream) directly; the
  # earlier gst-launch pipeline here couldn't drive qcom-camss
  # because GStreamer's v4l2src can't read 10-bit packed Bayer
  # (`pgAA`) which is the only format qcom-camss exposes.

  use GenServer
  require Logger

  alias Fp3Camera.Manager

  @cam_snap "/usr/bin/cam-snap"
  @cam_stream "/usr/bin/cam-stream"

  defstruct streams: %{}

  ## Public API

  def start_link(_opts \\ []),
    do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc """
  Capture a single JPEG. Blocks until the file is written or `cam-snap`
  exits. Recognised opts:

    * `:focus` — `:auto` (contrast-detect AF) or 0..1023 (rear only)
    * `:width`, `:height` — output size; defaults to sensor native
    * `:quality` — JPEG quality 1..100 (default 90)
    * `:exposure`, `:gain` — sensor controls
    * `:saturation`, `:contrast` — color processing knobs
    * `:phone_curve` — apply the histogram-match LUT (Android-look)
    * `:denoise`, `:frames` — bilateral strength / multi-frame avg
  """
  def snap(camera, path, opts \\ []) do
    with :ok <- Manager.setup(camera) do
      args = ["--camera", to_string(camera), "--out", path] ++ snap_extras(opts)

      case System.cmd(@cam_snap, args, stderr_to_stdout: true) do
        {_out, 0} ->
          {:ok, path}

        {out, rc} ->
          Logger.error("cam-snap exited #{rc}: #{out}")
          {:error, {:cam_snap_failed, rc, out}}
      end
    end
  end

  @doc """
  Capture and return the JPEG as a binary (no file written).

  Useful for downstream processing with Evision, Image, etc:

      {:ok, jpg} = Fp3Camera.Capture.snap_bytes(:rear, focus: :auto)
      mat = Evision.imdecode(jpg, Evision.Constant.cv_IMREAD_COLOR())
  """
  def snap_bytes(camera, opts \\ []) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "fp3_camera_#{:erlang.unique_integer([:positive])}.jpg"
      )

    case snap(camera, tmp, opts) do
      {:ok, _} ->
        case File.read(tmp) do
          {:ok, data} ->
            File.rm(tmp)
            {:ok, data}

          err ->
            err
        end

      err ->
        File.rm(tmp)
        err
    end
  end

  @doc """
  Start a live H.264 stream on a TCP port. Returns `{:ok, ref}` for
  later `stop_stream/1`. Open with `mpv tcp://nerves.local:<port>`.

  Defaults: rear → 8889, front → 8888. Stream is 1920×1080 H.264
  Baseline at 4 Mbps from Venus hardware encoder.
  """
  def start_stream(camera, opts \\ []) do
    GenServer.call(__MODULE__, {:start_stream, camera, opts})
  end

  def stop_stream(ref), do: GenServer.call(__MODULE__, {:stop_stream, ref})

  def list_streams, do: GenServer.call(__MODULE__, :list_streams)

  def tune(ref, opts), do: GenServer.call(__MODULE__, {:tune, ref, opts})

  ## GenServer

  @impl true
  def init(_), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:start_stream, camera, opts}, _from, state) do
    tcp_port = Keyword.get(opts, :port, default_port(camera))

    cond do
      existing = Enum.find(state.streams, fn {_r, i} -> i.camera == camera end) ->
        {_ref, info} = existing
        {:reply, {:error, {:camera_already_streaming, camera, info.ref}}, state}

      busy_port = port_conflict(state.streams, tcp_port) ->
        {:reply, {:error, {:port_in_use, busy_port}}, state}

      true ->
        case Manager.setup(camera) do
          :ok ->
            ref = make_ref()
            gst_port = open_stream_port(camera, tcp_port, opts)

            info = %{
              ref: ref,
              camera: camera,
              port: tcp_port,
              port_handle: gst_port,
              opts: opts,
              started_at: System.monotonic_time(:millisecond)
            }

            Logger.info(
              "Fp3Camera: stream #{inspect(ref)} from #{camera} on tcp/#{tcp_port} (control tcp/#{tcp_port + 1})"
            )

            {:reply, {:ok, ref}, %{state | streams: Map.put(state.streams, ref, info)}}

          err ->
            {:reply, err, state}
        end
    end
  end

  def handle_call({:tune, ref, opts}, _from, state) do
    case Map.fetch(state.streams, ref) do
      :error ->
        {:reply, {:error, :not_found}, state}

      {:ok, info} ->
        result = send_tune_commands(info.port + 1, opts)
        {:reply, result, state}
    end
  end

  def handle_call({:stop_stream, ref}, _from, state) do
    case Map.pop(state.streams, ref) do
      {nil, _} ->
        {:reply, {:error, :not_found}, state}

      {info, rest} ->
        close_stream_port(info.port_handle)
        {:reply, :ok, %{state | streams: rest}}
    end
  end

  def handle_call(:list_streams, _from, state) do
    summary =
      Enum.map(state.streams, fn {_ref, info} ->
        %{
          ref: info.ref,
          camera: info.camera,
          port: info.port,
          uptime_ms: System.monotonic_time(:millisecond) - info.started_at
        }
      end)

    {:reply, summary, state}
  end

  @impl true
  def handle_info({port, {:data, _line}}, state) when is_port(port) do
    # cam-stream's stderr is per-30-frame progress; we don't log per line
    # to keep the journal quiet. Stash if useful in the future.
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, state) when is_port(port) do
    case Enum.find(state.streams, fn {_, info} -> info.port_handle == port end) do
      {ref, info} ->
        # cam-stream's TCP server is single-client by design — when mpv
        # disconnects it exits cleanly. Respawn the Port so the stream
        # stays "listening" from the user's POV. The 250 ms sleep lets
        # the TCP socket leave TIME_WAIT before re-bind.
        Logger.info(
          "Fp3Camera: stream #{inspect(ref)} (#{info.camera}) client disconnected " <>
            "(exit #{status}), re-spawning"
        )

        Process.sleep(250)
        new_handle = open_stream_port(info.camera, info.port, info.opts)
        new_info = %{info | port_handle: new_handle}
        {:noreply, %{state | streams: Map.put(state.streams, ref, new_info)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Internals

  defp default_port(:rear), do: 8889
  defp default_port(:front), do: 8888

  defp open_stream_port(camera, tcp_port, opts) do
    args =
      ["--camera", to_string(camera), "--listen", to_string(tcp_port)] ++
        stream_extras(opts)

    Port.open({:spawn_executable, @cam_stream}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:args, args}
    ])
  end

  defp close_stream_port(port) do
    if Port.info(port) do
      case Port.info(port, :os_pid) do
        {:os_pid, pid} ->
          # cam-stream listens for SIGTERM via signal handler; send it,
          # then close the port to clean up file descriptors.
          System.cmd("kill", ["-TERM", Integer.to_string(pid)])

        _ ->
          :ok
      end

      try do
        Port.close(port)
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  defp snap_extras(opts) do
    Enum.flat_map(opts, fn
      {:focus, :auto} -> ["--autofocus"]
      {:focus, n} when is_integer(n) -> ["--focus", to_string(n)]
      {:width, n} -> ["--width", to_string(n)]
      {:height, n} -> ["--height", to_string(n)]
      {:quality, n} -> ["--quality", to_string(n)]
      {:exposure, n} -> ["--exposure", to_string(n)]
      {:gain, n} -> ["--gain", to_string(n)]
      {:saturation, f} -> ["--saturation", to_string(f)]
      {:contrast, f} -> ["--contrast", to_string(f)]
      {:gamma, f} -> ["--gamma", to_string(f)]
      {:brightness, f} -> ["--exposure-boost", to_string(f)]
      {:wb, {r, g, b}} -> ["--wb", to_string(r), to_string(g), to_string(b)]
      {:phone_curve, true} -> ["--phone-curve"]
      {:denoise, n} when is_integer(n) -> ["--denoise", to_string(n)]
      {:frames, n} when is_integer(n) -> ["--frames", to_string(n)]
      _ -> []
    end)
  end

  defp stream_extras(opts) do
    Enum.flat_map(opts, fn
      {:bitrate, n} when is_integer(n) -> ["--bitrate", to_string(n)]
      {:exposure, n} when is_integer(n) -> ["--exposure", to_string(n)]
      {:gain, n} when is_integer(n) -> ["--gain", to_string(n)]
      {:saturation, f} -> ["--saturation", to_string(f)]
      {:gamma, f} -> ["--gamma", to_string(f)]
      {:contrast, f} -> ["--contrast", to_string(f)]
      {:brightness, f} -> ["--brightness", to_string(f)]
      {:focus, n} when is_integer(n) -> ["--focus", to_string(n)]
      {:wb, {r, g, b}} -> ["--wb", to_string(r), to_string(g), to_string(b)]
      {:no_autofocus, true} -> ["--no-autofocus"]
      _ -> []
    end)
  end

  ## Port conflict check.
  ##
  ## Each stream owns two adjacent TCP ports: `port` (the H.264 listen
  ## socket) and `port + 1` (the live-tuning control socket). A new
  ## stream's requested port conflicts if either of its two ports
  ## matches either of any existing stream's two ports. Returns the
  ## colliding port, or nil if free.

  defp port_conflict(streams, new_port) do
    new_set = MapSet.new([new_port, new_port + 1])

    Enum.find_value(streams, fn {_ref, info} ->
      Enum.find([info.port, info.port + 1], fn p -> MapSet.member?(new_set, p) end)
    end)
  end

  ## Live tuning — talk to cam-stream's control socket on stream.port+1.

  defp send_tune_commands(ctrl_port, opts) do
    cmds =
      opts
      |> Enum.flat_map(fn
        {:wb, {r, g, b}} -> ["wb #{r} #{g} #{b}\n"]
        {:gamma, v} -> ["gamma #{v}\n"]
        {:contrast, v} -> ["contrast #{v}\n"]
        {:saturation, v} -> ["saturation #{v}\n"]
        {:brightness, v} -> ["brightness #{v}\n"]
        {:exposure, n} when is_integer(n) -> ["exposure #{n}\n"]
        {:gain, n} when is_integer(n) -> ["gain #{n}\n"]
        {:focus, n} when is_integer(n) -> ["focus #{n}\n"]
        _ -> []
      end)

    if cmds == [] do
      :ok
    else
      case :gen_tcp.connect(~c"127.0.0.1", ctrl_port, [:binary, {:active, false}], 1500) do
        {:ok, sock} ->
          :ok = :gen_tcp.send(sock, IO.iodata_to_binary(cmds))
          :gen_tcp.close(sock)
          :ok

        {:error, _} = err ->
          err
      end
    end
  end
end
