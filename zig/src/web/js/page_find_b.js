function beforeCodePoint(text, index) {
    if (index <= 0) return "";
    const last = text.charCodeAt(index - 1);
    if (last >= 0xDC00 && last <= 0xDFFF && index > 1) {
        const first = text.charCodeAt(index - 2);
        if (first >= 0xD800 && first <= 0xDBFF) return text.slice(index - 2, index);
    }
    return text.slice(index - 1, index);
}

function afterCodePoint(text, index) {
    if (index >= text.length) return "";
    const first = text.charCodeAt(index);
    if (first >= 0xD800 && first <= 0xDBFF && index + 1 < text.length) {
        const last = text.charCodeAt(index + 1);
        if (last >= 0xDC00 && last <= 0xDFFF) return text.slice(index, index + 2);
    }
    return text.slice(index, index + 1);
}

const wordCharacter = /^[\p{L}\p{N}\p{M}_]$/u;
function isWholeWord(text, start, end) {
    const before = beforeCodePoint(text, start);
    const after = afterCodePoint(text, end);
    return !(before && wordCharacter.test(before)) && !(after && wordCharacter.test(after));
}

function startMatching() {
    const spaced = needle.replace(/\s+/gu, " ").normalize("NFC");
    state.loose = !state.matchCase && bare(spaced) === spaced;
    const normalizedNeedle = spaced;
    const escaped = normalizedNeedle.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    state.matches = [];
    state.cursor = { run: 0, from: 0 };
    state.complete = false;
    try { state.expression = new RegExp(escaped, "gu" + (state.matchCase ? "" : "i")); }
    catch (_) { state.expression = null; state.complete = true; }
}

function makeMatch(run, start, end) {
    const from = startOf(run, start);
    const to = endOf(run, end - 1);
    if (run.control) {
        const control = run.control;
        return {
            kind: "control", win: run.win, control,
            start: from.offset, end: to.offset,
            savedStart: control.selectionStart, savedEnd: control.selectionEnd,
            savedDirection: control.selectionDirection || "none"
        };
    }
    try {
        const range = run.doc.createRange();
        range.setStart(from.node, from.offset);
        range.setEnd(to.node, to.offset);
        const rects = range.getClientRects();
        for (let i = 0; i < rects.length; i++) {
            if (rects[i].width > 0 || rects[i].height > 0) return { kind: "range", win: run.win, range };
        }
    } catch (_) {}
    return null;
}

// Goes on measuring matches until there are `until` of them or the text
// has been read to its end.
function collect(until) {
    const runs = state.runs, expression = state.expression, cursor = state.cursor;
    if (!expression || !cursor) { state.complete = true; return; }
    while (state.matches.length < until && cursor.run < runs.length) {
        const run = state.loose ? (runs[cursor.run].loose || runs[cursor.run]) : runs[cursor.run];
        expression.lastIndex = cursor.from;
        const found = expression.exec(run.text);
        if (!found) { cursor.run += 1; cursor.from = 0; continue; }
        const start = found.index;
        const end = start + found[0].length;
        cursor.from = end > start ? end : end + 1;
        if (end === start) continue;
        if (state.wholeWords && !isWholeWord(run.text, start, end)) continue;
        const match = makeMatch(run, start, end);
        if (match) state.matches.push(match);
    }
    state.complete = cursor.run >= runs.length;
}

function saveSelections(foundContexts) {
    state.savedSelections = [];
    for (const context of foundContexts) {
        try {
            const selection = context.win.getSelection();
            if (selection) {
                state.savedSelections.push({
                    win: context.win,
                    ranges: Array.from({ length: selection.rangeCount }, (_, i) => selection.getRangeAt(i).cloneRange())
                });
            }
        } catch (_) {}
    }
}

function mark(match) {
    unmarkCurrent();
    if (match.kind === "range") {
        try {
            const selection = match.win.getSelection();
            if (!selection) return;
            selection.removeAllRanges();
            selection.addRange(match.range);
            scrollRange(match.range, match.win);
        } catch (_) {}
    } else {
        try {
            match.control.setSelectionRange(match.start, match.end);
            match.control.scrollIntoView({ block: "center", inline: "nearest" });
        } catch (_) {}
    }
    state.current = match;
}

// The selection alone is drawn pale grey while the find bar has the keys,
// so every match is painted too: yellow, the current one orange. Matches
// in fields and shadow trees keep only their selection.
// Each window gets its two highlights once; after that they are only
// cleared and added to. A highlight repaints the ranges it gains or
// loses, whereas one set into or deleted from `CSS.highlights` could
// stay on screen, or stay off it, until something else was drawn.
function unpaint() {
    for (const highlights of state.painted) {
        try { highlights.all.clear(); highlights.current.clear(); } catch (_) {}
    }
    state.painted = [];
}

function highlightsIn(win) {
    const doc = win.document;
    let highlights = state.highlights.get(win);
    if (!highlights) {
        const sheet = new win.CSSStyleSheet();
        sheet.replaceSync(
            "::highlight(kea-find-match) { background-color: #ffff00; color: #000; }"
            + "::highlight(kea-find-current) { background-color: #ff9632; color: #000; }"
        );
        const current = new win.Highlight();
        current.priority = 1;
        highlights = { sheet, all: new win.Highlight(), current };
        state.highlights.set(win, highlights);
    }
    // A page may set its own sheets, or these names, again at any time.
    if (!doc.adoptedStyleSheets.includes(highlights.sheet)) {
        doc.adoptedStyleSheets = [...doc.adoptedStyleSheets, highlights.sheet];
    }
    if (win.CSS.highlights.get("kea-find-match") !== highlights.all) {
        win.CSS.highlights.set("kea-find-match", highlights.all);
    }
    if (win.CSS.highlights.get("kea-find-current") !== highlights.current) {
        win.CSS.highlights.set("kea-find-current", highlights.current);
    }
    return highlights;
}

