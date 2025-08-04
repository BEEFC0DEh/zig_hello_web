// References
// https://www.youtube.com/watch?v=L967hYylZuc
// https://pedropark99.github.io/zig-book/Chapters/04-http-server.html
// https://www.openmymind.net/TCP-Server-In-Zig-Part-1-Single-Threaded/

const std           = @import("std");

const socketStruct  = @import("socket.zig");
const request       = @import("request.zig");
const response      = @import("response.zig");

// Based on https://ssojet.com/binary-encoding-decoding/percent-encoding-url-encoding-in-zig/
fn percentEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();
    for (input) |char| {
        if (char <= ' ' or char > '~') {
            // Encode non-ASCII characters
            const hex = std.fmt.hex(char);
            try output.append('%');
            try output.appendSlice(&hex);
        } else {
            try output.append(char);
        }
    }
    return allocator.dupe(u8, output.items);
}

fn percentDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%') {
            const hex = input[i + 1..i + 3];
            const char = try std.fmt.parseInt(u8, hex, 16);
            try output.append(char);
            i += 3;
        } else {
            try output.append(input[i]);
            i += 1;
        }
    }
    return allocator.dupe(u8, output.items);
}

test "percentEncodeDecode" {
    std.debug.print("test percentEncodeDecode\n", .{});
    const encoded = try percentEncode(std.testing.allocator, "/my /.cool/uri-/,test");
    defer std.testing.allocator.free(encoded);
    std.debug.print("{s}\n", .{encoded});
    const decoded = try percentDecode(std.testing.allocator, encoded);
    std.debug.print("{s}\n", .{decoded});
    defer std.testing.allocator.free(decoded);
}

fn normalizedPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try std.fs.path.resolve(allocator, &.{"", path});
}

fn normalizedPathHelper(allocator: std.mem.Allocator, path: []const u8) void {
    if (normalizedPath(allocator, path)) |result| {
        std.debug.print("{s}\n", .{result});
        allocator.free(result);
    } else |err| {
        std.debug.print("{any}\n", .{err});
    }
}

test "normalizedPath" {
    normalizedPathHelper(std.testing.allocator, "");
    normalizedPathHelper(std.testing.allocator, "/");
    normalizedPathHelper(std.testing.allocator, "/..");
    normalizedPathHelper(std.testing.allocator, "/././../.");
    normalizedPathHelper(std.testing.allocator, "/test/.././lol/././1/2/../../3");
    normalizedPathHelper(std.testing.allocator, "test/.././lol/././1/2/../../3");

    var buffer: [4]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();
    normalizedPathHelper(allocator, "/test/.././lol/././1/2/../../3");
}

fn getDirListing(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const dirTemplate = "<h1>Directory listing</h1>"
                        ++ "<h2>Directory: {s}</h2>"
                        ++ "<hr>"
                        ++ "<ul>"
                        ++ "<li><a href=\"/{s}/..\">..</a></li>"
                        ++ "{s}"
                        ++ "</ul>"
                        ++ "<hr>";

    const entryTemplate = "<li><a href=\"/{s}/{s}\">{s}</a></li>";
    var listing = std.ArrayList(u8).init(allocator);
    defer listing.deinit();

    var dir = try std.fs.cwd().openDir(
        path,
        .{ .iterate = true },
    );
    defer {
        dir.close();
    }

    const percentEncodedPath = try percentEncode(allocator, path);
    defer allocator.free(percentEncodedPath);
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const entryHtml = try std.fmt.allocPrint(
            allocator,
            entryTemplate,
            .{percentEncodedPath, entry.name, entry.name}
        );
        defer allocator.free(entryHtml);
        try listing.appendSlice(entryHtml);
    }
    const pageHtml = try std.fmt.allocPrint(allocator, dirTemplate, .{path, percentEncodedPath, listing.items});
    return pageHtml;
}

