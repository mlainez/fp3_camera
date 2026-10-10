defmodule Fp3Camera.Still do
  @moduledoc false

  alias Fp3Camera.{Camera, Config, Pipeline, Streams}

  # The first frames come out dark while auto exposure settles, so a still
  # is the last of `:frames` frames. gst-launch encodes the frames it has
  # time for and writes the JPEGs back to back on stdout.
  def snap_bytes(camera, opts) do
    opts = Config.resolve(camera, :snap, opts)

    with :ok <- Streams.ensure_idle(camera),
         {:ok, info} <- Camera.info(camera) do
      size = if opts[:binned], do: info.binned, else: {info.width, info.height}
      out = output_size(size, opts)

      {jpegs, status} =
        MuonTrap.cmd("gst-launch-1.0", Pipeline.still(info, size, out, opts),
          env: Pipeline.env(info, size),
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

  # Only `:width` given keeps the aspect ratio; NV12 and JPEG want even sizes.
  defp output_size({w, h}, opts) do
    case {opts[:width], opts[:height]} do
      {nil, nil} -> {w, h}
      {ow, nil} -> {even(ow), even(ow * h / w)}
      {nil, oh} -> {even(oh * w / h), even(oh)}
      {ow, oh} -> {even(ow), even(oh)}
    end
  end

  defp even(x), do: 2 * div(round(x), 2)

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
