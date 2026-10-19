(function () {
  var video = document.querySelector('[data-kea-float]')
    || document.querySelector('video');
  if (!video || !video.duration || !isFinite(video.duration)) return [0, true];
  return [video.currentTime / video.duration, !video.paused];
})();
