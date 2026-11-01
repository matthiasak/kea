// Automatic Researcher Mode's reading of a page, in Kea's own world
// (researcher.zig appends the call): `('extract', force)` says whether the
// page looks like research — a paper, code, math, a post — and returns its
// sections; `('scrollTo', i)` brings section i back into view. The elements
// found are kept in this world's `__keaResearcherTargets`: the page's DOM
// is never touched and its scripts never see them.
(function (mode, arg) {
  if (mode === 'scrollTo') {
    var at = (window.__keaResearcherTargets || [])[arg];
    if (at && at.isConnected) at.scrollIntoView({ behavior: 'smooth', block: 'start' });
    return !!at;
  }
  var most = 8, cap = 1600;
  var host = location.hostname.replace(/^www\./, ''), path = location.pathname;
  var depth = path.split('/').filter(Boolean).length;
  function on(h) { return host === h || host.slice(-h.length - 1) === '.' + h; }
  function clean(s) { return (s || '').replace(/\s+/g, ' ').trim(); }

  var paper = ['arxiv.org', 'openreview.net', 'biorxiv.org', 'medrxiv.org', 'chemrxiv.org', 'ssrn.com', 'dl.acm.org',
    'ieeexplore.ieee.org', 'nature.com', 'science.org', 'springer.com', 'sciencedirect.com', 'ncbi.nlm.nih.gov',
    'semanticscholar.org', 'scholarpedia.org', 'plato.stanford.edu', 'distill.pub', 'transformer-circuits.pub',
    'doi.org'].some(on) || (on('huggingface.co') && /^\/papers/.test(path));
  var code = ((on('github.com') || on('gitlab.com') || on('codeberg.org')) && depth >= 2) ||
    ['gist.github.com', 'sr.ht', 'crates.io', 'pkg.go.dev', 'pypi.org', 'npmjs.com'].some(on);
  var post = ((on('x.com') || on('twitter.com')) && /\/status\//.test(path)) ||
    (on('bsky.app') && /\/post\//.test(path)) || (on('news.ycombinator.com') && path === '/item');

  function looksLikeResearch() {
    if (paper || code || post) return true;
    if (document.querySelector('meta[name^="citation_"]')) return true;
    var lds = document.querySelectorAll('script[type="application/ld+json"]');
    for (var i = 0; i < lds.length; i++) {
      if (/"(ScholarlyArticle|TechArticle|SoftwareSourceCode)"/.test(lds[i].textContent || '')) return true;
    }
    if (document.querySelector('math, .katex, .MathJax, mjx-container, script[type*="math/tex"]')) return true;
    var words = document.body ? document.body.innerText || '' : '';
    if ((words.match(/\$\$|\\begin\{(equation|align|theorem|proof)\}/g) || []).length >= 2) return true;
    var heads = document.querySelectorAll('h1, h2, h3');
    if (document.querySelectorAll('pre code').length >= 2 && heads.length >= 2) return true;
    var names = Array.prototype.map.call(heads, function (h) { return clean(h.textContent).toLowerCase(); }).join('|');
    return /abstract/.test(names) && /introduction|references|theorem|lemma/.test(names);
  }

  if (!arg && !looksLikeResearch()) return { qualifies: false };

  var targets = [], sections = [];
  function add(el, heading, excerpt) {
    if (sections.length >= most) return;
    targets.push(el);
    sections.push({ heading: clean(heading).slice(0, 200), excerpt: clean(excerpt).slice(0, cap) });
  }

  if (post) {
    var posts = document.querySelectorAll('[data-testid="tweet"]');
    if (!posts.length) posts = document.querySelectorAll(on('news.ycombinator.com') ? '.fatitem, .comtr' : 'article');
    for (var p = 0; p < posts.length; p++) add(posts[p], p === 0 ? 'Main Post' : 'Reply ' + p, posts[p].innerText);
  }

  var root = document.querySelector('.markdown-body') || document.querySelector('article') || document.querySelector('main') || document.body;
  if (!sections.length && root) {
    var hs = Array.prototype.filter.call(root.querySelectorAll('h1, h2, h3'), function (h) { return clean(h.textContent); });
    if (hs.length > most) hs = hs.filter(function (h) { return h.tagName !== 'H3'; });
    for (var k = 0; k < hs.length; k++) {
      var range = document.createRange();
      range.setStartAfter(hs[k]);
      if (k + 1 < hs.length) range.setEndBefore(hs[k + 1]); else range.setEndAfter(root.lastChild || root);
      add(hs[k], hs[k].textContent, range.toString());
    }
  }

  // No headings: the page in parts.
  if (!sections.length && root) {
    var all = clean(root.innerText);
    for (var n = 0; n * cap < all.length && n < 4; n++) add(root, 'Part ' + (n + 1), all.slice(n * cap, (n + 1) * cap));
  }

  window.__keaResearcherTargets = targets;
  return { qualifies: true, title: document.title || '', sections: sections };
})
