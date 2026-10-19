//go:build darwin && nanoui_hillclimb

// Copied into mygo's ui package by nanoui's hill-climb tool (tag
// nanoui_hillclimb). It runs the scenes of hillclimb/src/scenes.zig through
// mygo's own frames, without a window: the view builds, lays out and
// paints into a scene as in a window, then mygo's Metal renderer draws the
// scene into a texture. Nothing shows on screen.
package ui

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"slices"
	"strconv"
	"syscall"
	"testing"
	"time"

	"github.com/egoist/mygo/internal/gpu/metal"
	"github.com/egoist/mygo/internal/scene"
)

// hcHost is the headless host, keeping each frame's scene instead of
// rasterizing it on the CPU.
type hcHost struct {
	*headless
	scene *scene.Scene
}

func (h *hcHost) present(s *scene.Scene) { h.scene = s }

var (
	hcTime  float32
	hcFrame int
)

func hcView(name string) func(c *Context) {
	switch name {
	case "boxes":
		return hcBoxes
	case "text":
		return hcText
	case "scroll":
		return hcScroll
	case "list":
		return hcList
	default:
		return hcDashboard
	}
}

func hcBoxes(c *Context) {
	t := hcTime
	Column(c).Fill().Padding(10).Gap(4).Children(func() {
		for r := 0; r < 20; r++ {
			Row(c).Gap(4).Children(func() {
				for col := 0; col < 30; col++ {
					i := float32(r*30 + col)
					Box(c).Size(24, 24).Radius(6).Background(hcHSL(float32(math.Mod(float64(t*60+i*3), 360)))).
						Shadow(0, 2, 4, 0, RGBA(0, 0, 0, 0.2)).
						Translate(0, 6*float32(math.Sin(float64(t*3+i*0.1))))
				}
			})
		}
	})
}

func hcText(c *Context) {
	Column(c).Fill().Padding(10).Gap(6).Children(func() {
		for r := 0; r < 15; r++ {
			Row(c).Gap(4).Children(func() {
				for col := 0; col < 20; col++ {
					i := r*20 + col
					Box(c).Width(40).Children(func() {
						Text(c, strconv.Itoa((hcFrame*7+i*13)%10000)).FontSize(13)
					})
				}
			})
		}
	})
}

func hcScroll(c *Context) {
	const rowH, rows = 28, 1000
	offset := float32(math.Mod(float64(hcTime*600), rowH*rows-640))
	Box(c).Fill().Clip().Children(func() {
		Column(c).Translate(0, -offset).Children(func() {
			for i := 0; i < rows; i++ {
				Row(c).Height(rowH).Padding(0, 12).Gap(8).Children(func() {
					Text(c, "Row "+strconv.Itoa(i)+" — a line of a long list").FontSize(13)
					Spacer(c)
					Text(c, strconv.Itoa(i*7%100)).FontSize(12)
				})
			}
		})
	})
}

var hcListState ListState

// hcList is a virtual list of 100 000 rows, scrolled to another row each frame.
func hcList(c *Context) {
	const rows = 100_000
	hcListState.ScrollTo((hcFrame*3)%(rows-40), Start)
	List(c, &hcListState, rows, func(i int) {
		Row(c).Height(28).Padding(0, 12).Gap(8).Children(func() {
			Text(c, "Row "+strconv.Itoa(i)+" — a line of a long list").FontSize(13)
			Spacer(c)
			Text(c, strconv.Itoa(i*7%100)).FontSize(12)
		})
	}).Fill()
}

func hcDashboard(c *Context) {
	t := hcTime
	Column(c).Fill().Padding(16).Gap(12).Children(func() {
		for r := 0; r < 3; r++ {
			Row(c).Gap(12).Children(func() {
				for col := 0; col < 4; col++ {
					i := r*4 + col
					v := 0.5 + 0.5*float32(math.Sin(float64(t*2+float32(i))))
					Column(c).Width(200).Padding(14).Gap(8).Radius(12).Background(RGB(255, 255, 255)).
						Shadow(0, 4, 16, 0, RGBA(0, 0, 0, 0.12)).Children(func() {
						Text(c, "Metric "+strconv.Itoa(i)).FontSize(13)
						Text(c, strconv.Itoa(int(v*1000))).FontSize(28).Bold()
						Box(c).Size(172, 6).Radius(3).Background(RGB(224, 224, 229)).Children(func() {
							Box(c).Size(172*v, 6).Radius(3).Background(RGB(10, 132, 255))
						})
						Text(c, "updated "+strconv.Itoa(hcFrame%60)+"s ago").FontSize(11)
					})
				}
			})
		}
	})
}

func hcHSL(h float32) Color {
	s, l := float32(0.7), float32(0.55)
	f := func(n float32) uint8 {
		k := float32(math.Mod(float64(n+h/30), 12))
		a := s * min(l, 1-l)
		return uint8(255 * (l - a*max(-1, min(min(k-3, 9-k), 1))))
	}
	return RGB(f(0), f(8), f(4))
}

func cpuNow() time.Duration {
	var ru syscall.Rusage
	syscall.Getrusage(syscall.RUSAGE_SELF, &ru)
	return time.Duration(ru.Utime.Nano() + ru.Stime.Nano())
}

func median(xs []float64) float64 {
	s := slices.Clone(xs)
	slices.Sort(s)
	return s[len(s)/2]
}

func p95(xs []float64) float64 {
	s := slices.Clone(xs)
	slices.Sort(s)
	return s[len(s)*95/100]
}

func TestNanouiHillclimb(t *testing.T) {
	name := os.Getenv("HILLCLIMB_SCENE")
	frames, _ := strconv.Atoi(os.Getenv("HILLCLIMB_FRAMES"))
	if frames <= 0 {
		frames = 300
	}
	const w, h, scale = 900, 640, 2
	host := &hcHost{headless: &headless{w: w, h: h, scale: scale}}
	now := time.Unix(0, 0)
	rt := newRuntime(func(c *context) { hcView(name)(makeContext(c)) }, host)
	rt.clock = func() time.Time { return now }
	host.clock = rt.clock
	off, err := metal.NewOffscreen(w*scale, h*scale)
	if err != nil {
		t.Skip("no Metal:", err)
	}
	defer off.Release()
	var frameMs, encodeMs, gpuMs []float64
	var cpu0 time.Duration
	const warmup = 30
	for i := 0; i < warmup+frames; i++ {
		if i == warmup {
			cpu0 = cpuNow()
		}
		hcFrame = i
		hcTime = float32(i) / 120
		now = time.Unix(0, 0).Add(time.Duration(i) * time.Second / 120)
		t0 := time.Now()
		rt.runFrame()
		ft := time.Since(t0)
		enc, gpu, err := off.Frame(host.scene)
		if err != nil {
			t.Fatal(err)
		}
		if i >= warmup {
			frameMs = append(frameMs, float64(ft.Microseconds())/1000)
			encodeMs = append(encodeMs, float64(enc.Microseconds())/1000)
			gpuMs = append(gpuMs, float64(gpu.Microseconds())/1000)
		}
	}
	cpu := cpuNow() - cpu0
	out, _ := json.Marshal(map[string]any{
		"fw": "mygo", "scene": name, "frames": frames,
		"frame_ms": median(frameMs), "frame_p95": p95(frameMs),
		"encode_ms": median(encodeMs), "gpu_ms": median(gpuMs),
		"cpu_ms": float64(cpu.Microseconds()) / 1000 / float64(frames),
		"ops": len(host.scene.Ops),
	})
	fmt.Println("HILLCLIMB " + string(out))
}
