(function () {
  // The engine may have put the video in its own floating window as well —
  // some players ask for that themselves. Leaving one and not the other
  // leaves you with two.
  try {
    var out = document.querySelector('video[data-kea-float]')
      || document.querySelector('video');
    if (out) {
      if (out.webkitPresentationMode === 'picture-in-picture') {
        out.webkitSetPresentationMode('inline');
      }
      if (document.pictureInPictureElement && document.exitPictureInPicture) {
        document.exitPictureInPicture();
      }
    }
  } catch (e) {}

  var root = document.documentElement;
  var landing = window.__keaFloatLanding = {};
  function put() {
    // Floated again in the meantime: that is the float's now.
    if (window.__keaFloatLanding !== landing) return;
    window.__keaFloatLanding = null;
    clearInterval(window.__keaFloatWatch);
    window.__keaFloatWatch = null;
    root.classList.remove('kea-floating');
    var sheet = document.getElementById('kea-float');
    if (sheet) sheet.textContent = '';
    var video = document.querySelector('[data-kea-float]');
    if (video) video.removeAttribute('data-kea-float');
  }
  // Each frame until the page is laid out at another size than the
  // little window's — the tab's — and its player has had that frame's
  // resize to fit the video to it. A page not drawn, its tab no longer
  // the one in front, is put back by the clock.
  var wide = innerWidth, high = innerHeight, began = Date.now();
  (function frame() {
    if (window.__keaFloatLanding !== landing) return;
    if (innerWidth !== wide || innerHeight !== high || Date.now() - began > 400) return put();
    requestAnimationFrame(frame);
  })();
  setTimeout(put, 1000);
  return 'landing';
})();
