(function () {
  if (window.__keaMiddle) return;
  window.__keaMiddle = true;
  // Heard on the way down, before the page's own handlers, since some
  // stop the event there — YouTube's links did, and a middle-click on
  // them opened nothing, only some of the time. Whether the page wanted
  // the click for itself is asked once they have all run: a page that
  // prevented it keeps it, as in Chrome.
  // The link is found now: once the event is over its path is empty.
  window.addEventListener('auxclick', function (e) {
    if (e.button !== 1 || !e.isTrusted) return;
    var href = link(e);
    if (!href) return;
    setTimeout(function () {
      if (!e.defaultPrevented) window.webkit.messageHandlers.keaMiddle.postMessage({ href: href });
    }, 0);
  }, true);
  function link(e) {
    // The path, not the parents: a link inside an open shadow root is
    // on it too. An <area> of an image map is a link, and so is an SVG
    // <a>, whose href is an object that holds the address as written.
    var path = e.composedPath();
    for (var i = 0; i < path.length; i++) {
      var el = path[i];
      var tag = el.tagName ? el.tagName.toLowerCase() : '';
      if (tag !== 'a' && tag !== 'area') continue;
      var href = el.href;
      if (href && typeof href === 'object') {
        try { href = href.baseVal ? new URL(href.baseVal, el.baseURI).href : ''; } catch (_) { href = ''; }
      }
      if (!href) continue;
      return href;
    }
    return '';
  }
})();
