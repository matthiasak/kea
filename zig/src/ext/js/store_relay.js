(function () {
  if (location.hostname !== 'chromewebstore.google.com' || window.__keaStore) return;
  var state = { installed: [], busy: null };

  function pageID() {
    var m = location.pathname.match(/\/detail\/(?:[^\/]+\/)?([a-p]{32})/);
    return m ? m[1] : null;
  }

  function theirs() {
    var buttons = document.querySelectorAll('button[disabled]');
    for (var i = 0; i < buttons.length; i++) {
      var b = buttons[i];
      if (!b.dataset.kea && /chrome/i.test(b.textContent || '')) return b;
    }
    return null;
  }

  // From the banner's own button up, as far as it goes without taking in
  // the header beside it: short, and holding no install button.
  function bannerOf(button) {
    var box = null, up = button.parentElement;
    while (up && up !== document.body) {
      if (up.querySelector('button[disabled], button[data-kea]')) break;
      if ((up.innerText || '').length > 160) break;
      box = up;
      up = up.parentElement;
    }
    return box;
  }

  function hideBanner() {
    // And the floating "Switch to Chrome?" card, known by the Chrome logo
    // it carries in any language — it sits right over the button.
    var cards = document.querySelectorAll('[role="dialog"]');
    for (var c = 0; c < cards.length; c++) {
      if (!cards[c].dataset.kea && cards[c].querySelector('img[src*="productlogos/chrome"]')) {
        cards[c].style.display = 'none';
        cards[c].dataset.kea = 'promo';
      }
    }
    var buttons = document.querySelectorAll('button:not([disabled])');
    for (var i = 0; i < buttons.length; i++) {
      var b = buttons[i];
      if (b.dataset.kea || !/chrome/i.test(b.getAttribute('aria-label') || '')) continue;
      var box = bannerOf(b);
      if (box && !box.dataset.kea) {
        box.style.display = 'none';
        box.dataset.kea = 'banner';
      }
    }
  }

  // The words only, so the button keeps the store's own shape and colour.
  function label(button, text) {
    var walker = document.createTreeWalker(button, NodeFilter.SHOW_TEXT);
    var node, last = null;
    while ((node = walker.nextNode())) { if (node.nodeValue.trim()) last = node; }
    if (last) last.nodeValue = text; else button.textContent = text;
  }

  function render(ours) {
    var id = pageID();
    var installed = !!id && state.installed.indexOf(id) >= 0;
    var busy = !!id && state.busy === id;
    label(ours, installed ? 'Added to KeaZig' : (busy ? 'Adding…' : 'Add to KeaZig'));
    ours.disabled = installed || busy;
  }

  function mend() {
    hideBanner();
    if (!pageID()) return;
    var original = theirs();
    if (original && original.parentNode) {
      var ours = original.cloneNode(true);
      ['disabled', 'jsaction', 'jscontroller', 'jsname', 'jslog', 'aria-describedby'].forEach(function (name) {
        ours.removeAttribute(name);
      });
      ours.dataset.kea = 'add';
      original.dataset.kea = 'theirs';
      original.style.display = 'none';
      original.parentNode.insertBefore(ours, original.nextSibling);
      window.webkit.messageHandlers.keaStore.postMessage({ placed: pageID() });
    }
    renderAll();
  }

  // The store keeps the pages it has left, hidden, beside the one it shows.
  function renderAll() {
    var mine = document.querySelectorAll('button[data-kea="add"]');
    for (var i = 0; i < mine.length; i++) render(mine[i]);
  }

  // Caught on the window, before the store's own handlers — which listen
  // on the document — can see the click at all.
  window.addEventListener('click', function (e) {
    var mine = e.target && e.target.closest && e.target.closest('button[data-kea="add"]');
    if (!mine) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    if (!mine.disabled) window.webkit.messageHandlers.keaStore.postMessage({ add: true });
  }, true);

  window.__keaStore = {
    state: function (next) {
      state = next || state;
      renderAll();
    }
  };

  // The store is one page that rewrites itself: whatever it redraws, mend
  // again. A timer rather than a frame — a tab out of sight gets no frames.
  var queued = false;
  new MutationObserver(function () {
    if (queued) return;
    queued = true;
    setTimeout(function () { queued = false; mend(); }, 60);
  }).observe(document.documentElement, { childList: true, subtree: true });
  mend();
})();
