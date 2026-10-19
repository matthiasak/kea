(function () {
  var seen = 0, limit = 40000;
  var skip = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, IFRAME: 1, FRAME: 1, OBJECT: 1, EMBED: 1,
               INPUT: 1, TEXTAREA: 1, SELECT: 1, OPTION: 1, SVG: 1, CANVAS: 1, VIDEO: 1, AUDIO: 1, HEAD: 1 };
  var width = document.documentElement.scrollWidth, height = document.documentElement.scrollHeight;

  // Whether a person could see this element, and so everything in it.
  function shown(el) {
    if (el.hidden || el.getAttribute('aria-hidden') === 'true' || el.inert) return false;
    var s = getComputedStyle(el);
    if (s.display === 'none' || s.visibility === 'hidden' || s.visibility === 'collapse') return false;
    if (parseFloat(s.opacity) < 0.1 || s.contentVisibility === 'hidden') return false;
    if (parseFloat(s.fontSize) < 6) return false;
    // Clipped away to nothing: the "for screen readers only" trick.
    if ((s.clip && s.clip.indexOf('rect(0') === 0) || /circle\(0/.test(s.clipPath || '')) return false;
    var inset = /inset\((\d+)%/.exec(s.clipPath || '');
    if (inset && +inset[1] >= 50) return false;
    // Faded out by a filter, or its text pushed far off to the side.
    var faded = /opacity\(([\d.]+)(%?)\)/.exec(s.filter || '');
    if (faded && +faded[1] / (faded[2] ? 100 : 1) < 0.1) return false;
    if (parseFloat(s.textIndent) < -500) return false;
    var r = el.getBoundingClientRect();
    if ((r.width < 2 || r.height < 2) && s.overflow !== 'visible') return false;
    if (r.width < 1 && r.height < 1) return false;
    // Pushed off the page to the left or the top, where nobody scrolls.
    var x = r.right + window.scrollX, y = r.bottom + window.scrollY;
    if (x < 0 || y < 0 || r.left + window.scrollX > width + 50) return false;
    return true;
  }

  function prose(el) {
    var paragraphs = el.querySelectorAll('p');
    if (paragraphs.length < 2) return 0;
    var letters = 0;
    for (var i = 0; i < paragraphs.length; i++) letters += (paragraphs[i].textContent || '').length;
    if (letters < 400) return 0;
    return letters / (1 + el.querySelectorAll('a').length * 14);
  }
  function article() {
    var candidates = document.querySelectorAll('article, main, [role="main"], .post, .entry, .article, .content, #content, div, section');
    var top = null, mark = 0;
    for (var i = 0; i < candidates.length && i < 5000; i++) {
      var score = prose(candidates[i]);
      if (score > mark) { mark = score; top = candidates[i]; }
    }
    return top;
  }

  // What is around the words rather than part of them: navigation, the
  // foot of the page, asides, and an encyclopedia's reference lists and
  // boxes of links — which would take the place of the article's end.
  var clutter = 'nav, footer, aside, [role="navigation"], [role="contentinfo"], [role="complementary"], ' +
    '.reflist, .references, .mw-references-wrap, .refbegin, .navbox, .vertical-navbox, .catlinks, #references';

  // Colours, for text written in the colour of what is behind it.
  function rgb(value) {
    var m = /^rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)(?:,\s*([\d.]+))?\)/.exec(value || '');
    return m ? { r: +m[1], g: +m[2], b: +m[3], a: m[4] === undefined ? 1 : +m[4] } : null;
  }
  function light(c) {
    function one(v) { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }
    return 0.2126 * one(c.r) + 0.7152 * one(c.g) + 0.0722 * one(c.b);
  }
  function unreadable(color, behind) {
    var c = rgb(color);
    if (!c || !behind) return false;
    if (c.a < 0.3) return true;
    var a = light(c), b = light(behind);
    return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05) < 1.25;
  }

  var out = [], links = [];
  // `behind`: the colour behind this node, or null where a picture is
  // (text over an image can't be judged by colours alone).
  // `alpha`: how opaque it is through all its parents together.
  function walk(node, behind, alpha) {
    if (seen++ > limit) return;
    if (node.nodeType === 3) {
      var t = node.nodeValue.replace(/\s+/g, ' ');
      var ps = getComputedStyle(node.parentElement);
      var fill = rgb(ps.webkitTextFillColor);
      if (t.trim() && !unreadable(ps.color, behind) && !(fill && fill.a < 0.3)) out.push(t);
      return;
    }
    if (node.nodeType !== 1 || skip[node.tagName.toUpperCase()]) return;
    if (node.tagName === 'BR') { out.push('\n'); return; }
    if (node !== root && node.matches && node.matches(clutter)) return;
    if (!shown(node)) return;
    var s = getComputedStyle(node);
    if (s.backgroundImage && s.backgroundImage !== 'none') behind = null;
    else { var bg = rgb(s.backgroundColor); if (bg && bg.a > 0.5 && behind !== null) behind = bg; }
    var block = !/^inline/.test(s.display);
    if (block) out.push('\n');
    alpha = alpha * (parseFloat(s.opacity) || 0);
    if (alpha < 0.1) return;
    for (var c = node.firstChild; c; c = c.nextSibling) walk(c, behind, alpha);
    if (block) out.push('\n');
  }

  var root = article() || document.body;
  if (!root) return null;
  // The colour behind the article: its own, or the first of its
  // parents' that is painted, or white as a page is.
  var ground = { r: 255, g: 255, b: 255, a: 1 };
  for (var up = root; up && up.nodeType === 1; up = up.parentElement) {
    var painted = rgb(getComputedStyle(up).backgroundColor);
    if (painted && painted.a > 0.5) { ground = painted; break; }
  }
  // Every visible link on the page, the article's or not, for the check
  // on the answer: an address the page shows you is on the page.
  for (var l = 0; l < document.links.length && links.length < 400; l++) {
    var a = document.links[l];
    if (!/^https?:/.test(a.href)) continue;
    var visible = true;
    for (var up = a; up && up.nodeType === 1 && visible; up = up.parentElement) visible = shown(up);
    if (visible) links.push(a.href);
  }
  var heading = document.querySelector('h1');
  walk(root, ground, 1);
  var text = out.join('').replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
  return { title: document.title || (heading && heading.textContent.trim()) || '', text: text, links: links };
})();