(function () {
  var proto = HTMLMediaElement.prototype;
  var plain = Object.getOwnPropertyDescriptor(proto, 'playbackRate');
  if (!plain || !plain.get || !plain.set) return;
  // Off 1 by this much at most: a player catching up, not a choice.
  var nudge = 0.1, beside = 1.0001;
  var nudged = new WeakSet(), asked = new WeakMap();
  var smooth = {
    get playbackRate() {
      var now = plain.get.call(this), was = asked.get(this);
      // Changed some other way since — the video's own controls, an
      // extension: then what it is now is the answer.
      return was && Math.abs(now - was.played) < 1e-9 ? was.asked : now;
    },
    set playbackRate(value) {
      var rate = +value;
      var played = rate === 1 && nudged.has(this) ? beside : rate;
      // Refused (not a number, out of range): thrown, and nothing kept.
      plain.set.call(this, played);
      if (rate !== 1 && Math.abs(rate - 1) <= nudge) nudged.add(this);
      if (played !== rate) asked.set(this, { asked: rate, played: played });
      else asked.delete(this);
    }
  };
  var made = Object.getOwnPropertyDescriptor(smooth, 'playbackRate');
  try {
    Object.defineProperty(proto, 'playbackRate', {
      get: made.get, set: made.set, enumerable: plain.enumerable, configurable: true
    });
  } catch (e) {}
})();
