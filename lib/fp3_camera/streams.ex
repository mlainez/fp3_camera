defmodule Fp3Camera.Streams do
  @moduledoc false
  # Owns the gst-launch processes that hold a camera open: H.264 streams,
  # which it starts, and frame subscribers, which register themselves. A
  # camera serves one of them at a time, and stills wait their turn.

  use GenServer
  require Logger

  alias Fp3Camera.{Camera, Config, Pipeline}

  @default_ports %{rear: 8888, front: 8890}

  # When Venus stops answering, the kernel restarts its firmware and the
  # stream that hit it dies; starting it again a moment later works. A
  # stream that ran for a minute gets its restarts back.
  @max_restarts 3
  @restart_delay 5_000
  @healthy_run 60_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def start(camera, opts), do: GenServer.call(__MODULE__, {:start, camera, opts}, 30_000)
  def stop(ref), do: GenServer.call(__MODULE__, {:stop, ref}, 10_000)
  def list, do: GenServer.call(__MODULE__, :list)
  def ensure_idle(camera), do: GenServer.call(__MODULE__, {:ensure_idle, camera})
  def claim(camera, pid), do: GenServer.call(__MODULE__, {:claim, camera, pid})

  @impl true
  def init(nil), do: {:ok, %{streams: %{}, claims: %{}}}

  @impl true
  def handle_call({:start, camera, opts}, _from, state) do
    opts = Config.resolve(camera, :stream, opts)
    opts = Keyword.put_new(opts, :port, @default_ports[camera])

    with :ok <- idle(state, camera),
         {:ok, info} <- Camera.info(camera) do
      ref = make_ref()
      out = {Keyword.get(opts, :width, 1920), Keyword.get(opts, :height, 1080)}
      stream = %{camera: camera, port: opts[:port], args: Pipeline.stream(info, out, opts)}
      {:reply, {:ok, ref}, launch(state, ref, Map.put(stream, :restarts, 0))}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:stop, ref}, _from, state) do
    case Map.pop(state.streams, ref) do
      {nil, _} ->
        {:reply, :ok, state}

      {stream, streams} ->
        shutdown(stream)
        {:reply, :ok, %{state | streams: streams}}
    end
  end

  def handle_call(:list, _from, state) do
    list = for {ref, s} <- state.streams, do: %{ref: ref, camera: s.camera, port: s.port}
    {:reply, list, state}
  end

  def handle_call({:ensure_idle, camera}, _from, state), do: {:reply, idle(state, camera), state}

  def handle_call({:claim, camera, pid}, _from, state) do
    case idle(state, camera) do
      :ok ->
        Process.monitor(pid)
        {:reply, :ok, put_in(state.claims[camera], pid)}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:DOWN, mref, :process, pid, reason}, state) do
    case Enum.find(state.streams, fn {_ref, s} -> s.monitor == mref end) do
      {ref, stream} ->
        ran = System.monotonic_time(:millisecond) - stream.launched_at
        stream = if ran > @healthy_run, do: %{stream | restarts: 0}, else: stream

        if stream.restarts < @max_restarts do
          Logger.warning(
            "fp3_camera: #{stream.camera} stream exited (#{inspect(reason)}), restarting"
          )

          Process.send_after(self(), {:relaunch, ref}, @restart_delay)
          {:noreply, put_in(state.streams[ref], %{stream | restarts: stream.restarts + 1})}
        else
          Logger.error(
            "fp3_camera: #{stream.camera} stream exited (#{inspect(reason)}), giving up"
          )

          {:noreply, %{state | streams: Map.delete(state.streams, ref)}}
        end

      nil ->
        claims = for {camera, owner} <- state.claims, owner != pid, into: %{}, do: {camera, owner}
        {:noreply, %{state | claims: claims}}
    end
  end

  def handle_info({:relaunch, ref}, state) do
    case state.streams[ref] do
      nil -> {:noreply, state}
      stream -> {:noreply, launch(state, ref, stream)}
    end
  end

  defp idle(state, camera) do
    busy =
      Map.has_key?(state.claims, camera) or
        Enum.any?(state.streams, fn {_ref, s} -> s.camera == camera end)

    if busy, do: {:error, :busy}, else: :ok
  end

  defp launch(state, ref, stream) do
    spec = %{
      id: ref,
      restart: :temporary,
      start:
        {MuonTrap.Daemon, :start_link,
         [
           "gst-launch-1.0",
           stream.args,
           [env: [{"LIBCAMERA_LOG_LEVELS", "*:ERROR"}], stderr_to_stdout: true, log_output: :info]
         ]}
    }

    {:ok, pid} = DynamicSupervisor.start_child(Fp3Camera.StreamSupervisor, spec)

    stream =
      Map.merge(stream, %{
        daemon: pid,
        monitor: Process.monitor(pid),
        launched_at: System.monotonic_time(:millisecond)
      })

    put_in(state.streams[ref], stream)
  end

  # gst-launch -e turns SIGINT into end-of-stream, which closes the Venus
  # session properly; a session killed mid-frame can wedge the firmware.
  defp shutdown(%{daemon: pid, monitor: mref}) do
    Process.demonitor(mref, [:flush])
    mref = Process.monitor(pid)

    with os_pid when is_integer(os_pid) <- os_pid(pid) do
      for child <- children(os_pid), do: System.cmd("kill", ["-INT", child])
    end

    receive do
      {:DOWN, ^mref, :process, ^pid, _} -> :ok
    after
      3_000 -> DynamicSupervisor.terminate_child(Fp3Camera.StreamSupervisor, pid)
    end
  end

  # The kernel has no /proc/<pid>/task/<pid>/children, so match parent
  # pids in /proc/<pid>/stat: "pid (comm) state ppid ...".
  defp children(parent) do
    parent = Integer.to_string(parent)

    for entry <- File.ls!("/proc"),
        entry =~ ~r/^\d+$/,
        {:ok, stat} <- [File.read("/proc/#{entry}/stat")],
        [_, ppid] <- [Regex.run(~r/\) \S (\d+) /, stat)],
        ppid == parent,
        do: entry
  end

  # The daemon may already be gone while its stream waits to be relaunched.
  defp os_pid(pid) do
    MuonTrap.Daemon.os_pid(pid)
  catch
    :exit, _ -> :error
  end
end
