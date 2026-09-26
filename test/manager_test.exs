defmodule Fp3Camera.ManagerTest do
  use ExUnit.Case, async: false

  alias Fp3Camera.{FakeSystem, Manager}

  describe "parse_conf/1" do
    test "parses what fp3-cam-setup writes" do
      body = """
      SENSOR='imx363 3-0010'
      VIDEO=/dev/video2
      SUBDEV=/dev/v4l-subdev18
      LENS=/dev/v4l-subdev19
      WIDTH=4032
      HEIGHT=3024
      BAYER=rggb
      """

      assert Manager.parse_conf(body) == %{
               sensor: "imx363 3-0010",
               video: "/dev/video2",
               subdev: "/dev/v4l-subdev18",
               lens: "/dev/v4l-subdev19",
               width: 4032,
               height: 3024,
               bayer: "rggb"
             }
    end

    test "ignores empty values, unknown keys and junk lines" do
      assert Manager.parse_conf("LENS=\nFOO=bar\nnot a line\nWIDTH=abc\nHEIGHT=0\n") == %{}
    end
  end

  test "stream_size/2 mirrors cam-stream's geometry rule for each sensor" do
    # binned sizes from fp3-cam-setup's sensor_profile
    assert Manager.stream_size(2016, 1512) == {1920, 1056}
    assert Manager.stream_size(2000, 1500) == {1920, 1056}
    assert Manager.stream_size(1440, 1080) == {1408, 1056}
    assert Manager.stream_size(2304, 1728) == {1920, 1056}
  end

  test "setup/1 runs fp3-cam-setup natively and info/1 reads the conf" do
    dir = FakeSystem.install()
    assert Manager.info(:rear) == {:error, :not_configured}
    assert Manager.setup(:rear) == :ok
    assert FakeSystem.calls(dir, "fp3-cam-setup") == ["rear"]

    assert {:ok, info} = Manager.info(:rear)
    assert %{sensor: "imx363 3-0010", width: 4032, height: 3024, csiphy: "msm_csiphy0"} = info
    refute Map.has_key?(info, :lens)
  end

  test "setup/1 always runs the script — no stale cache" do
    dir = FakeSystem.install()
    assert :ok = Manager.setup(:rear)
    assert {:ok, _} = Manager.prepare_stream(:rear)
    assert :ok = Manager.setup(:rear)
    assert FakeSystem.calls(dir, "fp3-cam-setup") == ["rear", "--binned rear", "rear"]
    assert {:ok, %{width: 4032}} = Manager.info(:rear)
  end

  test "prepare_stream/1 configures binned and returns the output frame size" do
    FakeSystem.install(binned: {1440, 1080})

    assert {:ok, %{width: 1440, height: 1080, out_width: 1408, out_height: 1056}} =
             Manager.prepare_stream(:front)
  end

  test "failing script returns an error" do
    FakeSystem.install(setup: "echo 'no rear sensor' >&2; exit 1\n")
    assert {:error, {:setup_failed, 1, "no rear sensor"}} = Manager.setup(:rear)
  end

  test "success without a conf is an error" do
    FakeSystem.install(setup: "exit 0\n")
    assert {:error, {:no_conf_written, _}} = Manager.setup(:rear)
  end

  test "missing binary returns {:error, {:enoent, path}}" do
    FakeSystem.install(setup: :missing)
    assert {:error, {:enoent, path}} = Manager.setup(:rear)
    assert path =~ "missing-fp3-cam-setup"
    assert Process.whereis(Manager)
  end

  test "unknown camera" do
    assert Manager.setup(:side) == {:error, {:unknown_camera, :side}}
    assert Manager.info(:side) == {:error, {:unknown_camera, :side}}
  end
end
