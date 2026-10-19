(function () {
  var out = [];
  var links = document.querySelectorAll('link[rel]');
  for (var i = 0; i < links.length; i++) {
    var l = links[i];
    var rel = (l.getAttribute('rel') || '').toLowerCase();
    if (rel.indexOf('icon') < 0) continue;
    out.push({
      href: l.href,
      rel: rel,
      sizes: (l.getAttribute('sizes') || '').toLowerCase(),
      type: (l.getAttribute('type') || '').toLowerCase(),
      media: (l.getAttribute('media') || '').toLowerCase()
    });
  }
  return out;
})();
