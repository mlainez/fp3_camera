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

  # A child that dies sooner than this never served a client: it failed
  # to bind, or the camera would not open. Respawning that is a 4 Hz
  # loop, not a recovery. See handle_info/2 for the exit_status split.
  @min_lifetime_ms 3_000

  # A stream can also fail while staying alive: Venus wedges
  # (`wait for cpu and video core idle fail`) and the process sits there
  # holding its port, serving a client that receives nothing. Exit codes
  # never catch that, so liveness is judged on cam-stream's own
  # every-30-frames heartbeat instead.
  @health_interval_ms 5_000
  @stall_timeout_ms 10_000

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
  def init(_) do
    # A cam-stream outlives this VM if the VM went down between spawn and
    # Port.close — it keeps its TCP port bound, and the next start_stream
    # then dies on bind for a reason nobody can see from Elixir. Observed
    # on a running phone: an orphan held :8888 for six minutes and served
    # a client that connected to it by accident. Reap before we allocate.
    _ = System.cmd("pkill", ["-TERM", "-f", @cam_stream], stderr_to_stdout: true)

    :timer.send_interval(@health_interval_ms, :health_check)
    {:ok, %__MODULE__{}}
  end

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
              started_at: System.monotonic_time(:millisecond),
              # Per-spawn, unlike started_at: reset on every respawn so
              # the crash-loop guard measures this child, not the stream.
              spawned_at: System.monotonic_time(:millisecond),
              last_output: [],
              serving: false,
              last_progress_at: nil
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
  def handle_info({port, {:data, line}}, state) when is_port(port) do
    # Most of cam-stream's stderr is per-30-frame progress, so it is not
    # logged line by line. It is kept, though: when the child dies the
    # last thing it said is the whole diagnosis, and discarding it here
    # is what hid `bind: Address already in use` behind a respawn loop.
    case Enum.find(state.streams, fn {_, i} -> i.port_handle == port end) do
      {ref, info} ->
        # The heartbeat ends in \r, not \n — splitting on newlines alone
        # returns one ever-growing chunk and never sees a frame count.
        lines =
          line
          |> String.split(~r/[\r\n]+/, trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        now = System.monotonic_time(:millisecond)
        progressed? = Enum.any?(lines, &String.starts_with?(&1, "frames="))
        connected? = Enum.any?(lines, &String.contains?(&1, "client connected"))

        info = %{
          info
          | last_output: Enum.take(Enum.concat(info.last_output, lines), -5),
            serving: info.serving or connected?,
            last_progress_at: if(progressed?, do: now, else: info.last_progress_at)
        }

        {:noreply, put_in(state.streams[ref], info)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, state) when is_port(port) do
    case Enum.find(state.streams, fn {_, info} -> info.port_handle == port end) do
      {ref, info} ->
        lived = System.monotonic_time(:millisecond) - info.spawned_at

        # Two very different exits arrive through this one message.
        #
        # A client disconnecting is the normal one: cam-stream's TCP
        # server is single-client by design, so it exits when mpv goes
        # away and we respawn to keep the stream listening.
        #
        # A child that dies immediately never served anyone — it failed
        # to bind, or the camera would not open. Respawning that is not
        # recovery, it is a 4 Hz fork loop that hides the real error and
        # leaves `list_streams/0` reporting a stream nobody can watch.
        if lived < @min_lifetime_ms do
          Logger.error(
            "Fp3Camera: stream #{inspect(ref)} (#{info.camera}, tcp/#{info.port}) exited " <>
              "after #{lived} ms with status #{status} — not respawning. " <>
              "cam-stream said: #{Enum.join(info.last_output, " | ")}"
          )

          {:noreply, %{state | streams: Map.delete(state.streams, ref)}}
        else
          Logger.info(
            "Fp3Camera: stream #{inspect(ref)} (#{info.camera}) client disconnected " <>
              "after #{lived} ms (exit #{status}), re-spawning"
          )

          # Lets the listening socket leave TIME_WAIT before the re-bind.
          Process.sleep(250)

          new_info = %{
            info
            | port_handle: open_stream_port(info.camera, info.port, info.opts),
              spawned_at: System.monotonic_time(:millisecond),
              last_output: [],
              serving: false,
              last_progress_at: nil
          }

          {:noreply, %{state | streams: Map.put(state.streams, ref, new_info)}}
        end

      nil ->
        {:noreply, state}
    end
  end

  # Two faults that never produce an exit_status, so nothing else sees
  # them: the child was killed outside our control (the Port goes stale
  # without delivering a status in some races), and the child is alive
  # but has stopped producing frames because Venus wedged. Both leave
  # list_streams/0 reporting a healthy stream that serves nothing.
  def handle_info(:health_check, state) do
    now = System.monotonic_time(:millisecond)

    streams =
      Enum.reduce(state.streams, state.streams, fn {ref, info}, acc ->
        stalled? =
          info.serving and info.last_progress_at != nil and
            now - info.last_progress_at > @stall_timeout_ms

        cond do
          Port.info(info.port_handle) == nil ->
            Logger.error(
              "Fp3Camera: stream #{inspect(ref)} (#{info.camera}) vanished — the " <>
                "cam-stream process is gone without an exit status. Dropping it; " <>
                "last output: #{Enum.join(info.last_output, " | ")}"
            )

            Map.delete(acc, ref)

          stalled? ->
            Logger.error(
              "Fp3Camera: stream #{inspect(ref)} (#{info.camera}) stalled — no frames " <>
                "for #{now - info.last_progress_at} ms while serving a client. " <>
                "Restarting it; last output: #{Enum.join(info.last_output, " | ")}"
            )

            close_stream_port(info.port_handle)
            Process.sleep(250)

            Map.put(acc, ref, %{
              info
              | port_handle: open_stream_port(info.camera, info.port, info.opts),
                spawned_at: System.monotonic_time(:millisecond),
                last_output: [],
                serving: false,
                last_progress_at: nil
            })

          true ->
            acc
        end
      end)

    {:noreply, %{state | streams: streams}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Internals

  # Each stream occupies *two* consecutive TCP ports: the data socket,
  # and the control socket cam-stream derives as data+1 (cam-stream.c,
  # `control_port = listen_port + 1`). Rear used to default to 8889,
  # which put the rear data socket exactly on the front stream's control
  # port — so with both cameras streaming, whichever started second died
  # on bind. Allocate two apart, and pass --control explicitly so the
  # pairing is owned here rather than implied by the binary's default.
  defp default_port(:rear), do: 8888
  defp default_port(:front), do: 8890

  defp control_port(tcp_port), do: tcp_port + 1

  defp open_stream_port(camera, tcp_port, opts) do
    args =
      ["--camera", to_string(camera), "--listen", to_string(tcp_port),
       "--control", to_string(control_port(tcp_port))] ++
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
