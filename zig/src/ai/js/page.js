(function () {
  var seen = 0, limit = 150000;
  var skip = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, OBJECT: 1, EMBED: 1, VIDEO: 1, AUDIO: 1, HEAD: 1 };

  // Whether a person could see this element, and so everything in it.
  function shown(el) {
    if (el.hidden || el.getAttribute('aria-hidden') === 'true' || el.inert) return false;
    var s = getComputedStyle(el);
    if (s.display === 'none' || s.visibility === 'hidden' || s.visibility === 'collapse') return false;
    if (parseFloat(s.opacity) < 0.05 || s.contentVisibility === 'hidden') return false;
    if (parseFloat(s.fontSize) < 4) return false;
    // Clipped away to nothing: the "for screen readers only" trick.
    if ((s.clip && s.clip.indexOf('rect(0') === 0) || /circle\(0/.test(s.clipPath || '')) return false;
    var inset = /inset\((\d+)%/.exec(s.clipPath || '');
    if (inset && +inset[1] >= 50) return false;
    // Faded out by a filter, or its text pushed far off to the side.
    var faded = /opacity\(([\d.]+)(%?)\)/.exec(s.filter || '');
    if (faded && +faded[1] / (faded[2] ? 100 : 1) < 0.05) return false;
    if (parseFloat(s.textIndent) < -500) return false;
    var r = el.getBoundingClientRect();
    var tag = (el.tagName || '').toUpperCase();
    if (r.width < 1 && r.height < 1 && s.overflow !== 'visible' && tag !== 'TR' && tag !== 'CONTENTS' && s.display !== 'contents') return false;
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
    if (!c) return false;
    if (c.a < 0.15) return true;
    if (!behind) return false;
    var a = light(c), b = light(behind);
    return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05) < 1.25;
  }

  var out = [], links = [], root = null;
  function walk(node, behind, alpha) {
    if (seen++ > limit) return;
    if (node.nodeType === 3) {
      var t = node.nodeValue.replace(/\s+/g, ' ');
      var pe = node.parentElement;
      if (!pe) { if (t.trim()) out.push(t); return; }
      var ps = getComputedStyle(pe);
      var fill = rgb(ps.webkitTextFillColor);
      if (t.trim() && !unreadable(ps.color, behind) && !(fill && fill.a < 0.15)) out.push(t);
      return;
    }
    if (node.nodeType !== 1) return;
    var tag = (node.tagName || '').toUpperCase();
    if (skip[tag]) return;
    if (tag === 'BR') { out.push('\n'); return; }
    if (node !== root && node.matches && node.matches(clutter)) return;
    if (!shown(node)) return;
    if (tag === 'INPUT') {
      var tp = (node.type || 'text').toLowerCase();
      if (tp !== 'password' && tp !== 'hidden') {
        var iv = (node.value || node.placeholder || '').trim();
        if (iv) out.push(' ' + iv + ' ');
      }
      return;
    }
    if (tag === 'TEXTAREA') {
      var tv = (node.value || node.placeholder || '').trim();
      if (tv) out.push('\n' + tv + '\n');
      return;
    }
    if (tag === 'SELECT') {
      var opt = node.selectedOptions && node.selectedOptions[0];
      var sv = (opt ? opt.textContent : node.value || '').trim();
      if (sv) out.push(' ' + sv + ' ');
      return;
    }
    if (tag === 'IMG' || tag === 'CANVAS') {
      var alt = (node.getAttribute('alt') || node.getAttribute('aria-label') || '').trim();
      if (alt) out.push(' [' + alt + '] ');
      return;
    }
    if (tag === 'IFRAME' || tag === 'FRAME') {
      try {
        if (node.contentDocument && node.contentDocument.body) walk(node.contentDocument.body, null, alpha);
      } catch (e) {}
      return;
    }
    var s = getComputedStyle(node);
    if (s.backgroundImage && s.backgroundImage !== 'none') behind = null;
    else { var bg = rgb(s.backgroundColor); if (bg && bg.a > 0.85) behind = bg; }
    var block = !/^inline/.test(s.display);
    if (block) out.push('\n');
    alpha = alpha * (parseFloat(s.opacity) || 0);
    if (alpha < 0.05) return;
    if (node.shadowRoot) {
      for (var sc = node.shadowRoot.firstChild; sc; sc = sc.nextSibling) walk(sc, behind, alpha);
    }
    for (var c = node.firstChild; c; c = c.nextSibling) walk(c, behind, alpha);
    if (block) out.push('\n');
  }

  function groundOf(el) {
    for (var up = el; up && up.nodeType === 1; up = up.parentElement) {
      var us = getComputedStyle(up);
      if (us.backgroundImage && us.backgroundImage !== 'none') return null;
      var painted = rgb(us.backgroundColor);
      if (painted && painted.a > 0.85) return painted;
    }
    return null;
  }
  function extractFrom(start) {
    out = [];
    seen = 0;
    root = start;
    walk(start, groundOf(start), 1);
    return out.join('').replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
  }

  var art = article();
  var startRoot = art || document.body;
  if (!startRoot) return null;
  for (var l = 0; l < document.links.length && links.length < 400; l++) {
    var a = document.links[l];
    if (!/^https?:/.test(a.href)) continue;
    var visible = true;
    for (var up = a; up && up.nodeType === 1 && visible; up = up.parentElement) visible = shown(up);
    if (visible) links.push(a.href);
  }
  var heading = document.querySelector('h1');
  var text = extractFrom(startRoot);
  if (art && document.body && art !== document.body) {
    var bodyLen = (document.body.innerText || '').trim().length;
    if (text.length < 1200 || (bodyLen > 0 && text.length * 2 < bodyLen)) {
      text = extractFrom(document.body);
    }
  }
  return { title: document.title || (heading && heading.textContent.trim()) || '', text: text, links: links };
})();