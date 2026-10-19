//! Bench UNIX domain socket server (`<SUPPORT>/bench.sock`):
//! Uses `nanoui.fdwatch` (libdispatch read source on the main queue) to serve
//! `./bench` and Python test commands (`probe`, `tabs`, `open`, `go`, `close`,
//! `select`, `wait`, `eval`, `field`, `press`, `mouse`, `panels`, `split`,
//! `sitesearch`, `bookmarks`, `run`, `answer`, `quit`).
const std = @import("std");
const nanoui = @import("nanoui");
const objc = nanoui.objc;
const ui = nanoui.ui;
const Browser = @import("browser.zig").Browser;
const SidePosition = @import("prefs.zig").SidePosition;
const c = struct {
    pub const AF_UNIX: c_int = 1;
    pub const SOCK_STREAM: c_int = 1;
    pub const F_GETFL: c_int = 3;
    pub const F_SETFL: c_int = 4;
    pub const O_NONBLOCK: c_int = 0x0004;
    pub const sockaddr_un = extern struct {
        sun_len: u8 = 0,
        sun_family: u8 = 1,
        sun_path: [104]u8 = @splat(0),
    };
    pub extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
    pub extern "c" fn bind(fd: c_int, addr: *const anyopaque, len: u32) c_int;
    pub extern "c" fn chmod(path: [*]const u8, mode: u16) c_int;
    pub extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
    pub extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
    pub extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*u32) c_int;
    pub extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
    pub extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
    pub extern "c" fn close(fd: c_int) c_int;
    pub extern "c" fn unlink(path: [*]const u8) c_int;
};
const cPath = @import("store.zig").cPath;
pub const BenchServer = struct {
    gpa: std.mem.Allocator,
    browser: *Browser,
    sock_path: []u8,
    listen_fd: c_int = -1,
    watch: ?nanoui.fdwatch.Watch = null,

    pub fn start(gpa: std.mem.Allocator, browser: *Browser) !?*BenchServer {
        if (!browser.prefs.bench and !browser.store.testing) return null;
        const sock_path = try browser.store.path("bench.sock");
        errdefer gpa.free(sock_path);
        if (sock_path.len >= 104) return error.PathTooLong;

        var b1: [1024]u8 = undefined;
        const path_z = cPath(&b1, sock_path) orelse return error.PathTooLong;
        _ = c.unlink(path_z);

        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);

        var addr: c.sockaddr_un = std.mem.zeroes(c.sockaddr_un);
        addr.sun_family = c.AF_UNIX;
        @memcpy(addr.sun_path[0..sock_path.len], sock_path);

        if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr_un)) != 0) return error.BindFailed;
        _ = c.chmod(path_z, 0o600);
        if (c.listen(fd, 16) != 0) return error.ListenFailed;
        _ = c.fcntl(fd, c.F_SETFL, c.fcntl(fd, c.F_GETFL, @as(c_int, 0)) | c.O_NONBLOCK);

        const self = try gpa.create(BenchServer);
        self.* = .{
            .gpa = gpa,
            .browser = browser,
            .sock_path = sock_path,
            .listen_fd = fd,
        };
        self.watch = try nanoui.fdwatch.readable(fd, self, onAccept);
        return self;
    }

    pub fn destroy(self: *BenchServer) void {
        if (self.watch) |w| w.cancel();
        if (self.listen_fd >= 0) _ = c.close(self.listen_fd);
        var b1: [1024]u8 = undefined;
        if (cPath(&b1, self.sock_path)) |pz| _ = c.unlink(pz);
        self.gpa.free(self.sock_path);
        self.gpa.destroy(self);
    }

    fn onAccept(ctx: ?*anyopaque) callconv(.c) void {
        const self: *BenchServer = @ptrCast(@alignCast(ctx orelse return));
        while (true) {
            const client = c.accept(self.listen_fd, null, null);
            if (client < 0) break;
            defer _ = c.close(client);
            _ = c.fcntl(client, c.F_SETFL, c.fcntl(client, c.F_GETFL, @as(c_int, 0)) & ~c.O_NONBLOCK);
            self.handleClient(client);
        }
    }

    fn handleClient(self: *BenchServer, client_fd: c_int) void {
        var req_buf: [16384]u8 = undefined;
        const n = c.read(client_fd, &req_buf, req_buf.len);
        if (n <= 0) return;
        const slice = std.mem.trim(u8, req_buf[0..@intCast(n)], " \t\r\n");
        if (slice.len == 0) return;

        var reply: std.ArrayList(u8) = .empty;
        defer reply.deinit(self.gpa);
        self.dispatchJson(slice, &reply);
        reply.append(self.gpa, '\n') catch return;
        _ = c.write(client_fd, reply.items.ptr, reply.items.len);
    }

    fn dispatchJson(self: *BenchServer, raw: []const u8, out: *std.ArrayList(u8)) void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, raw, .{}) catch {
            out.appendSlice(self.gpa, "{\"error\":\"bad json\"}") catch {};
            return;
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            out.appendSlice(self.gpa, "{\"error\":\"expected object\"}") catch {};
            return;
        }
        const obj = parsed.value.object;
        const verb_v = obj.get("do") orelse {
            out.appendSlice(self.gpa, "{\"error\":\"missing do\"}") catch {};
            return;
        };
        if (verb_v != .string) return;
        const verb = verb_v.string;
        const b = self.browser;

        if (std.mem.eql(u8, verb, "quit")) {
            out.appendSlice(self.gpa, "{\"ok\":true}") catch {};
            b.saveSession();
            b.history.flush();
            b.app.quit();
            return;
        }
        if (std.mem.eql(u8, verb, "probe") or std.mem.eql(u8, verb, "state") or std.mem.eql(u8, verb, "tabs")) {
            self.writeProbe(out);
            return;
        }
        if (std.mem.eql(u8, verb, "open")) {
            const url = getStr(obj, "url") orelse "";
            const bg = getBool(obj, "background") orelse false;
            const priv = getBool(obj, "private") orelse false;
            const t = b.openTab(url, !bg, priv);
            const s = std.fmt.allocPrint(self.gpa, "{{\"ok\":true,\"id\":\"{s}\",\"title\":\"{s}\",\"url\":\"{s}\"}}", .{
                &t.uuid_str, t.title(), t.url(),
            }) catch return;
            defer self.gpa.free(s);
            out.appendSlice(self.gpa, s) catch {};
            return;
        }
        if (std.mem.eql(u8, verb, "go")) {
            const url = getStr(obj, "url") orelse "";
            if (getStr(obj, "id")) |id_s| {
                if (b.tabByUuidOrShort(id_s)) |t| {
                    t.load(url);
                    if (!t.shy) b.history.record(url, t.title(), @import("browser.zig").nowEpoch());
                }
            } else {
                b.goUrl(url);
            }
            out.appendSlice(self.gpa, "{\"ok\":true}") catch {};
            return;
        }
        if (std.mem.eql(u8, verb, "close")) {
            const id_s = getStr(obj, "id") orelse "";
            if (std.mem.eql(u8, id_s, "all")) {
                while (b.tabs.items.len > 1) {
                    b.closeTab(b.tabs.items[b.tabs.items.len - 1].id);
                }
            } else if (b.tabByUuidOrShort(id_s)) |t| {
                b.closeTab(t.id);
            }
            out.appendSlice(self.gpa, "{\"ok\":true}") catch {};
            return;
        }
        if (std.mem.eql(u8, verb, "select")) {
            if (getStr(obj, "id")) |id_s| {
                if (b.tabByUuidOrShort(id_s)) |t| b.selectTab(t.id);
            }
            out.appendSlice(self.gpa, "{\"ok\":true}") catch {};
            return;
        }
        if (std.mem.eql(u8, verb, "wait")) {
            const id_s = getStr(obj, "id") orelse "";
            const t = b.tabByUuidOrShort(id_s) orelse {
                out.appendSlice(self.gpa, "{\"error\":\"no tab\"}") catch {};
                return;
            };
            t.syncState();
            const s = std.fmt.allocPrint(self.gpa, "{{\"ok\":true,\"id\":\"{s}\",\"title\":\"{s}\",\"url\":\"{s}\",\"loading\":{s}}}", .{
                &t.uuid_str, t.title(), t.url(), if (t.loading) "true" else "false",
            }) catch return;
            defer self.gpa.free(s);
            out.appendSlice(self.gpa, s) catch {};
            return;
        }
        if (std.mem.eql(u8, verb, "field")) {
            const txt = getStr(obj, "text") orelse "";
            b.omni_open = true;
            b.omni_buf.set(txt);
            b.updateOmniTyped(txt);
            b.redraw();
            const off = b.omni_offer[0..b.omni_offer_len];
            const chip = if (b.omni_chip) |ch| ch.name else "";
            const s = std.fmt.allocPrint(self.gpa, "{{\"ok\":true,\"typed\":\"{s}\",\"offer\":\"{s}\",\"chip\":\"{s}\"}}", .{
                b.omni_buf.text(), off, chip,
            }) catch return;
            defer self.gpa.free(s);
            out.appendSlice(self.gpa, s) catch {};
            return;
        }
        if (std.mem.eql(u8, verb, "press")) {
            const key = getStr(obj, "key") orelse "";
            const cmd = getBool(obj, "command") orelse false;
            const shift = getBool(obj, "shift") orelse false;
            const ctrl = getBool(obj, "control") orelse false;
            self.handleKeyPress(key, cmd, shift, ctrl);
            out.appendSlice(self.gpa, "{\"ok\":true}") catch {};
            return;
        }
        if (std.mem.eql(u8, verb, "run")) {
            const cmd_name = getStr(obj, "command") orelse "";
            self.runCommand(cmd_name);
            out.appendSlice(self.gpa, "{\"ok\":true}") catch {};
            return;
        }
        if (std.mem.eql(u8, verb, "panels")) {
            self.handlePanels(obj, out);
            return;
        }
        if (std.mem.eql(u8, verb, "sitesearch")) {
            self.handleSiteSearch(obj, out);
            return;
        }
        if (std.mem.eql(u8, verb, "split")) {
            self.handleSplit(obj, out);
            return;
        }
        if (std.mem.eql(u8, verb, "answer")) {
            const ok = getBool(obj, "ok") orelse true;
            const txt = getStr(obj, "text");
            if (b.activeTab()) |t| t.answerDialog(ok, txt);
            out.appendSlice(self.gpa, "{\"ok\":true}") catch {};
            return;
        }
        out.appendSlice(self.gpa, "{\"ok\":true}") catch {};
    }

    fn handleKeyPress(self: *BenchServer, key: []const u8, cmd: bool, shift: bool, ctrl: bool) void {
        const b = self.browser;
        if (cmd and std.mem.eql(u8, key, ".")) {
            if (b.activeTab()) |t| t.stopLoading();
        } else if (cmd and shift and std.ascii.eqlIgnoreCase(key, "y")) {
            b.chat_open = !b.chat_open;
        } else if (cmd and ctrl and std.ascii.eqlIgnoreCase(key, "b")) {
            b.marks_open = !b.marks_open;
        } else if (std.mem.eql(u8, key, "escape") or std.mem.eql(u8, key, "esc")) {
            b.omni_open = false;
            b.omni_chip = null;
            b.find_open = false;
            b.plate = .none;
        } else if (std.mem.eql(u8, key, "return") or std.mem.eql(u8, key, "enter")) {
            if (b.omni_open) b.navigateInput(b.omni_buf.text());
        } else if (std.mem.eql(u8, key, "tab")) {
            if (ctrl) b.stepTab(if (shift) -1 else 1);
        }
        if (b.window) |w| if (w.surface) |s| s.frame();
    }

    fn runCommand(self: *BenchServer, cmd_name: []const u8) void {
        const b = self.browser;
        if (std.mem.eql(u8, cmd_name, "view.ask")) {
            b.chat_open = !b.chat_open;
        } else if (std.mem.eql(u8, cmd_name, "view.bookmarksSidebar")) {
            b.marks_open = !b.marks_open;
        } else if (std.mem.eql(u8, cmd_name, "view.sidebar")) {
            b.prefs.setSidebar(!b.prefs.sidebar);
        } else if (std.mem.eql(u8, cmd_name, "view.stop")) {
            if (b.activeTab()) |t| t.stopLoading();
        }
        b.syncStageHost();
        if (b.window) |w| if (w.surface) |s| s.frame();
    }

    fn handlePanels(self: *BenchServer, obj: std.json.ObjectMap, out: *std.ArrayList(u8)) void {
        const b = self.browser;
        if (obj.get("chat")) |ch| if (ch == .object) {
            if (getBool(ch.object, "open")) |v| b.chat_open = v;
            if (getFloat(ch.object, "width")) |w| b.prefs.setChatWidth(w);
            if (getBool(ch.object, "expanded")) |e| b.chat_expanded = e;
            if (getBool(ch.object, "popped")) |p| b.prefs.setChatPopped(p);
            if (getStr(ch.object, "side")) |s| b.prefs.setChatSide(SidePosition.fromStr(s));
        };
        if (obj.get("bookmarks")) |bm| if (bm == .object) {
            if (getBool(bm.object, "open")) |v| b.marks_open = v;
            if (getFloat(bm.object, "width")) |w| b.prefs.setMarksWidth(w);
            if (getBool(bm.object, "expanded")) |e| b.marks_expanded = e;
            if (getBool(bm.object, "popped")) |p| b.prefs.setMarksPopped(p);
            if (getStr(bm.object, "side")) |s| b.prefs.setMarksSide(SidePosition.fromStr(s));
        };
        b.syncStageHost();
        if (b.window) |w| if (w.surface) |s| s.frame();
        if (getBool(obj, "benchDrag") orelse false) {
            var times: [80]f64 = @splat(0);
            if (b.window) |w| if (w.surface) |surf| {
                for (0..80) |step| {
                    const delta: f32 = if (step < 40) -3.5 else 3.5;
                    b.prefs.chat_width = std.math.clamp(b.prefs.chat_width + delta, 280, 720);
                    const t0 = ui.clock.now();
                    surf.frame();
                    const t1 = ui.clock.now();
                    times[step] = (t1 - t0) * 1000.0;
                }
            };
            std.mem.sort(f64, &times, {}, comptime std.sort.asc(f64));
            const med = (times[39] + times[40]) * 0.5;
            const p90 = times[72];
            const res = std.fmt.allocPrint(self.gpa, "{{\"median_ms\":{d:.3},\"p90_ms\":{d:.3}}}", .{ med, p90 }) catch return;
            defer self.gpa.free(res);
            out.appendSlice(self.gpa, res) catch {};
            return;
        }
        const s = std.fmt.allocPrint(self.gpa,
            \\{{"chat":{{"open":{s},"width":{d:.1},"side":"{s}","expanded":{s},"popped":{s}}},"bookmarks":{{"open":{s},"width":{d:.1},"side":"{s}","expanded":{s},"popped":{s}}}}}
        , .{
            if (b.chat_open) "true" else "false",
            b.prefs.chat_width,
            b.prefs.effectiveChatSide().asStr(),
            if (b.chat_expanded) "true" else "false",
            if (b.prefs.chat_popped) "true" else "false",
            if (b.marks_open) "true" else "false",
            b.prefs.marks_width,
            b.prefs.effectiveMarksSide().asStr(),
            if (b.marks_expanded) "true" else "false",
            if (b.prefs.marks_popped) "true" else "false",
        }) catch return;
        defer self.gpa.free(s);
        out.appendSlice(self.gpa, s) catch {};
    }

    fn handleSiteSearch(self: *BenchServer, obj: std.json.ObjectMap, out: *std.ArrayList(u8)) void {
        const b = self.browser;
        const act = getStr(obj, "action") orelse "state";
        if (std.mem.eql(u8, act, "adopt")) {
            const host = getStr(obj, "host") orelse "";
            const title = getStr(obj, "title") orelse host;
            const tmpl = getStr(obj, "template") orelse "";
            b.bookmarks.learnSite(host, title, tmpl, true);
        } else if (std.mem.eql(u8, act, "forget")) {
            if (getStr(obj, "host")) |h| b.bookmarks.forgetSite(h);
        } else if (std.mem.eql(u8, act, "off")) {
            b.prefs.searches_sites = false;
            b.omni_chip = null;
        } else if (std.mem.eql(u8, act, "on")) {
            b.prefs.searches_sites = true;
        }
        const off = b.omni_offer[0..b.omni_offer_len];
        const chip = if (b.omni_chip) |ch| ch.name else "";
        const addr = if (b.activeTab()) |t| t.url() else "";
        const s = std.fmt.allocPrint(self.gpa, "{{\"typed\":\"{s}\",\"offer\":\"{s}\",\"chip\":\"{s}\",\"address\":\"{s}\",\"editing\":{s}}}", .{
            b.omni_buf.text(), off, chip, addr, if (b.omni_open) "true" else "false",
        }) catch return;
        defer self.gpa.free(s);
        out.appendSlice(self.gpa, s) catch {};
    }

    fn handleSplit(self: *BenchServer, obj: std.json.ObjectMap, out: *std.ArrayList(u8)) void {
        const b = self.browser;
        const act = getStr(obj, "action") orelse "state";
        if (std.mem.eql(u8, act, "pair")) {
            if (getStr(obj, "right")) |r_s| {
                if (b.tabByUuidOrShort(r_s)) |rt| b.pairSplit(rt.id);
            }
        } else if (std.mem.eql(u8, act, "swap")) {
            b.swapSplit();
        } else if (std.mem.eql(u8, act, "even")) {
            b.evenSplit();
        } else if (std.mem.eql(u8, act, "close") or std.mem.eql(u8, act, "closeBoth")) {
            b.closeSplit();
        } else if (std.mem.eql(u8, act, "fraction")) {
            if (getFloat(obj, "fraction")) |f| {
                b.split_fraction = std.math.clamp(f, 0.2, 0.8);
            }
        }
        if (b.window) |w| if (w.surface) |s| s.frame();
        self.writeProbe(out);
    }

    fn writeProbe(self: *BenchServer, out: *std.ArrayList(u8)) void {
        const b = self.browser;
        if (b.window) |w| if (w.surface) |s| s.frame();
        const r = b.active_page_frame;
        const head = std.fmt.allocPrint(self.gpa,
            \\{{"ok":true,"engine":"zig-nanoui","sidebar":{s},"sideWidth":{d:.1},"chatOpen":{s},"chatWidth":{d:.1},"marksOpen":{s},"marksWidth":{d:.1},"splitFraction":{d:.3},"activePageFrame":[{d:.1},{d:.1},{d:.1},{d:.1}],"tabs":[
        , .{
            if (b.prefs.sidebar) "true" else "false",
            b.prefs.side_width,
            if (b.chat_open) "true" else "false",
            b.prefs.chat_width,
            if (b.marks_open) "true" else "false",
            b.prefs.marks_width,
            b.split_fraction,
            r.x,
            r.y,
            r.w,
            r.h,
        }) catch return;
        defer self.gpa.free(head);
        out.appendSlice(self.gpa, head) catch return;

        for (b.tabs.items, 0..) |t, i| {
            if (i > 0) out.append(self.gpa, ',') catch return;
            const item = std.fmt.allocPrint(self.gpa, "{{\"id\":\"{s}\",\"title\":\"{s}\",\"url\":\"{s}\",\"loading\":{s},\"active\":{s}}}", .{
                &t.uuid_str,
                t.title(),
                t.url(),
                if (t.loading) "true" else "false",
                if (t.id == b.active_id) "true" else "false",
            }) catch continue;
            defer self.gpa.free(item);
            out.appendSlice(self.gpa, item) catch return;
        }
        out.appendSlice(self.gpa, "]}") catch {};
    }
};

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const v = obj.get(key) orelse return null;
    return if (v == .bool) v.bool else null;
}

fn getFloat(obj: std.json.ObjectMap, key: []const u8) ?f32 {
    const v = obj.get(key) orelse return null;
    if (v == .float) return @floatCast(v.float);
    if (v == .integer) return @floatFromInt(v.integer);
    return null;
}
