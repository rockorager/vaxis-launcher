const std = @import("std");
const vaxis = @import("vaxis");

const json = std.json;
const log = std.log;
const mem = std.mem;
const vxfw = vaxis.vxfw;

pub const std_options: std.Options = .{
    .log_level = .err,
};

const request = struct {
    const activate =
        \\{{"Activate": {d}}}
        \\
    ;

    const activate_context =
        \\{{"ActivateContext": {{ "id": {d}, "context": {d} }} }}
        \\
    ;

    const complete =
        \\{{"Complete": {d}}}
        \\
    ;

    const context =
        \\{{"Context": {d}}}
        \\
    ;

    const exit =
        \\"Exit"
        \\
    ;

    const interrupt =
        \\"Interrupt"
        \\
    ;

    const quit =
        \\{{"Quit": {d}}}
        \\
    ;

    const search =
        \\{{"Search": "{s}"}}
        \\
    ;
};

const SearchResult = struct {
    id: u32,
    name: []const u8,
    description: []const u8,
    icon: ?IconSource = null,
    category_icon: ?IconSource = null,
    window: ?[2]u32 = null,
};

const IconSource = union(enum) {
    Name: []const u8,
    Mime: []const u8,
};

const ResponseType = enum {
    close,
    context,
    desktop_entry,
    update,
    fill,
};

const Response = union(ResponseType) {
    close,
    context, // TODO:
    desktop_entry: []const u8,
    update: json.Parsed([]const SearchResult),
    fill: []const u8,

    fn fromString(str: []const u8) ?ResponseType {
        if (mem.eql(u8, "Close", str))
            return .close;
        if (mem.eql(u8, "Context", str))
            return .context;
        if (mem.eql(u8, "DesktopEntry", str))
            return .desktop_entry;
        if (mem.eql(u8, "Update", str))
            return .update;
        if (mem.eql(u8, "Fill", str))
            return .fill;
        return null;
    }
};

