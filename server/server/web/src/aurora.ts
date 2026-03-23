/**
 * Flowing iridescent aurora background rendered on <canvas>.
 * Uses animated gradient orbs with hue-shifting for a liquid light effect.
 */

interface Orb {
  x: number; y: number;
  vx: number; vy: number;
  r: number;
  hue: number;
  hueSpeed: number;
  phase: number;
  speed: number;
}

export function startAurora(canvas: HTMLCanvasElement): () => void {
  const ctx = canvas.getContext('2d', { alpha: false })!;
  let w = 0;
  let h = 0;
  let animId = 0;
  let orbs: Orb[] = [];

  function resize() {
    const dpr = Math.min(window.devicePixelRatio, 2);
    const rect = canvas.parentElement!.getBoundingClientRect();
    w = rect.width;
    h = rect.height;
    canvas.width = w * dpr;
    canvas.height = h * dpr;
    canvas.style.width = w + 'px';
    canvas.style.height = h + 'px';
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  function createOrbs() {
    const count = 6;
    orbs = [];
    for (let i = 0; i < count; i++) {
      orbs.push({
        x: Math.random() * w,
        y: Math.random() * h,
        vx: (Math.random() - 0.5) * 0.4,
        vy: (Math.random() - 0.5) * 0.4,
        r: Math.max(w, h) * (0.3 + Math.random() * 0.25),
        hue: (i / count) * 360,
        hueSpeed: 8 + Math.random() * 12, // degrees per second
        phase: Math.random() * Math.PI * 2,
        speed: 0.3 + Math.random() * 0.4,
      });
    }
  }

  function draw(t: number) {
    const seconds = t / 1000;

    // Deep background
    ctx.fillStyle = '#0a0a12';
    ctx.fillRect(0, 0, w, h);

    // Composite orbs with screen blending via globalCompositeOperation
    ctx.globalCompositeOperation = 'screen';

    for (const orb of orbs) {
      // Smooth Lissajous-like movement
      const ox = Math.sin(seconds * orb.speed + orb.phase) * w * 0.25;
      const oy = Math.cos(seconds * orb.speed * 0.7 + orb.phase * 1.3) * h * 0.25;

      const cx = orb.x + ox;
      const cy = orb.y + oy;

      // Shift hue over time
      const hue = (orb.hue + seconds * orb.hueSpeed) % 360;

      const grad = ctx.createRadialGradient(cx, cy, 0, cx, cy, orb.r);
      grad.addColorStop(0, `hsla(${hue}, 85%, 55%, 0.35)`);
      grad.addColorStop(0.4, `hsla(${hue + 30}, 80%, 45%, 0.15)`);
      grad.addColorStop(1, `hsla(${hue + 60}, 70%, 30%, 0)`);

      ctx.fillStyle = grad;
      ctx.fillRect(0, 0, w, h);
    }

    // Reset composite
    ctx.globalCompositeOperation = 'source-over';

    // Subtle vignette
    const vg = ctx.createRadialGradient(w / 2, h / 2, w * 0.2, w / 2, h / 2, w * 0.75);
    vg.addColorStop(0, 'rgba(0,0,0,0)');
    vg.addColorStop(1, 'rgba(0,0,0,0.4)');
    ctx.fillStyle = vg;
    ctx.fillRect(0, 0, w, h);

    animId = requestAnimationFrame(draw);
  }

  resize();
  createOrbs();
  animId = requestAnimationFrame(draw);

  const onResize = () => { resize(); createOrbs(); };
  window.addEventListener('resize', onResize);

  return () => {
    cancelAnimationFrame(animId);
    window.removeEventListener('resize', onResize);
  };
}
