        p.then((v) => callback(v), (e) => lastError(e, callback));
      });
    };
    const one = (o) => typeof o.url === "string" ? [o.url] : Array.isArray(o.url) ? o.url : null;
    swap("downloads", "download", one);
    swap("tabs", "create", one);
    swap("windows", "create", one);
  })();

  // Errors in an extension's own pages and worker are told to the browser,
  // which lists them — the only window onto a worker there is.
  if (root.addEventListener) {
    const tell = (text) => { try { native("debug.error", [String(text).slice(0, 2000)]).catch(() => {}); } catch (e) {} };
    root.addEventListener("error", (e) => tell((e.message || "error") + " @ " + String(e.filename || "").split("/").slice(3).join("/") + ":" + e.lineno));
    root.addEventListener("unhandledrejection", (e) => tell("unhandled: " + (e.reason && ((e.reason.message || "") + " — " + (e.reason.stack || "")) || e.reason)));
    // In a test run, what the extension says went wrong, too.
    if (__KEA_VERBOSE__ && root.console) {
      let told = 0;
      for (const level of ["error", "warn"]) {
        const original = console[level].bind(console);
        console[level] = (...args) => {
          original(...args);
          if (told++ < 60) tell("console." + level + ": " + args.map((a) => {
            if (a instanceof Error) return a.message + " — " + (a.stack || "");
            try { return typeof a === "string" ? a : JSON.stringify(a); } catch (e) { return String(a); }
          }).join(" "));
        };
      }
    }
  }
})();