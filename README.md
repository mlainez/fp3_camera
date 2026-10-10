# fp3_camera

Stills and live H.264 from the Fairphone 3 and 3+ cameras, on
[nerves_system_fp3](https://github.com/mlainez/nerves_system_fp3).

```elixir
{:ok, path} = Fp3Camera.snap(:rear, "/root/photo.jpg")
{:ok, ref}  = Fp3Camera.start_stream(:rear)
```

Frames come from [libcamera](https://libcamera.org) through its camss
pipeline handler: the camera ISP debayers, white balances, colour and
gamma corrects, scales and crops each frame in hardware and hands out
NV12. Streams are encoded to H.264 by the Venus hardware encoder. Each
capture is a `gst-launch-1.0` pipeline run under
[MuonTrap](https://hex.pm/packages/muontrap), so any GStreamer, V4L2 or
libcamera tool, Membrane or Evision can use the cameras the same way.

## Two phones, four sensors

The camera modules are user-replaceable and the Fairphone 3+ kit fits
different sensors in the same slots, so a phone can carry any mix:

| Slot  | Fairphone 3           | Fairphone 3+           |
| ----- | --------------------- | ---------------------- |
| Rear  | Sony IMX363, 12MP     | Samsung S5KGM1SP, 12MP |
| Front | Samsung S5K4H7YX, 8MP | Samsung S5K3P9SP, 16MP |

`Fp3Camera.info/1` reports the fitted sensor and the sizes it gives,
read from the device tree and the sensor's V4L2 subdevice.

## Sizes and frame rates

An output is at most the camera's largest mode and at least a sixteenth
of it each way, the ISP's largest downscale. Its width is a multiple of
16 and its height even. Anything else is refused with
`{:error, {:unsupported_size, size, reason}}`. The sensor runs the
smallest mode that covers the output, and the ISP scales it down and
crops it to the output's aspect ratio, as Android frames video.

| Sensor   | Largest output | Modes the ISP takes          | Frame rate |
| -------- | -------------- | ---------------------------- | ---------- |
| S5KGM1SP | 4000x3000      | 2000x1500, 4000x3000         | 60, 30     |
| S5K3P9SP | 2304x1728      | 2304x1728                    | 30         |
| IMX363   | 4032x3024      | 1920x1080, 2016x1512, 4032x3024 | 30      |
| S5K4H7YX | 3264x2448      | 752x564, 816x612, 1440x1080, 3264x2448 | 30 |

The ISP takes sensor lines of at most 4288 pixels, so the front
S5K3P9SP's full 4608x3456 mode is out of reach. A frame rate the mode
cannot run is refused with `{:error, {:unsupported_framerate, ...}}`.

## Capturing

```elixir
Fp3Camera.snap(:rear, "/root/photo.jpg")
Fp3Camera.snap(:rear, "/root/photo.jpg", binned: true, quality: 95)
{:ok, jpeg} = Fp3Camera.snap_bytes(:front, width: 1280)
```

`binned: true` uses the sensor's smaller mode: the same field of view at
a quarter of the pixels. A still takes about 0.9 s binned and 1.2 s at
12MP from a cold start, most of it the sensor starting up and auto
exposure settling.

Streams are **raw H.264 over TCP**, not HTTP, so a browser cannot open
them. Rear listens on 8888, front on 8890. Every second starts with a
keyframe, so a viewer can connect at any time.

By default a stream is 1920x1080 at 30 fps and 8 Mbit/s. Both cameras
hold 30 fps; the rear one also streams 1080p at 60 fps
(`framerate: 60`) and 3840x2160 at 30 fps. The sensor runs at the
stream's frame rate, which also bounds the exposure time.

Venus encodes the camera's buffers in place when the width is a multiple
of 128 and the sensor mode has lines to spare below the frame, as for
1280x720, 1920x1080 and 3840x2160. A 1080p or 4K stream at 30 fps then
keeps about 6% of the eight cores busy, 1080p at 60 fps about 8%. Other
sizes are copied into the encoder, which costs about twice that.

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

Exposure, gain, white balance and focus (`:exposure`, `:gain`, `:awb`,
`:wb`, `:focus`) map onto libcamera controls, each automatic or manual
on its own; `Fp3Camera.Pipeline` lists them. The ISP's tone curve is
fixed to sRGB, so `:gamma`, `:contrast`, `:saturation`, `:brightness`
and `:sharpen` are accepted and not applied yet.

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

nerves_system_fp3 with libcamera's camss pipeline handler and IPA, and
GStreamer with `libcamerasrc`, `v4l2h264enc`, `jpegenc` and
`tcpserversink`. The kernel needs the camss Bayer pixel path and a Venus
driver that recovers its firmware when it stops answering.

## Known limits

- One capture per camera at a time; a busy camera returns
  `{:error, :busy}`.
- No autofocus yet: `focus: :auto` leaves the lens where it is.
- Exposure and white balance are measured on the output frames, not by
  the ISP's statistics block.
- When the Venus firmware stops answering, the kernel restarts it and the
  stream starts again on its own a few seconds later.

## License

Apache-2.0.
