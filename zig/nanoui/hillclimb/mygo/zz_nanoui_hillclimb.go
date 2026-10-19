//go:build darwin && nanoui_hillclimb

// Copied into mygo's internal/gpu/metal by nanoui's hill-climb tool, built
// only with the nanoui_hillclimb tag: mygo's own code is unchanged. It
// draws scenes into a texture kept across frames, as mygo's
// BenchmarkRenderFillRate does, and times them.
package metal

import (
	"errors"
	"time"

	"github.com/ebitengine/purego"
	"github.com/egoist/mygo/internal/scene"
)

var hcDouble func(obj id, sel uintptr) float64

// Offscreen is a renderer and its target, for timed frames without a window.
type Offscreen struct {
	r   *Renderer
	tex id
}

func NewOffscreen(w, h int) (*Offscreen, error) {
	r, err := newRenderer()
	if err != nil {
		return nil, err
	}
	if hcDouble == nil {
		purego.RegisterFunc(&hcDouble, msgSend)
	}
	o := &Offscreen{r: r}
	pool(func() {
		r.cur = &r.formats[0]
		o.tex = r.newTexture(w, h, pixelFormatBGRA8Unorm, usageRenderTarget|usageShaderRead, nil, 0)
	})
	if o.tex == 0 {
		r.Release()
		return nil, errors.New("metal: cannot create a target")
	}
	return o, nil
}

// Frame encodes s, waits for the GPU, and returns the CPU time encoding
// took and the GPU time of the frame.
func (o *Offscreen) Frame(s *scene.Scene) (encode, gpu time.Duration, err error) {
	pool(func() {
		o.r.waitLast()
		t0 := time.Now()
		cb, e := o.r.encode(s, o.tex)
		if e != nil {
			err = e
			return
		}
		send(cb, "commit")
		encode = time.Since(t0)
		send(cb, "waitUntilCompleted")
		g := hcDouble(cb, uintptr(sel("GPUEndTime"))) - hcDouble(cb, uintptr(sel("GPUStartTime")))
		gpu = time.Duration(g * 1e9)
	})
	return
}

func (o *Offscreen) Release() {
	pool(func() { release(&o.tex) })
	o.r.Release()
}
