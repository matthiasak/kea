(function () {
  var real = window.PublicKeyCredential;
  if (!real) return;
  var claimed = false;
  function answered() {
    if (claimed) return true;
    try {
      if (navigator.credentials && Object.getOwnPropertyDescriptor(navigator.credentials, 'get')) claimed = true;
      else if ((new Error().stack || '').indexOf('-extension://') >= 0) claimed = true;
    } catch (e) {}
    return claimed;
  }
  try {
    Object.defineProperty(window, 'PublicKeyCredential', {
      configurable: true,
      get: function () { return answered() ? real : undefined; },
      set: function (value) { real = value; }
    });
  } catch (e) {
    try { delete window.PublicKeyCredential; } catch (ignored) {}
    return;
  }
  var proto = CredentialsContainer.prototype;
  ['get', 'create'].forEach(function (name) {
    var native = proto[name];
    try {
      Object.defineProperty(proto, name, {
        configurable: true, writable: true,
        value: function (options) {
          if (!options || !options.publicKey) return native.apply(this, arguments);
          var signal = options.signal;
          // Under the name field: nothing to offer, so it waits, as it
          // would while nobody picks one, until the page lets it go.
          if (name === 'get' && options.mediation === 'conditional') {
            return new Promise(function (resolve, reject) {
              if (!signal) return;
              var aborted = function () { return signal.reason || new DOMException('The operation was aborted.', 'AbortError'); };
              if (signal.aborted) return reject(aborted());
              signal.addEventListener('abort', function () { reject(aborted()); }, { once: true });
            });
          }
          return Promise.reject(new DOMException('The operation either timed out or was not allowed.', 'NotAllowedError'));
        }
      });
    } catch (e) {}
  });
})();