fn getDirListingHelper(allocator: std.mem.Allocator, path: []const u8) void {
    if (getDirListing(allocator, path)) |result| {
        std.debug.print("{s}\n", .{result});
        allocator.free(result);
    } else |err| {
        std.debug.print("{any}\n", .{err});
    }
}

test "getDirListing" {
    std.debug.print("test getDirListing\n", .{});
    getDirListingHelper(std.testing.allocator, "");
    getDirListingHelper(std.testing.allocator, "test");
    getDirListingHelper(std.testing.allocator, ".");
}

pub fn main() !void {
    var arenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arenaAllocator.allocator();
    defer {
        std.debug.print("ArenaAllocator.deinit().\n", .{});
        arenaAllocator.deinit();
    }
    const stdout = std.io.getStdOut().writer();

    const socket = try socketStruct.Socket.init();
    var messageBuffer: [1024]u8 = undefined;
    const message = try std.process.getCwd(&messageBuffer);
    try stdout.print(
        "Server address: {any}\n"
        ++ "Server cwd(): '{s}'",
        .{
            socket._address,
            message
        });
    var server = try socket._address.listen(.{.reuse_port = true});
    defer {
        std.debug.print("Closing the server.\n", .{});
        server.deinit();
    }

    var buffer: [4096]u8 = undefined;
    while (true) {
        const connection = try server.accept();
        const buff_slice = buffer[0..buffer.len];
        for (0..buffer.len) |i| {
            buffer[i] = 0;
        }
        try stdout.print("Got connection: {any}\n", .{connection});
        try request.readRequest(connection, buff_slice);
        try stdout.print("{s}\n", .{buffer});
        const req = request.parseRequest(buff_slice);
        try stdout.print("{any}\n", .{req});

        const responseTemplate = "<html><body><h1>{s}</h1></body></html>";
        errdefer |err| {
            std.debug.print("{any}\n", .{err});
            var errBuffer: [256]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&errBuffer);
            const errAllocator = fba.allocator();
            const formatted = std.fmt.allocPrint(errAllocator, responseTemplate, .{"Internal server error."});
//             defer allocator.free(payload); // Unnecessary because the buffer will be deleted anyway.
            if (formatted) |payload| {
                response.sendResponse(connection, 500, payload) catch {};
            } else |sendErr| {
                std.debug.print("Couldn't send an error response because of {any}\n", .{sendErr});
            }
        }

        switch (req.method) {
            .GET => {
                const normalizedUri = try normalizedPath(allocator, req.uri[1..req.uri.len]);
                defer allocator.free(normalizedUri);
                const percentDecodedUri = try percentDecode(allocator, normalizedUri);
                defer allocator.free(percentDecodedUri);
                if (std.fs.cwd().statFile(percentDecodedUri)) |file| {
                    switch (file.kind) {
                        .directory => {
                            const dirListing = try getDirListing(allocator, percentDecodedUri);
                            try response.sendResponse(connection, 200, dirListing);
                        },
                        .file => {
                            try response.sendFile(connection, percentDecodedUri);
                        },
                        else => {}
                    }
                } else |err| {
                    if (err == error.FileNotFound) {
                        const payload = try std.fmt.allocPrint(allocator, responseTemplate, .{"Not found"});
                        defer allocator.free(payload);
                        try response.sendResponse(connection, 404, payload);
                    } else {
                        return @as(anyerror!void, err); // https://github.com/ziglang/zig/issues/22987
                    }
                }

            },
            else => {
                const payload = try std.fmt.allocPrint(allocator, responseTemplate, .{"The requested method is not implemented."});
                defer allocator.free(payload);
                try response.sendResponse(connection, 501, payload);
            }
        }
    }
}

