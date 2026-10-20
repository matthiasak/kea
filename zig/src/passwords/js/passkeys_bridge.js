(function () {
  var handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.keaPasskeys;
  if (!handler || window.__bridged) return;
  window.__bridged = true;
  window.addEventListener('kea-passkeys-ask', function (event) {
    var message;
    try { message = JSON.parse(event.detail); } catch (e) { return; }
    if (!message || typeof message !== 'object' || typeof message.token !== 'string') return;
    function answer(reply) {
      window.dispatchEvent(new CustomEvent('kea-passkeys-answer', { detail: JSON.stringify({ token: message.token, reply: reply }) }));
    }
    handler.postMessage(message).then(function (reply) {
      if (message.kind !== 'cancel') answer(reply);
    }, function () {
      if (message.kind !== 'cancel') answer(null);
    });
  });
})();
