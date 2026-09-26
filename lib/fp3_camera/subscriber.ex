defmodule Fp3Camera.Subscriber do
  @moduledoc """
  Per-subscription process that owns a `cam-stream --out-nv12` child and
  forwards each NV12 frame to a subscriber process as

      {:camera_frame, %{
        format: :nv12,
        width: w,
        height: h,
        camera: :rear,
        data: <<w * h * 3 div 2 bytes>>
      }}

  The frame size is not fixed. cam-stream emits the largest frame that
  fits the sensor's 2x2-binned mode within 1920×1080, rounded down to the
  Venus encoder's alignment (width a multiple of 128, height of 32):
  1920×1056 on every camera except the Fairphone 3 front (S5K4H7YX),
  which gives 1408×1056. `Fp3Camera.subscribe/2` works it out with the
  same rule before starting cam-stream; read `width`/`height` from each
  message rather than assuming them.

  Use `Fp3Camera.subscribe/2` / `Fp3Camera.unsubscribe/1` rather than
  starting this directly.

  cam-stream's stdout carries nothing but frames. Its stderr (setup and
  progress logging) goes to `<tmp>/fp3_camera_nv12_<camera>.log`, and the
  last lines are logged if it exits.

  Backpressure: if the subscriber can't drain frames fast enough the OS
  pipe buffer fills and cam-stream blocks on `write`, which then drops
  V4L2 capture frames at the sensor side. The mailbox of a subscriber
  that never reads, however, is not bounded here.

  The process stops when the subscriber exits, when `unsubscribe/1` is
  called, or when cam-stream exits. It is not restarted; monitor the pid
  returned by `subscribe/2` to learn that the feed has ended.
  """
  use GenServer, restart: :temporary
  require Logger

  # cam-stream flags that mean nothing in --out-nv12 mode: there is no
  # encoder (bitrate) and the NV12 loop is not paced (fps).
  @h264_only [:bitrate, :fps]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def stop(pid), do: GenServer.stop(pid, :normal)

  @impl true
  def init(opts) do
    camera = Keyword.fetch!(opts, :camera)
    subscriber = Keyword.fetch!(opts, :subscriber)
    bin = Keyword.fetch!(opts, :binary)
    width = Keyword.fetch!(opts, :width)
    height = Keyword.fetch!(opts, :height)
    log = log_path(camera)

    Process.flag(:trap_exit, true)

    case open_port(bin, args(camera, Keyword.get(opts, :pipeline, [])), log) do
      {:ok, port} ->
        Process.monitor(subscriber)

        Logger.info(
          "Fp3Camera.Subscriber: cam-stream #{camera} #{width}x#{height} NV12 → #{inspect(subscriber)}"
        )

        {:ok,
         %{
           camera: camera,
           subscriber: subscriber,
           port: port,
           log: log,
           width: width,
           height: height,
           frame_size: frame_size(width, height),
           # iolist of pending bytes — avoids O(N²) `buf <> data` on a
           # ~3 MB-per-frame stream. Flattened only at frame boundaries.
           buf: [],
           buf_bytes: 0,
           frames_sent: 0
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    state = %{state | buf: [state.buf | data], buf_bytes: state.buf_bytes + byte_size(data)}
    {:noreply, drain_frames(state)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning(
      "Fp3Camera.Subscriber: cam-stream(#{state.camera}) exited #{status} after " <>
        "#{state.frames_sent} frames; last output: #{tail(state.log)}"
    )

    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{subscriber: pid} = state) do
    Logger.info("Fp3Camera.Subscriber: subscriber #{inspect(pid)} exited, stopping")
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) do
    if Port.info(port) do
      case Port.info(port, :os_pid) do
        {:os_pid, pid} ->
          try do
            System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
          rescue
            _ -> :ok
          end

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

  ## Internals

  @doc false
  def frame_size(width, height), do: div(width * height * 3, 2)

  @doc false
  def args(camera, pipeline_opts) do
    ["--camera", to_string(camera), "--out-nv12"] ++
      Fp3Camera.Capture.stream_flags(Keyword.drop(pipeline_opts, @h264_only))
  end

  # Through /bin/sh only to point stderr at a file: the Port has a single
  # data channel, and merging stderr into it (:stderr_to_stdout) splices
  # log text into the frame bytes and shifts every later frame. `exec`
  # keeps the Port's os_pid the cam-stream pid, so terminate/2 still
  # signals the right process.
  defp open_port(bin, args, log) do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        {:args, ["-c", ~S(exec "$0" "$@" 2>"$FP3_CAMERA_LOG"), bin | args]},
        {:env, [{~c"FP3_CAMERA_LOG", String.to_charlist(log)}]}
      ])

    {:ok, port}
  rescue
    e -> {:error, {:spawn_failed, Exception.message(e)}}
  end

  defp log_path(camera), do: Path.join(System.tmp_dir!(), "fp3_camera_nv12_#{camera}.log")

  defp tail(log) do
    case File.read(log) do
      {:ok, text} ->
        text
        |> String.split(~r/[\r\n]+/, trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.take(-5)
        |> Enum.join(" | ")

      _ ->
        "(no log)"
    end
  end

  # Slice complete frames off the buffer and send each one. Only flattens
  # once at least one full frame has arrived.
  defp drain_frames(%{buf_bytes: bytes, frame_size: size} = state) when bytes >= size do
    {frames, rest} = chop(IO.iodata_to_binary(state.buf), size)
    Enum.each(frames, &send_frame(state, &1))

    %{
      state
      | buf: [rest],
        buf_bytes: byte_size(rest),
        frames_sent: state.frames_sent + length(frames)
    }
  end

  defp drain_frames(state), do: state

  @doc false
  # Split `bin` into whole `size`-byte frames and the leftover tail.
  def chop(bin, size), do: chop(bin, size, [])

  defp chop(bin, size, acc) when byte_size(bin) >= size do
    <<frame::binary-size(^size), rest::binary>> = bin
    chop(rest, size, [frame | acc])
  end

  defp chop(bin, _size, acc), do: {Enum.reverse(acc), bin}

  defp send_frame(state, frame) do
    send(
      state.subscriber,
      {:camera_frame,
       %{
         format: :nv12,
         width: state.width,
         height: state.height,
         camera: state.camera,
         data: frame
       }}
    )
  end
end
