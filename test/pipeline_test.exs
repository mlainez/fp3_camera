defmodule Fp3Camera.PipelineTest do
  use ExUnit.Case, async: true

  alias Fp3Camera.Pipeline

  @rear %{
    id: "rear",
    lens: "dw9800w",
    pixel_array: {8, 8, 7992, 5992},
    sensor: "s5kgm1sp",
    width: 4000,
    height: 3000,
    binned: {2000, 1500},
    modes: [{2000, 1500}, {4000, 3000}]
  }

  @front %{
    id: "front",
    lens: nil,
    pixel_array: {16, 24, 4624, 3456},
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

  describe "stream/3" do
    test "has Venus encode frames in place when the ISP can lay them out for it" do
      for {info, out} <- [
            {@rear, {1920, 1080}},
            {@rear, {3840, 2160}},
            {@front, {2304, 1728}},
            {@front, {1920, 1080}}
          ] do
        assert "output-io-mode=dmabuf-import" in Pipeline.stream(info, out, port: 8888)
        assert List.keymember?(Pipeline.stream_env(info, out, []), "XDG_CONFIG_HOME", 0)
      end
    end

    test "copies frames whose lines Venus pads or whose mode has no lines to spare" do
      for {info, out} <- [{@rear, {1440, 1080}}, {@rear, {2000, 1500}}, {@rear, {3840, 3000}}] do
        refute "output-io-mode=dmabuf-import" in Pipeline.stream(info, out, port: 8888)
        refute List.keymember?(Pipeline.stream_env(info, out, []), "XDG_CONFIG_HOME", 0)
      end
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
  end

  describe "check_settings/4" do
    test "takes the settings the ISP applies and the call's own options" do
      opts = [
        awb: false,
        wb: {2.0, 1.0, 1.6},
        exposure: 20_000,
        gain: 2.0,
        focus: 300,
        quality: 80
      ]

      assert Pipeline.check_settings(@rear, {1920, 1080}, opts, [:quality]) == :ok
    end

    test "refuses settings that do nothing and values out of range" do
      assert {:error, {:bad_setting, :gamma, _}} =
               Pipeline.check_settings(@rear, {1920, 1080}, [gamma: 2.2], [])

      assert {:error, {:bad_setting, :gain, "out of range"}} =
               Pipeline.check_settings(@rear, {1920, 1080}, [gain: 40], [])
    end

    test "refuses focus on a fixed-focus camera" do
      assert {:error, {:bad_setting, :focus, "this camera has a fixed-focus lens"}} =
               Pipeline.check_settings(@front, {1920, 1080}, [focus: 300], [])
    end

    test "holds zoom to what the ISP reaches at the output size" do
      assert Pipeline.max_zoom(@rear, {1920, 1080}) == 2.08
      assert Pipeline.check_settings(@rear, {1920, 1080}, [zoom: 2.0], []) == :ok

      assert {:error, {:bad_setting, :zoom, "at most 1.04x at 3840x2160"}} =
               Pipeline.check_settings(@rear, {3840, 2160}, [zoom: 1.5], [])
    end
  end

  describe "zoom" do
    test "runs the largest mode and crops the middle of the pixel array" do
      args = Pipeline.still(@rear, {1920, 1080}, zoom: 2.0)
      assert "sensor-config=sensor/config,width=4000,height=3000,depth=10" in args
      assert "scaler-crop=<2006,1506,3996,2996>" in args
    end

    test "lists the sizes a camera produces" do
      assert Pipeline.sizes(@front) == [{2304, 1728}, {1920, 1080}, {1280, 720}, {640, 480}]
    end
  end
end
