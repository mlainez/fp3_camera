defmodule Fp3Camera.SubscriberTest do
  use ExUnit.Case, async: false

  alias Fp3Camera.{FakeSystem, Subscriber}

  test "chop/2 splits whole frames and keeps the tail" do
    assert Subscriber.chop(<<1, 2, 3, 4, 5, 6, 7, 8, 9, 10>>, 4) ==
             {[<<1, 2, 3, 4>>, <<5, 6, 7, 8>>], <<9, 10>>}

    assert Subscriber.chop(<<1, 2>>, 4) == {[], <<1, 2>>}
  end

  test "frame_size/2 is NV12" do
    assert Subscriber.frame_size(1920, 1056) == 3_041_280
  end

  test "args/2 drops the H.264-only flags" do
    assert Subscriber.args(:rear, bitrate: 1, fps: 2, gain: 3, focus: 10) ==
             ~w(--camera rear --out-nv12 --gain 3 --focus 10)
  end

  test "frames are sliced at the real geometry and stderr never reaches them" do
    # binned 257x65 → cam-stream rule gives 256x64 → 24_576-byte frames
    frame = (256 * 64 * 3) |> div(2)

    dir =
      FakeSystem.install(
        binned: {257, 65},
        cam_stream: """
        echo "cam-stream: bayer=rggb out=256x64" >&2
        head -c #{frame} /dev/zero | tr '\\000' 'A'
        echo "NV12 frames=1 fps=30.0" >&2
        head -c #{frame} /dev/zero | tr '\\000' 'B'
        exec sleep 30
        """
      )

    assert {:ok, pid} = Fp3Camera.subscribe(:rear, bitrate: 5)

    for byte <- [?A, ?B] do
      assert_receive {:camera_frame,
                      %{format: :nv12, width: 256, height: 64, camera: :rear, data: data}},
                     5_000

      assert data == :binary.copy(<<byte>>, frame)
    end

    refute_receive {:camera_frame, _}, 200

    [call] = FakeSystem.calls(dir, "cam-stream")
    assert call =~ "--camera rear --out-nv12"
    refute call =~ "--bitrate"
    assert call =~ "--wb 1.9 1.0 1.53"

    ref = Process.monitor(pid)
    assert :ok = Fp3Camera.unsubscribe(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    assert :ok = Fp3Camera.unsubscribe(pid)
  end

  test "the feed ends when cam-stream exits" do
    FakeSystem.install(cam_stream: "echo 'cap STREAMON: Device busy' >&2; exit 1\n")
    assert {:ok, pid} = Fp3Camera.subscribe(:rear)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
  end

  test "the feed follows the subscriber down" do
    FakeSystem.install(cam_stream: "exec sleep 30\n")
    test = self()

    client =
      spawn(fn ->
        send(test, Fp3Camera.subscribe(:rear))
        Process.sleep(:infinity)
      end)

    assert_receive {:ok, pid}
    ref = Process.monitor(pid)
    Process.exit(client, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
  end

  test "missing cam-stream returns an error" do
    FakeSystem.install(cam_stream: :missing)
    assert {:error, {:enoent, _}} = Fp3Camera.subscribe(:rear)
  end
end