const Model = struct {
    gpa: std.mem.Allocator,

    list: std.ArrayList(vxfw.RichText),
    results: ?json.Parsed([]const SearchResult) = null,

    list_view: vxfw.ListView,
    text_field: vxfw.TextField,
    unicode_data: *const vaxis.Unicode,

    cmd: std.process.Child,

    read_thread: ?std.Thread = null,

    responses: vaxis.Queue(Response, 16) = .{},

    fn deinit(self: *Model) void {
        if (self.cmd.stdin) |cmd| {
            cmd.writeAll(request.exit) catch {};
        }
        if (self.read_thread) |thread| {
            thread.join();
        }
        if (self.results) |items|
            items.deinit();
        self.text_field.deinit();
        self.list.deinit();
    }

    pub fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Model.typeErasedEventHandler,
            .drawFn = Model.typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => {
                // Initialize the filtered list
                self.cmd.stdin_behavior = .Pipe;
                self.cmd.stdout_behavior = .Pipe;
                self.cmd.stderr_behavior = .Pipe;
                self.cmd.spawn() catch |err| {
                    switch (err) {
                        error.FileNotFound => @panic("file not found"),
                        else => return err,
                    }
                };
                self.read_thread = try std.Thread.spawn(.{}, Model.readThread, .{self});
                try ctx.requestFocus(self.text_field.widget());
                try ctx.tick(16, self.widget());
            },
            .tick => {
                while (self.responses.tryPop()) |response| {
                    switch (response) {
                        .close => {
                            ctx.quit = true;
                            return;
                        },
                        .context => {},
                        .desktop_entry => |entry| {
                            defer self.gpa.free(entry);
                            var arena = std.heap.ArenaAllocator.init(self.gpa);
                            defer arena.deinit();
                            const de = try DesktopEntry.loadFromPathLeaky(arena.allocator(), entry);
                            const main_group = de.desktopEntry();
                            var exec = std.ArrayList(u8).init(arena.allocator());
                            const exec_line = main_group.exec() orelse {
                                // Exit??
                                @panic("TODO: no exec");
                            };
                            var iter = std.mem.tokenizeScalar(u8, exec_line, ' ');
                            const codes: []const []const u8 = &.{
                                "%f", // single file
                                "%F", // list of files
                                "%u", // single url
                                "%U", // list of urls
                                "%d", // deprecated
                                "%D", // deprecated
                                "%n", // deprecated
                                "%N", // deprecated
                                "%i", // icon key
                                "%c", // translated name of application
                                "%k", // location of desktop file as uri
                                "%v", // deprecated
                                "%m", // deprecated
                            };
                            outer: while (iter.next()) |item| {
                                for (codes) |code| {
                                    if (mem.eql(u8, code, item))
                                        continue :outer;
                                }
                                if (exec.items.len > 0) {
                                    try exec.append(' ');
                                }
                                try exec.appendSlice(item);
                            }

                            const argv = &.{
                                "swaymsg",
                                "exec",
                                exec.items,
                            };

                            var launch = std.process.Child.init(argv, self.gpa);
                            const ret = try launch.spawnAndWait();
                            switch (ret) {
                                .Exited => |code| {
                                    if (code != 0) {
                                        log.err("failed to launch: {s}", .{exec.items});
                                        @panic("failure to launch");
                                    }
                                },
                                else => {
                                    log.err("failed to launch: {s}", .{exec.items});
                                    @panic("failure to launch");
                                },
                            }
                            ctx.quit = true;
                        },
                        .update => |update| {
                            try self.handleUpdate(update);
                            ctx.redraw = true;
                        },
                        .fill => |fill| {
                            ctx.redraw = true;
                            defer self.gpa.free(fill);
                            self.text_field.clearAndFree();
                            try self.text_field.insertSliceAtCursor(fill);
                            try Model.onChange(self, ctx, fill);
                        },
                    }
                }
                try ctx.tick(16, self.widget());
            },
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true }) or
                    key.matches(vaxis.Key.escape, .{}))
                {
                    ctx.quit = true;
                    return;
                }
                return self.list_view.handleEvent(ctx, event);
            },
            .focus_in => {
                return ctx.requestFocus(self.text_field.widget());
            },
            else => {},
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();

        var list_view: vxfw.SubSurface = .{
            .origin = .{ .row = 2, .col = 0 },
            .surface = try self.list_view.draw(ctx.withConstraints(
                ctx.min,
                .{ .width = max.width, .height = max.height - 3 },
            )),
        };
        list_view.surface.focusable = false;

        const text_field: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 2 },
            .surface = try self.text_field.draw(ctx.withConstraints(
                ctx.min,
                .{ .width = max.width, .height = 1 },
            )),
        };

        const prompt: vxfw.Text = .{ .text = "", .style = .{ .fg = .{ .index = 4 } } };

        const prompt_surface: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try prompt.draw(ctx.withConstraints(ctx.min, .{ .width = 2, .height = 1 })),
        };

        const children = try ctx.arena.alloc(vxfw.SubSurface, 3);
        children[0] = list_view;
        children[1] = text_field;
        children[2] = prompt_surface;

        return .{
            .size = max,
            .widget = self.widget(),
            .focusable = true,
            .buffer = &.{},
            .children = children,
        };
    }

    fn widgetBuilder(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *const Model = @ptrCast(@alignCast(ptr));
        if (idx >= self.list.items.len) return null;

        return self.list.items[idx].widget();
    }

    fn onChange(maybe_ptr: ?*anyopaque, _: *vxfw.EventContext, str: []const u8) anyerror!void {
        const ptr = maybe_ptr orelse return;
        const self: *Model = @ptrCast(@alignCast(ptr));
        const search_request = try std.fmt.allocPrint(self.gpa, request.search, .{str});
        defer self.gpa.free(search_request);
        const cmd = self.cmd.stdin orelse unreachable;
        try cmd.writeAll(search_request);

        self.list_view.scroll.top = 0;
        self.list_view.scroll.offset = 0;
        self.list_view.cursor = 0;
    }

    fn onSubmit(maybe_ptr: ?*anyopaque, _: *vxfw.EventContext, _: []const u8) anyerror!void {
        const ptr = maybe_ptr orelse unreachable;
        const self: *Model = @ptrCast(@alignCast(ptr));
        const cmd = self.cmd.stdin orelse unreachable;
        {
            const activate = try std.fmt.allocPrint(
                self.gpa,
                request.complete,
                .{self.list_view.cursor},
            );
            defer self.gpa.free(activate);
            try cmd.writeAll(activate);
        }

        const activate = try std.fmt.allocPrint(
            self.gpa,
            request.activate,
            .{self.list_view.cursor},
        );
        defer self.gpa.free(activate);
        try cmd.writeAll(activate);
    }

    fn handleUpdate(self: *Model, update: json.Parsed([]const SearchResult)) anyerror!void {
        if (self.results) |items|
            items.deinit();
        self.results = update;
        self.list.clearAndFree();
        const arena = update.arena.allocator();
        const items = update.value;
        for (items) |item| {
            if (item.icon) |icon| {
                switch (icon) {
                    .Name => |name| log.debug("icon name={s}", .{name}),
                    .Mime => |mime| log.debug("icon mime={s}", .{mime}),
                }
            }
            const spans = try arena.alloc(vxfw.RichText.TextSpan, 3);
            spans[0] = .{
                .text = item.name,
                .style = .{
                    .fg = .{ .index = 4 },
                    .bold = true,
                },
            };
            spans[1] = .{ .text = "  " };
            spans[2] = .{
                .text = item.description,
                .style = .{ .italic = true },
            };
            try self.list.append(.{ .text = spans });
        }
    }

    fn readThread(self: *Model) !void {
        const reader = self.cmd.stdout.?.reader();
        var buf = std.ArrayList(u8).init(self.gpa);
        defer buf.deinit();
        while (true) {
            buf.clearRetainingCapacity();
            reader.readUntilDelimiterArrayList(&buf, '\n', 10_000_000) catch |err| {
                switch (err) {
                    error.EndOfStream => {},
                    else => log.err("read: {}", .{err}),
                }
                return;
            };
            const parsed = try json.parseFromSlice(std.json.Value, self.gpa, buf.items, .{});
            defer parsed.deinit();
            const value = parsed.value;
            switch (value) {
                .string => |str| {
                    if (mem.eql(u8, "Close", str)) {
                        self.responses.push(.close);
                    } else {
                        stringifyLog(self.gpa, "unknown response: {s}", value);
                    }
                },
                .object => |obj| {
                    const keys = obj.keys();
                    if (keys.len != 1) {
                        stringifyLog(self.gpa, "invalid response: {s}", value);
                        return;
                    }
                    const kind = Response.fromString(keys[0]) orelse {
                        stringifyLog(self.gpa, "unexpected response: {s}", value);
                        return;
                    };
                    const inner = obj.get(keys[0]) orelse unreachable;
                    switch (kind) {
                        .close => return,
                        .context => {
                            log.warn("context", .{});
                        },
                        .desktop_entry => {
                            if (inner != .object) {
                                stringifyLog(self.gpa, "unexpected response: {s}", value);
                                return;
                            }
                            const object = inner.object;
                            const path = object.get("path") orelse {
                                stringifyLog(self.gpa, "unexpected response: {s}", value);
                                return;
                            };
                            if (path != .string) {
                                stringifyLog(self.gpa, "unexpected response: {s}", value);
                                return;
                            }
                            const path_str = try self.gpa.dupe(u8, path.string);
                            self.responses.push(.{ .desktop_entry = path_str });
                        },
                        .update => {
                            const items = try json.parseFromValue([]const SearchResult, self.gpa, inner, .{});
                            self.responses.push(.{ .update = items });
                        },
                        .fill => {
                            if (inner == .string) {
                                const fill_str = try self.gpa.dupe(u8, inner.string);
                                self.responses.push(.{ .fill = fill_str });
                            } else {
                                stringifyLog(self.gpa, "unexpected response: {s}", value);
                                return;
                            }
                        },
                    }
                },
                else => unreachable,
            }
        }
    }
};

