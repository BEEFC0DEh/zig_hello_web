const std = @import("std");
const Connection = std.net.Server.Connection;

pub const Method = enum {
    GET,
    UNSUPPORTED,

    pub fn init(name: []const u8) Method {
        return MethodMap.get(name) orelse Method.UNSUPPORTED;
    }
};

const Map = std.static_string_map.StaticStringMap;
const MethodMap = Map(Method).initComptime(.{
    .{ "GET", Method.GET },
});

const Request = struct {
    method: Method,
    uri: []const u8,
    version: []const u8,

    pub fn init(method: Method,
                uri: []const u8,
                version: []const u8) Request {
        return Request{
            .method = method,
            .uri = uri,
            .version = version,
        };
    }

    pub fn format(
        self: Request,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("request.Request{{ {any} {s} {s} }}", .{
            self.method, self.uri, self.version
        });
    }
};

pub fn readRequest(conn: Connection,
                    buffer: [] u8) !void {
    const reader = conn.stream.reader();
    _ = try reader.read(buffer);
}

pub fn parseRequest(text: []const u8) Request {
    const line_index = std.mem.indexOfScalar(
        u8, text, '\r'
    ) orelse text.len;

    var iterator = std.mem.splitScalar(
        u8, text[0..line_index], ' '
    );
    const method = Method.init(iterator.next().?);
    const uri = iterator.next() orelse "";
    const version = iterator.next() orelse "";
    const request = Request.init(method, uri, version);
    return request;
}

test "parseRequest" {
    var request: Request = undefined;
    request = parseRequest("");
    try std.testing.expectEqual(request.method, Method.UNSUPPORTED);
    try std.testing.expectEqualStrings(request.uri, "");
    try std.testing.expectEqualStrings(request.version, "");

    request = parseRequest("GET / HTTP/1.1");
    try std.testing.expectEqual(request.method, Method.GET);
    try std.testing.expectEqualStrings(request.uri, "/");
    try std.testing.expectEqualStrings(request.version, "HTTP/1.1");

    request = parseRequest("POST / HTTP/1.1");
    try std.testing.expectEqual(request.method, Method.UNSUPPORTED);
    try std.testing.expectEqualStrings(request.uri, "/");
    try std.testing.expectEqualStrings(request.version, "HTTP/1.1");
}

test "parseRequest fuzzing" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            _ = parseRequest(input);
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
