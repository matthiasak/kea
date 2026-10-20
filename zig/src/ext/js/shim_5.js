      for (const key of names) {
        if (!/^on[A-Z]/.test(key) || (space === "runtime" && /^onMessage/.test(key))) continue;
        let target; try { target = ns[key]; } catch (e) { continue; }
        if (!target || typeof target.addListener !== "function" || target.listeners) continue;
        const add = target.addListener.bind(target), remove = target.removeListener.bind(target);
        const late = new Set();
        if (mentioned.has(space + "." + key)) {
          try {
            add(function (...args) {
              let answer;
              for (const f of [...late]) { try { const r = f(...args); if (r !== undefined) answer = r; } catch (e) { setTimeout(() => { throw e; }); } }
              return answer;
            });
          } catch (e) {}
        }
        put(target, "addListener", (listener, ...rest) => {
          try { return add(listener, ...rest); }
          catch (e) { if (/startup/i.test(String(e && e.message))) late.add(listener); else throw e; }
        });
        put(target, "removeListener", (listener) => { late.delete(listener); try { remove(listener); } catch (e) {} });
      }
    }
  }

  // What one of the extension's pages or its worker posts to another
  // before their port has opened — at once after connect, or from inside
  // onConnect — WebKit keeps until the other end takes the port, then
  // hands on once for each end's world: between two of the extension's
  // own, the same world, so twice. iCloud Passwords' popup asks its
  // worker for its state that way, and was answered twice. So between
  // the extension's own ends every message goes numbered by the end
  // that sends it, and a number already heard is let go by. A content
  // script's port, or an app's, goes as it is.
  if (runtime && typeof runtime.connect === "function" && runtime.onConnect) {
    const own = runtime.getURL("");
    const numbered = new WeakSet();
    // Set on the port itself, not with `put`, which holds what it touches
    // for good: a port is the extension's to let go. Its onMessage is held
    // by what is set here, so it isn't made afresh without it.
    const set = (target, key, value) => { try { Object.defineProperty(target, key, { value, configurable: true, writable: true }); } catch (e) {} };
    const number = (port) => {
      const event = port && port.onMessage, post = port && port.postMessage;
      if (!event || typeof event.addListener !== "function" || typeof post !== "function" || numbered.has(port)) return port;
      numbered.add(port);
      const me = Math.random().toString(36).slice(2);
      let sent = 0;
      const heard = new Map();
      const listeners = new Set();
      event.addListener.call(event, (message, ...rest) => {
        const tag = message && typeof message === "object" ? message.__keaPort : null;
        if (Array.isArray(tag)) {
          if (tag[1] <= (heard.get(tag[0]) || 0)) return;
          heard.set(tag[0], tag[1]);
          message = message.message;
        }
        for (const f of [...listeners]) { try { f(message, ...rest); } catch (e) { setTimeout(() => { throw e; }); } }
      });
      // WebKit makes a port's onMessage afresh once nothing holds it, and
      // a fresh one has none of what is set below: a listener added to it
      // later would hear the numbered wrapper. Held on the port, it stays.
      set(port, "onMessage", event);
      set(port, "postMessage", (message) => post.call(port, { __keaPort: [me, ++sent], message }));
      set(event, "addListener", (f) => { listeners.add(f); });
      set(event, "removeListener", (f) => { listeners.delete(f); });
      set(event, "hasListener", (f) => listeners.has(f));
      set(event, "hasListeners", () => listeners.size > 0);
      return port;
    };
    const connect = runtime.connect;
    // Only a port to the extension itself, and never a content script's:
    // another extension would hear the numbered wrapper, not the message,
    // and a content script's port reaches the worker with the website as
    // sender, so the worker leaves it plain; numbering one end only hides
    // its messages from the extension.
    put(runtime, "connect", (...args) => {
      const port = connect.apply(runtime, args);
      return inContent || (typeof args[0] === "string" && args[0] !== runtime.id) ? port : number(port);
    });
    const onConnect = runtime.onConnect;
    const add = onConnect.addListener, remove = onConnect.removeListener, has = onConnect.hasListener;
    const wrapped = new WeakMap();
    // The worker's sender is the bare origin, with no slash after it.
    const fromOwn = (port) => !!port && !!port.sender && (String(port.sender.url) + "/").startsWith(own);
    put(onConnect, "addListener", (listener, ...rest) => {
      if (typeof listener !== "function") return add.call(onConnect, listener, ...rest);
      let w = wrapped.get(listener);
      if (!w) {
        w = (port) => {
          const given = port && port.sender, sender = untabbed(given);
          port = fromOwn(port) ? number(port) : port;
          // WebKit makes a port's sender afresh at each look, over
          // anything set on the port: the port is seen through a proxy.
          if (sender !== given) {
            port = new Proxy(port, { get: (target, key) => {
              if (key === "sender") return sender;
              const value = target[key];
              return typeof value === "function" ? value.bind(target) : value;
            } });
          }
          return listener(port);
        };
        wrapped.set(listener, w);
      }
      return add.call(onConnect, w, ...rest);
    });
    put(onConnect, "removeListener", (listener) => remove.call(onConnect, wrapped.get(listener) || listener));
    put(onConnect, "hasListener", (listener) => has.call(onConnect, wrapped.get(listener) || listener));
  }

  // Members of namespaces WebKit has.
  if (chrome.i18n && !chrome.i18n.detectLanguage) put(chrome.i18n, "detectLanguage", call("i18n.detectLanguage"));
  if (runtime && !runtime.getContexts) put(runtime, "getContexts", call("runtime.getContexts"));

  // Chrome's old FileSystem API — requestFileSystem, entries, FileWriter and
  // `filesystem:` URLs — which WebKit never had. Extensions still save to it:
  // GoFullPage writes every capture there and shows, copies and downloads it
  // by a `filesystem:<origin>/persistent/...` URL it builds itself. So it is
  // rebuilt on the origin private file system: PERSISTENT and TEMPORARY are
  // the folders "persistent" and "temporary" at its root, so a filesystem: URL
  // and the file it names have the same path. WebKit can't load that scheme,
  // so where such a URL is handed to something that loads it is swapped for
  // the file: a blob: URL in an image, a link or fetch; a data: URL for a
  // download or a new tab, which the browser loads outside this page.
  // Extension pages only: a worker has no DOM to mend, and a content script
  // shares the page's origin.
  (() => {
    const root = globalThis;
    if (root.requestFileSystem || root.webkitRequestFileSystem || typeof document === "undefined"
        || !(root.navigator && navigator.storage && navigator.storage.getDirectory)) return;

    const TEMPORARY = 0, PERSISTENT = 1;
    const kinds = ["temporary", "persistent"];
    // Chrome answers with DOMExceptions whose name says what went wrong; the
    // legacy code comes with the name (NotFoundError is 8, and so on).
    const fail = (name, message) => new DOMException(message || name, name);
    const asError = (e) => e instanceof DOMException ? e : fail(e && e.name || "InvalidStateError", e && e.message || String(e));
    // Chrome calls back later, never in the same turn, success or not.
    // A callback that throws is reported as uncaught, not as a rejection.
    const invoke = (f, v) => { try { f(v); } catch (e) { setTimeout(() => { throw e; }); } };
    const settle = (promise, success, error) => {
      promise.then((v) => { if (typeof success === "function") invoke(success, v); },
        (e) => { if (typeof error === "function") invoke(error, asError(e)); });
    };

    // Paths are kept as their segments; "/a/b" is ["a", "b"].
    const segments = (base, path) => {
      path = String(path ?? "");
      const out = path.startsWith("/") ? [] : base.split("/").filter(Boolean);
      for (const part of path.split("/")) {
        if (!part || part === ".") continue;
        if (part === "..") out.pop(); else out.push(part);
      }
      return out;
    };
    const join = (segs) => "/" + segs.join("/");

    const top = [];
    const folder = (type) => top[type] || (top[type] = navigator.storage.getDirectory()
      .then((d) => d.getDirectoryHandle(kinds[type], { create: true })));
    const walk = async (type, segs, create = false) => {
      let dir = await folder(type);
      for (const name of segs) dir = await dir.getDirectoryHandle(name, { create });
      return dir;
    };
    // The handle at a path, whichever kind it is, or null.
    const lookup = async (type, segs) => {
      if (!segs.length) return folder(type);
      const dir = await walk(type, segs.slice(0, -1));
      const name = segs[segs.length - 1];
      try { return await dir.getFileHandle(name); } catch (e) {
        if (e.name !== "TypeMismatchError") { if (e.name === "NotFoundError") return null; throw e; }
      }
      return dir.getDirectoryHandle(name);
    };
    const need = async (type, segs) => {
      const handle = await lookup(type, segs).catch((e) => { if (e.name === "NotFoundError") return null; throw e; });
      if (!handle) throw fail("NotFoundError", "A requested file or directory could not be found.");
      return handle;
    };

    // OPFS files come without a type; a blob: URL or download wants one.
    const types = { png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif", webp: "image/webp",
      svg: "image/svg+xml", pdf: "application/pdf", txt: "text/plain", html: "text/html", json: "application/json",
      mp4: "video/mp4", webm: "video/webm" };
    const typed = (file) => {
      const type = file.type || types[(file.name.split(".").pop() || "").toLowerCase()] || "";
      return type === file.type ? file : new File([file], file.name, { type, lastModified: file.lastModified });
    };

    // blob: URLs already made, by "<type>:<path>", so the same file set on an
    // image twice gets the same URL, and at once. Changing a file drops its.
    const made = new Map();
    const forget = (type, path) => {
      for (const [key, url] of made) {
        const [t, p] = [Number(key[0]), key.slice(2)];
        if (t === type && (p === path || p.startsWith(path === "/" ? "/" : path + "/"))) {
          made.delete(key);
          Promise.resolve(url).then((u) => { if (u) setTimeout(() => URL.revokeObjectURL(u), 60000); }, () => {});
        }
      }
    };

    const systems = [];
    const system = (type) => systems[type] || (systems[type] = (() => {
      const fs = { name: location.host + ":" + (type ? "Persistent" : "Temporary") };
      fs.root = new DirectoryEntry(fs, type, "/");
      return fs;
    })());

    class Entry {
      constructor(fs, type, path) {
        Object.defineProperty(this, "_type", { value: type });
        this.filesystem = fs;
        this.fullPath = path;
        this.name = path === "/" ? "" : path.split("/").pop();
      }
      get _segs() { return segments("/", this.fullPath); }
      toURL() {
        return "filesystem:" + location.origin + "/" + kinds[this._type]
          + (this.fullPath === "/" ? "/" : this._segs.map(encodeURIComponent).map((s) => "/" + s).join(""));
      }
      toInternalURL() { return this.toURL(); }
      getParent(success, error) {
        settle(Promise.resolve(new DirectoryEntry(this.filesystem, this._type, join(this._segs.slice(0, -1)))), success, error);
      }
      getMetadata(success, error) {
        settle((async () => {
          const handle = await need(this._type, this._segs);
          if (handle.kind === "directory") return { modificationTime: new Date(), size: 0 };
          const file = await handle.getFile();
          return { modificationTime: new Date(file.lastModified), size: file.size };
        })(), success, error);
      }
      remove(success, error) {
        settle((async () => {
          const segs = this._segs;
          if (!segs.length) throw fail("InvalidModificationError", "The root directory cannot be removed.");
          const handle = await need(this._type, segs);
          // Not recursive: a directory with something in it is refused, as in
          // Chrome — WebKit says UnknownError there, Chrome InvalidModificationError.
          await (await walk(this._type, segs.slice(0, -1))).removeEntry(segs[segs.length - 1]).catch((e) => {
            throw handle.kind === "directory" && e.name !== "NotFoundError" ? fail("InvalidModificationError", "The directory is not empty.") : e;
          });
          forget(this._type, this.fullPath);
        })(), success, error);
      }
      moveTo(parent, name, success, error) { settle(this._transfer(parent, name, true), success, error); }
      copyTo(parent, name, success, error) { settle(this._transfer(parent, name, false), success, error); }
      async _transfer(parent, name, move) {
        if (!(parent instanceof DirectoryEntry)) throw fail("TypeMismatchError", "The parent is not a directory.");
        name = name == null || name === "" ? this.name : String(name);
        if (!name || name.includes("/") || name === "." || name === "..") throw fail("EncodingError", "Invalid name.");
        const from = this._segs, to = [...parent._segs, name];
        const same = parent._type === this._type;
        if (!from.length) throw fail("InvalidModificationError", "The root directory cannot be moved or copied.");
        if (same && (join(to) === this.fullPath || join(to).startsWith(this.fullPath + "/")))
          throw fail("InvalidModificationError", "An entry cannot be moved or copied onto or into itself.");
        const handle = await need(this._type, from);
        const into = await need(parent._type, parent._segs);
        if (into.kind !== "directory") throw fail("NotFoundError");
        // What is already there is replaced if it is a file over a file, or an
        // empty directory over a directory; otherwise Chrome refuses.
        const there = await lookup(parent._type, to).catch(() => null);
        if (there) {
          if (there.kind !== handle.kind) throw fail("InvalidModificationError", "An entry of another kind is in the way.");
          await into.removeEntry(name).catch(() => { throw fail("InvalidModificationError", "The directory in the way is not empty."); });
          forget(parent._type, join(to));
        }
        let moved = false;
        if (move && same && typeof handle.move === "function") {
          try { await handle.move(into, name); moved = true; } catch (e) {}
        }
        if (!moved) {
          await copy(handle, into, name);
          if (move) await (await walk(this._type, from.slice(0, -1))).removeEntry(from[from.length - 1], { recursive: true });
        }
        if (move) forget(this._type, this.fullPath);
        const Kind = this.isDirectory ? DirectoryEntry : FileEntry;
        return new Kind(parent.filesystem, parent._type, join(to));
      }
    }
    const copy = async (handle, into, name) => {
      if (handle.kind === "file") {
        const w = await (await into.getFileHandle(name, { create: true })).createWritable();
        await w.write(await handle.getFile());
        return w.close();
      }
      const dir = await into.getDirectoryHandle(name, { create: true });
      for await (const [child, h] of handle.entries()) await copy(h, dir, child);
    };

    class DirectoryEntry extends Entry {
      get isFile() { return false; }
      get isDirectory() { return true; }
      createReader() { return new DirectoryReader(this); }
      getFile(path, options, success, error) { settle(this._get(path, options, "file"), success, error); }
      getDirectory(path, options, success, error) { settle(this._get(path, options, "directory"), success, error); }
      async _get(path, options, kind) {
        const create = !!(options && options.create), exclusive = !!(options && options.exclusive);
        const segs = segments(this.fullPath, path);
        if (!segs.length) {
          if (kind === "file") throw fail("TypeMismatchError", "The root is a directory.");
          if (create && exclusive) throw fail("InvalidModificationError", "The directory already exists.");
          return this.filesystem.root;
        }
        const dir = await walk(this._type, segs.slice(0, -1)).catch((e) => {
          throw e.name === "TypeMismatchError" ? fail("NotFoundError") : e;
        });
        const name = segs[segs.length - 1];
        if (create && exclusive) {
          const there = await lookup(this._type, segs).catch(() => null);
          if (there) throw fail("InvalidModificationError", "The entry already exists.");
        }
        await (kind === "file" ? dir.getFileHandle(name, { create }) : dir.getDirectoryHandle(name, { create }));
        const Kind = kind === "file" ? FileEntry : DirectoryEntry;
        return new Kind(this.filesystem, this._type, join(segs));
      }
      removeRecursively(success, error) {
        settle((async () => {
          const segs = this._segs;
          if (!segs.length) throw fail("InvalidModificationError", "The root directory cannot be removed.");
          await need(this._type, segs);
          await (await walk(this._type, segs.slice(0, -1))).removeEntry(segs[segs.length - 1], { recursive: true });
          forget(this._type, this.fullPath);
        })(), success, error);
      }
    }

    // Chrome hands a directory's entries over in batches, then an empty one to
    // say it's done; callers loop until they see it.
    class DirectoryReader {
      constructor(dir) { this._dir = dir; this._left = null; }
      readEntries(success, error) {
        settle((async () => {
          const dir = this._dir;
          if (!this._left) {
            const handle = await need(dir._type, dir._segs);
            this._left = [];
            for await (const [name, h] of handle.entries()) {
              const Kind = h.kind === "file" ? FileEntry : DirectoryEntry;
              this._left.push(new Kind(dir.filesystem, dir._type, join([...dir._segs, name])));
            }
          }
          return this._left.splice(0, 100);
        })(), success, error);
      }
    }

    class FileEntry extends Entry {
      get isFile() { return true; }
      get isDirectory() { return false; }
      file(success, error) {
        settle((async () => {
          const handle = await need(this._type, this._segs);
          if (handle.kind !== "file") throw fail("TypeMismatchError");
          return typed(await handle.getFile());
        })(), success, error);
      }
      createWriter(success, error) {
        settle((async () => {
          const handle = await need(this._type, this._segs);
          if (handle.kind !== "file") throw fail("TypeMismatchError");
          return new FileWriter(this, handle, (await handle.getFile()).size);
        })(), success, error);
      }
    }

    // One write or truncate at a time, each a writable opened on the file as it
    // is and closed — OPFS commits on close — with Chrome's events around it:
    // writestart, write, writeend, or error then writeend.
    class FileWriter extends EventTarget {
      constructor(entry, handle, length) {
        super();
        Object.defineProperty(this, "_entry", { value: entry });
        Object.defineProperty(this, "_handle", { value: handle });
        Object.defineProperty(this, "_token", { value: null, writable: true });
        this.readyState = 0; this.position = 0; this.length = length; this.error = null;
        this.onwritestart = this.onprogress = this.onwrite = this.onabort = this.onerror = this.onwriteend = null;
      }
      _fire(type, loaded, total) {
        const event = new ProgressEvent(type, { lengthComputable: true, loaded, total });
        this.dispatchEvent(event);
        const handler = this["on" + type];
        if (typeof handler === "function") handler.call(this, event);
      }
      _run(size, work, after) {
        if (this.readyState === 1) throw fail("InvalidStateError", "A write is already in progress.");
        this.readyState = 1; this.error = null;
        const run = this._token = {};
        setTimeout(async () => {
          if (this._token !== run) return;
          this._fire("writestart", 0, size);
          try {
            const w = await this._handle.createWritable({ keepExistingData: true });
            try { await work(w); await w.close(); } catch (e) { await w.abort().catch(() => {}); throw e; }
            if (this._token !== run) return;
            after();
            forget(this._entry._type, this._entry.fullPath);
            this.readyState = 2;
            this._fire("progress", size, size);
            this._fire("write", size, size);
          } catch (e) {
            if (this._token !== run) return;
            this.error = asError(e);
            this.readyState = 2;
            this._fire("error", 0, size);
          }
          this._fire("writeend", this.readyState === 2 ? size : 0, size);
        });
      }
      write(data) {
        if (!(data instanceof Blob)) throw new TypeError("Failed to execute 'write' on 'FileWriter': parameter 1 is not of type 'Blob'.");
        const at = this.position;
        this._run(data.size, (w) => w.write({ type: "write", position: at, data }), () => {
          this.position = at + data.size;
          this.length = Math.max(this.length, this.position);
        });
      }
      truncate(size) {
        size = Math.max(0, Number(size) || 0);
        this._run(0, (w) => w.truncate(size), () => {
          this.length = size;
          this.position = Math.min(this.position, size);
        });
      }
      seek(offset) {
        if (this.readyState === 1) throw fail("InvalidStateError", "A write is in progress.");
        offset = Number(offset) || 0;
        if (offset < 0) offset = Math.max(0, this.length + offset);
        this.position = Math.min(offset, this.length);
      }
      abort() {
        if (this.readyState !== 1) return;
        this._token = null;
        this.readyState = 2;
        this.error = fail("AbortError", "The write was aborted.");
        this._fire("abort", 0, 0);
        this._fire("writeend", 0, 0);
      }
    }
    for (const [k, v] of [["INIT", 0], ["WRITING", 1], ["DONE", 2]]) {
      Object.defineProperty(FileWriter, k, { value: v });
      Object.defineProperty(FileWriter.prototype, k, { value: v });
    }

    const requestFileSystem = (type, size, success, error) => {
      type = Number(type);
      settle(type === TEMPORARY || type === PERSISTENT
        ? folder(type).then(() => system(type))
        : Promise.reject(fail("InvalidModificationError", "Unknown file system type.")), success, error);
    };

    // filesystem:<this origin>/<persistent|temporary>/<path>, or null.
    const parse = (url) => {
      const s = String(url);
      if (!s.startsWith("filesystem:")) return null;
      const m = /^filesystem:([^/]+:\/\/[^/]+)\/(temporary|persistent)(\/[^?#]*)?/i.exec(s);
      if (!m || m[1] !== location.origin) return null;
      let segs;
      try { segs = segments("/", (m[3] || "/").split("/").map(decodeURIComponent).join("/")); } catch (e) { return null; }
      return { type: kinds.indexOf(m[2].toLowerCase()), segs };
    };
    const resolveURL = (url, success, error) => {
      settle((async () => {
        const at = parse(url);
        if (!at) throw fail(String(url).startsWith("filesystem:") ? "SecurityError" : "EncodingError", "Not a filesystem: URL of this origin.");
        const handle = await need(at.type, at.segs);
        const fs = system(at.type);
        if (!at.segs.length) return fs.root;
        return new (handle.kind === "file" ? FileEntry : DirectoryEntry)(fs, at.type, join(at.segs));
      })(), success, error);
    };

    const fileAt = async (url) => {
      const at = parse(url);
      if (!at) throw fail("NotFoundError");
      const handle = await need(at.type, at.segs);
      if (handle.kind !== "file") throw fail("NotFoundError");
      return typed(await handle.getFile());
    };
    // The blob: URL now standing for a filesystem: URL, made once per file.
    const blobURL = (url) => {
      const at = parse(url);
      if (!at) return Promise.reject(fail("NotFoundError"));
      const key = at.type + ":" + join(at.segs);
      if (!made.has(key)) {
        const p = fileAt(url).then((file) => { const u = URL.createObjectURL(file); made.set(key, u); return u; });
        made.set(key, p);
        p.catch(() => { if (made.get(key) === p) made.delete(key); });
      }
      return Promise.resolve(made.get(key));
    };
    const ready = (url) => { const at = parse(url); const u = at && made.get(at.type + ":" + join(at.segs)); return typeof u === "string" ? u : null; };
    const dataURL = (url) => fileAt(url).then((file) => new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result);
      reader.onerror = () => reject(reader.error);
      reader.readAsDataURL(file);
    }));

    const define = (target, key, value) => {
      try { Object.defineProperty(target, key, { value, configurable: true, writable: true, enumerable: true }); } catch (e) {}
    };
    define(root, "TEMPORARY", TEMPORARY);
    define(root, "PERSISTENT", PERSISTENT);
    define(root, "requestFileSystem", requestFileSystem);
    define(root, "webkitRequestFileSystem", requestFileSystem);
    define(root, "resolveLocalFileSystemURL", resolveURL);
    define(root, "webkitResolveLocalFileSystemURL", resolveURL);
    // Code for this API asks for quota first; OPFS has its own, so any is granted.
    const quota = {
      requestQuota: (size, success, error) => settle(Promise.resolve(size), success, error),
      queryUsageAndQuota: (success, error) => settle(navigator.storage.estimate().then((e) => [e.usage || 0, e.quota || 0]),
        (v) => typeof success === "function" && success(v[0], v[1]), error),
    };
    if (!navigator.webkitPersistentStorage) define(navigator, "webkitPersistentStorage", quota);
    if (!navigator.webkitTemporaryStorage) define(navigator, "webkitTemporaryStorage", quota);
    for (const [name, Kind] of [["FileSystemEntry", Entry], ["FileSystemDirectoryEntry", DirectoryEntry],
      ["FileSystemFileEntry", FileEntry], ["FileSystemDirectoryReader", DirectoryReader]]) {
      // WebKit has these for dropped files; its instanceof checks keep its own.
      if (!root[name]) define(root, name, Kind);
    }
    if (!root.FileWriter) define(root, "FileWriter", FileWriter);

    // Where a filesystem: URL is loaded. An image or link gets the blob: URL
    // once it's made — at once when it already was, so a src set again stays
    // put — and reads back the filesystem: URL, as in Chrome. A file that
    // isn't there leaves the URL as it was, so the image fails as it would.
    const shown = new WeakMap();
    const hook = (proto, prop) => {
      const d = proto && Object.getOwnPropertyDescriptor(proto, prop);
      if (!d || !d.set || !d.get) return;
      Object.defineProperty(proto, prop, Object.assign({}, d, {
        get() {
          const value = d.get.call(this), was = shown.get(this);
          return was && was.blob === value ? was.url : value;
        },
        set(value) {
          const url = typeof value === "string" ? value : null;
          if (!url || !url.startsWith("filesystem:") || !parse(url)) { shown.delete(this); return d.set.call(this, value); }
          const now = ready(url);
          if (now) { shown.set(this, { url, blob: now }); return d.set.call(this, now); }
          const was = { url, blob: null };
          shown.set(this, was);
          blobURL(url).then((blob) => {
            if (shown.get(this) !== was) return;
            was.blob = blob;
            d.set.call(this, blob);
          }, () => { if (shown.get(this) === was) { shown.delete(this); d.set.call(this, url); } });
        },
      }));
    };
    hook(root.HTMLImageElement && HTMLImageElement.prototype, "src");
    hook(root.HTMLAnchorElement && HTMLAnchorElement.prototype, "href");
    // React and templates set the attribute, not the property.
    const setAttribute = Element.prototype.setAttribute;
    Element.prototype.setAttribute = function (name, value) {
      if (typeof value === "string" && value.startsWith("filesystem:")) {
        const n = String(name).toLowerCase();
        if ((n === "src" && this instanceof HTMLImageElement) || (n === "href" && this instanceof HTMLAnchorElement)) {
          this[n] = value;
          return;
        }
      }
      return setAttribute.call(this, name, value);
    };

    if (typeof root.fetch === "function") {
      const fetch = root.fetch;
      root.fetch = function (input, init) {
        const url = typeof input === "string" ? input : input instanceof URL ? input.href : null;
        if (!url || !url.startsWith("filesystem:") || !parse(url)) return fetch.apply(this, arguments);
        return fileAt(url).then((file) => new Response(file, { status: 200, headers: { "Content-Type": file.type || "application/octet-stream", "Content-Length": String(file.size) } }),
          () => { throw new TypeError("Load failed"); });
      };
    }

    // The browser downloads and opens tabs from outside this page, where a blob:
    // URL of this page means nothing: those get the file itself, as a data: URL.
    const chrome = root.chrome || root.browser;
    const lastError = (e, callback) => {
      const runtime = chrome && chrome.runtime;
      try { Object.defineProperty(runtime, "lastError", { value: { message: String(e && e.message || e) }, configurable: true }); } catch (x) {}
      try { callback(); } finally { try { delete runtime.lastError; } catch (x) {} }
    };
    const held = [];
    const swap = (space, method, urls) => {
      const ns = chrome && chrome[space];
      const original = ns && ns[method];
      if (typeof original !== "function") return;
      held.push(ns); // WebKit's namespace objects are dropped when nothing holds them, and what was set with them.
      define(ns, method, function (options, ...rest) {
        const list = options && urls(options);
        if (!list || !list.some((u) => typeof u === "string" && parse(u))) return original.call(this, options, ...rest);
        const callback = typeof rest[rest.length - 1] === "function" ? rest.pop() : null;
        const p = Promise.all(list.map((u) => typeof u === "string" && parse(u) ? dataURL(u) : u)).then((done) => {
          const copy = Object.assign({}, options, { url: Array.isArray(options.url) ? done : done[0] });
          return original.call(this, copy, ...rest);
        });
        if (!callback) return p;
