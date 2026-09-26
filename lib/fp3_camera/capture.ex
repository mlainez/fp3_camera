defmodule Fp3Camera.Capture do
  @moduledoc false
  # Stills and live H.264 streaming via the cam-snap and cam-stream
  # binaries from nerves_system_fp3's fp3-camera-utils package. Both do
  # V4L2 Bayer capture → software demosaic + WB + gamma → JPEG (cam-snap)
  # or Venus H.264 m2m (cam-stream) directly. GStreamer's v4l2src cannot
  # read the 10-bit packed Bayer (`pgAA`) that qcom-camss exposes, which
  # is why these are purpose-built C tools rather than a pipeline.
  #
  # Stills run in the caller's process; streams are owned by this
  # GenServer, which respawns cam-stream after each client disconnects
  # (its TCP server is single-client) and watches it for stalls.

  use GenServer
  require Logger

  alias Fp3Camera.{Config, Manager, Paths}

  # A child that dies sooner than this never served a client: it failed
  # to bind, or the camera would not open. Respawning that is a 4 Hz
  # loop, not a recovery. See handle_info/2 for the exit_status split.
  @min_lifetime_ms 3_000

  # How long start_stream/2 watches a new child before calling it started.
  # Long enough to catch a bind failure (~130 ms observed), short enough
  # not to be felt by the caller.
  @startup_grace_ms 700

  # start_stream/2 runs fp3-cam-setup through the Manager (15 s budget),
  # then waits out @startup_grace_ms. The default 5 s call timeout would
  # exit the caller while the stream was still coming up.
  @start_timeout 30_000

  # stop_stream/1 may escalate SIGTERM → SIGKILL, each with a 1 s grace.
  @stop_timeout 10_000

  # Teardown budgets. A wedged Venus ioctl will not answer SIGTERM, so
  # the escalation has to be bounded and then forceful.
  @term_grace_ms 1_000
  @kill_grace_ms 1_000
  @port_free_budget_ms 3_000

  # A stream can also fail while staying alive: Venus wedges
  # (`wait for cpu and video core idle fail`) and the process sits there
  # holding its port, serving a client that receives nothing. Exit codes
  # never catch that, so liveness is judged on cam-stream's own
  # every-30-frames heartbeat instead.
  @health_interval_ms 5_000
  @stall_timeout_ms 10_000

  # OS pids of the cam-stream processes this module started. Kept outside
  # the GenServer's state so they survive a crash-restart of it: cam-stream
  # only dies with the *VM* (PR_SET_PDEATHSIG), not with the Erlang
  # process that owned its Port, so a restarted Capture must reap its
  # predecessor's children — and only those. A blanket `pkill cam-stream`
  # here would also kill the ones Fp3Camera.Subscriber owns.
  @pids_key {__MODULE__, :os_pids}

  defstruct streams: %{}

  ## Public API

  def start_link(_opts \\ []),
    do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc """
  Capture a single JPEG with cam-snap. Blocks until cam-snap exits.
  Options are resolved through `Fp3Camera.Config` in `:snap` mode; see
  `snap_args/3` for the ones that map to cam-snap flags.
  """
  def snap(camera, path, opts \\ []) do
    # Setup first, then resolve. Config keys its defaults on the fitted
    # sensor, and the sensor name comes from /run/fp3-cam-<cam>.conf,
    # which fp3-cam-setup is what writes. Resolving first meant a fresh
    # boot looked up nil and silently got no defaults at all.
    with :ok <- Manager.setup(camera),
         {:ok, bin} <- Paths.executable(:cam_snap),
         opts = Config.resolve(camera, :snap, opts),
         {:ok, opts} <- resolve_auto_exposure(camera, opts) do
      case run_cam_snap(bin, snap_args(camera, path, opts)) do
        {:ok, _out} -> {:ok, path}
        {:error, _} = err -> err
      end
    end
  end

  @doc "Capture and return the JPEG as a binary (no file kept)."
  def snap_bytes(camera, opts \\ []) do
    tmp =
      Path.join(System.tmp_dir!(), "fp3_camera_#{:erlang.unique_integer([:positive])}.jpg")

    try do
      with {:ok, _} <- snap(camera, tmp, opts), do: File.read(tmp)
    after
      File.rm(tmp)
    end
  end

  @doc """
  Capture, and return what cam-snap measured and decided. Deliberately
  *not* config-resolved: this is the measurement used to derive the
  defaults, so it reports the sensor as it is.
  """
  def snap_stats(camera, opts \\ []) do
    path =
      Keyword.get_lazy(opts, :path, fn ->
        Path.join(System.tmp_dir!(), "fp3_cal_#{:erlang.unique_integer([:positive])}.jpg")
      end)

    with :ok <- Manager.setup(camera),
         {:ok, bin} <- Paths.executable(:cam_snap),
         {:ok, out} <- run_cam_snap(bin, snap_args(camera, path, Keyword.delete(opts, :path))) do
      {:ok, Map.put(parse_snap_stats(out), :path, path)}
    end
  end

  def start_stream(camera, opts \\ []),
    do: GenServer.call(__MODULE__, {:start_stream, camera, opts}, @start_timeout)

  def stop_stream(ref), do: GenServer.call(__MODULE__, {:stop_stream, ref}, @stop_timeout)

  def list_streams, do: GenServer.call(__MODULE__, :list_streams)

  def tune(ref, opts), do: GenServer.call(__MODULE__, {:tune, ref, opts})

  ## GenServer

  @impl true
  def init(_) do
    # So terminate/2 runs on supervisor shutdown and our children go with us.
    Process.flag(:trap_exit, true)
    reap_previous_children()
    :timer.send_interval(@health_interval_ms, :health_check)
    {:ok, %__MODULE__{}}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.streams, fn {_ref, info} -> close_stream_port(info.port_handle) end)
    :ok
  end

  @impl true
  def handle_call({:start_stream, camera, _opts}, _from, state)
      when camera not in [:rear, :front] do
    {:reply, {:error, {:unknown_camera, camera}}, state}
  end

  def handle_call({:start_stream, camera, opts}, _from, state) do
    tcp_port = Keyword.get(opts, :port, default_port(camera))

    cond do
      existing = Enum.find(state.streams, fn {_r, i} -> i.camera == camera end) ->
        {ref, _info} = existing
        {:reply, {:error, {:camera_already_streaming, camera, ref}}, state}

      busy_port = port_conflict(state.streams, tcp_port) ->
        {:reply, {:error, {:port_in_use, busy_port}}, state}

      true ->
        do_start_stream(camera, tcp_port, opts, state)
    end
  end

  def handle_call({:tune, ref, opts}, _from, state) do
    case Map.fetch(state.streams, ref) do
      :error -> {:reply, {:error, :not_found}, state}
      {:ok, info} -> {:reply, send_tune_commands(control_port(info.port), opts), state}
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
          width: info.width,
          height: info.height,
          uptime_ms: System.monotonic_time(:millisecond) - info.started_at
        }
      end)

    {:reply, summary, state}
  end

  @impl true
  def handle_info({port, {:data, line}}, state) when is_port(port) do
    # Most of cam-stream's stderr is per-30-frame progress, so it is not
    # logged line by line. It is kept, though: when the child dies the
    # last thing it said is the whole diagnosis. (A --listen cam-stream
    # writes nothing to stdout — the H.264 goes to the socket — so
    # merging stderr into the Port is safe here, unlike in Subscriber.)
    case find_by_port(state, port) do
      {ref, info} ->
        # The heartbeat ends in \r, not \n — splitting on newlines alone
        # returns one ever-growing chunk and never sees a frame count.
        lines = split_lines(line)
        now = System.monotonic_time(:millisecond)
        progressed? = Enum.any?(lines, &String.starts_with?(&1, "frames="))
        connected? = Enum.any?(lines, &String.contains?(&1, "client connected"))

        info = %{
          info
          | last_output: Enum.take(info.last_output ++ lines, -5),
            serving: info.serving or connected?,
            last_progress_at: if(progressed?, do: now, else: info.last_progress_at)
        }

        {:noreply, put_in(state.streams[ref], info)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, state) when is_port(port) do
    case find_by_port(state, port) do
      {ref, info} ->
        untrack_pid(info.os_pid)
        lived = System.monotonic_time(:millisecond) - info.spawned_at

        # Two very different exits arrive through this one message.
        #
        # A client disconnecting is the normal one: cam-stream's TCP
        # server is single-client by design, so it exits when the player
        # goes away and we respawn to keep the stream listening.
        #
        # A child that dies immediately never served anyone — it failed
        # to bind, or the camera would not open. Respawning that is not
        # recovery, it is a fork loop that hides the real error.
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

          # Do not guess at TIME_WAIT: wait until bind would actually
          # succeed, or give up loudly.
          await_port_free(info.port, @port_free_budget_ms)
          {:noreply, %{state | streams: respawn(state.streams, ref, info)}}
        end

      nil ->
        {:noreply, state}
    end
  end

  # Two faults that never produce an exit_status, so nothing else sees
  # them: the child was killed outside our control, and the child is
  # alive but has stopped producing frames because Venus wedged.
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

            untrack_pid(info.os_pid)
            Map.delete(acc, ref)

          stalled? ->
            Logger.error(
              "Fp3Camera: stream #{inspect(ref)} (#{info.camera}) stalled — no frames " <>
                "for #{now - info.last_progress_at} ms while serving a client. " <>
                "Restarting it; last output: #{Enum.join(info.last_output, " | ")}"
            )

            close_stream_port(info.port_handle)
            await_port_free(info.port, @port_free_budget_ms)
            respawn(acc, ref, info)

          true ->
            acc
        end
      end)

    {:noreply, %{state | streams: streams}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Stream lifecycle

  defp do_start_stream(camera, tcp_port, opts, state) do
    # prepare_stream runs `fp3-cam-setup --binned`, the same thing
    # cam-stream is about to do, so the Config lookup below sees the
    # fitted sensor and we know the frame size it will encode.
    with {:ok, geom} <- Manager.prepare_stream(camera),
         {:ok, bin} <- Paths.executable(:cam_stream),
         {:ok, port, os_pid} <- open_stream_port(bin, camera, tcp_port, opts) do
      # Do not report success until the child has survived long enough
      # to have bound its socket. Returning {:ok, ref} the instant the
      # Port opens is a lie whenever the port is already taken: the child
      # dies ~130 ms later on "bind: Address already in use" and the
      # caller is left holding a ref that stop_stream/1 then rejects.
      case await_start(port) do
        {:died, status, output} ->
          untrack_pid(os_pid)

          Logger.error(
            "Fp3Camera: #{camera} stream on tcp/#{tcp_port} failed to start " <>
              "(exit #{status}): #{Enum.join(output, " | ")}"
          )

          {:reply, {:error, {:stream_failed, status, output}}, state}

        {:started, output} ->
          now = System.monotonic_time(:millisecond)
          ref = make_ref()

          info = %{
            ref: ref,
            camera: camera,
            port: tcp_port,
            width: geom.out_width,
            height: geom.out_height,
            port_handle: port,
            os_pid: os_pid,
            opts: opts,
            started_at: now,
            # Per-spawn, unlike started_at: reset on every respawn so
            # the crash-loop guard measures this child, not the stream.
            spawned_at: now,
            last_output: output,
            serving: false,
            last_progress_at: nil
          }

          Logger.info(
            "Fp3Camera: stream #{inspect(ref)} from #{camera} on tcp/#{tcp_port} " <>
              "(control tcp/#{control_port(tcp_port)}), " <>
              "#{geom.out_width}x#{geom.out_height}"
          )

          {:reply, {:ok, ref}, %{state | streams: Map.put(state.streams, ref, info)}}
      end
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  # Reopen a stream's cam-stream in place. If that fails (binary gone,
  # fork failure) the stream is dropped with a log line rather than
  # crashing this process and taking every other stream with it.
  defp respawn(streams, ref, info) do
    with {:ok, bin} <- Paths.executable(:cam_stream),
         {:ok, port, os_pid} <- open_stream_port(bin, info.camera, info.port, info.opts) do
      Map.put(streams, ref, %{
        info
        | port_handle: port,
          os_pid: os_pid,
          spawned_at: System.monotonic_time(:millisecond),
          last_output: [],
          serving: false,
          last_progress_at: nil
      })
    else
      {:error, reason} ->
        Logger.error(
          "Fp3Camera: could not respawn stream #{inspect(ref)} (#{info.camera}): " <>
            "#{inspect(reason)} — dropping it"
        )

        Map.delete(streams, ref)
    end
  end

  defp open_stream_port(bin, camera, tcp_port, opts) do
    args = stream_args(camera, tcp_port, Config.resolve(camera, :stream, opts))

    port =
      Port.open({:spawn_executable, bin}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args}
      ])

    # Read the pid now: once the child exits the Port closes and it is gone.
    os_pid = port_os_pid(port)
    track_pid(os_pid)
    {:ok, port, os_pid}
  rescue
    e -> {:error, {:spawn_failed, Exception.message(e)}}
  end

  defp close_stream_port(port) do
    if Port.info(port) do
      case port_os_pid(port) do
        nil ->
          :ok

        pid ->
          # SIGTERM, then escalate. cam-stream handles SIGTERM and tears
          # down cleanly, but when Venus wedges it is stuck inside an
          # ioctl and never gets to the handler — observed as a restart
          # that immediately hit "bind: Address already in use" because
          # the corpse still held the socket.
          terminate_os_pid(pid)
          untrack_pid(pid)
      end

      try do
        Port.close(port)
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  defp terminate_os_pid(pid) do
    os_kill(pid, "-TERM")

    unless await_exit(pid, @term_grace_ms) do
      Logger.warning("Fp3Camera: pid #{pid} ignored SIGTERM, sending SIGKILL")
      os_kill(pid, "-KILL")
      await_exit(pid, @kill_grace_ms)
    end
  end

  defp os_kill(pid, signal) do
    System.cmd("kill", [signal, Integer.to_string(pid)], stderr_to_stdout: true)
  rescue
    _ -> :error
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end

  defp find_by_port(state, port),
    do: Enum.find(state.streams, fn {_, i} -> i.port_handle == port end)

  defp split_lines(data) do
    data
    |> String.split(~r/[\r\n]+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  ## Child tracking across restarts

  defp tracked_pids, do: :persistent_term.get(@pids_key, [])

  defp track_pid(nil), do: :ok
  defp track_pid(pid), do: :persistent_term.put(@pids_key, [pid | tracked_pids()])

  defp untrack_pid(nil), do: :ok

  defp untrack_pid(pid) do
    case tracked_pids() do
      [] -> :ok
      pids -> :persistent_term.put(@pids_key, List.delete(pids, pid))
    end
  end

  # Pids are reused, so only signal one that is still a cam-stream serving
  # a TCP stream — never a Subscriber's `--out-nv12` child.
  defp reap_previous_children do
    for pid <- tracked_pids(), capture_child?(pid) do
      Logger.warning("Fp3Camera: reaping cam-stream pid #{pid} left by a previous Capture")
      terminate_os_pid(pid)
    end

    if tracked_pids() != [], do: :persistent_term.erase(@pids_key)
    :ok
  end

  defp capture_child?(pid) do
    case File.read("/proc/#{pid}/cmdline") do
      {:ok, cmdline} ->
        args = String.split(cmdline, <<0>>, trim: true)
        Enum.any?(args, &String.ends_with?(&1, "cam-stream")) and "--listen" in args

      _ ->
        false
    end
  end

  # Watch the freshly spawned child for @startup_grace_ms. A bind failure
  # or a camera that will not open shows up well inside that window.
  defp await_start(port), do: await_start(port, [], System.monotonic_time(:millisecond))

  defp await_start(port, acc, t0) do
    left = @startup_grace_ms - (System.monotonic_time(:millisecond) - t0)

    if left <= 0 do
      {:started, Enum.take(acc, -5)}
    else
      receive do
        {^port, {:data, d}} -> await_start(port, acc ++ split_lines(d), t0)
        {^port, {:exit_status, st}} -> {:died, st, Enum.take(acc, -5)}
      after
        left -> {:started, Enum.take(acc, -5)}
      end
    end
  end

  # True once the pid is gone. /proc is the only honest answer here:
  # busybox `ps -o args` lists only the calling session's processes.
  defp await_exit(pid, budget_ms), do: await_exit(pid, budget_ms, 0)

  defp await_exit(_pid, budget, waited) when waited >= budget, do: false

  defp await_exit(pid, budget, waited) do
    if File.exists?("/proc/#{pid}") do
      Process.sleep(50)
      await_exit(pid, budget, waited + 50)
    else
      true
    end
  end

  # Wait until the port can actually be bound. TIME_WAIT, a lingering
  # child or a stray from an earlier VM all look the same to cam-stream;
  # the only thing that matters is whether bind(2) will succeed.
  defp await_port_free(tcp_port, budget_ms), do: await_port_free(tcp_port, budget_ms, 0)

  defp await_port_free(tcp_port, budget, waited) when waited >= budget do
    Logger.warning("Fp3Camera: tcp/#{tcp_port} still busy after #{budget} ms")
    false
  end

  defp await_port_free(tcp_port, budget, waited) do
    case :gen_tcp.listen(tcp_port, [:binary, {:reuseaddr, true}]) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        true

      {:error, _} ->
        Process.sleep(50)
        await_port_free(tcp_port, budget, waited + 50)
    end
  end

  ## Ports

  # Each stream occupies *two* consecutive TCP ports: the data socket and
  # the control socket (cam-stream's default is data+1; we pass --control
  # explicitly so the pairing is owned here). Rear 8888/8889 and front
  # 8890/8891 therefore never overlap.
  @doc false
  def default_port(:rear), do: 8888
  def default_port(:front), do: 8890

  defp control_port(tcp_port), do: tcp_port + 1

  @doc false
  # The colliding port if either of `new_port`/`new_port + 1` overlaps
  # either port of an existing stream, else nil.
  def port_conflict(streams, new_port) do
    new_set = MapSet.new([new_port, new_port + 1])

    Enum.find_value(streams, fn {_ref, info} ->
      Enum.find([info.port, info.port + 1], &MapSet.member?(new_set, &1))
    end)
  end

  ## cam-snap

  defp run_cam_snap(bin, args) do
    case System.cmd(bin, args, stderr_to_stdout: true) do
      {out, 0} ->
        {:ok, out}

      {out, rc} ->
        Logger.error("Fp3Camera: cam-snap exited #{rc}: #{out}")
        {:error, {:cam_snap_failed, rc, out}}
    end
  rescue
    # Present but not runnable (permissions, wrong architecture).
    e in ErlangError -> {:error, {:cam_snap_failed, Exception.message(e)}}
  end

  # `exposure: :auto` meters first. Nothing else sets exposure at all, so
  # without this a dim subject is simply dark — see Fp3Camera.AutoExposure.
  defp resolve_auto_exposure(camera, opts) do
    if Keyword.get(opts, :exposure) == :auto do
      opts = Keyword.delete(opts, :exposure)

      case Fp3Camera.AutoExposure.meter(camera, opts) do
        {:ok, settings} ->
          {:ok, Keyword.merge(opts, settings)}

        err ->
          Logger.warning("Fp3Camera: metering failed (#{inspect(err)}), capturing as-is")
          {:ok, opts}
      end
    else
      {:ok, opts}
    end
  end

  @doc false
  # cam-snap's argv. Every option maps to a flag in cam-snap.c's argument
  # parser; anything else is ignored. `:args` is the escape hatch for
  # flags not modelled here.
  def snap_args(camera, path, opts) do
    ["--camera", to_string(camera), "--out", path] ++ Enum.flat_map(opts, &snap_flag/1)
  end

  defp snap_flag({:focus, :auto}), do: ["--autofocus"]
  defp snap_flag({:focus, n}) when is_integer(n), do: ["--focus", to_string(n)]
  defp snap_flag({:quality, n}) when is_integer(n), do: ["--quality", to_string(n)]
  defp snap_flag({:exposure, n}) when is_integer(n), do: ["--exposure", to_string(n)]
  defp snap_flag({:gain, n}) when is_integer(n), do: ["--gain", to_string(n)]
  defp snap_flag({:saturation, f}) when is_number(f), do: ["--saturation", to_string(f)]
  defp snap_flag({:contrast, f}) when is_number(f), do: ["--contrast", to_string(f)]
  defp snap_flag({:gamma, f}) when is_number(f), do: ["--gamma", to_string(f)]
  defp snap_flag({:brightness, f}) when is_number(f), do: ["--exposure-boost", to_string(f)]
  defp snap_flag({:binned, true}), do: ["--binned"]
  defp snap_flag({:bayer, b}) when is_atom(b) or is_binary(b), do: ["--bayer", to_string(b)]
  defp snap_flag({:awb, true}), do: ["--awb"]
  defp snap_flag({:awb, false}), do: ["--no-awb"]
  defp snap_flag({:wb, {r, g, b}}), do: ["--wb", to_string(r), to_string(g), to_string(b)]
  defp snap_flag({:warm_bias, f}) when is_number(f), do: ["--warm-bias", to_string(f)]
  defp snap_flag({:lsc, f}) when is_number(f), do: ["--lsc", to_string(f)]
  defp snap_flag({:phone_curve, true}), do: ["--phone-curve"]
  defp snap_flag({:ccm, true}), do: ["--ccm"]
  defp snap_flag({:mhc, false}), do: ["--no-mhc"]
  defp snap_flag({:sharpen, false}), do: ["--no-sharpen"]
  defp snap_flag({:sharpen, true}), do: ["--sharpen"]
  defp snap_flag({:sharpen, f}) when is_float(f), do: ["--sharpen-amount", to_string(f)]
  defp snap_flag({:auto_levels, false}), do: ["--no-auto-levels"]

  defp snap_flag({:auto_levels, {lo, hi}}),
    do: ["--auto-levels", to_string(lo), to_string(hi)]

  defp snap_flag({:denoise, n}) when is_integer(n), do: ["--denoise", to_string(n)]
  defp snap_flag({:frames, n}) when is_integer(n), do: ["--frames", to_string(n)]
  defp snap_flag({:args, extra}) when is_list(extra), do: Enum.map(extra, &to_string/1)
  defp snap_flag(_), do: []

  @doc false
  # cam-snap reports what it measured and what it decided on stderr.
  # Handing that back makes calibration a closed loop in Elixir.
  def parse_snap_stats(out) do
    raw =
      case Regex.run(~r/with bayer=(\w+): R=([\d.]+) G=([\d.]+) B=([\d.]+)/, out) do
        [_, bayer, r, g, b] -> %{bayer: bayer, r: to_float(r), g: to_float(g), b: to_float(b)}
        _ -> nil
      end

    gains =
      case Regex.run(~r/wb gains: R=([\d.]+) G=([\d.]+) B=([\d.]+)/, out) do
        [_, r, g, b] -> %{r: to_float(r), g: to_float(g), b: to_float(b)}
        _ -> nil
      end

    sensor =
      case Regex.run(~r/cam-snap: sensor (.+)/, out) do
        [_, s] -> String.trim(s)
        _ -> nil
      end

    %{sensor: sensor, raw: raw, gains: gains, output: out}
  end

  defp to_float(s) do
    {f, _} = Float.parse(s)
    f
  end

  ## cam-stream

  @doc false
  # argv for a TCP H.264 stream.
  def stream_args(camera, tcp_port, opts) do
    [
      "--camera",
      to_string(camera),
      "--listen",
      to_string(tcp_port),
      "--control",
      to_string(control_port(tcp_port))
    ] ++
      stream_flags(opts)
  end

  @doc false
  # The pipeline flags cam-stream accepts. `:bitrate` and `:fps` only
  # mean anything to the H.264 path; Subscriber filters them out.
  def stream_flags(opts), do: Enum.flat_map(opts, &stream_flag/1)

  defp stream_flag({:bitrate, n}) when is_integer(n), do: ["--bitrate", to_string(n)]
  defp stream_flag({:fps, n}) when is_integer(n), do: ["--fps", to_string(n)]
  defp stream_flag({:exposure, n}) when is_integer(n), do: ["--exposure", to_string(n)]
  defp stream_flag({:gain, n}) when is_integer(n), do: ["--gain", to_string(n)]
  defp stream_flag({:saturation, f}) when is_number(f), do: ["--saturation", to_string(f)]
  defp stream_flag({:gamma, f}) when is_number(f), do: ["--gamma", to_string(f)]
  defp stream_flag({:contrast, f}) when is_number(f), do: ["--contrast", to_string(f)]
  defp stream_flag({:brightness, f}) when is_number(f), do: ["--brightness", to_string(f)]
  defp stream_flag({:wb, {r, g, b}}), do: ["--wb", to_string(r), to_string(g), to_string(b)]
  defp stream_flag({:focus, :auto}), do: ["--autofocus"]
  defp stream_flag({:focus, n}) when is_integer(n), do: ["--focus", to_string(n)]
  defp stream_flag({:args, extra}) when is_list(extra), do: Enum.map(extra, &to_string/1)
  defp stream_flag(_), do: []

  ## Live tuning — cam-stream's control socket, one command per line.

  @doc false
  def tune_commands(opts) do
    Enum.flat_map(opts, fn
      {:wb, {r, g, b}} -> ["wb #{r} #{g} #{b}\n"]
      {:gamma, v} when is_number(v) -> ["gamma #{v}\n"]
      {:contrast, v} when is_number(v) -> ["contrast #{v}\n"]
      {:saturation, v} when is_number(v) -> ["saturation #{v}\n"]
      {:brightness, v} when is_number(v) -> ["brightness #{v}\n"]
      {:exposure, n} when is_integer(n) -> ["exposure #{n}\n"]
      {:gain, n} when is_integer(n) -> ["gain #{n}\n"]
      {:focus, n} when is_integer(n) -> ["focus #{n}\n"]
      _ -> []
    end)
  end

  defp send_tune_commands(ctrl_port, opts) do
    case tune_commands(opts) do
      [] ->
        :ok

      cmds ->
        case :gen_tcp.connect(~c"127.0.0.1", ctrl_port, [:binary, {:active, false}], 1500) do
          {:ok, sock} ->
            result = :gen_tcp.send(sock, IO.iodata_to_binary(cmds))
            :gen_tcp.close(sock)
            result

          {:error, _} = err ->
            err
        end
    end
  end
end
