defmodule Fp3Camera.AutoExposure do
  @moduledoc """
  Metering for stills, done in Elixir on top of `snap_stats/2`.

  Nothing in the capture path sets exposure. `cam-snap` leaves
  `V4L2_CID_EXPOSURE` and `V4L2_CID_ANALOGUE_GAIN` at whatever the sensor
  driver happened to load, and the two parts differ enough that the same
  desk under the same lamp came out at raw G 154 on the FP3's IMX363 and
  102 on the FP3+'s S5KGM1SP — both far below mid-scale, the second
  almost black. Live streams looked fine throughout, which sent the
  investigation the wrong way for a while: `cam-stream` runs the sensor
  binned, and 2x2 binning is two stops of extra light.

  So: meter before capturing. Take a frame, read the raw green mean that
  `cam-snap` already reports, and move exposure — then gain, which is
  noisier — until the frame sits near `@target`.

  The limits below are measured on both phones rather than read off a
  datasheet, by sweeping each control and watching the raw mean:

      exposure  100  400 1000 2000 4000 8000
      FP3        80   92  123  178  241  242     <- flat after 4000
      FP3+        0   81   91  113  137  137

      gain (at exposure 4000)  0   64  128  256  512
      FP3                     246  271  305  419  415
      FP3+                    137  198  310  465  379   <- *drops* at 512

  Both controls clamp at those points, and gain 512 reads lower than 256
  on both, so the search stays inside the range the hardware honours.
  """

  require Logger

  alias Fp3Camera.Capture

  # Raw 10-bit green mean to aim for. Black level is 64, so this sits a
  # little under half scale — bright enough that a white desk renders
  # white, with headroom before the highlights clip.
  @target 420

  # Measured ceilings; see the sweeps above.
  @exposure_min 100
  @exposure_max 4_000
  @gain_max 256
  @black_level 64

  # Within this fraction of target, stop. Chasing closer costs another
  # full capture for a difference nobody can see.
  @tolerance 0.18

  @doc """
  Find exposure and gain for `camera` under the current light.

  Returns `{:ok, [exposure: e, gain: g]}`, ready to splice into a
  `snap/3` call. Costs a few captures, so hold on to the result while
  the light is unchanged rather than metering per frame.
  """
  def meter(camera, opts \\ []) do
    target = Keyword.get(opts, :target, @target)
    path = Keyword.get(opts, :path, "/tmp/fp3-meter.jpg")
    base = Keyword.drop(opts, [:target, :path, :exposure, :gain])

    with {:ok, exposure} <- converge_exposure(camera, target, path, base),
         {:ok, gain} <- converge_gain(camera, target, exposure, path, base) do
      {:ok, [exposure: exposure, gain: gain]}
    end
  end

  # Exposure first: it is free of noise, unlike gain.
  defp converge_exposure(camera, target, path, base) do
    Enum.reduce_while(1..3, {:ok, 1_000}, fn _step, {:ok, exposure} ->
      case measure(camera, [exposure: exposure, gain: 0] ++ base, path) do
        {:ok, level} ->
          if within?(level, target) or exposure >= @exposure_max do
            {:halt, {:ok, exposure}}
          else
            {:cont, {:ok, rescale(exposure, level, target, @exposure_min, @exposure_max)}}
          end

        err ->
          {:halt, err}
      end
    end)
  end

  # Then gain, only for what exposure could not reach.
  defp converge_gain(camera, target, exposure, path, base) do
    Enum.reduce_while(1..3, {:ok, 0}, fn _step, {:ok, gain} ->
      case measure(camera, [exposure: exposure, gain: gain] ++ base, path) do
        {:ok, level} ->
          if within?(level, target) or gain >= @gain_max do
            {:halt, {:ok, gain}}
          else
            # Gain is a multiplier on an already-exposed frame, so scale
            # it from wherever it is rather than from zero — and give it
            # a floor, since scaling 0 by anything is still 0.
            headroom = (target - @black_level) / max(level - @black_level, 1)
            next = max(gain, 64) * headroom
            {:cont, {:ok, next |> round() |> min(@gain_max) |> max(0)}}
          end

        err ->
          {:halt, err}
      end
    end)
  end

  defp measure(camera, opts, path) do
    case Capture.snap_stats(camera, Keyword.put(opts, :path, path)) do
      {:ok, %{raw: %{g: g}}} -> {:ok, g}
      {:ok, _} -> {:error, :no_statistics}
      err -> err
    end
  end

  defp within?(level, target), do: abs(level - target) / target <= @tolerance

  # Signal above black scales with exposure; the pedestal does not, so
  # take it off before taking the ratio. Skipping that step is what made
  # the gray-world white balance under-correct for so long.
  defp rescale(current, level, target, lo, hi) do
    ratio = (target - @black_level) / max(level - @black_level, 1)

    (current * ratio)
    |> round()
    |> min(hi)
    |> max(lo)
  end
end
