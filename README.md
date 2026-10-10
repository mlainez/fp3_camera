# fp3_camera

Stills and live H.264 from the Fairphone 3 and 3+ cameras, on
[nerves_system_fp3](https://github.com/mlainez/nerves_system_fp3).

```elixir
{:ok, path} = Fp3Camera.snap(:rear, "/root/photo.jpg")
{:ok, ref}  = Fp3Camera.start_stream(:rear)
```

Frames come from [libcamera](https://libcamera.org), whose software ISP
turns the sensors' raw Bayer data into RGB, and streams are encoded to
H.264 by the Venus hardware encoder. Each capture is a `gst-launch-1.0`
pipeline run under [MuonTrap](https://hex.pm/packages/muontrap).

## Two phones, four sensors

The camera modules are user-replaceable and the Fairphone 3+ kit fits
different sensors in the same slots, so a phone can carry any mix:

| Slot  | Fairphone 3           | Fairphone 3+           |
| ----- | --------------------- | ---------------------- |
| Rear  | Sony IMX363, 12MP     | Samsung S5KGM1SP, 12MP |
| Front | Samsung S5K4H7YX, 8MP | Samsung S5K3P9SP, 16MP |

`Fp3Camera.info/1` reports the fitted sensor and the frame sizes
libcamera gives it, read from the device tree and from libcamera.

## Capturing

```elixir
Fp3Camera.snap(:rear, "/root/photo.jpg")
Fp3Camera.snap(:rear, "/root/photo.jpg", binned: true, quality: 95)
{:ok, jpeg} = Fp3Camera.snap_bytes(:front, width: 1280)
```

`binned: true` uses the sensor's smaller mode: the same field of view at
a quarter of the pixels, and much faster.

Streams are **raw H.264 over TCP**, not HTTP, so a browser cannot open
them. Rear listens on 8888, front on 8890. Every second starts with a
keyframe, so a viewer can connect at any time.

By default a stream is 1920x1080 at 30 fps and 8 Mbit/s, cropped to 16:9
from the binned sensor mode as Android frames video. Both cameras hold
30 fps. The rear camera also streams 1080p at about 50 fps and 720p at
60 when the light allows a short exposure (`framerate: 60`). While a
stream runs the CPUs are held at their top frequency, as Android does
while its camera records; a 1080p stream at 30 fps keeps about a fifth
to a third of the eight cores busy.

```elixir
{:ok, ref} = Fp3Camera.start_stream(:rear, width: 1280, height: 960, bitrate: 4_000_000)
Fp3Camera.streams()
Fp3Camera.stop_stream(ref)
```

```console
$ ffplay tcp://nerves.local:8888
$ mpv --profile=low-latency tcp://nerves.local:8888
```

`Fp3Camera.subscribe/2` delivers raw NV12 frames to a process instead.

## Settings

Picture settings (`:gamma`, `:contrast`, `:saturation`, `:brightness`,
`:sharpen`, `:awb`, `:wb`, `:exposure`, `:gain`, `:focus`) map onto
libcamera controls; `Fp3Camera.Pipeline` lists them.

Resolution order, later winning:

1. `config :fp3_camera, :defaults, [...]`
2. `config :fp3_camera, :sensor_defaults, %{"s5kgm1sp" => [...]}`
3. runtime `Fp3Camera.configure/2`, persisted with `save_config/0`
4. options passed to the call

```elixir
Fp3Camera.configure({:rear, :snap}, gamma: 2.0, saturation: 1.8)
Fp3Camera.save_config()     # /root/fp3-camera.config, reloaded at boot
Fp3Camera.reset_config()
```

## What this needs from the system

GStreamer with libcamera's `libcamerasrc`, `v4l2h264enc`, `jpegenc`,
`videoconvertscale` and `tcpserversink`, and a kernel whose Venus driver
recovers its firmware when it stops answering.

## Known limits

- The sensors are not calibrated for libcamera yet, so colours are off.
- One capture per camera at a time; a busy camera returns
  `{:error, :busy}`.
- Demosaicing runs on the CPU. Binned modes keep up with the sensor's
  30 fps; full resolution is for stills.
- When the Venus firmware stops answering, the kernel restarts it and the
  stream starts again on its own a few seconds later.

## License

Apache-2.0.
