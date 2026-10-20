(() => {
  const root = globalThis;
  // Taken now, not looked up at each use: a sandbox that later locks
  // the globals away (MetaMask's LavaMoat) would break the shim's own
  // code that needs them — every fetch of a Request, every import.
  const { URL, FileReader, Response, Blob, File, DOMException, HTMLImageElement, HTMLAnchorElement, Element } = root;
  const chrome = root.chrome || root.browser;
  // A page's own world, where an extension's MAIN-world script runs with
  // this before it, has no extension APIs. Nothing to mend there, and
  // nothing may be left there for a page to see: Safari leaves nothing.
  // (There, Kea's passkey patch holds navigator.credentials.)
  const ours = (() => { try { return !!(chrome && chrome.runtime && chrome.runtime.id); } catch (e) { return false; } })();
  if (!ours || root.__keaShim) return;
  // Bitwarden's bundled TypeScript uses these as computed class keys
  // before it registers disposable resources. Define them before any
  // extension code runs; Symbol.for keeps the key shared by its frames.
  const symbol = root.Symbol;
  for (const name of ["dispose", "asyncDispose"]) {
    if (symbol[name] === undefined) Object.defineProperty(symbol, name, { value: symbol.for("Symbol." + name) });
  }
  // WebKit reverted `requestIdleCallback` after a page-load regression
  // (bug 287681), leaving Proton Pass's form detection without it.
  const nativeIdle = typeof root.requestIdleCallback === "function"
    ? root.requestIdleCallback.bind(root) : null;
  const nativeCancelIdle = typeof root.cancelIdleCallback === "function"
    ? root.cancelIdleCallback.bind(root) : null;
  if (!nativeIdle || !nativeCancelIdle) {
    const idle = new Map();
    let idleId = 0;
    root.requestIdleCallback = (callback, options) => {
      const id = ++idleId;
      if (nativeIdle) {
        const nativeId = nativeIdle((deadline) => {
          if (!idle.delete(id)) return;
          callback(deadline);
        }, options);
        idle.set(id, { nativeId });
      } else {
        // Let the requesting script finish first. Chrome's maximum
        // idle deadline is 50 ms; this fallback uses the full budget.
        const timer = setTimeout(() => {
          if (!idle.delete(id)) return;
          const start = Date.now();
          callback({ didTimeout: false, timeRemaining: () => Math.max(0, 50 - (Date.now() - start)) });
        }, 1);
        idle.set(id, { timer });
      }
      return id;
    };
    root.cancelIdleCallback = (id) => {
      const request = idle.get(id);
      if (request === undefined) {
        if (nativeCancelIdle) nativeCancelIdle(id);
        return;
      }
      idle.delete(id);
      if (request.timer !== undefined) clearTimeout(request.timer);
      else if (nativeCancelIdle) nativeCancelIdle(request.nativeId);
    };
  }
  // Keep the first credentials container alive so extension hooks
  // survive WebKit replacing an unreferenced container.
  const credentials = root.navigator && root.navigator.credentials;
  if (credentials && !Object.prototype.hasOwnProperty.call(root, "__keaCredentials")) {
    Object.defineProperty(root, "__keaCredentials", { value: credentials });
  }
  Object.defineProperty(root, "__keaShim", { value: true });
  // WebKit finds a page's extension APIs through the `chrome` and
  // `browser` globals when it delivers an event. A sandbox that locks
  // every global away (MetaMask's LavaMoat) cuts it off: nothing arrives
  // any more. Made fixed accessors, they can't be taken away, and code
  // that assigns its own polyfill to them still can.
  for (const key of ["browser", "chrome"]) {
    // SingleFile installs its own browser getter with __defineGetter__.
    // Keep chrome fixed for WebKit's listeners, but leave browser open
    // for that getter to replace it without killing the worker.
    if (key === "browser" && root.chrome?.runtime?.id === "mpiodijhokgodhhofbcjdecpffjipkle") continue;
    const d = Object.getOwnPropertyDescriptor(root, key);
    if (!d || !d.configurable) continue;
    let value = root[key];
    // A replacement that hides the APIs — a Proxy some extensions put
    // there to keep them from other code (Proton Pass) — would hide them
    // from WebKit too, and nothing would reach the extension again. A
    // replacement that still carries them is taken.
    const carries = (v) => { try { return !!(v && v.runtime && v.runtime.id); } catch (e) { return false; } };
    try { Object.defineProperty(root, key, { configurable: false, enumerable: d.enumerable, get: () => value, set: (v) => { if (carries(v)) value = v; } }); } catch (e) {}
  }
  // On a web page this is a content script: only Chrome's behaviour is
  // mended there, no API that Chrome doesn't give content scripts either.
  const inContent = typeof location !== "undefined" && !/^(chrome|webkit)-extension:$/.test(location.protocol);
  // One of the extension's pages in a frame of a website — Vimium's bar,
  // the list iCloud Passwords opens under a field. WebKit runs it in the
  // website's process, which it trusts with no more than a content
  // script: a single call to tabs, windows, scripting… and WebKit takes
  // the process for compromised and ends it. The page reloads, and a
  // frame that makes the call as it loads reloads it for ever. Chrome
  // gives such a frame everything, so here the worker makes those calls
  // for it (see `__keaCall`).
  const embedded = !inContent && typeof window !== "undefined" && window.top !== window && (() => {
    try { const a = location.ancestorOrigins; if (a && a.length) return [...a].some((o) => o !== location.origin); } catch (e) {}
    try { return window.top.location.origin !== location.origin; } catch (e) { return true; }
  })();
  const runtime = chrome.runtime;

  // WebKit's objects are kept — WebKit finds an extension's listeners
  // through them, and a replacement would hide them. Members are set on
  // them instead: a method lives on the prototype, so an own property of
  // the same name takes its place.
  // WebKit's namespace and event objects are wrappers it doesn't keep
  // alive: once no script holds one, it is collected, and the next
  // `chrome.tabs` is a fresh object without what was set on it. So every
  // object touched here is held for good.
  const kept = new Set();
  try { Object.defineProperty(root, "__keaKept", { value: kept }); } catch (e) {}
  const put = (target, key, value) => {
    if (target && (typeof target === "object" || typeof target === "function")) kept.add(target);
    try { Object.defineProperty(target, key, { value, configurable: true, writable: true, enumerable: true }); }
    catch (e) { try { target[key] = value; } catch (e2) {} }
  };
  // Held from the start, before the extension's own code runs — its
  // polyfills set things on these objects too.
  const spaces = new Set(Object.keys(chrome));
  for (let o = Object.getPrototypeOf(chrome); o && o !== Object.prototype; o = Object.getPrototypeOf(o)) Object.getOwnPropertyNames(o).forEach((k) => spaces.add(k));
  for (const space of spaces) {
    let ns; try { ns = chrome[space]; } catch (e) { continue; }
    if (!ns || typeof ns !== "object") continue;
    kept.add(ns);
    // And the same object every time it is asked for: WebKit can hand
    // out a fresh one, without what was set on the last.
    if (!Object.prototype.hasOwnProperty.call(chrome, space) || Object.getOwnPropertyDescriptor(chrome, space).get) {
      try { Object.defineProperty(chrome, space, { value: ns, configurable: true, writable: true, enumerable: true }); } catch (e) {}
    }
    for (let o = ns; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) {
      for (const key of Object.getOwnPropertyNames(o)) {
        if (!/^on[A-Z]/.test(key)) continue;
        try { const ev = ns[key]; if (ev && typeof ev === "object") kept.add(ev); } catch (e) {}
      }
    }
    for (const sub of ["local", "sync", "session", "managed"]) { try { if (ns[sub] && typeof ns[sub] === "object") kept.add(ns[sub]); } catch (e) {} }
  }
  const withLastError = (error, callback) => {
    put(runtime, "lastError", { message: String(error && error.message || error) });
    try { callback(); } finally { try { delete runtime.lastError; } catch (e) {} }
  };
  const manifest = (() => { try { return runtime.getManifest(); } catch (e) { return {}; } })();
  const offscreenCapable = [...(manifest.permissions || []), ...(manifest.optional_permissions || [])].includes("offscreen");
  // kea:content-skip-begin
  const native = (api, args) =>
    runtime.sendNativeMessage("kea", { api, args: JSON.parse(JSON.stringify(args ?? [])) })
      .then((reply) => {
        if (reply && reply.error) throw new Error(reply.error);
        return reply ? reply.value : undefined;
      });
  // Chrome's APIs take a callback last, or return a promise without one.
  const call = (api) => (...args) => {
    const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
    const promise = native(api, args);
    if (!callback) return promise;
    promise.then((value) => callback(value), (error) => withLastError(error, callback));
  };
  // Where a tab is, as Kea can find it: its place in its window's row
  // and that window's frame. WebKit's window numbers mean nothing to
  // Kea, and windows.getAll gives the frames they go with.
  const frames = async () => {
    const all = chrome.windows && typeof chrome.windows.getAll === "function"
      ? await Promise.resolve(chrome.windows.getAll()).catch(() => []) : [];
    return new Map((all || []).map((w) => [w.id, { left: w.left, top: w.top, width: w.width, height: w.height }]));
  };
  const placeOf = (t, known) => ({ i: t.index, w: known.get(t.windowId) });
  const event = () => {
    const listeners = new Set();
    return {
      addListener: (f) => listeners.add(f), removeListener: (f) => listeners.delete(f),
      hasListener: (f) => listeners.has(f), hasListeners: () => listeners.size > 0,
      listeners,
    };
  };

  // Several onMessage listeners: WebKit takes the first one's return —
  // usually undefined — as the answer, where Chrome waits for whichever
  // calls sendResponse or returns true. So the extension's listeners are
  // gathered behind a single one of WebKit's that follows Chrome's rule.
  const worker = typeof ServiceWorkerGlobalScope !== "undefined" && root instanceof ServiceWorkerGlobalScope;
  // The extension's background, whichever WebKit runs: the worker, or a
  // page — it picks the page when a manifest names scripts as well.
  const background = worker || (!inContent && typeof document !== "undefined" && (() => {
    try { return chrome.extension && typeof chrome.extension.getBackgroundPage === "function" && chrome.extension.getBackgroundPage() === root; }
    catch (e) { return false; }
  })());
  const backgroundPage = manifest.background || {};
  const hasWorker = !!(backgroundPage.service_worker || backgroundPage.scripts || backgroundPage.page);
  // A script a worker imports that isn't there: Chrome throws at once.
  // WebKit goes looking for it first, and while it does, runs the
  // promises already waiting — code that notes "still starting" until
  // its first promise settles (Tampermonkey) then thinks startup is
  // over, and refuses its own listeners. The extension's files are
  // known, so a missing one is refused the way Chrome refuses it, and
  // an empty one — Tampermonkey's test.js — isn't fetched at all.
  // The static routing API of Chrome's service workers (install
  // event.addRoutes) — a speed-up, so nothing is lost without it.
  if (worker && typeof root.InstallEvent === "function" && !InstallEvent.prototype.addRoutes) {
    InstallEvent.prototype.addRoutes = () => Promise.resolve();
  }
  // clients.matchAll() in an extension's worker: Chrome lists the
  // extension's own pages that are open — its popup, its pages in tabs.
  // WebKit lists none, so an extension that checks whether its popup is
  // open before sending it news always hears no: 1Password's popup
  // stays on "connecting to the app" for ever, the answer from the app
  // never passed on. The browser knows which pages are open, so they
  // are added to the list; a message posted to one reaches it through
  // a channel the pages listen on, as a message from the worker.
  // The other way round, a page reaches the worker through
  // navigator.serviceWorker, and the worker answers the page a message
  // came from — ScriptCat's worker hands each GM_xmlhttpRequest to its
  // offscreen document so. Here no worker controls the extension's
  // pages, so a page is given one that posts to the worker over the same
  // channel, and a message either way says who sent it. A port handed
  // over with a message can't cross the channel: it stays with the
  // sender, and what is posted to the one the other side is given comes
  // back over the channel to it.
  const clientsChannel = typeof BroadcastChannel === "function" && !inContent && !embedded ? new BroadcastChannel("kea-clients") : null;
  const heldPorts = new Map();
  const handOver = (transfer) => (Array.isArray(transfer) ? transfer : (transfer && transfer.transfer) || [])
    .filter((p) => p instanceof MessagePort)
    .map((port) => { const key = Math.random().toString(36).slice(2); heldPorts.set(key, port); return key; });
  const answered = (data) => {
    if (typeof data.port !== "string") return false;
    const port = heldPorts.get(data.port);
    if (port) port.postMessage(data.data);
    return true;
  };
  const messageFrom = (source, data, keys) => {
    const ports = (Array.isArray(keys) ? keys : []).map((key) => {
      const pair = new MessageChannel();
      pair.port1.onmessage = (e) => clientsChannel.postMessage({ port: key, data: e.data });
      return pair.port2;
    });
    const event = new MessageEvent("message", { data, ports, origin: location.origin });
    if (source) Object.defineProperty(event, "source", { value: source });
    return event;
  };
  if (worker && clientsChannel && root.clients && typeof root.clients.matchAll === "function") {
    const matchAll = root.clients.matchAll.bind(root.clients);
    const client = (p) => ({
      id: "kea-" + p.id, url: p.url, type: "window", frameType: "top-level",
      visibilityState: p.visible ? "visible" : "hidden", focused: !!p.focused,
      postMessage: (data, transfer) => { try { clientsChannel.postMessage({ url: p.url, data, ports: handOver(transfer) }); } catch (e) {} },
      focus() { return Promise.resolve(this); },
      navigate: () => Promise.resolve(null),
    });
    put(root.clients, "matchAll", async (options) => {
      const found = [...await matchAll(options)];
      const type = (options && options.type) || "window";
      if (type !== "window" && type !== "all") return found;
      let pages = [];
      try { pages = (await native("clients.pages", [])) || []; } catch (e) {}
      const listed = new Set(found.map((c) => c.url));
      return found.concat(pages.filter((p) => p && typeof p.url === "string" && !listed.has(p.url)).map(client));
    });
    clientsChannel.onmessage = ({ data }) => {
      if (!data || answered(data) || typeof data.from !== "string") return;
      root.dispatchEvent(messageFrom(client({ id: data.from, url: data.from }), data.data, data.ports));
    };
  } else if (clientsChannel && !background && typeof navigator !== "undefined" && navigator.serviceWorker) {
    const container = navigator.serviceWorker;
    const script = (() => { try { return (runtime.getManifest().background || {}).service_worker; } catch (e) { return null; } })();
    const controller = script && !container.controller ? {
      scriptURL: new URL(script, location.origin + "/").href, state: "activated", onstatechange: null, onerror: null,
      postMessage: (data, transfer) => { try { clientsChannel.postMessage({ from: location.href, data, ports: handOver(transfer) }); } catch (e) {} },
      addEventListener: () => {}, removeEventListener: () => {}, dispatchEvent: () => true,
    } : null;
    clientsChannel.onmessage = ({ data }) => {
      if (!data || answered(data) || data.url !== location.href) return;
      try { container.dispatchEvent(messageFrom(controller, data.data, data.ports)); } catch (e) {}
    };
    // Only the controller: `ready` is left as WebKit has it, since a
    // made-up registration has none of a real one's methods
    // (showNotification…), and a page calling them would throw where it
    // used to wait.
    if (controller) {
      kept.add(container);
      try { Object.defineProperty(container, "controller", { configurable: true, get: () => controller }); } catch (e) {}
    }
  }
  // WebKit runs an extension's worker on its web process's main thread,
  // and a worker's WebSocket waits there for the main thread to set up
  // its channel — for itself, for ever: the worker and every page of the
  // extension freeze. 1Password opens one as a sign-in succeeds. So a
  // worker's socket is made by the browser (ExtensionSocket.swift) and
  // its frames come and go over a native port.
  if (worker && typeof root.WebSocket === "function" && runtime && typeof runtime.connectNative === "function") {
    const connectNative = runtime.connectNative.bind(runtime);
    const encode = (bytes) => { let s = ""; for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000)); return btoa(s); };
    const decode = (text) => { const s = atob(text), bytes = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) bytes[i] = s.charCodeAt(i); return bytes.buffer; };
    const states = { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 };
    class WebSocket extends EventTarget {
      #port; #state = 0; #queue = Promise.resolve(); #origin; #hello;
      constructor(url, protocols) {
        super();
        let parsed;
        try { parsed = new URL(url, location.href); } catch (e) { throw new DOMException("The URL '" + url + "' is invalid.", "SyntaxError"); }
        if (parsed.protocol === "http:") parsed.protocol = "ws:";
        if (parsed.protocol === "https:") parsed.protocol = "wss:";
        if (!/^wss?:$/.test(parsed.protocol) || parsed.hash) throw new DOMException("The URL '" + url + "' is invalid.", "SyntaxError");
        const list = protocols === undefined ? [] : (Array.isArray(protocols) ? protocols : [protocols]).map(String);
        Object.defineProperty(this, "url", { value: parsed.href, enumerable: true });
        this.#origin = parsed.origin;
        this.protocol = ""; this.extensions = ""; this.binaryType = "blob"; this.bufferedAmount = 0;
        this.onopen = null; this.onmessage = null; this.onerror = null; this.onclose = null;
        this.#hello = { open: this.url, protocols: list, userAgent: navigator.userAgent };
        this.#connect();
      }
      // WebKit drops what a worker posts on a port it has only just
      // opened, without a word either way. So the opening is said again,
      // on the same port, until the browser answers anything at all.
      #connect() {
        const port = connectNative("kea.socket");
        let ready = false, tries = 0;
        this.#port = port;
        const again = () => {
          if (ready || this.#state === 3) return;
          if (tries++ >= 20) { this.#fire("error"); this.#closed(1006, "", false); return; }
          try { port.postMessage(this.#hello); } catch (e) {}
          setTimeout(again, 100 * Math.min(tries, 5));
        };
        port.onMessage.addListener((m) => {
          if (!ready) ready = true;
          if (m && m.ready === true) return;
          this.#take(m);
        });
        port.onDisconnect.addListener(() => {
          if (this.#state === 3) return;
          this.#fire("error");
          this.#closed(1006, "", false);
        });
        again();
      }
      get readyState() { return this.#state; }
      #fire(type, init) {
        let event;
        if (type === "message") event = new MessageEvent("message", init);
        else if (type === "close" && typeof CloseEvent === "function") event = new CloseEvent("close", init);
        else { event = new Event(type); if (init) for (const k in init) Object.defineProperty(event, k, { value: init[k] }); }
        const handler = this["on" + type];
        if (typeof handler === "function") { try { handler.call(this, event); } catch (e) { setTimeout(() => { throw e; }); } }
        this.dispatchEvent(event);
      }
      #closed(code, reason, wasClean) {
        this.#state = 3;
        try { this.#port.disconnect(); } catch (e) {}
        this.#fire("close", { code, reason, wasClean });
      }
      #take(m) {
        if (!m || this.#state === 3) return;
        if ("opened" in m) { this.protocol = m.opened; this.#state = 1; this.#fire("open"); }
        else if ("text" in m) this.#fire("message", { data: m.text, origin: this.#origin });
        else if ("binary" in m) {
          const buffer = decode(m.binary);
          this.#fire("message", { data: this.binaryType === "arraybuffer" ? buffer : new Blob([buffer]), origin: this.#origin });
        }
        else if ("failed" in m) this.#fire("error");
        else if ("closed" in m) this.#closed(m.closed, m.reason || "", !!m.clean);
      }
      send(data) {
        if (this.#state === 0) throw new DOMException("WebSocket is still in CONNECTING state.", "InvalidStateError");
        if (this.#state !== 1) return;
        const post = (message) => { try { this.#port.postMessage(message); } catch (e) {} };
        if (typeof data === "string") { this.#queue = this.#queue.then(() => post({ send: data })); return; }
        const bytes = data instanceof ArrayBuffer ? Promise.resolve(new Uint8Array(data))
          : ArrayBuffer.isView(data) ? Promise.resolve(new Uint8Array(data.buffer, data.byteOffset, data.byteLength))
          : data instanceof Blob ? data.arrayBuffer().then((b) => new Uint8Array(b))
          : Promise.resolve(null);
        this.#queue = this.#queue.then(() => bytes).then((b) => b ? post({ sendBinary: encode(b) }) : post({ send: String(data) }));
      }
      close(code, reason) {
        if (code !== undefined && code !== 1000 && !(code >= 3000 && code <= 4999)) {
          throw new DOMException("The close code must be either 1000, or between 3000 and 4999. " + code + " is neither.", "InvalidAccessError");
        }
        if (this.#state >= 2) return;
        this.#state = 2;
        const message = { close: code === undefined ? 1000 : code, reason: reason === undefined ? "" : String(reason) };
        this.#queue = this.#queue.then(() => { try { this.#port.postMessage(message); } catch (e) {} });
      }
    }
    for (const [k, v] of Object.entries(states)) { Object.defineProperty(WebSocket, k, { value: v }); Object.defineProperty(WebSocket.prototype, k, { value: v }); }
    Object.defineProperty(root, "WebSocket", { value: WebSocket, configurable: true, writable: true });
  }
  // The same loss meets a worker's port to an app on the Mac: what it
  // posts in its first moments never reaches the app, and comes back to
  // the worker's own listeners instead. iCloud Passwords says hello to
  // its helper that way, and without the helper's answer asks for the
  // code again and again. So on such a port, what the extension posts
  // is held from its first message until the browser says the port has
  // arrived — asked on the same port, as the socket asks — and then sent
  // in order. WebKit won't let connectNative be replaced in a worker, so
  // this is done on what every port shares, found through a port to the
  // browser itself; the question and the answer are kept from the
  // extension's listeners, and never reach the app.
  if (worker && runtime && typeof runtime.connectNative === "function") {
    let found = null;
    try { found = runtime.connectNative("kea"); found.disconnect(); } catch (e) {}
    const portProto = found && Object.getPrototypeOf(found);
    const eventProto = found && found.onMessage && Object.getPrototypeOf(found.onMessage);
    if (portProto && eventProto && typeof portProto.postMessage === "function" && typeof eventProto.addListener === "function") {
      // Ports that go to the extension's own pages or tabs, not an app.
      const toPages = new WeakSet();
      for (const [space, name] of [[runtime, "connect"], [chrome.tabs, "connect"]]) {
        const connect = space && space[name];
        if (typeof connect !== "function") continue;
        put(space, name, (...args) => { const port = connect.apply(space, args); try { toPages.add(port); } catch (e) {} return port; });
      }
      const post = portProto.postMessage, add = eventProto.addListener, remove = eventProto.removeListener, has = eventProto.hasListener;
      const ours = (m) => !!m && typeof m === "object" && "__keaNative" in m;
      // Ports seen, each with what waits to be sent (null once it may go).
      const ports = new WeakMap();
      const start = (port) => {
        const state = { held: [] };
        let tries = 0;
        const flush = () => { const list = state.held; state.held = null; for (const m of list || []) post.call(port, m); };
        const again = () => {
          if (!state.held) return;
          // Unanswered, they go anyway: no worse than before.
          if (tries++ >= 20) { flush(); return; }
          try { post.call(port, { __keaNative: "here?" }); } catch (e) {}
          setTimeout(again, 100 * Math.min(tries, 5));
        };
        add.call(port.onMessage, (m) => {
          if (m && m.__keaNative === "here" && state.held) flush();
          // WebKit keeps a worker only while it has posted on an open
          // port in the last two minutes; what arrives on one doesn't
          // count. The browser's word now and then is answered on the
          // port, so a worker holding a port to an app stays, as in
          // Chrome — iCloud Passwords otherwise forgets it was paired.
          if (m && m.__keaNative === "alive") { try { post.call(port, { __keaNative: "beat" }); } catch (e) {} }
        });
        add.call(port.onDisconnect, () => { state.held = null; });
        again();
        return state;
      };
      put(portProto, "postMessage", function (message) {
        let state = ports.get(this);
        if (!state) {
          const native = !toPages.has(this) && this.sender == null && typeof this.name === "string" && !/^kea(\.|$)/.test(this.name);
          state = native ? start(this) : { held: null };
          ports.set(this, state);
        }
        if (state.held) { state.held.push(message); return; }
        return post.call(this, message);
      });
      // A port's listeners, and only a port's (the namespaces' own
      // events are kept as they are), each behind one that lets the
      // question and the answer pass by.
      const wrapped = new WeakMap();
      const wrapper = (event, f, make) => {
        let byEvent = wrapped.get(event);
        if (!byEvent) { byEvent = new Map(); if (make) wrapped.set(event, byEvent); }
        let w = byEvent.get(f);
        if (!w && make) { w = function (m, ...rest) { if (ours(m)) return; return f.call(this, m, ...rest); }; byEvent.set(f, w); }
        return w;
      };
      put(eventProto, "addListener", function (f) {
        if (kept.has(this) || typeof f !== "function") return add.call(this, f);
        return add.call(this, wrapper(this, f, true));
      });
      put(eventProto, "removeListener", function (f) {
        const w = !kept.has(this) && typeof f === "function" && wrapper(this, f, false);
        if (!w) return remove.call(this, f);
        wrapped.get(this).delete(f);
        return remove.call(this, w);
      });
      put(eventProto, "hasListener", function (f) {
        const w = !kept.has(this) && typeof f === "function" && wrapper(this, f, false);
        return has.call(this, w || f);
      });
    }
  }
  // WebKit gives a worker the user agent of the last web page that set
  // one — Safari's, as Kea's tabs send — not the Chrome one the
  // extension's pages have. Code that picks its path by it then takes
  // the Safari one: Bitwarden's asks a Safari app for a reply thousands
  // of times a second and floods the browser.
  // Its pages too: an extension reads navigator.userAgent to pick a code
  // path, a download, a welcome page, and finds nothing it knows in
  // Safari's. (Not WebKit's setting: see Extensions.init.)
  if (!inContent && typeof navigator !== "undefined" && !/ Chrome\//.test(navigator.userAgent)) {
    const chromeUA = navigator.userAgent.replace(/ Version\/[\d.]+.*$/, "").replace(/ Safari\/[\d.]+$/, "") + " Chrome/__KEA_CHROME__ Safari/537.36";
    const proto = typeof WorkerNavigator !== "undefined" && worker ? WorkerNavigator.prototype : typeof Navigator !== "undefined" ? Navigator.prototype : null;
    try {
      if (proto) {
        Object.defineProperty(proto, "userAgent", { get: () => chromeUA, configurable: true });
        Object.defineProperty(proto, "appVersion", { get: () => chromeUA.replace(/^Mozilla\//, ""), configurable: true });
        Object.defineProperty(proto, "vendor", { get: () => "Google Inc.", configurable: true });
        if (!("userAgentData" in navigator)) {
          const major = "__KEA_CHROME__".split(".")[0];
          const brands = [{ brand: "Chromium", version: major }, { brand: "Google Chrome", version: major }, { brand: "Not.A/Brand", version: "99" }];
          const low = { brands, mobile: false, platform: "macOS" };
          const mac = (chromeUA.match(/Mac OS X (\d+)[_.](\d+)(?:[_.](\d+))?/) || []).slice(1).map((n) => n || "0").join(".") || "10.15.7";
          const high = {
            architecture: "arm", bitness: "64", model: "", platformVersion: mac, wow64: false,
            fullVersionList: brands.map((b) => ({ brand: b.brand, version: b.version === major ? "__KEA_CHROME__" : b.version + ".0.0.0" })),
            uaFullVersion: "__KEA_CHROME__",
          };
          const pick = (hints) => Object.assign({}, low, ...(Array.isArray(hints) ? hints : []).filter((h) => h in high).map((h) => ({ [h]: high[h] })));
          const data = Object.assign({}, low, { getHighEntropyValues: (hints) => Promise.resolve(pick(hints)), toJSON: () => low });
          Object.defineProperty(proto, "userAgentData", { get: () => data, configurable: true });
        }
      }
    } catch (e) {}
  }
  if (worker && typeof root.importScripts === "function") {
    const shipped = new Set(), empty = new Set();
    for (const p of __KEA_SCRIPTS__) p.startsWith("-") ? empty.add(p.slice(1)) : shipped.add(p);
    const load = root.importScripts.bind(root);
    root.importScripts = (...urls) => {
      const wanted = [];
      for (const u of urls) {
        let url; try { url = new URL(u, location.href); } catch (e) { wanted.push(u); continue; }
        const path = decodeURIComponent(url.pathname);
        if (url.origin === location.origin && empty.has(path)) continue;
        if (url.origin === location.origin && !shipped.has(path)) {
          throw new DOMException("Failed to execute 'importScripts' on 'WorkerGlobalScope': The script at '" + url.href + "' failed to load.", "NetworkError");
        }
        wanted.push(u);
      }
      if (wanted.length) return load(...wanted);
    };
  }
  // The tab an extension's framed page is in, asked once (see __keaToFrame).
  let ownTab = null;
  // Who has something to say about a message, told between the
  // extension's worker and its own pages on a channel they share (one
  // origin): each says, as soon as its listeners have run, whether it
  // answers or lets the message pass, and the sender says so of what
  // it sends. A page with nothing to say can then stay silent only
  // as long as someone else may still answer (see the end of `dispatch`).
  // A page in a website's frame is on the website's side of the
  // channel and takes no part; it waits, as before.
  const channel = !inContent && !embedded && typeof BroadcastChannel === "function" ? new BroadcastChannel("kea-messages") : null;
  const me = Math.random().toString(36).slice(2);
  const peers = new Set();
  const verdicts = new Map();
  const waiting = new Set();
  const present = new Set();
  // Pages that are there but didn't hear the last message sent to all —
  // WebKit doesn't bring every message to every page. Not waited for
  // until they say something about one they heard.
  const deaf = new Set();
  const keyOf = (message) => { try { const k = JSON.stringify(message); return k && k.length < 4000 ? k : null; } catch (e) { return null; } };
  const tell = (message, verdict, heard) => {
    const key = channel && keyOf(message);
    if (key) channel.postMessage({ key, from: background ? "worker" : me, verdict, heard, at: Date.now() });
  };
  // WebKit hands none of the extension's pages a message its worker or another of its pages sent, and Bitwarden's
  // sync and passkey window wait on those. so each one also goes over the channel, and a page that didn't hear it
  // from WebKit takes it from there.
  // Each message's copies are paired by count, keyed on all of it, and
  // only with what the extension's own pages and worker sent: one WebKit
  // delivered cancels one relayed copy still to come, and one relayed
  // cancels a late one from WebKit. A content script's message, however
  // alike, is never taken for one, and an unpaired copy is forgotten
  // after a few seconds (Security).
  const relayKey = (message) => {
    try { const text = JSON.stringify(message); return text === undefined ? null : text; } catch (e) { return null; }
  };
  const ownPlace = (() => { try { return runtime.getURL(""); } catch (e) { return ""; } })();
  const fromOwnPages = (sender) => !!sender && sender.id === runtime.id && typeof sender.url === "string" && !!ownPlace
    && (sender.url + "/").startsWith(ownPlace.replace(/\/$/, "") + "/");
  const heardNatively = new Map(), heardRelayed = new Map();
  const count = (map, key, by) => {
    const now = Date.now();
    for (const [k, v] of map) if (now - v.at > 5000) map.delete(k);
    const n = ((map.get(key) || {}).n || 0) + by;
    if (n > 0) { if (map.size > 200) map.clear(); map.set(key, { n, at: now }); } else map.delete(key);
  };
  const pending = (map, key) => { const v = map.get(key); return !!v && Date.now() - v.at <= 5000 && v.n > 0; };
  let deliverRelayed = null, relaying = false;
  const relay = (message) => { if (channel && !inContent) try { channel.postMessage({ relay: message, from: me, url: location.href }); } catch (e) {} };
  if (channel) {
    channel.onmessage = ({ data }) => {
      if (!data || data.from === me) return;
      if (data.relay !== undefined) {
        const key = relayKey(data.relay);
        if (!background && deliverRelayed) setTimeout(() => {
          if (key && pending(heardNatively, key)) { count(heardNatively, key, -1); return; }
          if (key) count(heardRelayed, key, 1);
          relaying = true;
          try { deliverRelayed(data.relay, { id: runtime.id, url: data.url, origin: location.origin }); } finally { relaying = false; }
        }, 50);
        return;
      }
      // The pages that listen, as they come and go.
      if (!background && data.hello) {
        const known = peers.has(data.from);
        peers.add(data.from);
        if (!known && listening) channel.postMessage({ hello: true, from: me, where: location.pathname });
        return;
      }
      if (data.bye) { peers.delete(data.from); waiting.forEach((check) => check()); return; }
      // A popup that closes is thrown away without a word; so a page
      // left waiting asks who is still there.
