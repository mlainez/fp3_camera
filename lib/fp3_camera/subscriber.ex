defmodule Fp3Camera.Subscriber do
  @moduledoc """
  Per-subscription GenServer that owns a `cam-stream --out-nv12` Port and
  forwards each NV12 frame to a subscriber process as

      {:camera_frame, %{
        format: :nv12,
        width: 1920,
        height: 1080,
        data: <<3_110_400 bytes>>
      }}

  Use `Fp3Camera.subscribe/2` / `Fp3Camera.unsubscribe/1` rather than
  starting this directly.

  Backpressure: if the subscriber can't drain frames fast enough the OS
  pipe buffer fills and cam-stream blocks on `write`, which then drops
  V4L2 capture frames at the sensor side. No unbounded memory growth.

  When the subscriber process exits, the Subscriber follows it down.
  """
  use GenServer, restart: :transient
  require Logger

  @cam_stream "/usr/bin/cam-stream"
  # NV12 1920×1080: Y plane (W*H) + interleaved UV plane (W*H/2)
  @width 1920
  @height 1080
  @frame_size div(@width * @height * 3, 2)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def stop(pid), do: GenServer.stop(pid, :normal)

  @impl true
  def init(opts) do
    camera = Keyword.fetch!(opts, :camera)
    subscriber = Keyword.fetch!(opts, :subscriber)

    args =
      ["--camera", to_string(camera), "--out-nv12"] ++ build_extras(opts)

    Process.flag(:trap_exit, true)
    Process.monitor(subscriber)

    port =
      Port.open({:spawn_executable, @cam_stream}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, args}
      ])

    Logger.info(
      "Fp3Camera.Subscriber: started cam-stream #{camera} → pid=#{inspect(subscriber)}"
    )

    {:ok,
     %{
       camera: camera,
       subscriber: subscriber,
       port: port,
       # iolist of pending bytes — avoids O(N²) `buf <> data` on the
       # 3.1 MB-per-frame NV12 stream. Bytes are flattened into a flat
       # binary only at frame boundaries.
       buf: [],
       buf_bytes: 0,
       frames_sent: 0,
       started_at: System.monotonic_time(:millisecond)
     }}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    state = %{
      state
      | buf: [state.buf | data],
        buf_bytes: state.buf_bytes + byte_size(data)
    }

    state = drain_frames(state)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning(
      "Fp3Camera.Subscriber: cam-stream(#{state.camera}) exited #{status}"
    )

    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{subscriber: pid} = state) do
    Logger.info("Fp3Camera.Subscriber: subscriber #{inspect(pid)} died, stopping")
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) do
    if Port.info(port) do
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> System.cmd("kill", ["-TERM", Integer.to_string(pid)])
        _ -> :ok
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

  # Slice complete @frame_size-sized chunks off the iolist buffer, send
  # each one to the subscriber. Only flattens to a binary once we know
  # at least one full frame's bytes have arrived — keeps the hot path
  # O(N) per frame rather than O(N²).
  defp drain_frames(%{buf_bytes: bytes} = state) when bytes >= @frame_size do
    flat = IO.iodata_to_binary(state.buf)
    {frames, rest} = chop(flat, [])
    Enum.each(frames, &send_frame(state, &1))

    %{
      state
      | buf: [rest],
        buf_bytes: byte_size(rest),
        frames_sent: state.frames_sent + length(frames)
    }
  end

  defp drain_frames(state), do: state

  defp chop(bin, acc) when byte_size(bin) >= @frame_size do
    <<frame::binary-size(@frame_size), rest::binary>> = bin
    chop(rest, [frame | acc])
  end

  defp chop(bin, acc), do: {Enum.reverse(acc), bin}

  defp send_frame(state, frame) do
    send(
      state.subscriber,
      {:camera_frame,
       %{
         format: :nv12,
         width: @width,
         height: @height,
         camera: state.camera,
         data: frame
       }}
    )
  end

  defp build_extras(opts) do
    Enum.flat_map(opts, fn
      {:exposure, n} when is_integer(n) -> ["--exposure", to_string(n)]
      {:gain, n} when is_integer(n) -> ["--gain", to_string(n)]
      {:saturation, f} -> ["--saturation", to_string(f)]
      {:gamma, f} -> ["--gamma", to_string(f)]
      {:contrast, f} -> ["--contrast", to_string(f)]
      {:brightness, f} -> ["--brightness", to_string(f)]
      {:wb, {r, g, b}} -> ["--wb", to_string(r), to_string(g), to_string(b)]
      {:no_autofocus, true} -> ["--no-autofocus"]
      _ -> []
    end)
  end
end
