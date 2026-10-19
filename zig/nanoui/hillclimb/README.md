# hillclimb

A terminal app, built on nanoui as a library, that measures nanoui against
[mygo](https://github.com/egoist/mygo) **without opening a window**: each
scene is built, laid out and painted frame after frame, then drawn by the
GPU into an offscreen texture, as a window's frames would be.

```sh
cd hillclimb
zig build run                                  # every scene, nanoui and mygo
zig build run -- --label "what changed"        # name the run in history.jsonl
zig build run -- --scene text,list --only nanoui --frames 600 --repeat 5
```

Each scene runs 30 frames of warm-up, then 300 measured, three times; the
run with the lowest median frame is kept. The table shows, per scene:

| metric | what |
|---|---|
| frame CPU | building the view, layout, paint (median, p95), and nanoui's three phases |
| encode CPU | uploading and encoding the frame for the GPU |
| GPU | the command buffer's GPU time (its timestamps) |
| process CPU / frame | the process's user + system time over the run, per frame |
| draw items | nanoui's instances, mygo's scene operations |

and compares nanoui with mygo (`n / m`), with nanoui's previous run (`Δ
last`) and with its best (`Δ best`). Changes within ±5% are noise.

## Scenes

- **boxes**: 600 rounded, shadowed boxes moving and changing color.
- **text**: 300 labels whose numbers change every frame.
- **scroll**: a plain column of 1000 rows, clipped, moving every frame.
- **list**: a virtualized list of 100 000 rows, scrolled every frame.
- **dashboard**: 12 cards of text, a large number and a progress bar.

## mygo's twin

`mygo/` holds two files the tool copies into a clone of mygo (`.mygo`,
cloned on first run): a test running the same scenes through mygo's own
frames, and a helper exposing mygo's offscreen Metal renderer, both built
only with the `nanoui_hillclimb` tag, so mygo's code is unchanged. Go 1.27
is fetched by `GOTOOLCHAIN=auto` if missing.

## Climbing

Change nanoui, run, keep the change if the numbers climb, label it:
`history.jsonl` records every run. Shadows count GPU time honestly: both
draw Gaussian shadows (nanoui's after GPUI's shader).
