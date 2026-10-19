const needle = String(query ?? "");
const epoch = Number(generation ?? 0);
const moves = Math.trunc(Number(steps ?? 0)) || 0;
const cap = Math.max(1, Math.trunc(Number(limit ?? 1000)) || 1000);
const key = "__keaPageFindState_v2";
let state = globalThis[key];
if (!state) {
    state = {
        generation: -1, query: null, matchCase: false, wholeWords: false,
        index: -1, matches: [], complete: true, cursor: null, expression: null,
        runs: null, current: null, savedSelections: [], painted: [], highlights: new WeakMap(),
        observers: [], documents: [], controls: [], dirty: true
    };
    Object.defineProperty(globalThis, key, { value: state, configurable: true });
}

const answer = (status, count = 0, index = 0, more = false) => ({ status, count, index, more });
if (epoch < state.generation) return answer("stale");

function sameRange(left, right) {
    try {
        return left.compareBoundaryPoints(0, right) === 0
            && left.compareBoundaryPoints(2, right) === 0;
    } catch (_) { return false; }
}

// Puts back whatever the page had selected before the find took over,
// unless the page has since selected something else itself.
function unmarkCurrent() {
    if (!state.current) return;
    if (state.current.kind === "range") {
        try {
            const selection = state.current.win.getSelection();
            const saved = state.savedSelections.find(item => item.win === state.current.win);
            if (selection && saved && selection.rangeCount === 1
                && sameRange(selection.getRangeAt(0), state.current.range)) {
                selection.removeAllRanges();
                for (const range of saved.ranges) selection.addRange(range);
            }
        } catch (_) {}
    } else if (state.current.kind === "control") {
        try {
            const control = state.current.control;
            if (control.selectionStart === state.current.start
                && control.selectionEnd === state.current.end) {
                control.setSelectionRange(state.current.savedStart, state.current.savedEnd, state.current.savedDirection);
            }
        } catch (_) {}
    }
    state.current = null;
}

function stopObservers() {
    for (const observer of state.observers) observer.disconnect();
    state.observers = [];
}

function clearState() {
    unmarkCurrent();
    unpaint();
    state.savedSelections = [];
    state.matches = [];
    state.complete = true;
    state.cursor = null;
    state.expression = null;
    state.runs = null;
    state.index = -1;
    state.query = null;
    state.documents = [];
    state.controls = [];
    state.dirty = true;
    stopObservers();
}

if (!needle.trim()) {
    clearState();
    state.generation = Math.max(state.generation, epoch);
    state.matchCase = false;
    state.wholeWords = false;
    return answer("ok", 0, 0);
}

if (document.contentType === "application/pdf") {
    return answer("pdf");
}

const hiddenTags = new Set(["script", "style", "noscript", "template", "head", "title", "select", "option", "optgroup"]);

// Null when the element and what is inside it are not drawn; otherwise
// whether it breaks the text into a block of its own.
function layout(element, doc) {
    if (hiddenTags.has(element.localName)) return null;
    if (element.hidden || element.hasAttribute("hidden")) return null;
    let style = null;
    try { style = doc.defaultView.getComputedStyle(element); } catch (_) {}
    if (!style) return { block: true };
    const display = style.display;
    if (display === "none" || style.visibility === "hidden"
        || style.visibility === "collapse" || style.contentVisibility === "hidden"
        || style.opacity === "0") return null;
    return {
        block: !(display.startsWith("inline") || display === "contents" || display === "ruby")
    };
}

function contexts() {
    const found = [];
    const seen = new Set();
    function visit(win) {
        if (seen.has(win)) return;
        seen.add(win);
        try {
            const doc = win.document;
            if (win !== window) {
                // Cross-origin frames cannot be read from this world.
                const frame = win.frameElement;
                if (!frame || !layout(frame, frame.ownerDocument)) return;
                const box = frame.getBoundingClientRect();
                if (box.width === 0 || box.height === 0) return;
            }
            if (doc && doc.body) found.push({ win, doc });
            for (let i = 0; i < win.frames.length; i++) visit(win.frames[i]);
        } catch (_) {}
    }
    visit(window);
    return found;
}

