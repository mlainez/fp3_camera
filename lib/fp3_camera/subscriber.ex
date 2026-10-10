defmodule Fp3Camera.Subscriber do
  @moduledoc """
  Per-subscription GenServer that runs a gst-launch pipeline writing NV12
  frames to stdout and forwards each frame to a subscriber process as

      {:camera_frame, %{format: :nv12, width: 1280, height: 960,
                        camera: :rear, data: <<1_843_200 bytes>>}}

  Use `Fp3Camera.subscribe/2` / `Fp3Camera.unsubscribe/1` rather than
  starting this directly.

  A subscriber that falls behind misses frames: one is dropped whenever
  the subscriber already has two waiting in its mailbox.

  When the subscriber process exits, the Subscriber follows it down.
  """
  use GenServer, restart: :temporary

  alias Fp3Camera.{Camera, Config, Pipeline, Streams}

  defmodule Sink do
    @moduledoc false
    # Forwards the command's output, as it arrives, to `pid`.
    defstruct [:pid]

    defimpl Collectable do
      def into(sink) do
        {sink,
         fn
           sink, {:cont, data} ->
             send(sink.pid, {:nv12, data})
             sink

           sink, :done ->
             sink

           _sink, :halt ->
             :ok
         end}
      end
    end
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def stop(pid), do: GenServer.stop(pid, :normal)

  @impl true
  def init(opts) do
    camera = Keyword.fetch!(opts, :camera)
    subscriber = Keyword.fetch!(opts, :subscriber)
    opts = Config.resolve(camera, :stream, opts)
    {w, h} = {Keyword.get(opts, :width, 1280), Keyword.get(opts, :height, 960)}

    with {:ok, info} <- Camera.info(camera),
         :ok <- Pipeline.check_size(info, {w, h}),
         :ok <- check_framerate(info, {w, h}, opts[:framerate]),
         :ok <- Streams.claim(camera, self()) do
      Process.flag(:trap_exit, true)
      Process.monitor(subscriber)
      args = Pipeline.frames(info, {w, h}, opts)
      me = self()

      task =
        spawn_link(fn ->
          MuonTrap.cmd("gst-launch-1.0", args,
            into: %Sink{pid: me},
            env: Pipeline.env()
          )
        end)

      {:ok,
       %{
         camera: camera,
         subscriber: subscriber,
         task: task,
         width: w,
         height: h,
         frame_size: div(w * h * 3, 2),
         buffer: <<>>
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info({:nv12, data}, state) do
    {frames, rest} = chop(state.buffer <> data, state.frame_size, [])
    Enum.each(frames, &deliver(state, &1))
    {:noreply, %{state | buffer: rest}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{subscriber: pid} = state),
    do: {:stop, :normal, state}

  # The pipeline ended: the camera failed or was taken away.
  def handle_info({:EXIT, pid, _reason}, %{task: pid} = state), do: {:stop, :normal, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # Killing the task closes MuonTrap's port, which stops gst-launch.
  @impl true
  def terminate(_reason, state), do: Process.exit(state.task, :kill)

  # Without a frame rate the camera runs at its default
  defp check_framerate(_info, _out, nil), do: :ok
  defp check_framerate(info, out, fps), do: Pipeline.check_framerate(info, out, fps)

  defp chop(bin, size, acc) when byte_size(bin) >= size do
    <<frame::binary-size(^size), rest::binary>> = bin
    chop(rest, size, [frame | acc])
  end

  defp chop(bin, _size, acc), do: {Enum.reverse(acc), bin}

  defp deliver(state, frame) do
    case Process.info(state.subscriber, :message_queue_len) do
      {:message_queue_len, n} when n < 2 ->
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

      _ ->
        :dropped
    end
  end
end
