(function () {
  if (!window.PublicKeyCredential || !window.CredentialsContainer) return;
  var proto = CredentialsContainer.prototype;
  // In once, whichever copy comes first — an extension's (see
  // ExtensionShims.passkeys) or Kea's own — and marked on the prototype
  // rather than on the window. The mark holds navigator.credentials too:
  // held, WebKit keeps it, and an extension's own get and create on it
  // with it.
  var mark = Symbol.for('kea.passkeys');
  if (proto[mark]) return;
  try { Object.defineProperty(proto, mark, { value: navigator.credentials }); } catch (e) { return; }
  var nativeGet = proto.get, nativeCreate = proto.create;
  var refused = 'The operation either timed out or was not allowed.';
  // WebCrypto as it is now, before the site's own scripts run: the PRF
  // results come back sealed for a key made here (see Passkeys.prfReply).
  var subtle = window.crypto && crypto.subtle, sealing = null;
  if (subtle) sealing = {
    generate: subtle.generateKey.bind(subtle), exportKey: subtle.exportKey.bind(subtle),
    importKey: subtle.importKey.bind(subtle), deriveBits: subtle.deriveBits.bind(subtle),
    deriveKey: subtle.deriveKey.bind(subtle), decrypt: subtle.decrypt.bind(subtle)
  };
  var utf8 = new TextEncoder(), text = new TextDecoder();

  function bytes(source) {
    if (source instanceof ArrayBuffer) return new Uint8Array(source);
    if (ArrayBuffer.isView(source)) return new Uint8Array(source.buffer, source.byteOffset, source.byteLength);
    throw new TypeError('Expected an ArrayBuffer or a view of one.');
  }
  function encode(source) {
    var b = bytes(source), s = '';
    for (var i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
    return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }
  function decode(text) {
    var s = (text || '').replace(/-/g, '+').replace(/_/g, '/');
    while (s.length % 4) s += '=';
    var raw = atob(s), out = new Uint8Array(raw.length);
    for (var i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
    return out.buffer;
  }
  // The PRF extension's salts, and what the passkey derived from them.
  function prfValues(v) {
    return { first: encode(v.first), second: v.second !== undefined ? encode(v.second) : null };
  }
  function prfInput(extensions, allowed) {
    var prf = extensions && extensions.prf;
    if (!prf) return null;
    var out = {};
    if (prf.eval) out.eval = prfValues(prf.eval);
    if (prf.evalByCredential) {
      // As the standard has it: salts for particular passkeys need the list
      // of them, and every one of them has to be on it.
      if (!allowed || !allowed.length) throw new DOMException('evalByCredential needs allowCredentials.', 'NotSupportedError');
      var ids = Array.prototype.map.call(allowed, function (c) { return encode(c.id); });
      out.byCredential = {};
      Object.keys(prf.evalByCredential).forEach(function (id) {
        if (!id || ids.indexOf(id) < 0) throw new DOMException('evalByCredential names a credential allowCredentials does not.', 'SyntaxError');
        out.byCredential[id] = prfValues(prf.evalByCredential[id]);
      });
    }
    return out;
  }
  function prfOutput(reply, made, binary) {
    var out = {};
    if (made) out.enabled = !!reply.enabled;
    if (reply.first) {
      var value = binary ? decode : function (s) { return s; };
      out.results = { first: value(reply.first) };
      if (reply.second) out.results.second = value(reply.second);
    }
    return out;
  }

  function descriptors(list) {
    return Array.prototype.map.call(list || [], function (c) {
      return { id: encode(c.id), transports: Array.prototype.slice.call(c.transports || []) };
    });
  }
  function aborted(signal) {
    return signal.reason !== undefined ? signal.reason : new DOMException('The operation was aborted.', 'AbortError');
  }
  // Data as read-only, as a native credential's are; methods (`hidden`)
  // writable, as a native credential's are on its prototype — libraries
  // put their own on the object: GitHub's webauthn-json sets toJSON on
  // what get() returns, which a read-only one turned into a TypeError
  // after the Mac's sheet (#407).
  function define(target, values, hidden) {
    Object.keys(values).forEach(function (k) {
      Object.defineProperty(target, k, { value: values[k], enumerable: !hidden, configurable: true, writable: !!hidden });
    });
    return target;
  }

  function credential(reply, extensions) {
    var response, made = reply.kind === 'create';
    if (made) {
      response = Object.create(AuthenticatorAttestationResponse.prototype);
      define(response, { clientDataJSON: decode(reply.clientDataJSON), attestationObject: decode(reply.attestationObject) });
      define(response, {
        getTransports: function () { return (reply.transports || []).slice(); },
        getAuthenticatorData: function () { return decode(reply.authenticatorData); },
        getPublicKey: function () { return reply.publicKey ? decode(reply.publicKey) : null; },
        getPublicKeyAlgorithm: function () { return reply.publicKeyAlgorithm != null ? reply.publicKeyAlgorithm : -7; }
      }, true);
    } else {
      response = Object.create(AuthenticatorAssertionResponse.prototype);
      define(response, {
        clientDataJSON: decode(reply.clientDataJSON),
        authenticatorData: decode(reply.authenticatorData),
        signature: decode(reply.signature),
        userHandle: reply.userHandle ? decode(reply.userHandle) : null
      });
    }
    // A passkey from the Mac is always one the site can find without
    // naming it; the site may have asked whether it is.
    var results = {};
    if (made && extensions && extensions.credProps && reply.attachment === 'platform') results.credProps = { rk: true };
    // PRF outputs are bytes: made afresh for each caller, base64url in JSON.
    var prf = extensions && extensions.prf && reply.prf ? reply.prf : null;
    var attachment = reply.attachment || null;
    var jsonResults = JSON.parse(JSON.stringify(results));
    if (prf) jsonResults.prf = prfOutput(prf, made, false);
    var json = { id: reply.id, rawId: reply.id, type: 'public-key', authenticatorAttachment: attachment, clientExtensionResults: jsonResults };
    json.response = made
      ? { clientDataJSON: reply.clientDataJSON, attestationObject: reply.attestationObject, authenticatorData: reply.authenticatorData,
          transports: (reply.transports || []).slice(), publicKeyAlgorithm: reply.publicKeyAlgorithm != null ? reply.publicKeyAlgorithm : -7 }
      : { clientDataJSON: reply.clientDataJSON, authenticatorData: reply.authenticatorData, signature: reply.signature };
    if (made && reply.publicKey) json.response.publicKey = reply.publicKey;
    if (!made && reply.userHandle) json.response.userHandle = reply.userHandle;
    var result = Object.create(PublicKeyCredential.prototype);
    define(result, { id: reply.id, rawId: decode(reply.id), type: 'public-key', authenticatorAttachment: attachment, response: response });
    return define(result, {
      getClientExtensionResults: function () {
        var copy = JSON.parse(JSON.stringify(results));
        if (prf) copy.prf = prfOutput(prf, made, true);
        return copy;
      },
      toJSON: function () { return JSON.parse(JSON.stringify(json)); }
    }, true);
  }

  var waiting = {};
  window.addEventListener('kea-passkeys-answer', function (event) {
    var data;
    try { data = JSON.parse(event.detail); } catch (e) { return; }
    var done = data && waiting[data.token];
    if (!done) return;
    delete waiting[data.token];
    done(data.reply);
  });
  function ask(message) {
    return new Promise(function (resolve) {
      if (message.kind === 'cancel') resolve(true); else waiting[message.token] = resolve;
      window.dispatchEvent(new CustomEvent('kea-passkeys-ask', { detail: JSON.stringify(message) }));
    });
  }

  // A one-time key pair for a request's PRF results; the private half
  // never leaves this script.
  function prfKeys() {
    if (!sealing) return Promise.resolve(null);
    return sealing.generate({ name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']).then(function (pair) {
      return sealing.exportKey('raw', pair.publicKey).then(function (raw) { return { pair: pair, raw: encode(raw) }; });
    }, function () { return null; });
  }
  function unseal(prf, keys) {
    if (!prf || !prf.sealed || !keys) return Promise.resolve(prf ? { enabled: prf.enabled } : null);
    var box = new Uint8Array(decode(prf.sealed.box));
    return sealing.importKey('raw', decode(prf.sealed.key), { name: 'ECDH', namedCurve: 'P-256' }, false, [])
      .then(function (theirs) { return sealing.deriveBits({ name: 'ECDH', public: theirs }, keys.pair.privateKey, 256); })
      .then(function (bits) { return sealing.importKey('raw', bits, 'HKDF', false, ['deriveKey']); })
      .then(function (base) {
        return sealing.deriveKey({ name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(0), info: utf8.encode('kea-prf') },
          base, { name: 'AES-GCM', length: 256 }, false, ['decrypt']);
      })
      .then(function (key) { return sealing.decrypt({ name: 'AES-GCM', iv: box.slice(0, 12) }, key, box.slice(12)); })
      .then(function (plain) {
        var results = JSON.parse(text.decode(plain));
        return { enabled: prf.enabled, first: results.first, second: results.second };
      }, function () { return { enabled: prf.enabled }; });
  }

  function send(request, signal, extensions) {
    if (signal && signal.aborted) return Promise.reject(aborted(signal));
    request.token = Math.random().toString(36).slice(2);
    return (request.prf ? prfKeys() : Promise.resolve(null)).then(function (keys) {
      if (keys) request.prfKey = keys.raw;
      return new Promise(function (resolve, reject) {
        if (signal) signal.addEventListener('abort', function () {
          ask({ kind: 'cancel', token: request.token });
          reject(aborted(signal));
        }, { once: true });
        ask(request).then(function (reply) {
          // Nothing to offer under the field here: it waits, as it does
          // while nobody picks one, until the page lets it go.
          if (reply && reply.error === 'Wait') return;
          if (!reply || reply.error) {
            var name = (reply && reply.error) || 'NotAllowedError';
            var message = (reply && reply.message) || refused;
            return reject(name === 'TypeError' ? new TypeError(message) : new DOMException(message, name));
          }
          unseal(reply.prf, keys).then(function (prf) {
            if (prf) reply.prf = prf; else delete reply.prf;
            resolve(credential(reply, extensions));
          });
        }, function () { reject(new DOMException(refused, 'NotAllowedError')); });
      });
    });
  }

  function replace(target, name, value) {
    try { Object.defineProperty(target, name, { value: value, configurable: true, writable: true }); } catch (e) {}
  }

  replace(proto, 'get', function get(options) {
    if (!options || !options.publicKey) return nativeGet.apply(this, arguments);
    var signal = options.signal, pk = options.publicKey, request;
    // From under the name field: offered there, answered once you pick.
    var underField = options.mediation === 'conditional';
    try {
      request = {
        kind: 'get', conditional: underField, challenge: encode(pk.challenge), rpId: pk.rpId || null,
        allowCredentials: descriptors(pk.allowCredentials),
        userVerification: pk.userVerification || 'preferred',
        prf: prfInput(pk.extensions, pk.allowCredentials)
      };
    } catch (e) { return Promise.reject(e); }
    return send(request, signal, pk.extensions);
  });

  replace(proto, 'create', function create(options) {
    if (!options || !options.publicKey) return nativeCreate.apply(this, arguments);
    var pk = options.publicKey, selection = pk.authenticatorSelection || {}, request;
    // A passkey made quietly after a password sign-in: not something
    // this browser does yet, so the site hears no, as it would if you had.
    if (options.mediation === 'conditional') return Promise.reject(new DOMException(refused, 'NotAllowedError'));
    try {
      request = {
        kind: 'create', challenge: encode(pk.challenge),
        rp: { id: (pk.rp && pk.rp.id) || null },
        user: { id: encode(pk.user.id), name: String(pk.user.name), displayName: pk.user.displayName ? String(pk.user.displayName) : '' },
        algorithms: Array.prototype.map.call(pk.pubKeyCredParams || [], function (p) { return p.alg; }),
        excludeCredentials: descriptors(pk.excludeCredentials),
        authenticatorAttachment: selection.authenticatorAttachment || null,
        residentKey: selection.residentKey || (selection.requireResidentKey ? 'required' : 'discouraged'),
        userVerification: selection.userVerification || 'preferred',
        attestation: pk.attestation || 'none',
        prf: prfInput(pk.extensions, null)
      };
    } catch (e) { return Promise.reject(e); }
    return send(request, options.signal, pk.extensions);
  });

  // What this browser can and can't do, for the pages that ask first:
  // passkeys from the Mac, a phone or a key, under the field too, and
  // none of what WebKit would have answered for itself.
  var P = PublicKeyCredential;
  replace(P, 'isUserVerifyingPlatformAuthenticatorAvailable', function () { return Promise.resolve(true); });
  replace(P, 'isConditionalMediationAvailable', function () { return Promise.resolve(true); });
  var nativeCapabilities = P.getClientCapabilities;
  if (typeof nativeCapabilities === 'function') {
    replace(P, 'getClientCapabilities', function () {
      function ours(c) {
        c = Object.assign({}, c);
        Object.keys(c).forEach(function (k) { if (k.indexOf('extension:') === 0 && k !== 'extension:credProps') c[k] = false; });
        c['extension:prf'] = __KEA_PRF__;
        return Object.assign(c, {
          conditionalCreate: false, conditionalGet: true, conditionalMediation: true, relatedOrigins: false,
          signalAllAcceptedCredentials: false, signalCurrentUserDetails: false, signalUnknownCredential: false,
          hybridTransport: true, passkeyPlatformAuthenticator: true, userVerifyingPlatformAuthenticator: true
        });
      }
      return nativeCapabilities.call(P).then(ours, function () { return ours({}); });
    });
  }
})();
