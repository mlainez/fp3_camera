defmodule Fp3Camera.PipelineTest do
  use ExUnit.Case, async: true

  alias Fp3Camera.Pipeline

  @rear %{
    sensor: "s5kgm1sp",
    width: 4000,
    height: 3000,
    binned: {2000, 1500},
    modes: [{2000, 1500}, {4000, 3000}]
  }

  @front %{
    sensor: "s5k3p9sp",
    width: 2304,
    height: 1728,
    binned: {2304, 1728},
    modes: [{2304, 1728}]
  }

  describe "check_size/2" do
    test "takes the sizes the ISP writes" do
      for size <- [{4000, 3000}, {3840, 2160}, {1920, 1080}, {1280, 720}, {256, 188}],
          do: assert(Pipeline.check_size(@rear, size) == :ok)

      assert Pipeline.check_size(@front, {2304, 1728}) == :ok
    end

    test "refuses outputs larger than the largest mode" do
      assert {:error, {:unsupported_size, {4608, 3456}, reason}} =
               Pipeline.check_size(@front, {4608, 3456})

      assert reason =~ "2304x1728"
      assert {:error, {:unsupported_size, _, _}} = Pipeline.check_size(@rear, {4096, 2160})
    end

    test "refuses outputs below the ISP's largest downscale" do
      assert {:error, {:unsupported_size, _, reason}} = Pipeline.check_size(@rear, {160, 120})
      assert reason =~ "250x187"
    end

    test "refuses widths off the 16 pixel grid and odd heights" do
      assert {:error, {:unsupported_size, _, reason}} = Pipeline.check_size(@rear, {1992, 1500})
      assert reason =~ "multiple of 16"

      assert {:error, {:unsupported_size, _, "the height must be even"}} =
               Pipeline.check_size(@rear, {1920, 1081})
    end

    test "refuses sizes that are not integers" do
      assert {:error, {:unsupported_size, _, _}} = Pipeline.check_size(@rear, {1920.0, 1080})
    end
  end

  describe "check_framerate/3" do
    test "runs the rear binned mode at 60 and the full one at 30" do
      assert Pipeline.check_framerate(@rear, {1920, 1080}, 60) == :ok

      assert {:error, {:unsupported_framerate, 60, _}} =
               Pipeline.check_framerate(@rear, {3840, 2160}, 60)

      assert Pipeline.check_framerate(@rear, {3840, 2160}, 30) == :ok
    end

    test "holds the front camera to 30" do
      assert Pipeline.check_framerate(@front, {1920, 1080}, 30) == :ok
      assert {:error, _} = Pipeline.check_framerate(@front, {1920, 1080}, 60)
    end

    test "refuses rates that are not positive integers" do
      assert {:error, _} = Pipeline.check_framerate(@rear, {1920, 1080}, 0)
      assert {:error, _} = Pipeline.check_framerate(@rear, {1920, 1080}, 29.97)
    end
  end

  describe "controls/1" do
    test "maps white balance gains relative to green" do
      assert Pipeline.controls(wb: {2.0, 1.0, 1.5}) ==
               ["awb-enable=false", "colour-gains=<2.0000,1.5000>"]
    end

    test "maps the lens position onto dioptres" do
      assert Pipeline.controls(focus: 1023) == ["af-mode=manual", "lens-position=10.0000"]
    end

    test "drops settings the ISP does not apply" do
      assert Pipeline.controls(gamma: 2.2, saturation: 1.5, sharpen: false) == []
    end
  end
end
