defmodule Fp3Camera.ConfigTest do
  use ExUnit.Case, async: false

  alias Fp3Camera.{Config, FakeSystem}

  setup do
    Config.reset()

    on_exit(fn ->
      Config.reset()
      Application.delete_env(:fp3_camera, :defaults)
      Application.delete_env(:fp3_camera, :sensor_defaults)
    end)

    dir = FakeSystem.install()
    :ok = Fp3Camera.setup(:rear)
    {:ok, dir: dir}
  end

  test "resolve/3 applies the five layers in order, later winning" do
    assert Config.resolve(:rear, :stream)[:wb] == {1.90, 1.0, 1.53}
    assert Config.resolve(:rear, :snap)[:exposure] == :auto

    Application.put_env(:fp3_camera, :defaults, wb: {2, 1, 2}, gamma: 1.1)
    assert Config.resolve(:rear, :stream)[:wb] == {2, 1, 2}

    Application.put_env(:fp3_camera, :sensor_defaults, %{"imx363" => [wb: {3, 1, 3}]})
    assert Config.resolve(:rear, :stream)[:wb] == {3, 1, 3}

    Config.put(:all, wb: {4, 1, 4})
    assert Config.resolve(:rear, :stream)[:wb] == {4, 1, 4}

    Config.put({:rear, :stream}, wb: {5, 1, 5})
    assert Config.resolve(:rear, :stream)[:wb] == {5, 1, 5}
    # {sensor, mode} scope does not leak into the other mode
    assert Config.resolve(:rear, :snap)[:wb] == {4, 1, 4}

    resolved = Config.resolve(:rear, :stream, wb: {6, 1, 6})
    assert resolved[:wb] == {6, 1, 6}
    assert resolved[:gamma] == 1.1
    assert Keyword.keys(resolved) |> Enum.frequencies() |> Map.values() |> Enum.all?(&(&1 == 1))
  end

  test "put/2 with nil clears a key; reset/1 drops a scope" do
    assert Enum.sort(Config.put({"imx363", :snap}, gamma: 2.0, contrast: 0.3)) ==
             [contrast: 0.3, gamma: 2.0]

    assert Config.put({:rear, :snap}, gamma: nil) == [contrast: 0.3]
    assert Config.get() == %{{"imx363", :snap} => [contrast: 0.3]}
    assert :ok = Config.reset({:rear, :snap})
    assert Config.get() == %{}
  end

  test "camera scope without a detected sensor is an error" do
    assert Config.put({:front, :stream}, gamma: 1.0) == {:error, {:not_configured, :front}}
    # without a sensor only the sensor-independent layers apply
    Config.put(:all, gamma: 1.3)

    assert Enum.sort(Config.resolve(:front, :stream, contrast: 0.2)) == [
             contrast: 0.2,
             gamma: 1.3
           ]
  end

  test "save/1 and load/1 round-trip; a corrupt file is not an error", %{dir: dir} do
    path = Path.join(dir, "cfg")
    Config.put(:all, gamma: 1.7)
    assert :ok = Config.save(path)
    Config.reset()
    assert {:ok, %{all: [gamma: 1.7]}} = Config.load(path)
    assert Config.get() == %{all: [gamma: 1.7]}

    File.write!(path, "garbage")
    assert Config.load(path) == {:ok, %{}}
    assert Config.load(Path.join(dir, "nope")) == {:ok, %{}}
  end
end
