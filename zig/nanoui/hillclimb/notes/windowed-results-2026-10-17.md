# nanoui vs mygo

Medians of 3 runs, release builds, on this Mac (Apple M3 Ultra, macOS 27.0). mygo at `a83f75f`.

| | nanoui | mygo |
|---|---:|---:|
| binary size (KB) | 707 | 11766 |

### idle

| | nanoui | mygo |
|---|---:|---:|
| time to first frame (ms) | 412.7 | 390.7 |
| physical footprint (MB) | 57.0 | 42.0 |
| CPU (% of a core) | 0.00 | 0.25 |
| GPU busy (ms per s) | 0.00 | 0.00 |

### boxes

| | nanoui | mygo |
|---|---:|---:|
| time to first frame (ms) | 406.7 | 384.4 |
| physical footprint (MB) | 453.0 | 493.0 |
| frames per second | 78.0 | 80.8 |
| CPU (% of a core) | 4.00 | 9.87 |
| CPU per frame (ms) | 0.51 | 1.23 |
| GPU busy (ms per s) | 58.8 | 184.9 |
| GPU per frame (ms) | 0.75 | 2.15 |

### text

| | nanoui | mygo |
|---|---:|---:|
| time to first frame (ms) | 327.2 | 301.0 |
| physical footprint (MB) | 454.0 | 499.0 |
| frames per second | 78.8 | 80.4 |
| CPU (% of a core) | 10.7 | 11.6 |
| CPU per frame (ms) | 1.36 | 1.69 |
| GPU busy (ms per s) | 55.6 | 58.7 |
| GPU per frame (ms) | 0.61 | 0.73 |

### ipc

| | nanoui | mygo |
|---|---:|---:|
| 5000 sequential calls (ms) | 493.0 | 528.0 |
| 1000 parallel calls (ms) | 6.00 | 8.00 |
| one 1 MB reply (ms) | 2.00 | 1.00 |