fn stringifyLog(gpa: mem.Allocator, comptime format: []const u8, value: json.Value) void {
    const stringified = json.stringifyAlloc(gpa, value, .{}) catch return;
    defer gpa.free(stringified);
    log.err(format, .{stringified});
}

const DesktopEntry = struct {
    groups: []const Group,

    const Group = struct {
        name: []const u8,
        entries: []const Entry,

        pub fn exec(self: Group) ?[]const u8 {
            for (self.entries) |entry| {
                if (!std.mem.eql(u8, "Exec", entry.key))
                    continue;
                return entry.value;
            }
            return null;
        }
    };

    const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn desktopEntry(self: DesktopEntry) Group {
        for (self.groups) |group| {
            if (std.mem.eql(u8, "Desktop Entry", group.name)) {
                return group;
            }
        }
        unreachable;
    }

    pub fn loadFromPathLeaky(arena: std.mem.Allocator, abs: []const u8) !DesktopEntry {
        const file = try std.fs.openFileAbsolute(abs, .{});
        defer file.close();

        var groups = std.ArrayList(Group).init(arena);
        var group_name: []const u8 = "";
        var entries = std.ArrayList(Entry).init(arena);

        const bytes = try file.readToEndAlloc(arena, 100_000_000);
        var iter = std.mem.splitScalar(u8, bytes, '\n');

        while (iter.next()) |line| {
            // Ignore empty and comments
            if (line.len == 0 or
                std.mem.startsWith(u8, line, "#"))
            {
                log.debug("skipping line: {s}", .{line});
                continue;
            }

            if (std.mem.startsWith(u8, line, "[")) {
                // New group
                if (group_name.len > 0 and entries.items.len > 0) {
                    // Add the group
                    const group: Group = .{
                        .name = group_name,
                        .entries = try entries.toOwnedSlice(),
                    };
                    log.debug("finishing group: {s}, n_entries={d}", .{ group_name, group.entries.len });
                    try groups.append(group);
                }
                const end = std.mem.lastIndexOfScalar(u8, line, ']') orelse unreachable;
                group_name = line[1..end];
                log.debug("new group: {s}", .{group_name});
                continue;
            }

            const idx = std.mem.indexOfScalar(u8, line, '=') orelse unreachable;
            const key = std.mem.trim(u8, line[0..idx], " ");
            const value = std.mem.trim(u8, line[idx + 1 ..], " ");
            log.debug("entry: key={s}, value={s}", .{ key, value });
            try entries.append(.{ .key = key, .value = value });
        }
        if (group_name.len > 0 and entries.items.len > 0) {
            // Add the group
            const group: Group = .{
                .name = group_name,
                .entries = try entries.toOwnedSlice(),
            };
            log.debug("finishing group: {s}, n_entries={d}", .{ group_name, group.entries.len });
            try groups.append(group);
        }
        return .{ .groups = try groups.toOwnedSlice() };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var app = try vxfw.App.init(allocator);
    defer app.deinit();

    const model = try allocator.create(Model);
    defer allocator.destroy(model);
    model.* = .{
        .list = std.ArrayList(vxfw.RichText).init(allocator),
        .list_view = .{
            .children = .{
                .builder = .{
                    .userdata = model,
                    .buildFn = Model.widgetBuilder,
                },
            },
        },
        .text_field = .{
            .buf = vxfw.TextField.Buffer.init(allocator),
            .unicode = &app.vx.unicode,
            .userdata = model,
            .onChange = Model.onChange,
            .onSubmit = Model.onSubmit,
        },
        .gpa = allocator,
        .cmd = std.process.Child.init(&.{"pop-launcher"}, allocator),
        .unicode_data = &app.vx.unicode,
    };
    defer model.deinit();

    try app.run(model.widget(), .{});
}
