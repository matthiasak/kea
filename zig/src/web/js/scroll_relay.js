(function () {
  var waiting = false, last = -1;
  function tell(first) {
    var root = document.documentElement;
    var y = window.scrollY || root.scrollTop || 0;
    var ceiling = Math.max(1, (root.scrollHeight || 0) - window.innerHeight);
    var step = Math.round(Math.min(1, Math.max(0, y / ceiling)) * 100);
    if (!first && step === last) return;
    last = step;
    window.webkit.messageHandlers.keaScroll.postMessage({ y: y, max: ceiling });
  }
  window.addEventListener('scroll', function () {
    if (waiting) return;
    waiting = true;
    requestAnimationFrame(function () { waiting = false; tell(); });
  }, { passive: true });
  tell(true);
})();
