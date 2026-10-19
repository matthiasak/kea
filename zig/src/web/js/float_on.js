(function () {
  var videos = document.querySelectorAll('video');
  var best = null, area = 0;
  for (var i = 0; i < videos.length; i++) {
    var v = videos[i];
    if (v.paused || v.ended || v.readyState < 2) continue;
    var box = v.getBoundingClientRect();
    if (box.width * box.height >= area) { area = box.width * box.height; best = v; }
  }
  if (!best) return 'none';

  // A landing still waiting for its tab is called off: the page is out
  // again.
  window.__keaFloatLanding = null;
  best.setAttribute('data-kea-float', '');
  var sheet = document.getElementById('kea-float');
  if (!sheet) {
    sheet = document.createElement('style');
    sheet.id = 'kea-float';
    (document.head || document.documentElement).appendChild(sheet);
  }
  sheet.textContent = [
    'html.kea-floating, html.kea-floating body {',
    'background:#000 !important; overflow:hidden !important; margin:0 !important}',
    'html.kea-floating body > * { visibility:hidden !important }',
    'html.kea-floating [data-kea-float] {',
    'visibility:visible !important; position:fixed !important;',
    'left:0 !important; top:0 !important; right:0 !important; bottom:0 !important;',
    'width:100vw !important; height:100vh !important;',
    'max-width:none !important; max-height:none !important;',
    // Players such as Netflix center the element with a translation.
    // With our top/left at zero, that moves it out of the floating window.
    'transform:none !important; translate:none !important; rotate:none !important; scale:none !important;',
    'opacity:1 !important; object-fit:contain !important; z-index:2147483647 !important}',
    // Netflix renders timed text after the video, in a layer of its own
    // beside it or one level up. Keep it above the video without
    // exposing the rest of the player.
    'html.kea-floating [data-kea-float] ~ .player-timedtext,',
    'html.kea-floating :has(> [data-kea-float]) > .player-timedtext,',
    'html.kea-floating :has([data-kea-float]) > .player-timedtext {',
    'visibility:visible !important; z-index:2147483647 !important}',
    // Fixed or not, the video is still cut to the box of any ancestor
    // that clips — YouTube's player does — and in a window this small
    // that box sits partly or wholly off screen, more so on a page that
    // was scrolled. That was the black window.
    'html.kea-floating body :has([data-kea-float]) {',
    'overflow:visible !important;',
    // And fixed is only fixed to the window while no ancestor makes a
    // box of its own for it: a transform, a filter, containment, a
    // perspective, a backdrop, a container query — Twitch's player has
    // some — and the video was placed and sized inside that box instead,
    // part of it or none of it in the window. An ancestor drawn only
    // when on screen (content-visibility) wasn't drawn at all once the
    // rest of the page was hidden, and one faded out hid the video too.
    'transform:none !important; translate:none !important; rotate:none !important; scale:none !important;',
    'filter:none !important; backdrop-filter:none !important; -webkit-backdrop-filter:none !important;',
    'perspective:none !important; contain:none !important; container-type:normal !important;',
    'will-change:auto !important; content-visibility:visible !important;',
    'clip-path:none !important; mask:none !important; -webkit-mask:none !important;',
    'opacity:1 !important}',
    // The player's own controls would sit under ours, and two sets of
    // buttons on one small window is one set too many.
    'html.kea-floating [data-kea-float]::-webkit-media-controls {',
    'display:none !important}'
  ].join('');
  document.documentElement.classList.add('kea-floating');

  // The mark has to be defended.
  //
  // Everything but the marked element is hidden, so the moment a player
  // rebuilds its DOM — and they all do, on a quality change, an ad break,
  // a React re-render — the mark goes with the old element and the window
  // turns pure black while still holding a perfectly live page. That is the
  // black rectangle, and it is not an orphaned window at all.
  //
  // So the mark is put back on whatever is playing now, four times a
  // second, for as long as the page is out.
  clearInterval(window.__keaFloatWatch);
  window.__keaFloatWatch = setInterval(function () {
    if (document.querySelector('[data-kea-float]')) return;
    var again = null, most = 0;
    var all = document.querySelectorAll('video');
    for (var j = 0; j < all.length; j++) {
      var one = all[j];
      if (one.paused || one.ended || one.readyState < 2) continue;
      var shape = one.getBoundingClientRect();
      if (shape.width * shape.height >= most) {
        most = shape.width * shape.height;
        again = one;
      }
    }
    if (again) again.setAttribute('data-kea-float', '');
  }, 250);

  return 'floating';
})();
