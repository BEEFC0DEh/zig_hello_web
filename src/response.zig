const std = @import("std");
const Connection = std.net.Server.Connection;

const CRLF = "\r\n";
const CRLFCRLF = CRLF ++ CRLF;
const HTML = "html";
const PLAIN = "plain";
pub fn sendHeaders(connection: Connection, code: u16, textType: []const u8) !void {
    const template = (
        "HTTP/1.1 {s}" ++ CRLF
        ++ "Transfer-Encoding: chunked" ++ CRLF
        ++ "Content-Type: text/{s}" ++ CRLF
        ++ "Connection: close" ++ CRLFCRLF
    );

    var buffer: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    const response = switch (code) {
        200 => "200 OK",
        404 => "404 Not Found",
        500 => "500 Internal Server Error",
        else => "501 Not Implemented"
    };

    const message = try std.fmt.allocPrint(allocator, template, .{response, textType});
    defer allocator.free(message);
    try connection.stream.writeAll(message);
}

pub fn sendBody(connection: Connection, payload: []const u8) !void {
    const template = (
        "{x}" ++ CRLF
        ++ "{s}" ++ CRLF
    );

    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();
    const message = try std.fmt.allocPrint(allocator, template, .{payload.len, payload});
    defer allocator.free(message);
    try connection.stream.writeAll(message);
}

pub fn sendResponse(connection: Connection, code: u16, payload: []const u8) !void {
    std.debug.print("Sending a long response:\n{s}\n", .{payload});
    var sentSize: usize = 0;
    var delta: usize = 0;
    try sendHeaders(connection, code, HTML);
    while (sentSize < payload.len) {
        delta = @min(4000, payload.len - sentSize);
        try sendBody(connection, payload[sentSize..sentSize + delta]);
        sentSize += delta;
    }
    try sendBody(connection, "");
    // https://ziggit.dev/t/implement-a-basic-try-catch-block/2650/2
//     (trySend: {
//         var sentSize: usize = 0;
//         var delta: usize = 0;
//         sendHeaders(connection, code, HTML) catch |err| break :trySend err;
//         while (sentSize < payload.len) {
//             delta = std.math.Min(4000, payload.len - sentSize);
//             sendBody(connection, payload[sentSize..sentSize + delta]) catch |err| break :trySend err;
//             sentSize += delta;
//         }
//         sendBody(connection, "") catch |err| break :trySend err;
//     } catch |err| {
//         std.debug.print("sendLongResponse: {any}\n", .{err});
//     });
}

pub fn sendFile(connection: Connection, path: []const u8) !void{
    std.debug.print("Sending a file: '{s}'\n", .{path});
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var buffer: [4000]u8 = undefined;
    var totalSize: u64 = 0;
    try sendHeaders(connection, 200, PLAIN);
    const fileStat = try file.stat();
    while (totalSize < fileStat.size) {
        const size = try file.read(&buffer);
        totalSize += size;
        try sendBody(connection, buffer[0..size]);
    }
    try sendBody(connection, "");
//     (trySend: {
//         const file = std.fs.cwd().openFile(path, .{}) catch |err| break :trySend err;
//         defer file.close();
//
//         var buffer: [4000]u8 = undefined;
//         var totalSize: u64 = 0;
//         sendHeaders(connection, 200, PLAIN) catch |err| break :trySend err;
//         const fileStat = file.stat() catch |err| break :trySend err;
//         while (totalSize < fileStat.size) {
//             const size = file.read(&buffer) catch |err| break :trySend err;
//             totalSize += size;
//             sendBody(connection, buffer[0..size]) catch |err| break :trySend err;
//         }
//         sendBody(connection, "") catch |err| break :trySend err;
//     } catch |err| {
//         std.debug.print("sendFile: {any}\n", .{err});
//     });
}