function paint() {
    unpaint();
    // WebKit before macOS 14.2 has no highlights: the selection is all.
    if (typeof Highlight !== "function") return;
    const painted = new Map();
    for (const match of state.matches) {
        if (match.kind !== "range") continue;
        try {
            let highlights = painted.get(match.win);
            if (!highlights) {
                highlights = highlightsIn(match.win);
                painted.set(match.win, highlights);
                state.painted.push(highlights);
            }
            highlights.all.add(match.range);
        } catch (_) {}
    }
    const current = state.matches[state.index];
    if (current?.kind === "range") {
        try { painted.get(current.win)?.current.add(current.range); } catch (_) {}
    }
}

function scrollRange(range, win) {
    const target = range.startContainer;
    const element = target.nodeType === 1 ? target : target.parentElement;
    for (let ancestor = element; ancestor && ancestor !== win.document.documentElement; ancestor = ancestor.parentElement) {
        try {
            const style = win.getComputedStyle(ancestor);
            const scrollsY = /(auto|scroll|overlay)/.test(style.overflowY)
                && ancestor.scrollHeight > ancestor.clientHeight;
            const scrollsX = /(auto|scroll|overlay)/.test(style.overflowX)
                && ancestor.scrollWidth > ancestor.clientWidth;
            if (scrollsY || scrollsX) {
                const matchRect = range.getBoundingClientRect();
                const box = ancestor.getBoundingClientRect();
                if (scrollsY) {
                    if (matchRect.top < box.top) ancestor.scrollTop -= box.top - matchRect.top;
                    else if (matchRect.bottom > box.bottom) ancestor.scrollTop += matchRect.bottom - box.bottom;
                }
                if (scrollsX) {
                    if (matchRect.left < box.left) ancestor.scrollLeft -= box.left - matchRect.left;
                    else if (matchRect.right > box.right) ancestor.scrollLeft += matchRect.right - box.right;
                }
            }
        } catch (_) {}
    }
    try {
        const rect = range.getBoundingClientRect();
        const margin = 24;
        const scroller = win.document.scrollingElement;
        if (scroller && rect.top < margin) scroller.scrollTop += rect.top - margin;
        else if (scroller && rect.bottom > win.innerHeight - margin) {
            scroller.scrollTop += rect.bottom - win.innerHeight + margin;
        }
        if (scroller && rect.left < margin) scroller.scrollLeft += rect.left - margin;
        else if (scroller && rect.right > win.innerWidth - margin) {
            scroller.scrollLeft += rect.right - win.innerWidth + margin;
        }
    } catch (_) {}
    let child = win;
    while (child !== child.parent) {
        try { child.frameElement?.scrollIntoView({ block: "nearest", inline: "nearest" }); }
        catch (_) {}
        child = child.parent;
    }
}

function sameSpec() {
    return state.generation === epoch && state.query === needle
        && state.matchCase === Boolean(matchCase) && state.wholeWords === Boolean(wholeWords);
}

const changed = !sameSpec();
const currentContexts = contexts();
const documents = currentContexts.map(context => context.doc);
if (documents.length !== state.documents.length
    || documents.some((doc, index) => doc !== state.documents[index])) {
    state.dirty = true;
    for (const observer of state.observers) {
        if (!documents.includes(observer.doc)) observer.disconnect();
    }
    state.observers = state.observers.filter(observer => documents.includes(observer.doc));
    state.documents = documents;
}
for (const observer of state.observers) {
    if (observer.takeRecords().length) state.dirty = true;
}
if (state.controls.some(item => {
    try { return item.element.value !== item.value; }
    catch (_) { return true; }
})) state.dirty = true;

if (changed) {
    unmarkCurrent();
    state.savedSelections = [];
    state.generation = epoch;
    state.query = needle;
    state.matchCase = Boolean(matchCase);
    state.wholeWords = Boolean(wholeWords);
    state.index = -1;
}

const rebuilt = state.dirty || !state.runs;
if (rebuilt) {
    state.runs = buildRuns(currentContexts);
    state.dirty = false;
}
if (changed || rebuilt) {
    const oldIndex = changed ? -1 : state.index;
    const oldCurrent = oldIndex >= 0 ? state.matches[oldIndex] : null;
    startMatching();
    collect(Math.max(cap, oldIndex + 1));
    state.index = -1;
    if (oldCurrent) {
        state.index = state.matches.findIndex(candidate => {
            if (candidate.win !== oldCurrent.win || candidate.kind !== oldCurrent.kind) return false;
            if (candidate.kind === "range") return sameRange(candidate.range, oldCurrent.range);
            return candidate.control === oldCurrent.control
                && candidate.start === oldCurrent.start && candidate.end === oldCurrent.end;
        });
    }
}

if (state.matches.length === 0) {
    unmarkCurrent();
    unpaint();
    state.savedSelections = [];
    state.index = -1;
    return answer("ok", 0, 0);
}

let target;
if (changed) {
    saveSelections(currentContexts);
    target = moves;
} else if (state.index < 0) {
    // The match that was current has gone from the page: start again
    // from the first, with the page's own selection put back first.
    unmarkCurrent();
    saveSelections(currentContexts);
    target = 0;
} else {
    target = state.index + moves;
}
if (target >= state.matches.length && !state.complete) collect(target + cap);
if (target < 0 && !state.complete) collect(Infinity);
const total = state.matches.length;
state.index = ((target % total) + total) % total;
mark(state.matches[state.index]);
paint();
return answer("ok", total, state.index + 1, !state.complete || !!state.cut);
