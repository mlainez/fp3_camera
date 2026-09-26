defmodule Fp3Camera.CaptureTest do
  use ExUnit.Case, async: false

  alias Fp3Camera.{Capture, Config, FakeSystem}

  setup do
    Config.reset()
    :ok
  end

  describe "snap_args/3" do
    test "maps options to cam-snap flags and drops unknown ones" do
      args =
        Capture.snap_args(:rear, "/tmp/x.jpg",
          focus: :auto,
          quality: 95,
          exposure: 1000,
          gain: 64,
          brightness: 1.2,
          wb: {2.0, 1.0, 1.5},
          awb: false,
          binned: true,
          bayer: :rggb,
          sharpen: 0.5,
          auto_levels: {2, 250},
          mhc: false,
          denoise: 0,
          frames: 3,
          width: 1280,
          height: 960,
          bogus: 1,
          args: ["--ccm"]
        )

      assert args == ~w(--camera rear --out /tmp/x.jpg --autofocus --quality 95 --exposure 1000
                        --gain 64 --exposure-boost 1.2 --wb 2.0 1.0 1.5 --no-awb --binned
                        --bayer rggb --sharpen-amount 0.5 --auto-levels 2 250 --no-mhc
                        --denoise 0 --frames 3 --ccm)
    end

    test "exposure: :auto never reaches the binary" do
      assert Capture.snap_args(:front, "p", exposure: :auto) == ~w(--camera front --out p)
    end
  end

  test "stream_args/3 pairs --listen with --control and passes pipeline flags" do
    assert Capture.stream_args(:front, 8890, bitrate: 2_000_000, fps: 25, focus: 300, port: 1) ==
             ~w(--camera front --listen 8890 --control 8891 --bitrate 2000000 --fps 25 --focus 300)
  end

  test "default ports leave room for each stream's control port" do
    assert Capture.default_port(:rear) == 8888
    assert Capture.default_port(:front) == 8890
  end

  test "port_conflict/2 checks both ports of each stream" do
    streams = %{a: %{port: 8888}}
    assert Capture.port_conflict(streams, 8888) == 8888
    assert Capture.port_conflict(streams, 8887) == 8888
    assert Capture.port_conflict(streams, 8889) == 8889
    assert Capture.port_conflict(streams, 8890) == nil
    assert Capture.port_conflict(%{}, 8888) == nil
  end

  test "parse_snap_stats/1" do
    out = """
    cam-snap: sensor imx363 3-0010
    with bayer=rggb: R=113.6 G=146 B=114.1 (G/R=1.29 G/B=1.28)
    wb gains: R=2.100 G=1.000 B=1.500 (warm_bias=1.05, lsc=0.40)
    """

    assert %{
             sensor: "imx363 3-0010",
             raw: %{bayer: "rggb", r: 113.6, g: 146.0, b: 114.1},
             gains: %{r: 2.1, g: 1.0, b: 1.5}
           } = Capture.parse_snap_stats(out)

    assert %{sensor: nil, raw: nil, gains: nil} = Capture.parse_snap_stats("garbage")
  end

  test "tune_commands/1" do
    assert Capture.tune_commands(wb: {1.8, 1.0, 1.4}, gamma: 1.6, focus: 700, fps: 3) ==
             ["wb 1.8 1.0 1.4\n", "gamma 1.6\n", "focus 700\n"]
  end

  describe "stills against fake binaries" do
    test "snap/3 meters, then captures with the metered exposure" do
      dir = FakeSystem.install()
      path = Path.join(dir, "out.jpg")
      assert {:ok, ^path} = Capture.snap(:rear, path)
      assert File.read!(path) == <<0xFF, 0xD8, "fakejpeg">>

      calls = FakeSystem.calls(dir, "cam-snap")
      # two metering captures (exposure, then gain), then the real one
      assert length(calls) == 3
      assert List.last(calls) =~ "--exposure 1000 --gain 0"
    end

    test "snap_bytes/2 returns the JPEG" do
      FakeSystem.install()
      assert {:ok, <<0xFF, 0xD8, _::binary>>} = Capture.snap_bytes(:rear, exposure: 500)
    end

    test "snap_stats/2 returns the measurements" do
      dir = FakeSystem.install()

      assert {:ok, %{raw: %{g: 420.0}, gains: %{r: 2.1}, path: path}} =
               Capture.snap_stats(:rear, path: Path.join(dir, "s.jpg"))

      assert path == Path.join(dir, "s.jpg")
    end

    test "missing cam-snap returns {:error, {:enoent, path}}" do
      FakeSystem.install(cam_snap: :missing)
      assert {:error, {:enoent, _}} = Capture.snap(:rear, "/tmp/never.jpg")
      assert {:error, {:enoent, _}} = Capture.snap_stats(:rear)
    end

    test "cam-snap failure is reported" do
      FakeSystem.install(cam_snap: "echo 'STREAMON: Broken pipe' >&2; exit 1\n")
      assert {:error, {:cam_snap_failed, 1, out}} = Capture.snap(:rear, "/tmp/x.jpg", exposure: 1)
      assert out =~ "Broken pipe"
    end

    test "missing fp3-cam-setup returns an error before cam-snap runs" do
      FakeSystem.install(setup: :missing)
      assert {:error, {:enoent, _}} = Capture.snap(:rear, "/tmp/x.jpg")
    end
  end

  describe "streams against fake binaries" do
    setup do
      on_exit(fn -> Enum.each(Capture.list_streams(), &Capture.stop_stream(&1.ref)) end)
      :ok
    end

    test "start, list, refuse duplicates, tune without a control socket, stop" do
      dir = FakeSystem.install()
      capture = Process.whereis(Capture)
      port = 40_000 + :rand.uniform(10_000)

      assert {:ok, ref} = Capture.start_stream(:rear, port: port, bitrate: 1_000_000)

      assert [%{ref: ^ref, camera: :rear, port: ^port, width: 1920, height: 1056}] =
               Capture.list_streams()

      assert {:error, {:camera_already_streaming, :rear, ^ref}} = Capture.start_stream(:rear)
      assert {:error, {:port_in_use, _}} = Capture.start_stream(:front, port: port + 1)

      # nothing listens on the control port: an error, not a crash
      assert {:error, _} = Capture.tune(ref, gamma: 1.2)
      assert Process.whereis(Capture) == capture

      [call] = FakeSystem.calls(dir, "cam-stream")
      assert call =~ "--camera rear --listen #{port} --control #{port + 1}"
      assert call =~ "--bitrate 1000000"
      # Config's built-in stream white balance for the IMX363
      assert call =~ "--wb 1.9 1.0 1.53"

      [os_pid] = :persistent_term.get({Capture, :os_pids}, [])
      assert :ok = Capture.stop_stream(ref)
      refute File.exists?("/proc/#{os_pid}")
      assert Capture.list_streams() == []
      assert Capture.stop_stream(ref) == {:error, :not_found}
    end

    test "a child that dies at once is reported, not left in the list" do
      FakeSystem.install(cam_stream: "echo 'bind :8888: Address already in use' >&2; exit 1\n")
      assert {:error, {:stream_failed, 1, output}} = Capture.start_stream(:rear)
      assert Enum.any?(output, &(&1 =~ "Address already in use"))
      assert Capture.list_streams() == []
    end

    test "missing cam-stream returns an error and Capture survives" do
      FakeSystem.install(cam_stream: :missing)
      capture = Process.whereis(Capture)
      assert {:error, {:enoent, _}} = Capture.start_stream(:rear)
      assert Process.whereis(Capture) == capture
    end

    test "a restarted Capture reaps the streams its predecessor started" do
      FakeSystem.install()
      old = Process.whereis(Capture)
      assert {:ok, _ref} = Capture.start_stream(:rear, port: 40_000 + :rand.uniform(10_000))
      [os_pid] = :persistent_term.get({Capture, :os_pids}, [])
      assert File.exists?("/proc/#{os_pid}")

      Process.exit(old, :kill)
      new = wait_for_restart(old)
      assert is_pid(new)
      refute File.exists?("/proc/#{os_pid}")
      assert Capture.list_streams() == []
    end

    test "unknown camera" do
      assert Capture.start_stream(:side) == {:error, {:unknown_camera, :side}}
    end
  end

  defp wait_for_restart(old, tries \\ 100) do
    case Process.whereis(Capture) do
      pid when is_pid(pid) and pid != old ->
        # init/1 has finished once the process answers a call
        _ = Capture.list_streams()
        pid

      _ when tries > 0 ->
        Process.sleep(20)
        wait_for_restart(old, tries - 1)

      _ ->
        nil
    end
  end
end
