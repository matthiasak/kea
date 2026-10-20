  // widened: every rule matches what its pattern matched.
  const expandRegex = (source, limit = 24) => {
    let i = 0;
    // An atom repeated a counted number of times, a{2,4}, written out
    // as a a a? a?: the same strings, without the braces WebKit refuses.
    const counted = (atom) => {
      const m = /^\{(\d+)(,(\d*))?\}/.exec(source.slice(i));
      if (!m) return atom;
      const least = Number(m[1]), most = m[2] === undefined ? least : m[3] === "" ? null : Number(m[3]);
      if (most === null || most < least || most > 12) return null;
      i += m[0].length;
      return atom.repeat(least) + (atom + "?").repeat(most - least);
    };
    const alternatives = () => {
      let options = [""];
      const all = [];
      while (i < source.length) {
        const c = source[i];
        if (c === "\\") {
          const kind = source[i + 1];
          const size = kind === "x" ? 4 : kind === "c" ? 3
            : kind === "u" ? (source[i + 2] === "{" ? source.indexOf("}", i) + 1 - i : 6) : 2;
          if (size < 2 || /[1-9]/.test(kind || "")) return null;
          const t = source.slice(i, i + size);
          i += size;
          const piece = counted(t);
          if (piece === null) return null;
          options = options.map((o) => o + piece);
          continue;
        }
        if (c === "[") {
          let j = i + 1;
          if (source[j] === "^") j++;
          if (source[j] === "]") j++;
          while (j < source.length && source[j] !== "]") { if (source[j] === "\\") j++; j++; }
          const t = source.slice(i, j + 1);
          i = j + 1;
          const piece = counted(t);
          if (piece === null) return null;
          options = options.map((o) => o + piece);
          continue;
        }
        if (c === "|") { all.push(...options); options = [""]; i++; continue; }
        if (c === ")") break;
        if (c === "(") {
          i++;
          if (source.startsWith("?:", i)) i += 2;
          else if (source[i] === "?") return null;
          const inner = alternatives();
          if (inner === null || source[i] !== ")") return null;
          i++;
          if (/^[*+?{]/.test(source[i] || "")) {
            if (inner.length > 1 || source[i] === "{") return null;
            options = options.map((o) => o + "(" + inner[0] + ")");
            continue;
          }
          options = options.flatMap((o) => inner.map((x) => o + x));
          if (options.length > limit) return null;
          continue;
        }
        i++;
        const piece = /[.\w/:-]/.test(c) ? counted(c) : c;
        if (piece === null) return null;
        options = options.map((o) => o + piece);
      }
      all.push(...options);
      return all.length > limit ? null : all;
    };
    const out = alternatives();
    return out === null || i !== source.length ? null : out;
  };
  // The rules made from one are kept out of sight: the extension sees its
  // own, and taking it away takes them too. Their ids come from the
  // rule's own, so nothing has to be remembered — a relaunch, a worker
  // started afresh or a second page all know which they are (Security).
  const madeBase = 1000000000, madeStride = 32;
  const madeIds = (id) => Number.isInteger(id) && id >= 1 && id < 30000000
    ? Array.from({ length: madeStride - 1 }, (_, k) => madeBase + id * madeStride + k + 1) : [];
  const madeFrom = (id, present) => {
    if (!Number.isInteger(id) || id <= madeBase) return null;
    const offset = id - madeBase, k = offset % madeStride, from = (offset - k) / madeStride;
    return k && present.has(from) ? from : null;
  };
  const spread = (name, rule, taken) => {
    const c = rule && rule.condition;
    const pattern = c && c.regexFilter;
    if (typeof pattern !== "string" || !/\||\(\?:|\{\d/.test(pattern)) return [rule];
    const substitution = rule.action && rule.action.redirect && rule.action.redirect.regexSubstitution;
    if (typeof substitution === "string" && /\\[1-9]/.test(substitution)) return [rule];
    const patterns = expandRegex(pattern);
    if (!patterns || !patterns.length) return [rule];
    const ids = madeIds(rule.id);
    // An id past what the scheme holds, or one already an extension's
    // own: this rule isn't written out, and is left out as before.
    if (patterns.length > 1 && (ids.length < patterns.length - 1 || ids.slice(0, patterns.length - 1).some((id) => taken.has(id)))) return [rule];
    return patterns.map((regexFilter, k) => ({ ...rule, id: k === 0 ? rule.id : ids[k - 1], condition: { ...c, regexFilter } }));
  };
  const rawGet = {};
  for (const [get, name] of [["getSessionRules", "updateSessionRules"], ["getDynamicRules", "updateDynamicRules"]]) {
    if (!dnr || typeof dnr[get] !== "function") continue;
    const original = dnr[get].bind(dnr);
    rawGet[name] = () => Promise.resolve(original()).then((r) => r || []);
    put(dnr, get, (filter, callback) => {
      if (typeof filter === "function") { callback = filter; filter = undefined; }
      const p = rawGet[name]().then((all) => {
        const present = new Set(all.map((r) => r.id));
        const own = all.filter((r) => madeFrom(r.id, present) === null);
        const ids = filter && Array.isArray(filter.ruleIds) ? new Set(filter.ruleIds) : null;
        return ids ? own.filter((r) => ids.has(r.id)) : own;
      });
      if (typeof callback !== "function") return p;
      p.then((r) => callback(r), (e) => withLastError(e, callback));
    });
  }
  if (dnr) for (const name of ["updateSessionRules", "updateDynamicRules"]) {
    if (typeof dnr[name] !== "function") continue;
    const original = dnr[name].bind(dnr);
    put(dnr, name, (options = {}, callback) => {
      const ready = (rawGet[name] ? rawGet[name]() : Promise.resolve([])).catch(() => []).then((all) => {
        const present = new Set(all.map((r) => r.id));
        if (options && Array.isArray(options.removeRuleIds)) {
          const gone = new Set(options.removeRuleIds);
          const extra = all.map((r) => r.id).filter((id) => gone.has(madeFrom(id, present)));
          if (extra.length) options = { ...options, removeRuleIds: options.removeRuleIds.concat(extra) };
        }
        if (options && Array.isArray(options.addRules)) {
          const leaving = new Set(options.removeRuleIds || []);
          const taken = new Set([...present].filter((id) => !leaving.has(id) && !leaving.has(madeFrom(id, present))));
          options.addRules.forEach((r) => r && taken.add(r.id));
          options = { ...options, addRules: options.addRules.map(mendRule).filter(Boolean).flatMap((r) => spread(name, r, taken)) };
        }
      });
      const attempt = async (opts, left) => {
        try { return await original(opts); }
        catch (e) {
          // WebKit builds one content blocker of an extension's rules,
          // and it can't hold rules for some sites beside rules for all
          // but some: Tampermonkey's rule for any .user.js link, all but
          // its own sites, kept every other rule from loading. The
          // all-but rules are left out, as a refused rule is.
          if (/Unable to load declarativeNetRequest rules/.test(String(e && e.message)) && Array.isArray(opts.addRules) && left > 0) {
            const excluding = (r) => { const c = r && r.condition; return !!(c && (c.excludedRequestDomains || c.excludedInitiatorDomains || c.excludedDomains)); };
            const narrowing = (r) => { const c = r && r.condition; return !!(c && (c.requestDomains || c.initiatorDomains || c.domains)); };
            if (opts.addRules.some(excluding) && opts.addRules.some(narrowing)) {
              for (const rule of opts.addRules.filter(excluding)) {
                const kind = rule && rule.action && rule.action.type || "?";
                try { native("debug.error", ["declarativeNetRequest: " + kind + " rule " + (rule && rule.id) + " left out — it excludes sites beside rules for given sites, which WebKit can't load together"]).catch(() => {}); } catch (x) {}
              }
              return attempt({ ...opts, addRules: opts.addRules.filter((r) => !excluding(r)) }, left - 1);
            }
          }
          const at = /rule at index (\d+)/.exec(String(e && e.message));
          if (!at || !Array.isArray(opts.addRules) || left <= 0) throw e;
          const index = Number(at[1]);
          const rule = opts.addRules[index];
          try { native("debug.error", ["declarativeNetRequest: rule " + (rule && rule.id) + " left out — " + e.message]).catch(() => {}); } catch (x) {}
          return attempt({ ...opts, addRules: opts.addRules.filter((_, i) => i !== index) }, left - 1);
        }
      };
      const p = ready.then(() => attempt(options, 100));
      // In a test run, an update that still fails is said, not only
      // handed back to an extension that may drop it.
      if (__KEA_VERBOSE__) p.catch((e) => { try { native("debug.error", ["declarativeNetRequest: " + name + " failed — " + (e && e.message)]).catch(() => {}); } catch (x) {} });
      if (typeof callback !== "function") return p;
      p.then(() => callback(), (e) => withLastError(e, callback));
    });
  }

  // Context menu entries for places Kea has no menu for — the old
  // toolbar button contexts are the button's menu now, and there is no
  // app launcher at all.
  for (const name of ["contextMenus", "menus"]) {
    const menus = chrome[name];
    if (!menus || typeof menus.create !== "function") continue;
    const mend = (props) => {
      if (!props || !Array.isArray(props.contexts)) return props;
      const contexts = [...new Set(props.contexts.map((c) => c === "browser_action" || c === "page_action" ? "action" : c).filter((c) => c !== "launcher"))];
      return { ...props, contexts: contexts.length ? contexts : ["page"] };
    };
    const create = menus.create.bind(menus), update = menus.update.bind(menus);
    put(menus, "create", (props, callback) => create(mend(props), callback));
    put(menus, "update", (id, props, callback) => update(id, mend(props), callback));
  }

  // webRequest listeners with options WebKit doesn't take — blocking
  // needs a policy-installed extension in Chrome's MV3 too; extra headers
  // WebKit reports anyway — are added with the options it does take.
  if (chrome.webRequest) for (const key of Object.keys(chrome.webRequest)) {
    const target = chrome.webRequest[key];
    if (!/^on[A-Z]/.test(key) || !target || typeof target.addListener !== "function") continue;
    const add = target.addListener.bind(target);
    put(target, "addListener", (listener, filter, spec) => {
      // WebKit can't read ws:// and wss:// patterns, and refuses the
      // whole listener over one; Chrome watches sockets too. The
      // listener is kept for everything else.
      if (filter && Array.isArray(filter.urls)) {
        const urls = filter.urls.filter((u) => !/^wss?:/i.test(u));
        if (!urls.length) return;
        filter = { ...filter, urls };
      }
      // Added after a worker's startup, WebKit refuses it; Chrome takes
      // it. It isn't heard, but neither does it stop the code that added
      // it — a listener for every request can't join the late list
      // (it would wake the worker for all of them).
      const late = (e) => { if (!/startup/i.test(String(e && e.message))) throw e; };
      try {
        if (!Array.isArray(spec)) return add(listener, filter);
        const kept = spec.filter((s) => s === "requestHeaders" || s === "responseHeaders" || s === "requestBody");
        try { return add(listener, filter, kept); } catch (e) { if (/startup/i.test(String(e && e.message))) throw e; return add(listener, filter); }
      } catch (e) { late(e); }
    });
  }

  // Tabs as Chrome describes them. Every tab has a groupId, which code
  // tests before anything else: -1 when in no group, and the group's
  // number, asked of the browser, for an extension that asked for
  // "tabGroups" — only those have any use for it, so the others are
  // spared the question. With the "tabs" permission an extension sees
  // every tab's address and title, where WebKit shows them only for
  // sites it has host access to.
  if (chrome.tabs) {
    const permissions = (() => { try { return runtime.getManifest().permissions || []; } catch (e) { return []; } })();
    const seesTabs = permissions.includes("tabs"), seesGroups = permissions.includes("tabGroups");
    const isTab = (t) => t && typeof t === "object" && typeof t.id === "number";
    // Mends in place; a promise only when the browser has to be asked.
    const mend = (list) => {
      const tabs = list.filter(isTab);
      for (const t of tabs) if (t.groupId === undefined) try { t.groupId = -1; } catch (e) {}
      const blind = seesTabs ? tabs.filter((t) => !t.url && t.index >= 0) : [];
      const placed = seesGroups ? tabs.filter((t) => t.index >= 0) : [];
      if (!blind.length && !placed.length) return null;
      return frames().then((known) => Promise.all([
        blind.length && native("tabs.describe", [blind.map((t) => placeOf(t, known))]).then((info) => {
          blind.forEach((t, i) => {
            const d = info && info[i];
            if (!d) return;
            try {
              if (d.url) t.url = d.url;
              if (d.title && !t.title) t.title = d.title;
              if (d.favIconUrl && !t.favIconUrl) t.favIconUrl = d.favIconUrl;
            } catch (e) {}
          });
        }, () => {}),
        placed.length && native("tabs.groups", [placed.map((t) => placeOf(t, known))]).then((ids) => {
          placed.forEach((t, i) => {
            if (ids && typeof ids[i] === "number") try { t.groupId = ids[i]; } catch (e) {}
          });
        }, () => {}),
      ]));
    };
    const tabsIn = (value) => Array.isArray(value) ? value.flatMap(tabsIn)
      : isTab(value) ? [value] : value && Array.isArray(value.tabs) ? value.tabs : [];
    const mendResult = (target, name) => {
      if (!target || typeof target[name] !== "function") return;
      const original = target[name].bind(target);
      put(target, name, (...args) => {
        const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
        const p = Promise.resolve(original(...args)).then(async (r) => { await mend(tabsIn(r)); return r; });
        if (!callback) return p;
        p.then((r) => callback(r), (e) => withLastError(e, callback));
      });
    };
    for (const name of ["query", "get", "getCurrent", "create", "update", "duplicate", "move", "reload"]) mendResult(chrome.tabs, name);
    // A query for a group's tabs: WebKit knows no groupId, so it is asked
    // without one and the tabs are sorted out after.
    if (seesGroups && typeof chrome.tabs.query === "function") {
      const query = chrome.tabs.query.bind(chrome.tabs);
      put(chrome.tabs, "query", (info, callback) => {
        if (typeof info === "function") { callback = info; info = {}; }
        const wanted = info && info.groupId;
        let p;
        if (wanted === undefined) p = query(info || {});
        else {
          const rest = Object.assign({}, info);
          delete rest.groupId;
          p = Promise.resolve(query(rest)).then((tabs) => tabs.filter((t) => t.groupId === wanted));
        }
        if (typeof callback !== "function") return p;
        p.then((r) => callback(r), (e) => withLastError(e, callback));
      });
    }
    for (const name of ["get", "getAll", "getCurrent", "getLastFocused", "create"]) mendResult(chrome.windows, name);
    // WebKit's windows.getCurrent ignores which extension page called
    // it and returns the frontmost window. In a top-level extension page
    // opened in a tab — a popup window's page among them (Bitwarden's
    // passkey window) — find that page's current tab each time and ask
    // for its window instead. When there is no real tab, as in a toolbar
    // action popup or an offscreen page, keep WebKit's answer; workers
    // and content scripts never enter here. From #408, by lulkebit.
    if (!inContent && !embedded && typeof document !== "undefined"
        && chrome.windows && typeof chrome.windows.getCurrent === "function"
        && typeof chrome.windows.get === "function" && typeof chrome.tabs.getCurrent === "function") {
      const getCurrentWindow = chrome.windows.getCurrent.bind(chrome.windows);
      const getWindow = chrome.windows.get.bind(chrome.windows);
      const getCurrentTab = chrome.tabs.getCurrent.bind(chrome.tabs);
      put(chrome.windows, "getCurrent", (...args) => {
        const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
        const getInfo = typeof args[0] === "function" ? undefined : args[0];
        const options = getInfo === undefined ? [] : [getInfo];
        const p = Promise.resolve().then(() => getCurrentTab()).then((tab) => {
          const windowId = tab && tab.windowId;
          const hasPlace = tab && Number.isInteger(tab.index) && tab.index >= 0 && tab.index < 1e6
            && Number.isInteger(windowId) && windowId >= 0;
          return hasPlace ? getWindow(windowId, ...options) : getCurrentWindow(...options);
        }, () => getCurrentWindow(...options));
        if (!callback) return p;
        p.then((window) => callback(window), (error) => withLastError(error, callback));
      });
    }
    // Listeners given a tab: the tab is mended before they see it.
    const mendArgs = (target, positions, told, skip) => {
      if (!target || typeof target.addListener !== "function") return;
      const add = target.addListener.bind(target), remove = target.removeListener.bind(target);
      const wrapped = new Map();
      put(target, "addListener", (listener, ...rest) => {
        const state = new Map();
        const w = function (...args) {
          if (skip && skip(args)) return;
          const pending = mend(positions.map((i) => args[i]));
          if (!pending) { if (told) told(args, state); return listener.apply(this, args); }
          pending.then(() => { if (told) told(args, state); listener.apply(this, args); });
        };
        wrapped.set(listener, w);
        return add(w, ...rest);
      });
      put(target, "removeListener", (listener) => { const w = wrapped.get(listener); wrapped.delete(listener); return remove(w || listener); });
      put(target, "hasListener", (listener) => wrapped.has(listener));
    };
    // An offscreen document is a tab to WebKit, so that its frames'
    // content scripts can name it, but in no window: the extension
    // never hears of it coming or going, as in Chrome (#192).
    mendArgs(chrome.tabs.onCreated, [0], null, (args) => isTab(args[0]) && args[0].windowId === -1);
    mendArgs(chrome.tabs.onRemoved, [], null, (args) => !!args[1] && args[1].windowId === -1);
    // What changed, in onUpdated's changeInfo. Without host access
    // WebKit blanks url and title there ("") and leaves favIconUrl out,
    // and a tab manager, or an extension watching its sign-in tab, reads
    // them there. A blanked one is filled from the tab; one left out is
    // added when it differs from what this listener last saw of the tab.
    const told = seesTabs ? (args, state) => {
      const info = args[1], tab = args[2];
      if (!info || typeof info !== "object" || !isTab(tab) || !tab.url) return;
      const before = state.get(tab.id);
      const fill = (key, changed) => {
        const value = tab[key];
        if (value && (info[key] === "" || (info[key] === undefined && changed))) try { info[key] = value; } catch (e) {}
      };
      fill("url", before ? before.url !== tab.url : info.status === "loading");
      fill("title", !!before && before.title !== tab.title);
      fill("favIconUrl", !!before && before.favIconUrl !== tab.favIconUrl);
      state.set(tab.id, { url: tab.url, title: tab.title, favIconUrl: tab.favIconUrl });
    } : null;
    mendArgs(chrome.tabs.onUpdated, [2], told);
    mendArgs(chrome.action && chrome.action.onClicked, [0]);
    mendArgs(chrome.contextMenus && chrome.contextMenus.onClicked, [1]);
    mendArgs(chrome.menus && chrome.menus.onClicked, [1]);
    mendArgs(chrome.commands && chrome.commands.onCommand, [1]);
  }

  // Permissions. WebKit knows its own and throws on any other name,
  // where Chrome answers false. The ones Kea answers itself are
  // Kea's to grant: those a manifest names are granted, optional
  // ones are asked for.
  if (chrome.permissions) {
    const webkit = new Set(["activeTab", "alarms", "clipboardWrite", "contextMenus", "cookies", "declarativeNetRequest",
      "declarativeNetRequestFeedback", "declarativeNetRequestWithHostAccess", "menus", "nativeMessaging", "scripting",
      "storage", "tabs", "unlimitedStorage", "webNavigation", "webRequest"]);
    const ours = new Set(["bookmarks", "history", "downloads", "downloads.open", "downloads.shelf", "downloads.ui",
      "tabGroups", "sidePanel", "offscreen", "notifications", "tts", "fontSettings", "management", "identity",
      "identity.email", "idle", "power", "privacy", "browsingData", "sessions", "topSites", "search", "system.cpu",
      "system.memory", "system.storage", "system.display", "readingList", "contentSettings", "proxy", "favicon",
      "clipboardRead", "geolocation", "userScripts"]);
    const manifest = (() => { try { return runtime.getManifest() || {}; } catch (e) { return {}; } })();
    const declared = new Set(manifest.permissions || []);
    const split = (list = []) => ({
      theirs: list.filter((p) => webkit.has(p)), mine: list.filter((p) => ours.has(p)),
      unknown: list.filter((p) => !webkit.has(p) && !ours.has(p)),
    });
    const p = chrome.permissions;
    const contains = p.contains.bind(p), request = p.request.bind(p), getAll = p.getAll.bind(p), remove = p.remove.bind(p);
    const granted = () => native("permissions.granted", []).then((list) => new Set([...declared, ...(list || [])]));
    const withCb = (f) => (arg, callback) => {
      const pr = f(arg || {});
      if (typeof callback !== "function") return pr;
      pr.then((v) => callback(v), (e) => withLastError(e, callback));
    };
    // Extension pages are never an extension's to reach, as in Chrome,
    // where such a pattern isn't even valid (see
    // Extensions.reachesExtensions): never held, never asked for. Nor
    // files, as in Chrome with file access left off (Extensions.reachesFiles).
    const extensionPages = (origins) => origins.some((o) => /^((chrome|webkit)-extension|file):/i.test(String(o)));
    put(p, "contains", withCb(async ({ permissions = [], origins = [] }) => {
      const { theirs, mine, unknown } = split(permissions);
      if (unknown.length || extensionPages(origins)) return false;
      if (mine.length) { const have = await granted(); if (!mine.every((m) => have.has(m))) return false; }
      return theirs.length || origins.length ? contains({ permissions: theirs, origins }) : true;
    }));
    put(p, "request", withCb(async ({ permissions = [], origins = [] }) => {
      const { theirs, mine, unknown } = split(permissions);
      if (unknown.length || extensionPages(origins)) return false;
      if (mine.length) {
        const have = await granted();
        const missing = mine.filter((m) => !have.has(m));
        if (missing.length && !(await native("permissions.request", [missing]))) return false;
      }
      if (!theirs.length && !origins.length) return true;
      // Asked from a click on the extension's button: when filling in
      // the tab it was given (mend) cost WebKit the click, Kea
      // knows it was one and asks the same question.
      return Promise.resolve(request({ permissions: theirs, origins })).catch((e) =>
        /user gesture/i.test(String(e && e.message)) ? native("permissions.afterClick", [theirs, origins]) : Promise.reject(e));
    }));
    put(p, "getAll", (callback) => {
      const pr = (async () => {
        const all = await getAll();
        const have = await granted();
        return { ...all, permissions: [...new Set([...(all.permissions || []), ...[...have].filter((m) => ours.has(m))])] };
      })();
      if (typeof callback !== "function") return pr;
      pr.then((v) => callback(v), (e) => withLastError(e, callback));
    });
    put(p, "remove", withCb(async ({ permissions = [], origins = [] }) => {
      const { theirs, mine } = split(permissions);
      if (mine.length) await native("permissions.remove", [mine]);
      return theirs.length || origins.length ? remove({ permissions: theirs, origins }) : true;
    }));
  }

  // chrome.userScripts — what Tampermonkey, Violentmonkey and the
  // advanced rules of the ad blockers run on — carried out through
  // WebKit's registered content scripts. The browser writes each script
  // into a file of the extension's (content scripts come from files),
  // wrapped so the globs Chrome takes are honoured and, for Chrome's
  // USER_SCRIPT world, so its messages reach onUserScriptMessage rather
  // than the extension's own onMessage. The list lives with the browser,
  // and is registered again whenever the worker starts.
  const scripting = chrome.scripting;
  // What an extension registers for a page's own world has Kea's
  // passkey patch before it, as its manifest's do (see prepare): a
  // password manager keeps a reference to navigator.credentials as it
  // finds it, and falls back to that. An update that names no world gets
  // it too; in any other world the patch does nothing.
  if (scripting) {
    const first = (scripts, updating) => Array.isArray(scripts) ? scripts.map((s) => {
      if (!s || !Array.isArray(s.js) || s.js.includes("kea-passkeys.js")) return s;
      const world = String(s.world || "").toUpperCase();
      return world === "MAIN" || (updating && !world) ? { ...s, js: ["kea-passkeys.js", ...s.js] } : s;
    }) : scripts;
    for (const name of ["registerContentScripts", "updateContentScripts"]) {
      const original = scripting[name];
      if (typeof original === "function") {
        put(scripting, name, function (scripts, ...rest) { return original.call(scripting, first(scripts, name === "updateContentScripts"), ...rest); });
      }
    }
  }
  const wantsUserScripts = (() => { try { return (runtime.getManifest().permissions || []).includes("userScripts"); } catch (e) { return false; } })();
  if (!chrome.userScripts && wantsUserScripts && scripting && typeof scripting.registerContentScripts === "function") {
    const tag = "kea-us-";
    const content = async (script) => ({
      id: tag + script.id,
      matches: script.matches && script.matches.length ? script.matches : ["*://*/*"],
      excludeMatches: script.excludeMatches || [],
      js: [await native("userScripts.file", [script])],
      runAt: script.runAt || "document_idle",
      allFrames: !!script.allFrames,
      world: script.world === "MAIN" ? "MAIN" : "ISOLATED",
      persistAcrossSessions: false,
    });
    const registered = async () => (await scripting.getRegisteredContentScripts()).filter((s) => s.id.startsWith(tag));
    const list = () => native("userScripts.list", []).then((l) => l || []);
    const save = (l) => native("userScripts.save", [l]);
    const sync = async () => {
      const want = await list();
      const have = new Set((await registered()).map((s) => s.id));
      const missing = want.filter((s) => !have.has(tag + s.id));
      if (!missing.length) return;
      const scripts = await Promise.all(missing.map(content));
      // Two starts of the worker racing each other: the later one takes
      // the registration over.
      await scripting.registerContentScripts(scripts).catch(async (e) => {
        if (!/duplicate/i.test(String(e && e.message))) throw e;
        await scripting.unregisterContentScripts({ ids: scripts.map((s) => s.id) }).catch(() => {});
        await scripting.registerContentScripts(scripts);
      });
    };
    const pick = (filter, l) => filter && Array.isArray(filter.ids) ? l.filter((s) => filter.ids.includes(s.id)) : l;
    const api = {
      register: async (scripts) => {
        const l = await list();
        for (const s of scripts) if (l.some((o) => o.id === s.id)) throw new Error("Duplicate script id '" + s.id + "'");
        await scripting.registerContentScripts(await Promise.all(scripts.map(content)));
        await save([...l, ...scripts]);
      },
      update: async (scripts) => {
        const l = await list();
        const merged = scripts.map((s) => {
          const old = l.find((o) => o.id === s.id);
          if (!old) throw new Error("Script with id '" + s.id + "' does not exist");
          return { ...old, ...s };
        });
        await scripting.unregisterContentScripts({ ids: merged.map((s) => tag + s.id) }).catch(() => {});
        await scripting.registerContentScripts(await Promise.all(merged.map(content)));
        await save(l.map((o) => merged.find((m) => m.id === o.id) || o));
      },
      unregister: async (filter) => {
        const l = await list();
        const gone = pick(filter, l);
        const ids = (await registered()).map((s) => s.id).filter((id) => gone.some((g) => tag + g.id === id));
        if (ids.length) await scripting.unregisterContentScripts({ ids });
        await save(l.filter((o) => !gone.includes(o)));
      },
      getScripts: async (filter) => pick(filter, await list()),
      configureWorld: (properties) => native("userScripts.world", [properties || {}]),
      getWorldConfigurations: () => native("userScripts.worlds", []),
      resetWorldConfiguration: (worldId) => native("userScripts.world", [{ worldId, reset: true }]),
      execute: async (injection) => {
        const file = await native("userScripts.file", [{ id: "execute-" + Date.now(), js: injection.js || [], world: injection.world }]);
        return scripting.executeScript({ target: injection.target, files: [file], world: injection.world === "MAIN" ? "MAIN" : "ISOLATED",
          injectImmediately: !!injection.injectImmediately });
      },
    };
    const callbacks = Object.fromEntries(Object.entries(api).map(([k, f]) => [k, (...args) => {
      const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
      const p = f(...args);
      if (!callback) return p;
      p.then((v) => callback(v), (e) => withLastError(e, callback));
    }]));
    put2("userScripts", { ...callbacks, ExecutionWorld: { MAIN: "MAIN", USER_SCRIPT: "USER_SCRIPT" } });
    if (background) sync().catch((e) => { try { native("debug.error", ["userScripts: " + e.message]).catch(() => {}); } catch (x) {} });

    // Messages from the USER_SCRIPT world come tagged (see the file's
    // wrapper); they go to onUserScriptMessage and onUserScriptConnect.
    const onMessage = runtime.onUserScriptMessage, onConnect = runtime.onUserScriptConnect;
    root.__keaUserScriptMessage = (message, sender, respond) => {
      let keep = false;
      for (const f of [...onMessage.listeners]) {
        const r = f(message, sender, respond);
        if (r === true) keep = true;
        else if (r && typeof r.then === "function") { keep = true; r.then(respond); }
      }
      return keep;
    };
    if (runtime.onConnect && typeof runtime.onConnect.addListener === "function") {
      const marker = "kea-us:";
      const add = runtime.onConnect.addListener.bind(runtime.onConnect);
      const remove = runtime.onConnect.removeListener.bind(runtime.onConnect);
      const wrapped = new Map();
      try {
        add((port) => {
          if (!String(port.name).startsWith(marker)) return;
          const view = Object.create(port, { name: { value: port.name.slice(marker.length) } });
          for (const f of [...onConnect.listeners]) f(view);
        });
      } catch (e) {}
      put(runtime.onConnect, "addListener", (listener) => {
        const w = (port) => { if (!String(port.name).startsWith(marker)) return listener(port); };
        wrapped.set(listener, w);
        return add(w);
      });
      put(runtime.onConnect, "removeListener", (listener) => { const w = wrapped.get(listener); if (w) { wrapped.delete(listener); remove(w); } });
    }
  }

  // WebKit says "install" again when an extension is taken up afresh in
  // the same session — after a Reload, or a worker brought back — where
  // Chrome says "update"; extensions open their welcome page on
  // "install". The first one of a session is marked, and any later one
  // told as the update it is.
  if (background && runtime.onInstalled && typeof runtime.onInstalled.addListener === "function") {
    let decided = null;
    const seenBefore = () => decided || (decided = native("background.loadedBefore", []).then((v) => !!v, () => false));
    const add = runtime.onInstalled.addListener.bind(runtime.onInstalled);
    const remove = runtime.onInstalled.removeListener.bind(runtime.onInstalled);
    const wrapped = new Map();
    put(runtime.onInstalled, "addListener", (listener) => {
      const w = (details) => {
        if (!details || details.reason !== "install") return listener(details);
        seenBefore().then((seen) => listener(seen ? { ...details, reason: "update", previousVersion: runtime.getManifest().version } : details));
      };
      wrapped.set(listener, w);
      return add(w);
    });
    put(runtime.onInstalled, "removeListener", (listener) => { const w = wrapped.get(listener); wrapped.delete(listener); return remove(w || listener); });
    put(runtime.onInstalled, "hasListener", (listener) => wrapped.has(listener));
  }

  // A worker may add listeners only while it starts; WebKit throws for
  // one added later, where Chrome takes it. So for every event this
  // extension's code mentions, the worker has one listener of WebKit's
  // from the start, and a late one joins the list behind it. Events it
  // never mentions still take late listeners without throwing — they
  // just aren't heard. (Request events are left alone: a listener for
  // all of them would wake the worker for every request.)
  if (background) {
    const mentioned = new Set(__KEA_EVENTS__);
    for (const space of Object.keys(chrome)) {
      if (space === "webRequest") continue;
      let ns; try { ns = chrome[space]; } catch (e) { continue; }
      if (!ns || typeof ns !== "object") continue;
      const names = new Set();
      for (let o = ns; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) Object.getOwnPropertyNames(o).forEach((k) => names.add(k));
