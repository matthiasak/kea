(function () {
  var video = document.querySelector('[data-kea-float]')
    || document.querySelector('video');
  if (!video) return true;
  if (video.paused) { video.play(); } else { video.pause(); }
  return !video.paused;
})();
