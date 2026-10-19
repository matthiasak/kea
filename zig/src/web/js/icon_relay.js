(function () {
  if (window.top !== window || !document.head) return;
  var timer = null, last = 0;
  var icon = function (n) {
    return n && n.nodeType === 1 && n.tagName === 'LINK' && /icon/i.test(n.getAttribute('rel') || '');
  };
  var touched = function (r) {
    if (icon(r.target)) return true;
    for (var i = 0; i < r.addedNodes.length; i++) if (icon(r.addedNodes[i])) return true;
    for (var j = 0; j < r.removedNodes.length; j++) if (icon(r.removedNodes[j])) return true;
    return false;
  };
  new MutationObserver(function (records) {
    if (!records.some(touched)) return;
    clearTimeout(timer);
    timer = setTimeout(function () {
      last = Date.now();
      try { webkit.messageHandlers.keaIcon.postMessage(1); } catch (e) {}
    }, Math.max(500, 2000 - (Date.now() - last)));
  }).observe(document.head, { childList: true, subtree: true, attributes: true, attributeFilter: ['href', 'rel', 'media'] });
})();
