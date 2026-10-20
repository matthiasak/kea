      if (data.roll) { if (listening && !background) channel.postMessage({ here: true, from: me, to: data.from }); return; }
      if (data.here) { if (data.to === me) present.forEach((hear) => hear(data.from)); return; }
      if (typeof data.key !== "string") return;
      const now = Date.now();
      for (const [k, v] of verdicts) { if (now - v.at > 30000) verdicts.delete(k); else break; }
      const entry = verdicts.get(data.key) || { at: now, worker: null, pages: new Map() };
      verdicts.delete(data.key);
      verdicts.set(data.key, entry);
      entry.at = now;
      if (data.from === "worker") entry.worker = data;
      else { peers.add(data.from); if (data.heard) deaf.delete(data.from); entry.pages.set(data.from, data); }
      waiting.forEach((check) => check());
    };
    if (!background) try { root.addEventListener("pagehide", () => leave()); } catch (e) {}
  }
  // Only a page that listens for messages is waited for: one that
  // doesn't never hears them, so never says anything about them.
  let listening = false;
  const join = () => { if (channel && !background && !listening) { listening = true; channel.postMessage({ hello: true, from: me, where: location.pathname }); } };
  const leave = () => { if (channel && !background && listening) { listening = false; channel.postMessage({ bye: true, from: me }); } };
  // Who sent a message from the extension's popup, as Chrome says it:
  // no tab. WebKit only carries a page's messages when it can name the
  // tab the page is in, so the popup is one (see PopupPage) — a tab at
  // no place in the window's row (its index comes as NaN), its own
  // page at the top. Passbolt's worker takes a port that comes with a
  // tab for one of its frames in a website, and turned its popup's
  // away: the popup stayed empty.
  const untabbed = (sender) => {
    const tab = sender && sender.tab;
    if (!tab || tab.index >= 0 || sender.frameId || tab.url !== sender.url
      || !runtime || !String(sender.url).startsWith(runtime.getURL(""))) return sender;
    const plain = { ...sender };
    delete plain.tab;
    return plain;
  };
  const gather = (event, told) => {
    if (!event || typeof event.addListener !== "function") return;
    const add = event.addListener.bind(event);
    const remove = event.removeListener.bind(event);
    const internalMessages = event === runtime.onMessage;
    const relayHost = internalMessages && offscreenCapable && !hasWorker;
    const listeners = new Set();
    let attached = false;
    const dispatch = function (message, sender, respond, local = false) {
      if (!local && !background && !relaying && fromOwnPages(sender)) {
        const k = relayKey(message);
        if (k && pending(heardRelayed, k)) { count(heardRelayed, k, -1); return; }
        if (k) count(heardNatively, k, 1);
      }
      let settled = false, keep = false;
      const sendResponse = (value) => { if (!settled) { settled = true; respond(value); } };
      // WebKit excludes the sender's whole page from runtime delivery,
      // so an offscreen iframe cannot reach its parent directly. Another
      // context of the same extension carries that delivery to the browser.
      if (!local && message && message.__keaOffscreenRelay === true && sender.id === runtime.id) {
        native("offscreen.sendMessage", [message.token, message.message, sender])
          .then(sendResponse, (error) => sendResponse({ relayError: String(error) }));
        return true;
      }
      // Only the worker answers; any other page stays out of it.
      if (message && message.__keaPing === true) {
        if (background) { sendResponse("pong"); return; }
        return true;
      }
      // Kea's own envelopes come from this extension only: another
      // extension (onMessageExternal) could otherwise speak as one of its
      // user scripts, or as a frame of its own.
      const fromHere = !!(sender && sender.id === runtime.id);
      if (message && (message.__keaUserScript === true || message.__keaToFrame) && !fromHere) return;
      if (message && message.__keaUserScript === true) {
        const route = root.__keaUserScriptMessage;
        return route && route(message.message, sender, sendResponse) && !settled ? true : undefined;
      }
      // A tab's message, handed on by the worker (see alsoFramed): taken
      // by the frame it names, in the tab it names; every other page lets
      // it pass without answering, as it would a message not for it.
      if (message && message.__keaToFrame) {
        const to = message.__keaToFrame;
        if (!embedded || !(to.urls || []).includes(location.href)) {
          if (!background) setTimeout(() => sendResponse(undefined), 10000);
          return background ? undefined : true;
        }
        if (!ownTab) ownTab = Promise.resolve(runtime.sendMessage({ __keaCall: { space: "tabs", method: "getCurrent", args: [] } }))
          .then((reply) => reply && reply.value ? reply.value.id : null, () => null);
        ownTab.then((id) => {
          if (id !== to.tabId) return setTimeout(() => sendResponse(undefined), 10000);
          let kept = false;
          for (const listener of [...listeners]) {
            let result;
            try { result = listener(to.message, sender, sendResponse); } catch (e) { setTimeout(() => { throw e; }); continue; }
            if (result === true) kept = true;
            else if (result && typeof result.then === "function") { kept = true; result.then(sendResponse, () => sendResponse(undefined)); }
          }
          if (!kept) sendResponse(undefined);
        });
        return true;
      }
      // A call one of the extension's pages in a website's frame can't
      // make itself (see `embedded`), made here for it — and only for
      // one of its pages: a content script gets no more than Chrome
      // gives it.
      if (message && message.__keaCall) {
        if (!background) return true;
        const { space, method, args } = message.__keaCall;
        const own = (() => { try { return new URL(sender.url).origin === location.origin; } catch (e) { return false; } })();
        if (!own) { sendResponse({ error: "chrome." + space + " isn't available to content scripts" }); return; }
        if (space === "tabs" && method === "getCurrent") { sendResponse({ value: sender.tab }); return; }
        let ns; try { ns = chrome[space]; } catch (e) {}
        if (!ns || typeof ns[method] !== "function") { sendResponse({ error: "chrome." + space + "." + method + " isn't available" }); return; }
        Promise.resolve().then(async () => {
          if (space === "scripting" && method === "executeScript" && typeof args?.[0]?.__keaFunction === "string") {
            const { __keaFunction, args: functionArgs, ...details } = args[0];
            if (details.files) throw new Error("Cannot specify both 'func' and 'files'");
            const file = await native("scripting.file", [__keaFunction, functionArgs || []]);
            return ns[method]({ ...details, files: [file] });
          }
          return ns[method](...(args || []));
        })
          .then((value) => sendResponse({ value }), (e) => sendResponse({ error: String(e && e.message || e) }));
        return true;
      }
      sender = untabbed(sender);
      for (const listener of [...listeners]) {
        let result;
        try { result = listener(message, sender, sendResponse); } catch (e) { setTimeout(() => { throw e; }); continue; }
        if (result === true) keep = true;
        else if (result && typeof result.then === "function") { keep = true; result.then(sendResponse, () => sendResponse(undefined)); }
      }
      if (!local && !inContent) tell(message, keep || settled ? "answers" : "passes", true);
      if (keep || settled) return keep && !settled ? true : undefined;
      // A direct offscreen delivery has no other local receiver to wait for.
      if (local) return undefined;
      // Nothing here answers it. In Chrome that leaves the question to
      // the extension's other pages and its worker; WebKit takes the
      // first reply from any of them, and an empty one from a page that
      // only listens for something else — an offscreen document, an
      // options page — would arrive before the worker's real answer. So
      // a page that has nothing to say steps aside, and says nothing
      // only once everyone else has had ample time — or as soon as the
      // worker and every other open page have said they let it pass too,
      // or the worker sent it itself. Bitwarden's offscreen document
      // keeps its storage and answers a save with nothing: ten seconds
      // on each one got in the way of signing in.
      if (!background && !inContent) {
        const received = Date.now();
        const key = channel && keyOf(message);
        let check = () => {}, roll = null;
        const done = () => { waiting.delete(check); clearTimeout(late); clearTimeout(roll); };
        const late = setTimeout(() => { done(); sendResponse(undefined); }, 10000);
        if (key) {
          // Only what was said about this message, not an identical one
          // a while ago.
          const fresh = (said) => said && said.at >= received - 2000;
          check = () => {
            const entry = verdicts.get(key);
            if (settled || !entry) return;
            const worker = entry.worker;
            if (fresh(worker) && worker.verdict === "answers") { done(); return; }
            const said = [...peers].filter((id) => !deaf.has(id) || entry.pages.has(id)).map((id) => entry.pages.get(id));
            if (said.some((p) => fresh(p) && p.verdict === "answers")) { done(); return; }
            if (!fresh(worker) || said.some((p) => !fresh(p))) return;
            done();
            sendResponse(undefined);
          };
          waiting.add(check);
          check();
          // Still waiting on someone after a moment: those who don't say
          // they are here within a second are gone, and those who do but
          // still have said nothing about this message didn't hear it.
          roll = setTimeout(() => {
            if (settled) return;
            const heard = new Set();
            const hear = (id) => heard.add(id);
            present.add(hear);
            channel.postMessage({ roll: true, from: me });
            setTimeout(() => {
              present.delete(hear);
              for (const id of [...peers]) if (!heard.has(id)) peers.delete(id);
              const entry = verdicts.get(key);
              for (const id of peers) { const p = entry && entry.pages.get(id); if (!p || p.at < received - 2000) deaf.add(id); }
              check();
            }, 1000);
          }, 200);
        }
        return true;
      }
      return undefined;
    };
    if (internalMessages) {
      put(root, "__keaOffscreenDispatch", (message, sender) => new Promise((resolve) => {
        const timer = setTimeout(() => resolve({ handled: false }), 30000);
        const done = (result) => { clearTimeout(timer); resolve(result); };
        const waiting = dispatch(message, sender, (value) => done({ handled: true, value }), true);
        if (waiting !== true) done({ handled: false });
      }));
    }
    put(event, "addListener", (listener) => {
      listeners.add(listener);
      if (told) { join(); deliverRelayed = (m, s) => dispatch(m, s, () => {}); }
      if (!attached) { attached = true; add(dispatch); }
    });
    put(event, "removeListener", (listener) => {
      listeners.delete(listener);
      if (told && listeners.size === 0 && !relayHost) leave();
      if (attached && listeners.size === 0 && !(internalMessages && (background || relayHost))) {
        attached = false; remove(dispatch);
      }
    });
    put(event, "hasListener", (listener) => listeners.has(listener));
    put(event, "hasListeners", () => listeners.size > 0);
    // A worker may only add listeners while it starts; one that adds its
    // first later would be refused. So in a worker the one listener is
    // WebKit's from the start.
    if (background || relayHost) { attached = true; add(dispatch); if (told) join(); }
  };
  // kea:content-skip-end
  if (runtime) {
    const names = new Set();
    for (let o = runtime; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) Object.getOwnPropertyNames(o).forEach((k) => names.add(k));
    for (const name of names) {
      if (name === "constructor" || /^on[A-Z]/.test(name)) continue;
      let f; try { f = runtime[name]; } catch (e) { continue; }
      if (typeof f === "function") put(runtime, name, f.bind(runtime));
    }
  }
  if (inContent) {
    // A frame inside this extension's own page — its offscreen
    // document reading a site, say — is part of that page's tab, and
    // WebKit brings none of its messages to the page around it. So a
    // copy goes by way of another of the extension's contexts, which
    // hands it to the page (see offscreen.sendMessage). Only there: in a
    // frame of a website, the page above is the website's, and a second
    // send would only cost every message a round trip (#192).
    const insideOwnPage = (() => {
      try {
        const above = location.ancestorOrigins;
        return window !== window.top && !!above && above.length > 0 && above[above.length - 1] + "/" === runtime.getURL("");
      } catch (e) { return false; }
    })();
    if (offscreenCapable && insideOwnPage && runtime && typeof runtime.sendMessage === "function") {
      const send = runtime.sendMessage.bind(runtime);
      let sequence = 0;
      const prefix = Array.from(crypto.getRandomValues(new Uint32Array(4)), (n) => n.toString(16)).join("-");
      put(runtime, "sendMessage", (...args) => {
        const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
        const options = args[1];
        const isOptions = options == null || (typeof options === "object" && !Array.isArray(options)
          && Object.keys(options).every((key) => key === "includeTlsChannelId"));
        const explicit = args.length >= 3 || (args.length === 2 && typeof args[0] === "string" && !isOptions);
        const own = !explicit || !args[0] || args[0] === runtime.id;
        const original = send(...args);
        let answer = original;
        if (own && args.length) {
          const relay = send({ __keaOffscreenRelay: true, token: prefix + ":" + (++sequence),
            message: args[explicit ? 1 : 0] }).then((reply) => {
              if (reply && reply.relayError) throw new Error(reply.relayError);
              return reply && reply.handled ? reply.value : undefined;
            });
          // An empty native reply must not beat the parent document's
          // reply. Preserve the first actual response from either route.
          answer = new Promise((resolve, reject) => {
            let left = 2, failure;
            const done = (value) => {
              if (value !== undefined) resolve(value);
              if (--left === 0) failure ? reject(failure) : resolve(undefined);
            };
            for (const response of [original, relay]) response.then(done, (error) => { failure = error; done(); });
          });
        }
        if (!callback) return answer;
        answer.then(callback, (error) => withLastError(error, callback));
      });
    }
    return;
  }
  // kea:content-end

  // In a website's frame, everything WebKit keeps to the extension's own
  // process goes through the worker instead. What stays direct is what
  // WebKit lets a content script call too. Namespaces the shim adds
  // itself further down answer through the browser, which is allowed.
  if (embedded) {
    const direct = new Set(["runtime", "storage", "i18n", "extension", "permissions", "dom", "test"]);
    const ask = (space, method, args) => {
      while (args.length && args[args.length - 1] === undefined) args.pop();
      // A function cannot cross the message channel. Keep its source
      // separately so the worker can inject it from an extension file.
      if (space === "scripting" && method === "executeScript" && typeof (args[0] && args[0].func) === "function") {
        args = [{ ...args[0], func: undefined, __keaFunction: args[0].func.toString() }, ...args.slice(1)];
      }
      let payload;
      try { payload = JSON.parse(JSON.stringify(args)); } catch (e) { return Promise.reject(e); }
      return Promise.resolve(chrome.runtime.sendMessage({ __keaCall: { space, method, args: payload } })).then((reply) => {
        if (!reply) throw new Error("chrome." + space + "." + method + " had no answer from the extension's background");
        if (reply.error) throw new Error(reply.error);
        return reply.value;
      });
    };
    for (const space of spaces) {
      if (direct.has(space)) continue;
      let ns; try { ns = chrome[space]; } catch (e) { continue; }
      if (!ns || typeof ns !== "object") continue;
      const names = new Set();
      for (let o = ns; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) Object.getOwnPropertyNames(o).forEach((k) => names.add(k));
      for (const name of names) {
        if (name === "constructor" || /^on[A-Z]/.test(name)) continue;
        let f; try { f = ns[name]; } catch (e) { continue; }
        if (typeof f !== "function") continue;
        // A port can't be carried over: one that closes at once, as
        // Chrome's does when nothing answers, rather than a dead process.
        if (name === "connect") {
          put(ns, name, (...args) => {
            const port = { name: (args.find((a) => a && typeof a === "object") || {}).name || "", sender: undefined,
              postMessage: () => {}, disconnect: () => {}, onMessage: event(), onDisconnect: event() };
            setTimeout(() => {
              put(runtime, "lastError", { message: "Could not establish connection. Receiving end does not exist." });
              try { for (const f of [...port.onDisconnect.listeners]) f(port); } finally { try { delete runtime.lastError; } catch (e) {} }
            });
            return port;
          });
          continue;
        }
        put(ns, name, (...args) => {
          const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
          const answer = ask(space, name, args);
          if (!callback) return answer;
          answer.then((value) => callback(value), (error) => withLastError(error, callback));
        });
      }
    }
  }

  // WebKit unloads an extension's worker after half a minute idle, and
  // starts it again for an event only if it remembers a listener for
  // it — which it does for messages, the worker's listener being in
  // place from its first line (see gather).
  //
  // A reply that never came is answered Chrome's way: in callback
  // form, with lastError set — WebKit calls back with nothing and no
  // error, and code that pings a tab to see if its script is there
  // waits for ever.
  const replied = (promise, callback, gone) => {
    if (typeof callback !== "function") return promise;
    promise.then((r) => r === undefined ? withLastError(new Error(gone), callback) : callback(r),
      (e) => withLastError(e, callback));
  };
  let checkWorker = () => {};
  // When the worker was last heard from — a reply, a port message.
  let heard = 0;
  if (runtime && typeof runtime.sendMessage === "function") {
    const page = typeof document !== "undefined";
    // WebKit's own, looked up at each call — not held from the page's
    // first moment, when the page isn't yet the tab or popup it will be.
    const original = Object.getPrototypeOf(runtime).sendMessage;
    const send = (...args) => original.apply(chrome.runtime, args);
    // WebKit can also lose a worker without knowing — its process
    // stopped along with a tab's — and then answers every message with
    // nothing, for good. So after waking it, a page asks the worker
    // itself (its shim answers) at most every few seconds; no answer,
    // and the browser takes the extension up afresh.
    // The message itself doesn't wait on the answer: a worker busy
    // starting up can take seconds. An empty reply means gone; silence
    // for a quarter of a minute does too.
    let asking = false;
    const check = () => {
      if (!hasWorker || asking || Date.now() - heard < 5000) return;
      asking = true;
      // Asked three times, a second apart, then once more after waking
      // it — only then taken for gone: a restart has consequences
      // (welcome pages, a popup loading again), and a question can go
      // unanswered for reasons that pass. Waking a worker that runs
      // starts it over, so that is kept for last.
      const ping = Object.getPrototypeOf(runtime).sendMessage;
      const ask = () => Promise.race([ping.call(runtime, { __keaPing: true }), new Promise((r) => setTimeout(() => r("late"), 15000))]).catch(() => undefined);
      const pause = (ms) => new Promise((w) => setTimeout(w, ms));
      const tries = [() => ask(), () => pause(1000).then(ask), () => pause(1000).then(ask),
        () => native("background.wake", []).catch(() => {}).then(() => pause(1000)).then(ask)];
      const attempt = (i, last) => i >= tries.length || last === "pong" ? Promise.resolve(last) : tries[i]().then((r) => attempt(i + 1, r));
      const started = Date.now();
      attempt(0).then((r) => {
        // Any real answer from the worker meanwhile says it runs, too:
        // the question alone can go unheard from a page that listens.
        if (r === "pong" || heard >= started) heard = Math.max(heard, Date.now());
        else {
          if (__KEA_VERBOSE__) native("debug.error", ["worker check: " + String(r) + " from " + location.pathname]).catch(() => {});
          native("background.revive", []).catch(() => {});
        }
      }).finally(() => { asking = false; });
    };
    checkWorker = page ? check : () => {};
    put(runtime, "sendMessage", (...args) => {
      const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
      // Never heard back by the one that sends it, so said for it.
      if (!inContent) tell(typeof args[0] === "string" && args.length > 1 && typeof args[1] !== "function" ? args[1] : args[0], "passes");
      checkWorker();
      const answer = send(...args).then((r) => { if (r !== undefined) heard = Date.now(); return r; });
      if (typeof args[0] !== "string" && !(args[0] && Object.keys(args[0]).some((k) => k.startsWith("__kea")))) relay(args[0]);
      return replied(answer, callback, "The message port closed before a response was received.");
    });
  }
  // A message for a tab reaches only its content scripts in WebKit. In
  // Chrome it reaches the extension's own pages framed in that tab too —
  // 1Password's sign-in banner is one, told this way to offer a passkey
  // instead of a password, and without it the site's request failed. So
  // the worker hands it to those frames as well, and the first answer
  // from either wins.
  const alsoFramed = (answer, tabId, message, options) => {
    const nav = chrome.webNavigation;
    if (!nav || typeof nav.getAllFrames !== "function" || typeof tabId !== "number") return answer;
    const own = runtime.getURL("");
    const wanted = options && typeof options.frameId === "number" ? options.frameId : null;
    const framed = Promise.resolve(nav.getAllFrames({ tabId })).then((frames) => {
      const urls = (frames || []).filter((f) => f.url && f.url.startsWith(own) && f.frameId !== 0 && (wanted === null || f.frameId === wanted)).map((f) => f.url);
      if (!urls.length) return undefined;
      return Object.getPrototypeOf(runtime).sendMessage.call(runtime, { __keaToFrame: { tabId, urls, message } });
    }, () => undefined);
    return new Promise((resolve, reject) => {
      let left = 2, failure = null;
      const none = () => { if (--left === 0) failure ? reject(failure) : resolve(undefined); };
      answer.then((v) => v !== undefined ? resolve(v) : none(), (e) => { failure = e; none(); });
      framed.then((v) => v !== undefined ? resolve(v) : none(), () => none());
    });
  };
  if (chrome.tabs && typeof chrome.tabs.sendMessage === "function") {
    const send = chrome.tabs.sendMessage.bind(chrome.tabs);
    put(chrome.tabs, "sendMessage", (tabId, message, options, callback) => {
      if (typeof options === "function") { callback = options; options = undefined; }
      const p = options === undefined ? send(tabId, message) : send(tabId, message, options);
      return replied(background ? alsoFramed(p, tabId, message, options) : p, callback, "Could not establish connection. Receiving end does not exist.");
    });
  }
  if (typeof document !== "undefined" && runtime && typeof runtime.connect === "function") {
    const connect = runtime.connect.bind(runtime);
    put(runtime, "connect", (...args) => {
      checkWorker();
      const port = connect(...args);
      try { port.onMessage.addListener(() => { heard = Date.now(); }); } catch (e) {}
      return port;
    });
  }

  gather(runtime && runtime.onMessage, true);
  gather(runtime && runtime.onMessageExternal);

  // Whole namespaces WebKit lacks, answered by the browser.
  const define = (name, methods, events = [], extra = {}) => {
    if (chrome[name]) return;
    const api = Object.assign({}, extra);
    for (const m of methods) api[m] = call(name + "." + m);
    for (const e of events) api[e] = event();
    put(chrome, name, api);
    if (root.browser && root.browser !== chrome && !root.browser[name]) put(root.browser, name, api);
  };
  define("bookmarks",
    ["get", "getChildren", "getRecent", "getSubTree", "getTree", "search", "create", "move", "update", "remove", "removeTree"],
    ["onCreated", "onRemoved", "onChanged", "onMoved", "onChildrenReordered", "onImportBegan", "onImportEnded"]);
  define("history",
    ["search", "getVisits", "addUrl", "deleteUrl", "deleteRange", "deleteAll"],
    ["onVisited", "onVisitRemoved"]);
  define("downloads",
    ["download", "search", "pause", "resume", "cancel", "open", "show", "showDefaultFolder", "erase", "removeFile", "getFileIcon"],
    ["onCreated", "onChanged", "onErased", "onDeterminingFilename"]);
  // A blob URL made in an extension worker belongs to that worker. The
  // page WebKit uses to perform downloads cannot read it. Hand WebKit a
  // data URL instead, then tell the extension when Kea has saved it.
  // SingleFile waits for downloads.onChanged before ending its save task.
  if (chrome.downloads?.onChanged?.listeners) {
    const downloads = chrome.downloads;
    const start = downloads.download;
    const search = downloads.search;
    put(downloads, "download", (options, ...rest) => {
      const callback = typeof rest[rest.length - 1] === "function" ? rest.pop() : null;
      const pending = (async () => {
        let request = options;
        if (typeof options?.url === "string" && options.url.startsWith("blob:")) {
          const blob = await (await fetch(options.url)).blob();
          // Held whole in the worker as it is turned into a data: address:
          // past half a gigabyte it is refused, not tried (Security).
          if (blob.size > 512 * 1024 * 1024) throw new Error("This file is too large to save from an extension's worker (over 512 MB).");
          const bytes = new Uint8Array(await blob.arrayBuffer());
          let binary = "";
          for (let i = 0; i < bytes.length; i += 8192) binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
          request = { ...options, url: "data:" + (blob.type || "application/octet-stream") + ";base64," + btoa(binary) };
        }
        const id = await start.call(downloads, request, ...rest);
        const deadline = Date.now() + 120000;
        const completed = async () => {
          try {
            const items = await search.call(downloads, { id });
            if (items?.some((item) => item.id === id && item.state === "complete" && item.exists)) {
              for (const listener of [...downloads.onChanged.listeners]) listener({ id, state: { current: "complete", previous: "in_progress" } });
              return;
            }
          } catch (e) {}
          if (Date.now() >= deadline) {
            for (const listener of [...downloads.onChanged.listeners]) listener({ id, state: { current: "interrupted", previous: "in_progress" }, error: { current: "NETWORK_FAILED" } });
            return;
          }
          setTimeout(completed, 250);
        };
        setTimeout(completed, 0);
        return id;
      })();
      if (!callback) return pending;
      pending.then((id) => callback(id), (error) => withLastError(error, callback));
    });
  }
  define("sidePanel", ["open", "setOptions", "getOptions", "setPanelBehavior", "getPanelBehavior"]);
  define("offscreen", ["createDocument", "closeDocument", "hasDocument"], [],
    { Reason: new Proxy({}, { get: (_, key) => String(key) }) });
  define("tabGroups", ["get", "query", "update", "move"],
    ["onCreated", "onRemoved", "onUpdated", "onMoved"], { TAB_GROUP_ID_NONE: -1,
      // Read as the worker starts: Claude's lists its colours in a class.
      Color: { GREY: "grey", BLUE: "blue", RED: "red", YELLOW: "yellow", GREEN: "green",
        PINK: "pink", PURPLE: "purple", CYAN: "cyan", ORANGE: "orange" } });
  // Groups change in Kea's hands, where no event reaches the
  // extension: while it listens, they are asked for every few seconds
  // and what changed is told as Chrome tells it — and at once after the
  // extension changes one itself.
  let groupsChanged = () => {};
  if (chrome.tabGroups && chrome.tabGroups.onCreated && chrome.tabGroups.onCreated.listeners) {
    const groups = chrome.tabGroups, told = ["onCreated", "onRemoved", "onUpdated"];
    let known = null, timer = null;
    // What an update changes; the order of the keys is the browser's.
    const shape = (g) => JSON.stringify([g.title, g.collapsed, g.color]);
    const tell = (name, group) => {
      for (const f of groups[name].listeners) try { f(group); } catch (e) { setTimeout(() => { throw e; }); }
    };
    groupsChanged = () => {
      if (!told.some((name) => groups[name].listeners.size)) return;
      native("tabGroups.query", [{}]).then((now) => {
        const next = new Map((now || []).map((g) => [g.id, g]));
        if (known) {
          for (const [id, g] of next) {
            if (!known.has(id)) tell("onCreated", g);
            else if (shape(known.get(id)) !== shape(g)) tell("onUpdated", g);
          }
          for (const [id, g] of known) if (!next.has(id)) tell("onRemoved", g);
        }
        known = next;
      }, () => {});
    };
    for (const name of told) {
      const add = groups[name].addListener;
      groups[name].addListener = (f) => {
        add(f);
        if (timer) return;
        groupsChanged();
        timer = setInterval(groupsChanged, 3000);
      };
    }
    put(groups, "update", (id, props, callback) => {
      if (typeof props === "function") { callback = props; props = {}; }
      const p = native("tabGroups.update", [id, props || {}]).then((g) => { groupsChanged(); return g; });
      if (typeof callback !== "function") return p;
      p.then((g) => callback(g), (e) => withLastError(e, callback));
    });
  }
  define("fontSettings",
    ["getFontList", "getFont", "setFont", "clearFont", "getDefaultFontSize", "setDefaultFontSize",
     "clearDefaultFontSize", "getDefaultFixedFontSize", "setDefaultFixedFontSize", "clearDefaultFixedFontSize",
     "getMinimumFontSize", "setMinimumFontSize", "clearMinimumFontSize"],
    ["onFontChanged", "onDefaultFontSizeChanged", "onDefaultFixedFontSizeChanged", "onMinimumFontSizeChanged"]);
  define("management", ["getSelf", "getAll", "get", "setEnabled", "uninstallSelf"],
    ["onInstalled", "onUninstalled", "onEnabled", "onDisabled"]);
  define("notifications", ["create", "update", "clear", "getAll", "getPermissionLevel"],
    ["onClicked", "onClosed", "onButtonClicked", "onPermissionLevelChanged", "onShowSettings"]);
  define("tts", ["speak", "stop", "pause", "resume", "isSpeaking", "getVoices"], ["onVoicesChanged"]);
  define("identity",
    ["launchWebAuthFlow", "getAuthToken", "getProfileUserInfo", "removeCachedAuthToken", "clearAllCachedAuthTokens"],
    ["onSignInChanged"],
    { getRedirectURL: (path = "") => "https://" + runtime.id + ".chromiumapp.org/" + String(path).replace(/^\//, "") });

  // Chrome's settings objects: get, set and clear, and an event.
  const setting = (name) => ({
    get: call("setting.get:" + name), set: call("setting.set:" + name),
    clear: call("setting.clear:" + name), onChange: event(),
  });
  const settings = (prefix, names) =>
    Object.fromEntries(names.map((n) => [n, setting(prefix + "." + n)]));
  const put2 = (name, api) => {
    if (chrome[name]) return;
    put(chrome, name, api);
    if (root.browser && root.browser !== chrome && !root.browser[name]) put(root.browser, name, api);
  };
  // Something only Chrome can do, answered the way Chrome answers when
  // it can't: a rejection, or lastError for a callback.
  const refuse = (what) => (...args) => {
    const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
    const error = new Error(what + " isn't available in Kea");
    if (!callback) return Promise.reject(error);
    withLastError(error, callback);
  };

  define("search", ["query"]);
  define("idle", ["queryState", "getAutoLockDelay"], [],
    { IdleState: { ACTIVE: "active", IDLE: "idle", LOCKED: "locked" } });
  if (chrome.idle && !chrome.idle.onStateChanged) {
    // Asked every so often while anyone listens, the way Chrome
    // notices on its own.
