(function (x, y, s, W) {{
  var ox = window.scrollX, oy = window.scrollY;
  var cx = x / s, cy = y / s;
  if (s > 1.05) {{
    return JSON.stringify({{ scale: 1, x: Math.max(0, ox + cx - x), y: Math.max(0, oy + cy - y) }});
  }}
  var el = document.elementFromPoint(cx, cy);
  if (!el) return null;
  // The innermost block wide enough to be a column of something — a
  // paragraph's column, a card, a feed — rather than the whole page's
  // layout, which is what walking up to a wide ancestor finds.
  var vw = W / s, best = null, enough = Math.max(240, vw * 0.2);
  for (var e = el; e && e !== document.documentElement; e = e.parentElement) {{
    var r = e.getBoundingClientRect();
    if (r.width < 80 || r.height < 16) continue;
    var d = getComputedStyle(e).display;
    if (d === 'inline' || d === 'contents') continue;
    if (!best) best = r;
    if (r.width >= enough) {{ best = r; break; }}
  }}
  if (!best) best = el.getBoundingClientRect();
  var pad = 12;
  var target = Math.max(1, Math.min(3, W / (best.width + 2 * pad)));
  if (target < 1.15) target = Math.min(3, s * 2);
  return JSON.stringify({{
    scale: target,
    x: Math.max(0, ox + best.left - pad),
    y: Math.max(0, oy + cy - y / target)
  }});
}})({d}, {d}, {d}, {d})