// Впечатления от языка
// + Приятная инфраструктура: удобная заготовка проекта, встроенное тестирование и фаззинг (!).
// + Очень открытое сообщество. Авторы языка активно отвечают на вопросы и участвуют в обсуждениях.
// + Есть работа со строками на этапе компиляции. Наконец-то кто-то это сделал!
// + Явное управление памятью через аллокаторы. Есть несколько готовых аллокаторов под разные сценарии.
// + Неиспользуемые переменные == ошибка компиляции.
// + Перекрытие имён из внешнего скоупа == ошибка компиляции.
// + Присутствует метапрограммирование.
// + Маленький размер выходного исполняемого файла. Для этого кода: debug=2.8 MiB, release-fast=1.1 MiB, release-small=25 KiB
// - Документация на аллокаторы практически отсуствует. Очень сложно понять какой выбрать и как правильно пользоваться.
// - Управление памятью иногда очень запутанное. См. Dir.Iterator.iterate();
// - Почему posix.toPosixPath() не UB?!
// - Dir.openDir() молча принимает относительные и абсолютные пути. https://github.com/ziglang/zig/issues/7540
// - Текст ошибок компилятора очень часто бесполезен. Примерно как ошибки компиляции шаблонов в C++: логика есть, но не зная глубоких нюансов языка не разобраться о чём речь.
// - В целом строки это боль. Изначальная идея хорошая, но слайсами всё испортили.
// - Нет нормализации путей для операций с ФС.
// - В целом складывается ощущение, что с различные нюансы системного программирования авторы изучают по ходу разработки
// - Язык позиционируется как общего назначения, но в глаза очень бросается специализированность языка под какие-то специфичные задачи авторов.
// - Язык не всегда следует своему же дзен. Например, строки и слайсы противоречат принципу "Only one obvious way to do things.".
// - Приходится костылить странные конструкции чтобы сделать некоторые тривиальные вещи.

// Итого:
// Мне не понравилось. В языке реализованы интересные концепции, тулинг неплох и есть прямая
// совместимость с C, но я совсем не получал удовольствие от процесса из-за постоянных проблеем
// то с документацией, то с необходимостью костылить тривиальные вещи. Часть примеров и советов
// элементарно не работают на версии 0.14 из-за изменений в языке и стандартной библиотеке. Самое
// главное - я так и не разобрался как правильно управлять памятью. Тем более, что половина
// стандартной библиотеки никак не указывает это в документации, хотя сами же авторы пишут: "The
// API documentation for functions and data structures should take great care to explain the
// ownership and lifetime semantics of pointers."
//
// Язык явно заточен под написание высокопроизводительного кода и это на нём делать действительно
// удобнее, чем на C или C++. В текущем виде я бы использовал его только для написания критичных по
// производительности модулей, стараясь избегать использования стандартной библиотеки. Остальную
// часть приложения я писал бы на более привычном языке.

// Полезные ссылки
// https://gist.github.com/AndreyArthur/1faac27e88af0175080553e7354c1b41
// https://notes.eatonphil.com/errors-and-zig.html
// https://www.openmymind.net/Switching-On-Strings-In-Zig/
// https://www.reddit.com/r/Zig/comments/11mr0r8/defer_errdefer_and_sigint_ctrlc/
// https://www.reddit.com/r/Zig/comments/1k92bud/struggling_with_comptime_error_when_comparing/
// https://www.reddit.com/r/Zig/comments/1gaj60t/consolereadkey_but_in_zig/
// https://ziggit.dev/t/unreachable/3653
// https://ziggit.dev/t/implement-a-basic-try-catch-block/2650/2
// https://blog.lohr.dev/after-a-day-of-programming-in-zig
// https://blog.orhun.dev/zig-bits-01/
// https://github.com/ziglang/zig/issues/7540
// https://ziggit.dev/t/using-arenaallocator-in-a-short-lived-command-line-zig-program/3812
// https://ziggit.dev/t/convert-relative-to-absolute-path/1898/2
// https://ziggit.dev/t/why-fs-file-doesnt-have-a-method-to-generate-full-path/5081
// https://github.com/ziglang/zig/issues/22677
// https://ziggit.dev/t/when-to-use-read-and-readall/3584/3
