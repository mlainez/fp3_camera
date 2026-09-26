defmodule Fp3Camera.MiscTest do
  use ExUnit.Case, async: false

  alias Fp3Camera.{AutoExposure, Diagnostics}

  describe "Diagnostics.jpeg_size/1" do
    test "reads SOF0 past other segments" do
      app0 = <<0xFF, 0xE0, 16::16, 0::size(14 * 8)>>
      sof0 = <<0xFF, 0xC0, 17::16, 8, 3024::16, 4032::16, 0::size(12 * 8)>>

      assert Diagnostics.jpeg_size(<<0xFF, 0xD8>> <> app0 <> sof0 <> <<0xFF, 0xD9>>) ==
               {4032, 3024}
    end

    test "not a JPEG, or truncated" do
      assert Diagnostics.jpeg_size("hello") == {0, 0}
      assert Diagnostics.jpeg_size(<<0xFF, 0xD8, 0xFF, 0xE0, 100::16, 1, 2>>) == {0, 0}
    end
  end

  test "Diagnostics.count_nals/1 histograms Annex-B NAL types" do
    nal = fn type -> <<0, 0, 0, 1, type, 0xAA, 0xBB>> end
    data = nal.(0x67) <> nal.(0x68) <> nal.(0x65) <> nal.(0x41) <> nal.(0x41) <> <<0, 0, 1, 0x41>>
    assert Diagnostics.count_nals(data) == %{sps: 1, pps: 1, idr: 1, p: 3}
    assert Diagnostics.count_nals(<<>>) == %{sps: 0, pps: 0, idr: 0, p: 0}
  end

  test "AutoExposure.rescale/5 scales signal above black and clamps" do
    # (420-64)/(242-64) = 2
    assert AutoExposure.rescale(1000, 242, 420, 100, 4000) == 2000
    assert AutoExposure.rescale(3000, 100, 420, 100, 4000) == 4000
    assert AutoExposure.rescale(1000, 10, 420, 100, 4000) == 4000
    assert AutoExposure.rescale(1000, 4000, 420, 100, 4000) == 100
  end

  describe "on a host without the system binaries" do
    setup do
      old = Application.get_env(:fp3_camera, :binaries)

      Application.put_env(:fp3_camera, :binaries,
        cam_snap: "/nonexistent/cam-snap",
        cam_stream: "/nonexistent/cam-stream",
        fp3_cam_setup: "/nonexistent/fp3-cam-setup"
      )

      on_exit(fn ->
        if old,
          do: Application.put_env(:fp3_camera, :binaries, old),
          else: Application.delete_env(:fp3_camera, :binaries)
      end)
    end

    test "every entry point returns an error and the app stays up" do
      sup = Process.whereis(Fp3Camera.Supervisor)
      err = {:error, {:enoent, "/nonexistent/fp3-cam-setup"}}

      assert Fp3Camera.setup(:rear) == err
      assert Fp3Camera.snap(:rear, "/tmp/x.jpg") == err
      assert Fp3Camera.snap_bytes(:front) == err
      assert Fp3Camera.snap_stats(:rear) == err
      assert Fp3Camera.start_stream(:rear) == err
      assert Fp3Camera.subscribe(:front) == err
      assert Fp3Camera.streams() == []

      assert Process.whereis(Fp3Camera.Supervisor) == sup

      for {_, pid, _, _} <- Supervisor.which_children(Fp3Camera.Supervisor),
          do: assert(is_pid(pid))
    end
  end
end