function observe(context) {
    if (state.observers.some(item => item.doc === context.doc)) return;
    try {
        const observer = new context.win.MutationObserver(() => { state.dirty = true; });
        observer.observe(context.doc.documentElement, {
            subtree: true, childList: true, characterData: true, attributes: true
        });
        observer.doc = context.doc;
        state.observers.push(observer);
    } catch (_) {}
}

// A run is one block's text with runs of white space made one space, and
// a list of segments mapping it back: from text offset t0 on, either
// straight into one node (kind 0: node offset so + (i - t0)), or all of
// it onto one span of the page (kind 1: sn/so to en/eo), as a collapsed
// space or a recomposed accent is.
function makeRun(context, control) {
    return {
        win: context.win, doc: context.doc, control: control || null,
        parts: [], length: 0, nodes: [], text: "",
        t0: [], kind: [], sn: [], so: [], en: [], eo: [], pending: null
    };
}

function emitSpace(run) {
    const space = run.pending;
    if (!space) return;
    run.pending = null;
    run.t0.push(run.length); run.kind.push(1);
    run.sn.push(space.sn); run.so.push(space.so); run.en.push(space.en); run.eo.push(space.eo);
    run.parts.push(" ");
    run.length += 1;
}

function addPiece(run, node, offset, piece) {
    emitSpace(run);
    run.t0.push(run.length); run.kind.push(0);
    run.sn.push(node); run.so.push(offset); run.en.push(node); run.eo.push(offset);
    run.parts.push(piece);
    run.length += piece.length;
}

function addValue(run, node, value) {
    const space = /\s+/g;
    let last = 0;
    let found;
    while ((found = space.exec(value))) {
        if (found.index > last) addPiece(run, node, last, value.slice(last, found.index));
        const end = found.index + found[0].length;
        if (!run.pending) run.pending = { sn: node, so: found.index, en: node, eo: end };
        else { run.pending.en = node; run.pending.eo = end; }
        last = end;
    }
    if (last < value.length) addPiece(run, node, last, value.slice(last));
}

function segmentAt(run, index) {
    const t0 = run.t0;
    let low = 0, high = t0.length - 1;
    while (low < high) {
        const middle = (low + high + 1) >> 1;
        if (t0[middle] <= index) low = middle; else high = middle - 1;
    }
    return low;
}

function startOf(run, index) {
    const k = segmentAt(run, index);
    if (run.kind[k] === 0) return { node: run.nodes[run.sn[k]], offset: run.so[k] + index - run.t0[k] };
    return { node: run.nodes[run.sn[k]], offset: run.so[k] };
}

function endOf(run, index) {
    const k = segmentAt(run, index);
    if (run.kind[k] === 0) return { node: run.nodes[run.sn[k]], offset: run.so[k] + index - run.t0[k] + 1 };
    return { node: run.nodes[run.en[k]], offset: run.eo[k] };
}

// Composed and decomposed accents read alike: each letter with the marks
// after it is recomposed (NFC), and every unit of the result maps onto
// the whole letter. Only runs that change under NFC take this path.
function canonicalize(run) {
    if (run.text.normalize("NFC") !== run.text) remap(run, (letter) => letter.normalize("NFC"));
}

// Without Match case, a letter typed without its accent finds it with
// one, as WebKit's own find does: "ete" finds "été", but "été" doesn't
// find "ete". A run with accents gets a twin without them, each of its
// letters mapped onto the whole letter it came from.
const accent = /\p{M}/gu;
const bare = (text) => text.normalize("NFD").replace(accent, "");
function loosen(run) {
    if (bare(run.text) === run.text) return;
    const twin = Object.assign({}, run);
    remap(twin, bare);
    run.loose = twin;
}

