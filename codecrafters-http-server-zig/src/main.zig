const std = @import("std");
const net = std.net;
const stdout = std.io.getStdOut().writer();

const Arguments = struct { dir: []const u8 };

const HttpRequest = struct {
    method: []const u8,
    url: []const u8,
    version: []const u8,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    alloc: std.mem.Allocator,
    pub fn init(buffer: []const u8, alloc: std.mem.Allocator) !HttpRequest {
        var iter = std.mem.splitSequence(u8, buffer, "\r\n");

        const first_line = iter.next().?;
        var first_line_iter = std.mem.splitSequence(u8, first_line, " ");
        const method = first_line_iter.next().?;
        const url = first_line_iter.next().?;
        const version = first_line_iter.next().?;

        var headers = std.StringHashMap([]const u8).init(alloc);
        errdefer headers.deinit();
        while (iter.next()) |line| {
            if (line.len == 0) break;
            var chunks = std.mem.splitSequence(u8, line, ": ");
            const key = chunks.next().?;
            const value = chunks.next().?;
            try headers.put(key, value);
        }

        const body = iter.next().?;

        return HttpRequest{
            .method = method,
            .url = url,
            .version = version,
            .headers = headers,
            .body = body,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *HttpRequest) void {
        self.headers.deinit();
    }
};

fn status_message(status_code: u32) []const u8 {
    return switch (status_code) {
        200 => "OK",
        404 => "Not Found",
        201 => "Created",
        500 => "Internal Server Error",
        else => unreachable,
    };
}

const HttpResponse = struct {
    status_code: u32 = 200,
    headers: std.StringHashMap([]const u8),
    body: []const u8 = &.{},
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) !HttpResponse {
        const headers = std.StringHashMap([]const u8).init(alloc);
        return HttpResponse{
            .headers = headers,
            .alloc = alloc,
        };
    }

    pub fn set(self: *HttpResponse, key: []const u8, value: []const u8) !void {
        try self.headers.put(key, value);
    }

    pub fn send(self: *const HttpResponse, conn: std.net.Server.Connection, encoding: ?[]const u8) !void {
        _ = try conn.stream.writer().print("HTTP/1.1 {d} {s}\r\n", .{ self.status_code, status_message(self.status_code) });

        var iter = self.headers.iterator();
        while (iter.next()) |h| {
            _ = try conn.stream.writer().print("{s}: {s}\r\n", .{ h.key_ptr.*, h.value_ptr.* });
        }

        var encoded = false;
        if (encoding) |enc| {
            var encoding_iter = std.mem.splitSequence(u8, enc, ", ");
            while (encoding_iter.next()) |each| {
                if (std.mem.eql(u8, each, "gzip")) {
                    _ = try conn.stream.writer().print("Content-Encoding: {s}\r\n", .{each});
                    var compressed = std.ArrayList(u8).init(self.alloc);
                    defer compressed.deinit();
                    var content_reader = std.io.fixedBufferStream(self.body);
                    try std.compress.gzip.compress(content_reader.reader(), compressed.writer(), .{ .level = .fast });
                    _ = try conn.stream.writer().print("Content-Length: {d}\r\n", .{compressed.items.len});
                    _ = try conn.stream.write("\r\n");

                    _ = try conn.stream.writer().print("{s}", .{compressed.items});
                    encoded = true;
                    break;
                }
            }
        }

        if (!encoded) {
            _ = try conn.stream.writer().print("Content-Length: {d}\r\n", .{self.body.len});
            _ = try conn.stream.write("\r\n");

            _ = try conn.stream.writer().print("{s}", .{self.body});
        }
    }

    pub fn deinit(self: *HttpResponse) void {
        self.headers.deinit();
    }

    pub fn err(code: u32, alloc: std.mem.Allocator) !HttpResponse {
        var resp = try HttpResponse.init(alloc);
        resp.status_code = code;
        return resp;
    }
};

const Matcher = *const fn ([]const u8, []const u8) bool;
const Handler = *const fn (HttpRequest, std.mem.Allocator, Arguments) anyerror!HttpResponse;

