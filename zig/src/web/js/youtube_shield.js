(() => {
    const host = (location.hostname || '').replace(/^www\./i, '').toLowerCase();
    if (!/(^|\.)(youtube\.com|youtube-nocookie\.com)$/i.test(host)) return;
    if (Array.isArray(window.__keaShieldPaused) && window.__keaShieldPaused.includes(host)) return;

    const AD_KEYS = new Set(['adPlacements', 'playerAds', 'adSlots', 'adBreakHeartbeatParams']);

    function stripAds(obj, depth = 0) {
        if (!obj || typeof obj !== 'object' || depth > 8) return obj;
        if (Array.isArray(obj)) {
            for (let i = 0; i < obj.length; i++) stripAds(obj[i], depth + 1);
            return obj;
        }
        for (const k of AD_KEYS) {
            if (k in obj) delete obj[k];
        }
        if (obj.playerResponse && typeof obj.playerResponse === 'object') stripAds(obj.playerResponse, depth + 1);
        if (obj.response && typeof obj.response === 'object') stripAds(obj.response, depth + 1);
        return obj;
    }

    const origParse = JSON.parse;
    JSON.parse = function (...args) {
        const res = origParse.apply(this, args);
        return stripAds(res);
    };

    if (window.Response && Response.prototype && Response.prototype.json) {
        const origJson = Response.prototype.json;
        Response.prototype.json = function (...args) {
            return origJson.apply(this, args).then(data => stripAds(data));
        };
    }

    let ytPlayerResp = window.ytInitialPlayerResponse ? stripAds(window.ytInitialPlayerResponse) : undefined;
    try {
        Object.defineProperty(window, 'ytInitialPlayerResponse', {
            configurable: true,
            enumerable: true,
            get() { return ytPlayerResp; },
            set(v) { ytPlayerResp = stripAds(v); }
        });
    } catch (_) {}

    let savedMuted = null;
    let savedRate = null;

    function handleAdState() {
        const player = document.querySelector('.html5-video-player');
        if (!player) return;
        const video = player.querySelector('video.html5-main-video') || player.querySelector('video');
        const showingAd = player.classList.contains('ad-showing') || player.classList.contains('ad-interrupting');
        if (showingAd) {
            if (video) {
                if (savedMuted === null) savedMuted = video.muted;
                if (savedRate === null) savedRate = video.playbackRate || 1;
                video.muted = true;
                if (Number.isFinite(video.duration) && video.duration > 0 && video.currentTime < video.duration - 0.1) {
                    try { video.currentTime = video.duration; } catch (_) {}
                } else {
                    try { video.playbackRate = 16; } catch (_) {}
                }
            }
            const skip = player.querySelector('.ytp-ad-skip-button, .ytp-skip-ad-button, .ytp-ad-skip-button-modern, .ytp-ad-overlay-close-button');
            if (skip && typeof skip.click === 'function') {
                try { skip.click(); } catch (_) {}
            }
        } else if (savedMuted !== null || savedRate !== null) {
            if (video) {
                if (savedMuted !== null) video.muted = savedMuted;
                if (savedRate !== null) {
                    try { video.playbackRate = savedRate; } catch (_) {}
                }
            }
            savedMuted = null;
            savedRate = null;
        }
    }

    function observe() {
        const root = document.documentElement || document;
        const obs = new MutationObserver(handleAdState);
        obs.observe(root, { attributes: true, attributeFilter: ['class'], subtree: true, childList: true });
        handleAdState();
    }

    if (document.documentElement) observe();
    else window.addEventListener('DOMContentLoaded', observe, { once: true });
})();
