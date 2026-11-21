export type FlowNode = {
  id: string;
  label: string;
  sub: string;
  x: number;
  y: number;
  color: string;
  live: boolean;
};

export type FlowArc = {
  id: string;
  from: string;
  to: string;
  color: string;
  weight: number;
  born: number;
};

type Point = { x: number; y: number };

function quad(a: Point, c: Point, b: Point, t: number): Point {
  const u = 1 - t;
  return {
    x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
    y: u * u * a.y + 2 * u * t * c.y + t * t * b.y,
  };
}

function control(a: Point, b: Point, lift: number): Point {
  return { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - lift };
}

export function drawStage(
  ctx: CanvasRenderingContext2D,
  width: number,
  height: number,
  nodes: FlowNode[],
  arcs: FlowArc[],
  now: number,
) {
  ctx.clearRect(0, 0, width, height);
  const byId = new Map(nodes.map((node) => [node.id, node]));

  for (const arc of arcs) {
    const from = byId.get(arc.from);
    const to = byId.get(arc.to);
    if (!from || !to) continue;
    const a = { x: from.x * width, y: from.y * height };
    const b = { x: to.x * width, y: to.y * height };
    const lift = 36 + arc.weight * 28;
    const c = control(a, b, lift);
    const age = Math.min(1, (now - arc.born) / 900);
    ctx.save();
    ctx.beginPath();
    ctx.moveTo(a.x, a.y);
    ctx.quadraticCurveTo(c.x, c.y, b.x, b.y);
    ctx.strokeStyle = arc.color;
    ctx.globalAlpha = 0.22 + age * 0.35;
    ctx.lineWidth = 1.5 + arc.weight * 7;
    ctx.shadowColor = arc.color;
    ctx.shadowBlur = 22;
    ctx.stroke();
    ctx.restore();

    const count = 3 + Math.round(arc.weight * 4);
    for (let i = 0; i < count; i += 1) {
      const t = ((now / (1400 + arc.weight * 400) + i / count) % 1) * age;
      const p = quad(a, c, b, t);
      ctx.save();
      ctx.beginPath();
      ctx.arc(p.x, p.y, 2.1 + arc.weight * 1.6, 0, Math.PI * 2);
      ctx.fillStyle = "#f4f8ff";
      ctx.shadowColor = arc.color;
      ctx.shadowBlur = 16;
      ctx.globalAlpha = 0.95;
      ctx.fill();
      ctx.restore();
    }
  }

  for (const node of nodes) {
    const x = node.x * width;
    const y = node.y * height;
    ctx.save();
    ctx.beginPath();
    ctx.arc(x, y, node.live ? 16 : 11, 0, Math.PI * 2);
    ctx.fillStyle = node.color;
    ctx.shadowColor = node.color;
    ctx.shadowBlur = node.live ? 28 : 10;
    ctx.globalAlpha = node.live ? 0.95 : 0.45;
    ctx.fill();
    ctx.restore();

    ctx.save();
    ctx.fillStyle = "#e7eefc";
    ctx.globalAlpha = node.live ? 1 : 0.62;
    ctx.font = "650 13px Outfit, sans-serif";
    ctx.textAlign = "center";
    ctx.fillText(node.label, x, y + 34);
    ctx.font = "380 11px Outfit, sans-serif";
    ctx.fillStyle = "rgba(231,238,252,0.72)";
    ctx.fillText(node.sub, x, y + 50);
    ctx.restore();
  }
}