const Route = struct {
    method: []const u8,
    path: []const u8,
    matcher: Matcher,
    handler: Handler,
    pub fn get(path: []const u8, matcher: Matcher, handler: Handler) Route {
        return Route{ .method = "GET", .path = path, .matcher = matcher, .handler = handler };
    }
    pub fn post(path: []const u8, matcher: Matcher, handler: Handler) Route {
        return Route{ .method = "POST", .path = path, .matcher = matcher, .handler = handler };
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn startsWith(a: []const u8, b: []const u8) bool {
    return std.mem.startsWith(u8, a, b);
}

const HttpServer = struct {
    listener: net.Server,
    routes: []const Route,
    args: Arguments,
    pub fn start(self: *HttpServer, alloc: std.mem.Allocator) !void {
        while (true) {
            const conn = try self.listener.accept();
            defer conn.stream.close();
            try stdout.print("client connected!\n", .{});
            const buffer = try alloc.alloc(u8, 1024);
            defer alloc.free(buffer);
            _ = try conn.stream.read(buffer);
            var request = try HttpRequest.init(buffer, alloc);
            defer request.deinit();

            var notfound = true;

            for (self.routes) |route| {
                if (eql(route.method, request.method) and route.matcher(request.url, route.path)) {
                    var resp = try route.handler(request, alloc, self.args);
                    try resp.send(conn, request.headers.get("Accept-Encoding"));
                    notfound = false;
                    break;
                }
            }

            if (notfound) {
                var resp = try HttpResponse.err(404, alloc);
                _ = try resp.send(conn, null);
            }
        }
    }
};

fn run(routes: []const Route, alloc: std.mem.Allocator, args: Arguments) !void {
    const address = try net.Address.resolveIp("127.0.0.1", 4221);
    var listener = try address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    var server = HttpServer{ .listener = listener, .routes = routes, .args = args };
    try server.start(alloc);
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    var dirname: []u8 = undefined;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--directory")) {
            dirname = @constCast(args.next().?);
        }
    }

    const arguments = Arguments{ .dir = dirname };

    const routes = .{
        Route.get("/", eql, root),
        Route.get("/echo", startsWith, echo),
        Route.get("/user-agent", eql, user_agent),
        Route.get("/files", startsWith, send_file),
        Route.post("/files", startsWith, create_file),
    };

    var thread_pool = std.ArrayList(std.Thread).init(alloc);
    defer thread_pool.deinit();

    for (0..4) |_| {
        try thread_pool.append(try std.Thread.spawn(.{}, run, .{ &routes, alloc, arguments }));
    }

    for (thread_pool.items) |thread| {
        thread.join();
    }
}

pub fn root(_: HttpRequest, alloc: std.mem.Allocator, _: Arguments) !HttpResponse {
    const resp = try HttpResponse.init(alloc);
    return resp;
}

pub fn echo(req: HttpRequest, alloc: std.mem.Allocator, _: Arguments) !HttpResponse {
    var resp = try HttpResponse.init(alloc);
    try resp.set("Content-Type", "text/plain");
    resp.body = req.url[6..];
    return resp;
}

pub fn user_agent(req: HttpRequest, alloc: std.mem.Allocator, _: Arguments) !HttpResponse {
    var resp = try HttpResponse.init(alloc);
    try resp.set("Content-Type", "text/plain");
    resp.body = req.headers.get("User-Agent").?;
    return resp;
}

fn send_file(req: HttpRequest, alloc: std.mem.Allocator, args: Arguments) !HttpResponse {
    const dir = std.fs.cwd().openDir(args.dir, .{}) catch return HttpResponse.err(404, alloc);
    const file = dir.openFile(req.url[7..], .{}) catch return HttpResponse.err(404, alloc);
    defer file.close();
    const file_buffer = try file.readToEndAlloc(alloc, 1024 * 1024);

    var resp = try HttpResponse.init(alloc);
    try resp.set("Content-Type", "application/octet-stream");
    resp.body = file_buffer;
    return resp;
}

fn create_file(req: HttpRequest, alloc: std.mem.Allocator, args: Arguments) !HttpResponse {
    const dir = std.fs.cwd().openDir(args.dir, .{}) catch return HttpResponse.err(404, alloc);
    const file = try dir.createFile(req.url[7..], .{});
    defer file.close();
    const len = req.headers.get("Content-Length").?;
    const n = try std.fmt.parseInt(u64, len, 10);
    _ = try file.writeAll(req.body[0..n]);

    var resp = try HttpResponse.init(alloc);
    resp.status_code = 201;
    return resp;
}