// Rewrites a run letter by letter (a letter and the marks after it),
// keeping every unit of the result mapped onto the letter it came from.
function remap(run, change) {
    const original = run.text;
    const n = original.length;
    const sn = new Array(n), so = new Array(n), en = new Array(n), eo = new Array(n);
    for (let k = 0; k < run.t0.length; k++) {
        const from = run.t0[k];
        const to = k + 1 < run.t0.length ? run.t0[k + 1] : n;
        for (let i = from; i < to; i++) {
            if (run.kind[k] === 0) {
                sn[i] = run.sn[k]; so[i] = run.so[k] + i - from;
                en[i] = run.sn[k]; eo[i] = so[i] + 1;
            } else {
                sn[i] = run.sn[k]; so[i] = run.so[k]; en[i] = run.en[k]; eo[i] = run.eo[k];
            }
        }
    }
    const mark = /^\p{M}$/u;
    const parts = [];
    let length = 0;
    run.t0 = []; run.kind = []; run.sn = []; run.so = []; run.en = []; run.eo = [];
    for (let offset = 0; offset < n;) {
        const first = offset;
        offset += original.codePointAt(offset) > 0xFFFF ? 2 : 1;
        while (offset < n) {
            const size = original.codePointAt(offset) > 0xFFFF ? 2 : 1;
            if (!mark.test(original.slice(offset, offset + size))) break;
            offset += size;
        }
        const value = change(original.slice(first, offset));
        for (let i = 0; i < value.length; i++) {
            run.t0.push(length + i); run.kind.push(1);
            run.sn.push(sn[first]); run.so.push(so[first]);
            run.en.push(en[offset - 1]); run.eo.push(eo[offset - 1]);
        }
        parts.push(value);
        length += value.length;
    }
    run.text = parts.join("");
    run.length = length;
}

function collectRuns(context, runs) {
    let run = makeRun(context);
    function flush() {
        run.pending = null;
        if (run.length) {
            run.text = run.parts.join("");
            run.parts = null;
            canonicalize(run);
            loosen(run);
            runs.push(run);
        }
        run = makeRun(context);
    }
    function addControl(element, value) {
        flush();
        state.controls.push({ element, value });
        const controlRun = makeRun(context, element);
        controlRun.nodes.push(element);
        addValue(controlRun, 0, value);
        run = controlRun;
        flush();
    }
    function walk(node) {
        if (node.nodeType === 3) {
            const value = node.nodeValue || "";
            if (!value) return;
            addValue(run, run.nodes.push(node) - 1, value);
            return;
        }
        if (node.nodeType !== 1) return;
        // Each element's style is asked for, which is what costs: past
        // the budget the walk stops, and the count says there may be
        // more, rather than the page holding Find up (Security).
        if (--state.budget < 0) { state.cut = true; return; }
        const element = node;
        const box = layout(element, context.doc);
        if (!box) return;
        const tag = element.localName;
        if (tag === "input") {
            const type = (element.type || "text").toLowerCase();
            if (type !== "password" && element.selectionStart !== null
                && element.getAttribute("aria-hidden") !== "true"
                && element.getClientRects().length > 0) addControl(element, element.value || "");
            return;
        }
        if (tag === "textarea") {
            if (element.getAttribute("aria-hidden") !== "true"
                && element.getClientRects().length > 0) addControl(element, element.value || "");
            return;
        }
        if (tag === "br") { flush(); return; }
        if (box.block) flush();
        for (let child = element.firstChild; child; child = child.nextSibling) walk(child);
        if (box.block) flush();
    }
    walk(context.doc.body);
    flush();
}

function buildRuns(foundContexts) {
    state.controls = [];
    state.budget = 60000;
    state.cut = false;
    const runs = [];
    for (const context of foundContexts) {
        observe(context);
        collectRuns(context, runs);
    }
    // Whatever the walk itself set off is already in the list.
    for (const observer of state.observers) observer.takeRecords();
    return runs;
}

