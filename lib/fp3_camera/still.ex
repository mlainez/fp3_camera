defmodule Fp3Camera.Still do
  @moduledoc false

  alias Fp3Camera.{Camera, Config, Pipeline, Streams}

  @options [:binned, :width, :height, :quality, :frames, :timeout]

  # The first frames come out dark while auto exposure settles, so a still
  # is the last of `:frames` frames. gst-launch encodes the frames it has
  # time for and writes the JPEGs back to back on stdout.
  def snap_bytes(camera, opts) do
    opts = Config.resolve(camera, :snap, opts)

    with :ok <- Streams.ensure_idle(camera),
         {:ok, info} <- Camera.info(camera),
         size = if(opts[:binned], do: info.binned, else: {info.width, info.height}),
         out = output_size(size, opts),
         :ok <- Pipeline.check_size(info, out),
         :ok <- Pipeline.check_settings(info, out, opts, @options) do
      {jpegs, status} =
        MuonTrap.cmd("gst-launch-1.0", Pipeline.still(info, out, opts),
          env: Pipeline.env(),
          timeout: Keyword.get(opts, :timeout, 60_000)
        )

      case last_jpeg(jpegs) do
        nil -> {:error, {:no_frame, status}}
        jpeg -> {:ok, jpeg}
      end
    end
  end

  def snap(camera, path, opts) do
    with {:ok, jpeg} <- snap_bytes(camera, opts),
         :ok <- File.write(path, jpeg) do
      {:ok, path}
    end
  end

  # One side given keeps the aspect ratio: the width it derives is rounded
  # to the 16 pixels the ISP writes, the height to an even number.
  defp output_size({w, h}, opts) do
    case {opts[:width], opts[:height]} do
      {nil, nil} -> {w, h}
      {ow, nil} -> {ow, even(ow * h / w)}
      {nil, oh} -> {16 * round(oh * w / h / 16), oh}
      {ow, oh} -> {ow, oh}
    end
  end

  defp even(x), do: 2 * round(x / 2)

  # The last complete one: a timeout can cut the final JPEG short.
  defp last_jpeg(data) do
    starts = for {start, _} <- :binary.matches(data, <<0xFF, 0xD8, 0xFF>>), do: start

    starts
    |> Enum.zip(Enum.drop(starts, 1) ++ [byte_size(data)])
    |> Enum.map(fn {from, to} -> binary_part(data, from, to - from) end)
    |> Enum.reverse()
    |> Enum.find(&String.ends_with?(&1, <<0xFF, 0xD9>>))
  end
end
