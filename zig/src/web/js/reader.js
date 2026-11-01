(function () {
  // Markdown already rendered into an <article> by Kea: read that, as it is.
  var mdPrebuilt = !!window.__keaMarkdownArticle;
  if (mdPrebuilt) delete window.__keaMarkdownArticle;
  // Its Markdown twin failed to load: the HTML page is what there is.
  var skipMdLink = !!window.__keaSkipMdLink;
  if (skipMdLink) delete window.__keaSkipMdLink;
  if (!mdPrebuilt) {
    if (document.contentType === 'text/markdown' || document.contentType === 'text/x-markdown' || /\.md$/i.test(location.pathname)) {
      var rawMd = document.body ? (document.body.innerText || '') : '';
      if (rawMd.trim().length > 0) return 'md:' + rawMd;
    }
    var mdLink = skipMdLink ? null : document.querySelector('link[rel="alternate"][type="text/markdown"], link[rel="alternate"][type="text/x-markdown"]');
    if (mdLink && mdLink.href) {
      try {
        var mdUrl = new URL(mdLink.href, location.href);
        if (mdUrl.origin === location.origin) return 'mdurl:' + mdUrl.href;
      } catch (_) {}
    }
  }
  function prose(el) {
    var paragraphs = el.querySelectorAll('p');
    if (paragraphs.length < 2) return 0;
    var letters = 0;
    for (var i = 0; i < paragraphs.length; i++) {
      letters += (paragraphs[i].innerText || '').length;
    }
    if (letters < 400) return 0;
    // A rail of related links has plenty of text and nothing to read.
    var links = el.querySelectorAll('a').length;
    return letters / (1 + links * 14);
  }

  function best() {
    var candidates = document.querySelectorAll(
      'article, main, [role="main"], .post, .entry, .article, .content, #content, div, section'
    );
    var top = null, mark = 0;
    for (var i = 0; i < candidates.length; i++) {
      var score = prose(candidates[i]);
      if (score > mark) { mark = score; top = candidates[i]; }
    }
    return top;
  }

  var article = mdPrebuilt ? document.querySelector('article') : best();
  if (!article) return 'none';

  // Every picture is resolved while the real page is still standing.
  //
  // currentSrc is what the browser actually chose and loaded, after srcset,
  // sizes and <picture> have had their say. Reading it here and writing it
  // back as a plain src is the only way to be sure the reader shows the
  // same image the page did — copying the markup alone gets you a lazy
  // placeholder, or nothing at all.
  var late = ['data-src', 'data-original', 'data-lazy-src', 'data-lazy',
              'data-full-src', 'data-hi-res-src', 'data-image', 'data-echo'];
  var pictures = article.querySelectorAll('img');
  for (var i = 0; i < pictures.length; i++) {
    var picture = pictures[i];
    picture.setAttribute('loading', 'eager');
    var real = picture.currentSrc || picture.getAttribute('src') || '';
    // A one-pixel placeholder counts as nothing.
    if (!real || real.indexOf('data:image') === 0 || picture.naturalWidth <= 2) {
      for (var k = 0; k < late.length; k++) {
        var kept = picture.getAttribute(late[k]);
        if (kept) { real = kept; break; }
      }
    }
    if (real) picture.setAttribute('src', real);
    var lateSet = picture.getAttribute('data-srcset');
    if (lateSet && !picture.getAttribute('srcset')) {
      picture.setAttribute('srcset', lateSet);
    }
  }

  var heading = document.querySelector('h1');
  var title = (heading && heading.innerText.trim()) || document.title;

  var sheet = document.createElement('style');
  sheet.id = 'kea-reader-style';
  sheet.textContent = [
    'html{--kr-bg:#ffffff;--kr-ink:#171717;--kr-muted:#a3a3a3;--kr-code:#f5f5f5;--kr-rule:#e8e8e8;--kr-quote:#555555;--kr-size:18px;--kr-width:38em}',
    'html[data-kr-theme="sepia"]{--kr-bg:#f4ecd8;--kr-ink:#3b2f1e;--kr-muted:#8a7a5c;--kr-code:#ebe1c8;--kr-rule:#d9cba8;--kr-quote:#5c4b33}',
    'html[data-kr-theme="dark"]{--kr-bg:#1c1c1e;--kr-ink:#e6e6e6;--kr-muted:#8e8e93;--kr-code:#2c2c2e;--kr-rule:#3a3a3c;--kr-quote:#b0b0b5}',
    '@media (prefers-color-scheme: dark){html[data-kr-theme="auto"]{--kr-bg:#1c1c1e;--kr-ink:#e6e6e6;--kr-muted:#8e8e93;--kr-code:#2c2c2e;--kr-rule:#3a3a3c;--kr-quote:#b0b0b5}}',
    'html,body{background:var(--kr-bg) !important;margin:0 !important;padding:0 !important}',
    '#kea-reader{max-width:var(--kr-width);margin:0 auto;padding:72px 24px 160px;',
    'font:400 18px/1.72 ui-serif,Georgia,"Times New Roman",serif;font-size:var(--kr-size);color:var(--kr-ink)}',
    '#kea-reader h1{font:600 30px/1.24 -apple-system,BlinkMacSystemFont,sans-serif;',
    'margin:0 0 8px;letter-spacing:-0.01em}',
    '#kea-reader .kea-from{font:400 12px/1 -apple-system,sans-serif;color:var(--kr-muted);',
    'margin:0 0 40px;text-transform:uppercase;letter-spacing:.06em}',
    '#kea-reader p{margin:0 0 1.35em}',
    '#kea-reader img,#kea-reader video,#kea-reader iframe{max-width:100%;',
    'height:auto;border-radius:6px;margin:1.6em 0;display:block}',
    '#kea-reader iframe{width:100%;aspect-ratio:16/9;height:auto;border:0}',
    '#kea-reader figure{margin:1.8em 0}',
    '#kea-reader figcaption{font:400 13px/1.5 -apple-system,sans-serif;',
    'color:var(--kr-muted);margin-top:.6em}',
    '#kea-reader a{color:var(--kr-ink);text-underline-offset:3px}',
    '#kea-reader h2,#kea-reader h3{font:600 20px/1.3 -apple-system,sans-serif;',
    'margin:2em 0 .6em}',
    '#kea-reader pre,#kea-reader code{font-family:ui-monospace,monospace;font-size:14px}',
    '#kea-reader pre{background:var(--kr-code);padding:14px;border-radius:8px;overflow:auto}',
    '#kea-reader blockquote{margin:1.6em 0;padding-left:1.2em;',
    'border-left:2px solid var(--kr-rule);color:var(--kr-quote)}',
    '#kea-reader-theme{position:fixed;top:18px;right:22px;display:flex;gap:4px;padding:3px;border-radius:999px;background:var(--kr-code);border:1px solid var(--kr-rule);opacity:0.35;transition:opacity 0.15s ease;font:500 11px/1 -apple-system,sans-serif;z-index:9999}',
    '#kea-reader-theme:hover{opacity:1}',
    '#kea-reader-theme button{all:unset;cursor:pointer;padding:4px 8px;border-radius:999px;color:var(--kr-muted)}',
    '#kea-reader-theme button[data-active="true"]{background:var(--kr-bg);color:var(--kr-ink);box-shadow:0 1px 2px rgba(0,0,0,0.08)}'
  ].join('');

  var wrap = document.createElement('div');
  wrap.id = 'kea-reader';
  wrap.innerHTML = article.innerHTML;

  // What was arranged around the words rather than being part of them.
  // Not header: an article's opening image lives there as often as not.
  var clutter = wrap.querySelectorAll(
    'script,style,noscript,form,nav,aside,footer,button,input,select,textarea,' +
    '[role="complementary"],[role="navigation"],[role="banner"],[aria-hidden="true"]'
  );
  for (var c = 0; c < clutter.length; c++) clutter[c].remove();

  // Embedded video is part of the article; every other frame is not.
  var players = /youtube|youtu\.be|vimeo|dailymotion|loom\.com|streamable|wistia|ted\.com/i;
  var frames = wrap.querySelectorAll('iframe');
  for (var f = 0; f < frames.length; f++) {
    var where = frames[f].getAttribute('src') || frames[f].getAttribute('data-src') || '';
    if (players.test(where)) {
      frames[f].setAttribute('src', where);
      frames[f].removeAttribute('height');
      frames[f].removeAttribute('width');
    } else {
      frames[f].remove();
    }
  }

  // A picture with nothing behind it is a broken icon, which is worse than
  // no picture at all.
  var kept = wrap.querySelectorAll('img');
  for (var g = 0; g < kept.length; g++) {
    var src = kept[g].getAttribute('src') || '';
    if (!src || src.indexOf('data:image') === 0) kept[g].remove();
  }

  var top = document.createElement('h1');
  top.textContent = title;
  var from = document.createElement('p');
  from.className = 'kea-from';
  from.textContent = location.host.replace(/^www\./, '');

  var themeBar = document.createElement('div');
  themeBar.id = 'kea-reader-theme';
  var themes = [['auto', 'Auto'], ['light', 'Light'], ['sepia', 'Sepia'], ['dark', 'Dark']];
  var curTheme = document.documentElement.dataset.krTheme || 'auto';
  themes.forEach(function (pair) {
    var btn = document.createElement('button');
    btn.textContent = pair[1];
    btn.dataset.theme = pair[0];
    btn.dataset.active = pair[0] === curTheme ? 'true' : 'false';
    btn.addEventListener('click', function () {
      document.documentElement.dataset.krTheme = pair[0];
      var all = themeBar.querySelectorAll('button');
      for (var b = 0; b < all.length; b++) all[b].dataset.active = all[b] === btn ? 'true' : 'false';
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.keaReader) {
        window.webkit.messageHandlers.keaReader.postMessage(pair[0]);
      }
    });
    themeBar.appendChild(btn);
  });
  document.body.innerHTML = '';
  document.head.appendChild(sheet);
  wrap.insertBefore(from, wrap.firstChild);
  wrap.insertBefore(top, wrap.firstChild);
  wrap.insertBefore(themeBar, wrap.firstChild);
  document.body.appendChild(wrap);
  window.scrollTo(0, 0);
  return 'read';
})();
