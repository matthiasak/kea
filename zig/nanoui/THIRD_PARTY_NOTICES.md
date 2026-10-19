# Third-party notices

nanoui's own source code is licensed under the MIT License in
[`LICENSE`](LICENSE). The material below keeps its own copyright and license.

## mygo

nanoui began as a port of the core of [mygo](https://github.com/egoist/mygo)
to Zig, Copyright (c) 2026 MyGo contributors. It keeps mygo's architecture:
the Objective-C runtime called directly, runtime classes for delegates, a
batched outbox with one evaluation per main-loop turn, events held until the
page is ready, a generated typed client, and native UI drawn by the framework.
mygo's MIT license, with its permission and warranty notice, is kept verbatim
in [`third_party/licenses/mygo-MIT.txt`](third_party/licenses/mygo-MIT.txt)
(as of mygo
[`269e2f9`](https://github.com/egoist/mygo/tree/269e2f9aca82b742f67497e467a95f6adb54bf5d)).

Liquid Glass (`src/ui/glass.zig`, `src/ui/glass.metal`, `src/ui/metal_glass.zig`)
is ported from mygo's glass plugin, as of
[`c7361ec`](https://github.com/egoist/mygo/tree/c7361ec842f475ebc0c1c6145912a823b46af220/plugins/glass).
That covers the material measured from AppKit, the lens, the normal, the tone
curve, and the backdrop, averaged and blurred. It's under the same license.

## GPUI

nanoui's native UI follows designs from
[GPUI](https://github.com/zed-industries/zed/tree/main/crates/gpui), part of
Zed, Copyright 2022–2025 Zed Industries, Inc.:
- elements styled by method chains (`src/ui/div.zig`);
- the virtualized `uniform_list` (`src/ui/list.zig`);
- layouts cached across frames, with glyphs rasterized once into an atlas;
- Gaussian shadows (`src/ui/shader.metal`, `src/ui/raster.zig`).

GPUI is licensed under the Apache License 2.0, whose text is kept verbatim in
[`third_party/licenses/GPUI-Apache-2.0.txt`](third_party/licenses/GPUI-Apache-2.0.txt).

## Apps

[nanoterm](https://github.com/justrach/nanoterm) and
[nanomon](https://github.com/justrach/nanomon), under `apps/`, are separate
repositories with their own licenses and notices. Both use CodeGraff's
colors and run graff as a separate program; CodeGraff is distributed under
its modified AGPLv3 terms, as their notices say.
