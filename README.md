# fp3_camera

Stills and live H.264 from the Fairphone 3 and 3+ cameras, on
[nerves_system_fp3](https://github.com/mlainez/nerves_system_fp3).

```elixir
{:ok, path} = Fp3Camera.snap(:rear, "/root/photo.jpg")
{:ok, ref}  = Fp3Camera.start_stream(:rear)
```

Both calls configure the CAMSS media graph, pick settings for whichever
camera module is actually fitted, and capture. There is nothing to set
up first.

## Two phones, four sensors, one call

The camera modules are user-replaceable and the Fairphone 3+ kit fits
different silicon in the same slots, so a phone can carry any mix:

| Slot  | Fairphone 3        | Fairphone 3+        |
| ----- | ------------------ | ------------------- |
| Rear  | Sony IMX363, 12MP  | Samsung S5KGM1SP, 48MP |
| Front | Samsung S5K4H7YX, 8MP | Samsung S5K3P9SP, 16MP |

Nothing here is indexed by phone model or by slot. `fp3-cam-setup` walks
the media graph, and everything downstream — geometry, Bayer order,
device nodes, white balance — follows the part it finds. Device numbering
is looked up too: CAMSS registers its video nodes alongside Venus and the
numbers move between phones and between boots.

## Capturing

```elixir
Fp3Camera.snap(:rear, "/root/photo.jpg")
Fp3Camera.snap(:rear, "/root/photo.jpg", focus: :auto, quality: 95)
{:ok, jpeg} = Fp3Camera.snap_bytes(:front)
```

Streams are **raw H.264 over TCP** — not HTTP, so a browser cannot open
them. Rear listens on 8888, front on 8890 (each stream also uses the next
port up for its control socket):

```elixir
{:ok, ref} = Fp3Camera.start_stream(:rear)
Fp3Camera.streams()
Fp3Camera.stop_stream(ref)
```

```console
$ ffplay tcp://nerves.local:8888
$ mpv --profile=low-latency tcp://nerves.local:8888
$ vlc --demux=h264 tcp://nerves.local:8888
```

A running stream can be adjusted without restarting it:

```elixir
Fp3Camera.tune(ref, wb: {1.9, 1.0, 1.5}, focus: 700, saturation: 1.6)
```

## Settings

Defaults are compiled into `Fp3Camera.Config`, keyed by fitted sensor
*and* by mode. Both halves matter. `cam-snap` demosaics with
Malvar-He-Cutler at full resolution while `cam-stream` runs a cheaper
bilinear pass over a 2x2-binned frame, and gains that render a still
neutral leave the stream visibly green on the same sensor.

Resolution order, later winning:

1. the built-in table, by sensor and mode
2. `config :fp3_camera, :defaults, [...]`
3. `config :fp3_camera, :sensor_defaults, %{"imx363" => [...]}`
4. runtime `Fp3Camera.configure/2`, persisted with `save_config/0`
5. options passed to the call

So calibrating is a session in IEx, not a rebuild:

```elixir
Fp3Camera.configure({:rear, :stream}, wb: {1.9, 1.0, 1.53})
Fp3Camera.save_config()     # /root/fp3-camera.config, reloaded at boot
Fp3Camera.config()
Fp3Camera.reset_config()
```

`snap_stats/2` reports what the sensor measured and what the pipeline
applied, so white balance can be closed as a loop on the device:

```elixir
{:ok, s} = Fp3Camera.snap_stats(:rear)
s.raw     #=> %{bayer: "rggb", r: 114.6, g: 174.0, b: 139.8}
s.gains   #=> %{r: 2.1, g: 1.0, b: 1.5}
Fp3Camera.snap_stats(:rear, wb: {s.raw.g / s.raw.r, 1.0, s.raw.g / s.raw.b})
```

`snap_stats/2` deliberately ignores the config table — it is the
measurement the table is derived from.

### Options

Sensor: `:exposure` (`:auto` meters first), `:gain`, `:focus`
(`:auto`, or a 0..1023 VCM value, 0 = infinity — **rear only**, the front
modules are fixed-focus), `:width`, `:height`.

White balance: `:awb` (gray-world from the frame), `:wb` as `{r, g, b}`
explicit gains, `:warm_bias`.

Tone and detail: `:gamma`, `:contrast`, `:saturation`, `:brightness`,
`:sharpen`, `:denoise`, `:lsc`, `:auto_levels`, `:phone_curve`, `:ccm`,
`:frames`, `:quality`.

Streams also take `:bitrate`, `:fps`, `:port`. `:args` passes a list
through verbatim for anything newer than this documentation.

## Auto-exposure

Nothing in the capture path used to set exposure, and the two rear parts
differ enough that one desk under one lamp came out at raw green 154 on
the IMX363 and 102 on the S5KGM1SP — both well under mid-scale.
`Fp3Camera.AutoExposure` meters through `snap_stats/2`: take a frame,
read the raw green mean, move exposure, then add gain for whatever
exposure could not reach. It is the default for stills.

Control limits in it are swept from real hardware, not datasheets — both
sensors clamp at exposure 4000, and analogue gain 512 reads *lower* than
256 on both.

Streams have no metering. They rarely need it: binning is two stops, and
that is why streams looked correctly exposed for a long time while stills
came out dark.

## Checking it works

```elixir
Fp3Camera.selftest()
```

Runs every capability end to end on each fitted camera and judges each on
a byte you can point at — JPEG magic and SOF0 dimensions for stills, a
counted IDR and P-frames pulled off a real socket for streams, a freed
port and an empty process table afterwards, and dmesg diffed for new
venus/camss errors. Nothing passes on an exit code, because counting NAL
units once certified a stream that was in fact shearing into diagonal
noise.

## What this needs from the system

`cam-snap`, `cam-stream`, `cam-grab`, `fp3-cam-setup` and `media-ctl`,
all from `nerves_system_fp3`. The H.264 encoder is Venus; its
`venus-enc`/`venus-dec` modules have no device-tree node and never
autoload, so `fp3-cam-setup` modprobes them.

## Known limits

- Demosaicing is in software. The msm8953 CPP hardware ISP is not driven.
- Colour is close to Android's on all four sensors but not calibrated
  against a known target under known illuminants; the built-in gains come
  from measurements in one scene.
- **The FP3+ front camera is captured binned, at 2304x1728 rather than
  4608x3456.** Its full-resolution mode returns pure sensor noise on this
  board; the binned mode is clean. Verified both ways, repeatedly, and
  consistent with the stream path, which has only ever run binned and has
  never been affected. Full res is roughly four times the MIPI data rate,
  so this most likely lives in the CSIPHY timer or link frequency for
  that one sensor mode. It is a workaround, not a fix — that camera
  yields 4 MP stills instead of 16.
- Streams centre-crop rather than scale, so a stream sees roughly 30% less
  vertical field of view than the still from the same camera.
- Venus wants its NV12 input width a multiple of 128; `cam-stream`
  refuses to start rather than emit a sheared picture if the driver pads
  the buffer.

## License

Apache-2.0.
