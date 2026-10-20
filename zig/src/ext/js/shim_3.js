    const changed = event(), add = changed.addListener;
    let every = 60, state = "active", timer = null;
    changed.addListener = (f) => {
      add(f);
      if (timer) return;
      timer = setInterval(() => native("idle.queryState", [every]).then((now) => {
        if (now === state) return;
        state = now;
        for (const g of changed.listeners) try { g(now); } catch (e) { setTimeout(() => { throw e; }); }
      }).catch(() => {}), 15000);
    };
    put(chrome.idle, "onStateChanged", changed);
    put(chrome.idle, "setDetectionInterval", (seconds) => { every = Math.max(15, Number(seconds) || 60); });
  }
  define("power", ["requestKeepAwake", "releaseKeepAwake", "reportActivity"]);
  define("browsingData",
    ["remove", "removeAppcache", "removeCache", "removeCacheStorage", "removeCookies", "removeDownloads",
     "removeFileSystems", "removeFormData", "removeHistory", "removeIndexedDB", "removeLocalStorage",
     "removePasswords", "removeServiceWorkers", "removeWebSQL", "settings"]);
  define("sessions", ["getRecentlyClosed", "getDevices", "restore"], ["onChanged"], { MAX_SESSION_RESULTS: 25 });
  define("topSites", ["get"]);
  define("readingList", ["query", "addEntry", "removeEntry", "updateEntry"],
    ["onEntryAdded", "onEntryRemoved", "onEntryUpdated"]);
  put2("system", {
    cpu: { getInfo: call("system.cpu.getInfo") },
    memory: { getInfo: call("system.memory.getInfo") },
    storage: { getInfo: call("system.storage.getInfo"), ejectDevice: refuse("system.storage.ejectDevice"),
               getAvailableCapacity: refuse("system.storage.getAvailableCapacity"), onAttached: event(), onDetached: event() },
    display: { getInfo: call("system.display.getInfo"), onDisplayChanged: event() },
  });
  put2("privacy", {
    services: settings("privacy.services", ["alternateErrorPagesEnabled", "autofillAddressEnabled",
      "autofillCreditCardEnabled", "autofillEnabled", "passwordSavingEnabled", "safeBrowsingEnabled",
      "safeBrowsingExtendedReportingEnabled", "searchSuggestEnabled", "spellingServiceEnabled", "translationServiceEnabled"]),
    network: settings("privacy.network", ["networkPredictionEnabled", "webRTCIPHandlingPolicy"]),
    websites: settings("privacy.websites", ["adMeasurementEnabled", "doNotTrackEnabled", "fledgeEnabled",
      "hyperlinkAuditingEnabled", "protectedContentEnabled", "referrersEnabled", "relatedWebsiteSetsEnabled",
      "thirdPartyCookiesAllowed", "topicsEnabled"]),
    IPHandlingPolicy: { DEFAULT: "default", DEFAULT_PUBLIC_AND_PRIVATE_INTERFACES: "default_public_and_private_interfaces",
      DEFAULT_PUBLIC_INTERFACE_ONLY: "default_public_interface_only", DISABLE_NON_PROXIED_UDP: "disable_non_proxied_udp" },
  });
  const contentSetting = () => ({
    get: (details, cb) => { const v = { setting: "allow" }; if (cb) cb(v); else return Promise.resolve(v); },
    set: (details, cb) => { if (cb) cb(); else return Promise.resolve(); },
    clear: (details, cb) => { if (cb) cb(); else return Promise.resolve(); },
    getResourceIdentifiers: (cb) => { if (cb) cb([]); else return Promise.resolve([]); },
  });
  put2("contentSettings", Object.fromEntries(["automaticDownloads", "autoVerify", "camera", "clipboard", "cookies",
    "images", "javascript", "location", "microphone", "notifications", "plugins", "popups", "sound"]
    .map((n) => [n, contentSetting()])));
  put2("proxy", { settings: setting("proxy.settings"), onProxyError: event() });
  put2("omnibox", { setDefaultSuggestion: () => {}, onInputStarted: event(), onInputChanged: event(),
    onInputEntered: event(), onInputCancelled: event(), onDeleteSuggestion: event() });
  // Screen recording (see ExtensionCapture.swift). Chrome's picker is
  // Kea's question, then the Mac's own; the stream id it hands back is
  // an id Kea gives once, which getUserMedia in the extension's page
  // turns into the stream. Defined only for an extension that asks for
  // it, as in Chrome: Awesome Screenshot records with getDisplayMedia
  // when there is no desktopCapture.
  const declares = (name) => [...(manifest.permissions || []), ...(manifest.optional_permissions || [])].includes(name);
  const recorder = !inContent && !worker && typeof navigator !== "undefined" && !!navigator.mediaDevices
    && typeof root.MediaDevices === "function";
  // Only an extension's own page, at the top: Kea checks that too.
  const captureChannel = (() => {
    try { return recorder && !embedded && window.top === window ? root.webkit.messageHandlers.keaCapture : null; } catch (e) { return null; }
  })();
  const askCapture = (op, body) => captureChannel
    ? Promise.resolve(captureChannel.postMessage(Object.assign({ op }, body)))
    : Promise.resolve({ error: "NotAllowedError", message: "Recording isn't available here" });
  const refused = (reply) => new DOMException(String(reply && reply.message || "Permission denied"), String(reply && reply.error || "NotAllowedError"));
  // What WebKit's getDisplayMedia takes: no min, no exact.
  const displayVideo = (v) => {
    if (!v || typeof v !== "object") return true;
    const out = {};
    for (const k of ["width", "height", "frameRate"]) {
      const x = v[k] ?? (v.mandatory && v.mandatory["max" + k[0].toUpperCase() + k.slice(1)]);
      if (typeof x === "number") out[k] = { max: x };
      else if (x && typeof x === "object") {
        const y = {};
        if (x.max !== undefined) y.max = x.max;
        if (x.ideal !== undefined) y.ideal = x.ideal;
        if (Object.keys(y).length) out[k] = y;
      }
    }
    return Object.keys(out).length ? out : true;
  };
  if (recorder) {
    const P = root.MediaDevices.prototype;
    const realGUM = P.getUserMedia, realGDM = P.getDisplayMedia;
    const held = new Map();
    // Called by Kea alone (ExtensionCapture.record). WebKit counts an
    // app's call as a click, and only until its first await, so the
    // page's own getDisplayMedia — kept before any of the extension's
    // code ran — is called at once.
    if (typeof realGDM === "function") {
      Object.defineProperty(root, Symbol.for("kea.capture"), { value: (token, video) => {
        let started;
        try { started = realGDM.call(navigator.mediaDevices, { video: video == null ? true : video, audio: false }); }
        catch (e) { return Promise.resolve({ error: e.name, message: String(e.message) }); }
        return started.then((stream) => {
          held.set(token, stream);
          // An id never taken is stopped, not left recording.
          setTimeout(() => {
            if (held.get(token) !== stream) return;
            held.delete(token);
            stream.getTracks().forEach((t) => t.stop());
          }, 60000);
          return { ok: true };
        }, (e) => ({ error: e.name, message: String(e.message) }));
      } });
    }
    // Chrome's desktop and tab constraints, which WebKit would read as a
    // plain camera request.
    const desktopId = (c) => {
      if (!c || typeof c !== "object") return null;
      const m = c.mandatory || c;
      return /^(desktop|screen|window|tab)$/.test(String(m.chromeMediaSource || "")) ? String(m.chromeMediaSourceId || "") : null;
    };
    // Chrome's older constraints (mandatory, optional, goog…) in the
    // standard form.
    const standard = (t) => {
      if (!t || typeof t !== "object" || !(t.mandatory || t.optional)) return t;
      const out = {};
      for (const [k, v] of Object.entries(t)) if (k !== "mandatory" && k !== "optional") out[k] = v;
      const set = (name, part, v) => { const x = out[name] && typeof out[name] === "object" ? out[name] : {}; x[part] = v; out[name] = x; };
      const read = (k, v, strong) => {
        const m = /^(min|max)(Width|Height|FrameRate|AspectRatio)$/.exec(k);
        if (m) return set(m[2][0].toLowerCase() + m[2].slice(1), m[1], v);
        if (k === "sourceId" || k === "deviceId") return set("deviceId", strong ? "exact" : "ideal", v);
        const goog = { googEchoCancellation: "echoCancellation", googAutoGainControl: "autoGainControl", googNoiseSuppression: "noiseSuppression" }[k];
        if (goog) out[goog] = v;
      };
      for (const [k, v] of Object.entries(t.mandatory || {})) read(k, v, true);
      for (const o of t.optional || []) for (const [k, v] of Object.entries(o || {})) read(k, v, false);
      return Object.keys(out).length ? out : true;
    };
    const take = async (id, c) => {
      let stream = held.get(id);
      if (!stream && id) {
        const reply = await askCapture("consume", { token: id, video: displayVideo(c.video) });
        if (!reply || !reply.ok) throw refused(reply);
        stream = held.get(id);
      }
      held.delete(id);
      if (!stream) throw refused();
      // The sound of a screen or a tab alone: WebKit records none.
      if (desktopId(c.video) === null) {
        stream.getTracks().forEach((t) => t.stop());
        throw new DOMException("Kea can't record the sound of a screen or a tab", "NotFoundError");
      }
      const [track] = stream.getVideoTracks();
      const want = displayVideo(c.video);
      if (track && want !== true) try { await track.applyConstraints(want); } catch (e) {}
      return stream;
    };
    put(P, "getUserMedia", function (c) {
      const asked = c || {};
      const id = desktopId(asked.video) ?? desktopId(asked.audio);
      if (id !== null) return take(id, asked);
      const self = this;
      // An offscreen document is lent to the pill first (see
      // ExtensionCapture, "lend"); one not made to record is refused.
      return askCapture("lend", {}).then((reply) => {
        if (captureChannel && (!reply || !reply.ok)) throw refused(reply);
        return realGUM.call(self, { audio: standard(asked.audio), video: standard(asked.video) });
      });
    });
    if (typeof realGDM === "function") {
      put(P, "getDisplayMedia", function (c) {
        const asked = c || {};
        const surface = asked.video && typeof asked.video === "object" ? String(asked.video.displaySurface || "") : "";
        return askCapture("display", { video: displayVideo(asked.video), surface }).then((reply) => {
          const stream = reply && reply.ok && held.get(reply.token);
          if (!stream) throw refused(reply);
          held.delete(reply.token);
          return stream;
        });
      });
    }
    // Chrome's older callback form, which Loom still records with.
    const legacy = function (c, ok, fail) {
      navigator.mediaDevices.getUserMedia(c).then(ok, (e) => { if (typeof fail === "function") fail(e); });
    };
    for (const name of ["getUserMedia", "webkitGetUserMedia"]) {
      if (typeof navigator[name] !== "function") put(root.Navigator.prototype, name, legacy);
    }
  }
  if (declares("desktopCapture")) {
    let asks = 0;
    const cancelled = new Set();
    put2("desktopCapture", {
      chooseDesktopMedia: (sources, tab, cb) => {
        const f = typeof tab === "function" ? tab : cb;
        const id = ++asks;
        const done = (token) => { if (!cancelled.has(id) && typeof f === "function") f(token || "", { canRequestAudioTrack: false }); };
        // From a page: asked and recorded there at once, so a cancelled
        // picker is an empty id, as in Chrome. From the worker, which has
        // nothing to record in: an id for one of its pages to use.
        const asked = worker || background || !captureChannel
          ? native("capture.grant", [sources || []])
          : askCapture("choose", { sources: sources || [] }).then((r) => (r && r.ok ? r.token : ""));
        Promise.resolve(asked).then(done, () => done(""));
        return id;
      },
      cancelChooseDesktopMedia: (id) => { cancelled.add(id); },
      DesktopCaptureSourceType: { SCREEN: "screen", WINDOW: "window", TAB: "tab", AUDIO: "audio" },
    });
  }
  // A tab alone can't be recorded in Kea: an extension that falls back
  // to the screen, as Loom does, records the window instead.
  if (declares("tabCapture")) {
    put2("tabCapture", { capture: refuse("tabCapture.capture"), getMediaStreamId: refuse("tabCapture.getMediaStreamId"),
      getCapturedTabs: (cb) => { if (cb) cb([]); else return Promise.resolve([]); }, onStatusChanged: event() });
  }
  put2("pageCapture", { saveAsMHTML: refuse("pageCapture.saveAsMHTML") });
  put2("debugger", { attach: refuse("debugger.attach"), detach: refuse("debugger.detach"),
    sendCommand: refuse("debugger.sendCommand"), getTargets: (cb) => { if (cb) cb([]); else return Promise.resolve([]); },
    onEvent: event(), onDetach: event() });
  put2("gcm", { register: refuse("gcm.register"), unregister: refuse("gcm.unregister"), send: refuse("gcm.send"),
    onMessage: event(), onMessagesDeleted: event(), onSendError: event() });
  put2("instanceID", { getID: refuse("instanceID.getID"), getToken: refuse("instanceID.getToken"),
    deleteID: refuse("instanceID.deleteID"), deleteToken: refuse("instanceID.deleteToken"),
    getCreationTime: refuse("instanceID.getCreationTime"), onTokenRefresh: event() });
  // Rules that show a button on matching pages: every button is always
  // shown in Kea, so there is nothing for them to do.
  const rules = () => ({ addRules: (r, cb) => { if (cb) cb(r || []); }, removeRules: (i, cb) => { if (cb) cb(); },
    getRules: (i, cb) => { const f = typeof i === "function" ? i : cb; if (f) f([]); } });
  put2("declarativeContent", { onPageChanged: rules(),
    PageStateMatcher: function (o) { Object.assign(this, o); }, ShowAction: function () {}, ShowPageAction: function () {},
    SetIcon: function (o) { Object.assign(this, o); }, RequestContentScript: function (o) { Object.assign(this, o); } });

  // WebKit serves an extension's .wasm files without the application/wasm
  // type, so compiling one as it streams in fails. Most code falls back
  // to fetching it whole, with a warning; some has no fallback and
  // stops. The whole file is what they get from the start.
  if (root.WebAssembly && typeof WebAssembly.instantiateStreaming === "function") {
    const own = (r) => r && typeof r.url === "string" && /^(chrome|webkit)-extension:/.test(r.url);
    const instantiate = WebAssembly.instantiateStreaming.bind(WebAssembly);
    WebAssembly.instantiateStreaming = async (source, imports) => {
      const response = await source;
      return own(response) ? WebAssembly.instantiate(await response.arrayBuffer(), imports) : instantiate(response, imports);
    };
    if (typeof WebAssembly.compileStreaming === "function") {
      const compile = WebAssembly.compileStreaming.bind(WebAssembly);
      WebAssembly.compileStreaming = async (source) => {
        const response = await source;
        return own(response) ? WebAssembly.compile(await response.arrayBuffer()) : compile(response);
      };
    }
  }

  // Members Chrome has on the namespaces WebKit has too, that WebKit
  // leaves out. Plenty are read at the top of a worker — an enum, an
  // event to listen to — where one missing member is a TypeError that
  // stops the whole worker before it has done anything.
  const fill = (name, members) => {
    const target = chrome[name];
    if (!target) return;
    for (const [key, value] of Object.entries(members)) {
      let there;
      try { there = target[key]; } catch (e) {}
      if (there === undefined) put(target, key, value);
    }
  };
  const resolve = (value) => (...args) => {
    const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
    const v = typeof value === "function" ? value(...args) : value;
    if (!callback) return Promise.resolve(v);
    setTimeout(() => callback(v));
  };
  const enumOf = (...values) => Object.fromEntries(values.map((v) => [v.toUpperCase().replace(/[-.]/g, "_").replace(/([a-z])([A-Z])/g, "$1_$2").toUpperCase(), v]));
  const resourceTypes = enumOf("main_frame", "sub_frame", "stylesheet", "script", "image", "font", "object",
    "xmlhttprequest", "ping", "csp_report", "media", "websocket", "webtransport", "webbundle", "other");
  fill("runtime", {
    onUpdateAvailable: event(), onRestartRequired: event(), onSuspend: event(), onSuspendCanceled: event(),
    onBrowserUpdateAvailable: event(), onConnectNative: event(), onUserScriptConnect: event(), onUserScriptMessage: event(),
    requestUpdateCheck: (callback) => {
      if (typeof callback === "function") { setTimeout(() => callback("no_update", {})); return; }
      return Promise.resolve({ status: "no_update" });
    },
    restart: () => {}, restartAfterDelay: resolve(undefined),
    getPackageDirectoryEntry: refuse("runtime.getPackageDirectoryEntry"),
    OnInstalledReason: enumOf("install", "update", "chrome_update", "shared_module_update"),
    OnRestartRequiredReason: enumOf("app_update", "os_update", "periodic"),
    PlatformArch: { ARM: "arm", ARM64: "arm64", X86_32: "x86-32", X86_64: "x86-64", MIPS: "mips", MIPS64: "mips64" },
    PlatformNaclArch: { ARM: "arm", X86_32: "x86-32", X86_64: "x86-64", MIPS: "mips", MIPS64: "mips64" },
    PlatformOs: { MAC: "mac", WIN: "win", ANDROID: "android", CROS: "cros", LINUX: "linux", OPENBSD: "openbsd", FUCHSIA: "fuchsia" },
    RequestUpdateCheckStatus: enumOf("throttled", "no_update", "update_available"),
    ContextType: { TAB: "TAB", POPUP: "POPUP", BACKGROUND: "BACKGROUND", OFFSCREEN_DOCUMENT: "OFFSCREEN_DOCUMENT",
      SIDE_PANEL: "SIDE_PANEL", DEVELOPER_TOOLS: "DEVELOPER_TOOLS" },
  });
  // The popup Kea shows is a page of its own, known to WebKit as a
  // tab with no place in the row (no index). Chrome has no current
  // tab in a popup, and lists it among the popup views; extensions lay
  // themselves out by that (Bitwarden, Proton Pass: or else they fill
  // the window as if in a tab).
  if (typeof document !== "undefined") {
    // Known at once for the manifest's popup page — pages lay themselves
    // out before any answer can come back — and settled by what WebKit
    // says of the tab.
    let popup = (() => {
      try {
        const m = runtime.getManifest(), a = m.action || m.browser_action || {};
        return !!a.default_popup && new URL(a.default_popup, location.origin + "/").pathname === location.pathname;
      } catch (e) { return false; }
    })();
    // Not in a website's frame: never the popup, and asking costs the
    // worker a message for every frame the extension opens.
    if (!embedded && chrome.tabs && typeof chrome.tabs.getCurrent === "function") {
      const getCurrent = chrome.tabs.getCurrent.bind(chrome.tabs);
      const current = () => Promise.resolve(getCurrent()).then((t) => {
        if (t && !(t.index >= 0 && t.index < 1e6)) { popup = true; return undefined; }
        if (t) popup = false;
        return t;
      });
      current().catch(() => {});
      put(chrome.tabs, "getCurrent", (callback) => {
        const p = current();
        if (typeof callback !== "function") return p;
        p.then((t) => callback(t), (e) => withLastError(e, callback));
      });
    }
    if (chrome.extension && typeof chrome.extension.getViews === "function") {
      const extension = chrome.extension;
      const getViews = extension.getViews.bind(extension);
      const views = (properties = {}) => {
        let list = [...(getViews(properties) || [])];
        if (popup && properties.type === "tab") list = list.filter((v) => v !== root);
        if (popup && (!properties.type || properties.type === "popup") && !list.includes(root)) list.push(root);
        return list;
      };
      put(extension, "getViews", views);
      // WebKit's getViews is read-only, and so is chrome.extension: both
      // ignore any redefinition without a word. The popup page's code
      // is then handed a `chrome` of its own, built on WebKit's, whose
      // extension namespace answers getViews and passes everything else
      // on (Malwarebytes lays itself out as a tab otherwise).
      if (popup && extension.getViews !== views) {
        const bound = new Map();
        const ownExtension = Object.create(extension);
        for (const key of Object.getOwnPropertyNames(extension)) {
          if (key === "getViews") continue;
          Object.defineProperty(ownExtension, key, { configurable: true, enumerable: true, get: () => {
            const v = extension[key];
            if (typeof v !== "function") return v;
            if (!bound.has(key)) bound.set(key, v.bind(extension));
            return bound.get(key);
          } });
        }
        Object.defineProperty(ownExtension, "getViews", { value: views, configurable: true, writable: true, enumerable: true });
        const ownChrome = Object.create(chrome);
        Object.defineProperty(ownChrome, "extension", { value: ownExtension, configurable: true, writable: true, enumerable: true });
        for (const key of ["chrome", "browser"]) {
          try { if (root[key] === chrome) root[key] = ownChrome; } catch (e) {}
        }
      }
    }
  }
  fill("extension", {
    getURL: (path) => runtime.getURL(path), ViewType: { TAB: "tab", POPUP: "popup" },
    sendRequest: (...args) => runtime.sendMessage(...args), onRequest: event(), onRequestExternal: event(),
    getExtensionTabs: () => [], setUpdateUrlData: () => {},
  });
  fill("tabs", {
    TabStatus: enumOf("unloaded", "loading", "complete"), MutedInfoReason: enumOf("user", "capture", "extension"),
    WindowType: enumOf("normal", "popup", "panel", "app", "devtools"),
    ZoomSettingsMode: enumOf("automatic", "manual", "disabled"),
    ZoomSettingsScope: { PER_ORIGIN: "per-origin", PER_TAB: "per-tab" },
    MAX_CAPTURE_VISIBLE_TAB_CALLS_PER_SECOND: 2, TAB_INDEX_NONE: -1,
    getZoomSettings: resolve({ mode: "automatic", scope: "per-origin", defaultZoomFactor: 1 }),
    setZoomSettings: resolve(undefined), onZoomChange: event(),
    onSelectionChanged: event(), onActiveChanged: event(), onHighlightChanged: event(),
    getSelected: (windowId, callback) => {
      const f = typeof windowId === "function" ? windowId : callback;
      chrome.tabs.query({ active: true, currentWindow: true }).then((t) => f && f(t[0]));
    },
    getAllInWindow: (windowId, callback) => {
      const f = typeof windowId === "function" ? windowId : callback;
      chrome.tabs.query({ currentWindow: true }).then((t) => f && f(t));
    },
  });
  if (chrome.tabs) {
    // Moving, sleeping and bringing forward tabs, by where they are in
    // the row — the one thing both sides agree on.
    const settle = () => new Promise((r) => setTimeout(r, 60));
    const byIndex = (api) => async (ids, extra) => {
      const out = [];
      for (const id of Array.isArray(ids) ? ids : [ids]) {
        const tab = await chrome.tabs.get(id);
        await native(api, [placeOf(tab, await frames()), extra]);
        await settle();
        out.push(await chrome.tabs.get(id).catch(() => tab));
      }
      return Array.isArray(ids) ? out : out[0];
    };
    const withCallback = (f) => (...args) => {
      const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
      const p = f(...args);
      if (!callback) return p;
      p.then((v) => callback(v), (e) => withLastError(e, callback));
    };
    const indexes = async (ids) => {
      const known = await frames();
      return Promise.all((Array.isArray(ids) ? ids : [ids]).map((id) => chrome.tabs.get(id).then((t) => placeOf(t, known))));
    };
    fill("tabs", {
      // Into a group, a new one or one named by its number, or out of
      // one. A group left with no tab is gone, as in Chrome.
      group: withCallback(async (options = {}) => {
        const id = await native("tabs.group", [await indexes(options.tabIds), options.groupId ?? -1]);
        groupsChanged();
        return id;
      }),
      ungroup: withCallback(async (ids) => {
        await native("tabs.ungroup", [await indexes(ids)]);
        groupsChanged();
      }),
      move: withCallback(async (ids, props = {}) => {
        const list = Array.isArray(ids) ? ids : [ids];
        const out = [];
        let at = props.index ?? -1;
        for (const id of list) {
          out.push(await byIndex("tabs.move")(id, at));
          if (at !== -1) at++;
        }
        return Array.isArray(ids) ? out : out[0];
      }),
      discard: withCallback((id) => id === undefined
        ? chrome.tabs.query({ active: false, currentWindow: true }).then((t) => t[0] && byIndex("tabs.discard")(t[0].id))
        : byIndex("tabs.discard")(id)),
      highlight: withCallback(async (info = {}) => {
        const first = Array.isArray(info.tabs) ? info.tabs[0] : info.tabs;
        const window = info.windowId ?? (await chrome.windows.getCurrent()).id;
        await native("tabs.activate", [{ i: first, w: (await frames()).get(window) }]);
        await settle();
        return chrome.windows ? chrome.windows.getCurrent({ populate: true }) : undefined;
      }),
    });
  }
  fill("windows", {
    // Chrome's, and not WebKit's: an extension subscribing to it at
    // start — Session Buddy, inside a try — threw there and never
    // reached the rest, its button's listener included. Never fired:
    // a window's bounds are read when they are asked for.
    onBoundsChanged: event(),
    CreateType: enumOf("normal", "popup", "panel"), WindowType: enumOf("normal", "popup", "panel", "app", "devtools"),
    WindowState: { NORMAL: "normal", MINIMIZED: "minimized", MAXIMIZED: "maximized", FULLSCREEN: "fullscreen", LOCKED_FULLSCREEN: "locked-fullscreen" },
  });
  fill("storage", {
    managed: { get: resolve({}), getBytesInUse: resolve(0), onChanged: event() },
    AccessLevel: { TRUSTED_CONTEXTS: "TRUSTED_CONTEXTS", TRUSTED_AND_UNTRUSTED_CONTEXTS: "TRUSTED_AND_UNTRUSTED_CONTEXTS" },
  });
  // A page at the address of the extension's popup hears no events
  // from WebKit: WebKit takes it for its own popup, and Kea's popup
  // is a view of Kea's. The one that matters, storage.onChanged —
  // Bitwarden learns a self-hosted server's address from it — is passed
  // on by the background, which does hear it, to such pages: the popup,
  // and the same page opened in a tab ("pop out"). They keep their
  // address, which extensions check (Dark Reader only answers its popup
  // at its own).
  {
    const manifest = (() => { try { return runtime.getManifest() || {}; } catch (e) { return {}; } })();
    const action = manifest.action || manifest.browser_action || {};
    let popupPath = null;
    try { if (typeof action.default_popup === "string" && action.default_popup) popupPath = new URL(action.default_popup, location.origin + "/").pathname; } catch (e) {}
    const relay = popupPath && !embedded && typeof BroadcastChannel === "function" ? new BroadcastChannel("kea-storage") : null;
    if (relay && background && chrome.storage && chrome.storage.onChanged) {
      kept.add(chrome.storage.onChanged);
      chrome.storage.onChanged.addListener((changes, area) => {
        try { relay.postMessage({ changes, area }); } catch (e) {}
      });
    } else if (relay && !background && typeof location !== "undefined" && location.pathname === popupPath && chrome.storage) {
      const all = new Set(), byArea = {};
      const mend = (ev, set) => {
        if (!ev || typeof ev !== "object") return;
        put(ev, "addListener", (f) => { if (typeof f === "function") set.add(f); });
        put(ev, "removeListener", (f) => { set.delete(f); });
        put(ev, "hasListener", (f) => set.has(f));
        put(ev, "hasListeners", () => set.size > 0);
      };
      mend(chrome.storage.onChanged, all);
      for (const area of ["local", "sync", "session", "managed"]) {
        const store = chrome.storage[area];
        if (store && store.onChanged) mend(store.onChanged, byArea[area] = new Set());
      }
      relay.onmessage = ({ data }) => {
        if (!data || !data.changes) return;
        for (const f of [...all]) { try { f(data.changes, data.area); } catch (e) { console.error(e); } }
        for (const f of [...(byArea[data.area] || [])]) { try { f(data.changes); } catch (e) { console.error(e); } }
      };
    }
  }
  // Items built with Object.create(null) — Chrome stores them, WebKit
  // throws that an object is expected.
  for (const area of ["local", "sync", "session"]) {
    const store = chrome.storage && chrome.storage[area];
    if (!store || typeof store.set !== "function") continue;
    const set = store.set.bind(store);
    put(store, "set", (items, ...rest) => set(items && typeof items === "object" && Object.getPrototypeOf(items) !== Object.prototype ? Object.assign({}, items) : items, ...rest));
  }
  fill("scripting", {
    ExecutionWorld: { ISOLATED: "ISOLATED", MAIN: "MAIN", USER_SCRIPT: "USER_SCRIPT" },
    StyleOrigin: { AUTHOR: "AUTHOR", USER: "USER" },
  });
  // The popup an extension sets for its button, told to the browser too:
  // Kea opens a popup itself (see Extensions.press), and has to know
  // which page it is now.
  for (const name of ["action", "browserAction"]) {
    const a = chrome[name];
    if (!a || typeof a.setPopup !== "function") continue;
    const setPopup = a.setPopup.bind(a);
    put(a, "setPopup", (details = {}, callback) => {
      const tell = (index) => native("action.popup", [details.popup || "", index]).catch(() => {});
      if (typeof details.tabId === "number" && chrome.tabs) chrome.tabs.get(details.tabId).then((t) => tell(t.index), () => {});
      else tell(-1);
      return setPopup(details, callback);
    });
  }
  fill("action", {
    getUserSettings: resolve({ isOnToolbar: true }), onUserSettingsChanged: event(),
    setBadgeTextColor: resolve(undefined), getBadgeTextColor: resolve([255, 255, 255, 255]),
  });
  fill("webNavigation", {
    onCreatedNavigationTarget: event(), onHistoryStateUpdated: event(), onReferenceFragmentUpdated: event(), onTabReplaced: event(),
    TransitionType: enumOf("link", "typed", "auto_bookmark", "auto_subframe", "manual_subframe", "generated",
      "start_page", "form_submit", "reload", "keyword", "keyword_generated"),
    TransitionQualifier: enumOf("client_redirect", "server_redirect", "forward_back", "from_address_bar"),
  });
  fill("webRequest", {
    OnBeforeRequestOptions: { BLOCKING: "blocking", REQUEST_BODY: "requestBody", EXTRA_HEADERS: "extraHeaders" },
    OnBeforeSendHeadersOptions: { REQUEST_HEADERS: "requestHeaders", BLOCKING: "blocking", EXTRA_HEADERS: "extraHeaders" },
    OnSendHeadersOptions: { REQUEST_HEADERS: "requestHeaders", EXTRA_HEADERS: "extraHeaders" },
    OnHeadersReceivedOptions: { BLOCKING: "blocking", RESPONSE_HEADERS: "responseHeaders", EXTRA_HEADERS: "extraHeaders" },
    OnAuthRequiredOptions: { RESPONSE_HEADERS: "responseHeaders", BLOCKING: "blocking", ASYNC_BLOCKING: "asyncBlocking", EXTRA_HEADERS: "extraHeaders" },
    OnResponseStartedOptions: { RESPONSE_HEADERS: "responseHeaders", EXTRA_HEADERS: "extraHeaders" },
    OnBeforeRedirectOptions: { RESPONSE_HEADERS: "responseHeaders", EXTRA_HEADERS: "extraHeaders" },
    OnCompletedOptions: { RESPONSE_HEADERS: "responseHeaders", EXTRA_HEADERS: "extraHeaders" },
    OnErrorOccurredOptions: { EXTRA_HEADERS: "extraHeaders" },
    ResourceType: resourceTypes, MAX_HANDLER_BEHAVIOR_CHANGED_CALLS_PER_10_MINUTES: 20,
    handlerBehaviorChanged: resolve(undefined), onActionIgnored: event(),
  });
  fill("declarativeNetRequest", {
    GUARANTEED_MINIMUM_STATIC_RULES: 30000, MAX_NUMBER_OF_REGEX_RULES: 1000, MAX_NUMBER_OF_SESSION_RULES: 5000,
    MAX_NUMBER_OF_UNSAFE_DYNAMIC_RULES: 5000, MAX_NUMBER_OF_UNSAFE_SESSION_RULES: 5000,
    MAX_GETMATCHEDRULES_CALLS_PER_INTERVAL: 20, GETMATCHEDRULES_QUOTA_INTERVAL: 10,
    DYNAMIC_RULESET_ID: "_dynamic", SESSION_RULESET_ID: "_session",
    getAvailableStaticRuleCount: resolve(30000), getDisabledRuleIds: resolve([]), updateStaticRules: resolve(undefined),
    testMatchOutcome: refuse("declarativeNetRequest.testMatchOutcome"), onRuleMatchedDebug: event(),
    RuleActionType: { BLOCK: "block", REDIRECT: "redirect", ALLOW: "allow", UPGRADE_SCHEME: "upgradeScheme",
      MODIFY_HEADERS: "modifyHeaders", ALLOW_ALL_REQUESTS: "allowAllRequests" },
    ResourceType: resourceTypes, HeaderOperation: enumOf("append", "set", "remove"),
    DomainType: { FIRST_PARTY: "firstParty", THIRD_PARTY: "thirdParty" },
    RequestMethod: enumOf("connect", "delete", "get", "head", "options", "patch", "post", "put", "other"),
    UnsupportedRegexReason: { SYNTAX_ERROR: "syntaxError", MEMORY_LIMIT_EXCEEDED: "memoryLimitExceeded" },
  });
  const contextTypes = enumOf("all", "page", "frame", "selection", "link", "editable", "image", "video", "audio",
    "launcher", "browser_action", "page_action", "action");
  fill("contextMenus", { ContextType: contextTypes, ItemType: enumOf("normal", "checkbox", "radio", "separator") });
  fill("menus", { ContextType: contextTypes, ItemType: enumOf("normal", "checkbox", "radio", "separator") });

  // Rules WebKit can't carry out — a header it doesn't know how to set,
  // say — are refused one by one, where Chrome would take them all. The
  // rest still go in: one rule Kea can't honour shouldn't cost an
  // extension every other rule, or its startup.
  const dnr = chrome.declarativeNetRequest;
  // Before WebKit sees them, rules are put the way it takes them: a
  // redirect to one of the extension's own files by path rather than by
  // address, and without the resource types it has no name for.
  const unknownTypes = new Set(["webtransport", "webbundle", "object"]);
  const base = (() => { try { return runtime.getURL(""); } catch (e) { return ""; } })();
  const mendRule = (rule) => {
    if (!rule || typeof rule !== "object") return rule;
    const r = { ...rule, action: rule.action && { ...rule.action }, condition: rule.condition && { ...rule.condition } };
    const redirect = r.action && r.action.redirect;
    if (redirect && typeof redirect.url === "string" && base && redirect.url.startsWith(base)) {
      r.action.redirect = { extensionPath: "/" + redirect.url.slice(base.length) };
    }
    const c = r.condition;
    if (c && Array.isArray(c.resourceTypes)) {
      c.resourceTypes = c.resourceTypes.filter((t) => !unknownTypes.has(t));
      if (!c.resourceTypes.length) return null;
    }
    if (c && Array.isArray(c.excludedResourceTypes)) c.excludedResourceTypes = c.excludedResourceTypes.filter((t) => !unknownTypes.has(t));
    return r;
  };
  if (dnr && typeof dnr.isRegexSupported === "function") {
    const original = dnr.isRegexSupported.bind(dnr);
    put(dnr, "isRegexSupported", (options, callback) => {
      const p = Promise.resolve(original(options)).then((r) => r || { isSupported: false, reason: "syntaxError" },
        () => ({ isSupported: false, reason: "syntaxError" }));
      if (typeof callback !== "function") return p;
      p.then((r) => callback(r));
    });
  }
  // WebKit's rules take a narrow kind of regular expression: no `|` and
  // no `(?:`. Tampermonkey's rule for .user.js links has both, so a
  // script couldn't be installed from a link (idea 197). A pattern
  // that can be written without them, matching exactly the same
  // addresses, becomes that many rules; one that can't (a choice inside
  // a repeated group, a look-around) is left out as before. Nothing is
