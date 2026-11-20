//! One bounded HTTP request per connection. The operator can put TLS in front of this listener.
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const protocol = @import("protocol.zig");
const Registry = @import("registry.zig");
const Server = @This();
const log = std.log.scoped(.directory);

pub const default_connections = 8;
const max_response = Registry.page_size * (protocol.max_body + 512) + 256;
const Request = std.http.Server.Request;

io: Io,
trust_proxy: bool,
registry: *Registry,
max_connections: usize = default_connections,
mutex: Io.Mutex = .init,
active: std.atomic.Value(usize) = .init(0),

pub fn serve(server: *Server, address: net.IpAddress) !void {
    var listener = try address.listen(server.io, .{ .reuse_address = true, .kernel_backlog = 32 });
    defer listener.deinit(server.io);
    var workers: Io.Group = .init;
    defer workers.cancel(server.io);
    log.info("listening on {f}", .{listener.socket.address});
    while (true) {
        const stream = listener.accept(server.io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.ConnectionAborted => continue,
            else => {
                log.warn("could not accept a connection: {t}", .{err});
                try server.io.sleep(.fromSeconds(1), .awake);
                continue;
            },
        };
        if (server.active.fetchAdd(1, .monotonic) < server.max_connections) {
            if (workers.concurrent(server.io, serveConnection, .{ server, stream })) |_| continue else |_| {}
        }
        _ = server.active.fetchSub(1, .monotonic);
        stream.close(server.io);
    }
}

fn serveConnection(server: *Server, stream: net.Stream) void {
    defer _ = server.active.fetchSub(1, .monotonic);
    defer stream.close(server.io);
    const Event = union(enum) { request: void, deadline: Io.Cancelable!void };
    var events: [2]Event = undefined;
    var select: Io.Select(Event) = .init(server.io, &events);
    defer select.cancelDiscard();
    select.concurrent(.deadline, Io.sleep, .{ server.io, .fromSeconds(5), .awake }) catch return;
    select.concurrent(.request, respond, .{ server, stream }) catch return;
    _ = select.await() catch return;
}

fn respond(server: *Server, stream: net.Stream) void {
    var input: [8192]u8 = undefined;
    var output: [4096]u8 = undefined;
    var reader = stream.reader(server.io, &input);
    var writer = stream.writer(server.io, &output);
    var http: std.http.Server = .init(&reader.interface, &writer.interface);
    var request = http.receiveHead() catch return;
    const source = server.requestSource(&request, stream.socket.address) catch {
        reply(&request, .bad_request, "{}");
        return;
    };
    const now = Io.Clock.awake.now(server.io).toSeconds();
    const admitted = rate: {
        server.mutex.lock(server.io) catch return;
        defer server.mutex.unlock(server.io);
        break :rate server.registry.admit(source, now);
    };
    admitted catch |err| {
        reply(&request, status(err), "{}");
        return;
    };
    server.dispatch(&request, source, now) catch |err| {
        reply(&request, status(err), "{}");
    };
}

fn dispatch(server: *Server, request: *Request, source: net.IpAddress, now: i64) !void {
    const target = request.head.target;
    const path, const query = splitTarget(target);
    if (request.head.expect != null or request.head.transfer_encoding != .none or request.head.transfer_compression != .identity)
        return error.InvalidRequest;
    if (request.head.method == .GET) {
        if ((request.head.content_length orelse 0) != 0) return error.InvalidRequest;
        if (std.mem.eql(u8, path, "/v1/capabilities") and query.len == 0) {
            reply(request, .ok, "{\"version\":1,\"listings\":true,\"rendezvous\":false,\"stun\":false,\"turn\":false}");
            return;
        }
        if (std.mem.eql(u8, path, "/v1/listings")) {
            try server.browse(request, query, now);
            return;
        }
        return error.Missing;
    }
    if (request.head.method != .POST) return error.WrongMethod;
    if (query.len != 0) return error.InvalidRequest;

    const prefix = "/v1/";
    if (!std.mem.startsWith(u8, path, prefix)) return error.Missing;
    const action = path[prefix.len..];
    const issue_challenge = std.mem.eql(u8, action, "challenge");
    const operation = std.meta.stringToEnum(protocol.Operation, action);
    if (operation == null and !issue_challenge) return error.Missing;

    const public = protocol.publicAddress(source) orelse return error.Forbidden;
    const length = request.head.content_length orelse return error.InvalidRequest;
    if (length > protocol.max_body) return error.BodyTooLarge;
    const proof = if (issue_challenge) null else try readProof(request);
    var request_body: [protocol.max_body]u8 = undefined;
    const body = request_body[0..@intCast(length)];
    var read_buffer: [1024]u8 = undefined;
    if (body.len != 0) {
        const input = request.readerExpectNone(&read_buffer);
        input.readSliceAll(body) catch return error.InvalidRequest;
    }
    // Take the lease time after reading the request body.
    const received_at = Io.Clock.awake.now(server.io).toSeconds();
    var temporary = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer temporary.deinit();
    if (issue_challenge) {
        const parsed = std.json.parseFromSliceLeaky(protocol.ChallengeRequest, temporary.allocator(), body, .{}) catch return error.InvalidRequest;
        const who: protocol.Identity = .{
            .key = protocol.decodeHex(protocol.public_key_size, parsed.key) catch return error.InvalidRequest,
            .session = protocol.decodeHex(@sizeOf(protocol.Session), parsed.session) catch return error.InvalidRequest,
        };
        var token: protocol.Token = undefined;
        try server.io.randomSecure(&token);
        {
            try server.mutex.lock(server.io);
            defer server.mutex.unlock(server.io);
            try server.registry.challenge(who, public, parsed.operation, token, received_at);
        }
        var buffer: [256]u8 = undefined;
        var result: Io.Writer = .fixed(&buffer);
        try std.json.Stringify.value(.{ .challenge = std.fmt.bytesToHex(token, .lower), .expires_in_seconds = Registry.challenge_seconds }, .{}, &result);
        reply(request, .ok, result.buffered());
        return;
    }

    const op = operation.?;
    const advertisement = if (op == .withdraw) empty: {
        if (body.len != 0) return error.InvalidRequest;
        break :empty null;
    } else ad: {
        const ad = std.json.parseFromSliceLeaky(protocol.Advertisement, temporary.allocator(), body, .{}) catch return error.InvalidRequest;
        if (!ad.valid()) return error.InvalidRequest;
        break :ad ad;
    };
    {
        try server.mutex.lock(server.io);
        defer server.mutex.unlock(server.io);
        try server.registry.authorise(proof.?, public, op, body, received_at);
        if (advertisement) |ad| {
            try server.registry.advertise(op, proof.?.identity, public, ad, body, received_at);
        } else server.registry.withdraw(proof.?.identity);
    }
    if (op == .withdraw) {
        reply(request, .no_content, "");
        return;
    }
    var buffer: [128]u8 = undefined;
    var result: Io.Writer = .fixed(&buffer);
    try std.json.Stringify.value(.{ .expires_in_seconds = Registry.lease_seconds, .renew_after_seconds = Registry.renewal_seconds }, .{}, &result);
    reply(request, .ok, result.buffered());
}

fn browse(server: *Server, request: *Request, query: []const u8, now: i64) !void {
    var parts = std.mem.splitScalar(u8, query, '&');
    const game_field = parts.next() orelse return error.InvalidRequest;
    if (!std.mem.startsWith(u8, game_field, "game=")) return error.InvalidRequest;
    const game = game_field["game=".len..];
    if (!protocol.identifier(game)) return error.InvalidRequest;
    const cursor = if (parts.next()) |part| value: {
        if (!std.mem.startsWith(u8, part, "cursor=") or parts.next() != null) return error.InvalidRequest;
        break :value std.fmt.parseInt(usize, part["cursor=".len..], 10) catch return error.InvalidRequest;
    } else 0;

    var buffer: [max_response]u8 = undefined;
    var result: Io.Writer = .fixed(&buffer);
    {
        try server.mutex.lock(server.io);
        defer server.mutex.unlock(server.io);
        try server.registry.browse(game, cursor, now, &result);
    }
    reply(request, .ok, result.buffered());
}

fn splitTarget(target: []const u8) struct { []const u8, []const u8 } {
    const end = std.mem.indexOfScalar(u8, target, '?') orelse return .{ target, "" };
    return .{ target[0..end], target[end + 1 ..] };
}

pub fn loopback(address: net.IpAddress) bool {
    if (net.Ip4Address.fromAny(address)) |ip| return ip.bytes[0] == 127;
    return std.mem.eql(u8, &address.ip6.bytes, &net.Ip6Address.loopback(0).bytes);
}

fn requestSource(server: *const Server, request: *const Request, remote: net.IpAddress) !net.IpAddress {
    var address = remote;
    if (server.trust_proxy) {
        if (!loopback(remote)) return error.InvalidRequest;
        var forwards: ?[]const u8 = null;
        var headers = request.iterateHeaders();
        while (headers.next()) |header| {
            if (!std.ascii.eqlIgnoreCase(header.name, "x-forwarded-for")) continue;
            if (forwards != null) return error.InvalidRequest;
            forwards = header.value;
        }
        address = try net.IpAddress.parse(forwards orelse return error.InvalidRequest, 0);
    }
    address.setPort(0);
    if (net.Ip4Address.fromAny(address)) |ip| return .{ .ip4 = ip };
    return address;
}

fn readProof(request: *const Request) !protocol.Proof {
    const Header = enum { key, session, challenge, signature };
    const names = std.EnumArray(Header, []const u8).init(.{
        .key = "x-directory-key",
        .session = "x-directory-session",
        .challenge = "x-directory-challenge",
        .signature = "x-directory-signature",
    });
    var values: std.EnumArray(Header, ?[]const u8) = .initFill(null);
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        for (std.enums.values(Header)) |field| {
            if (!std.ascii.eqlIgnoreCase(header.name, names.get(field))) continue;
            if (values.get(field) != null) return error.Unauthorised;
            values.set(field, header.value);
            break;
        }
    }
    return .{
        .identity = .{
            .key = protocol.decodeHex(protocol.public_key_size, values.get(.key) orelse return error.Unauthorised) catch return error.Unauthorised,
            .session = protocol.decodeHex(@sizeOf(protocol.Session), values.get(.session) orelse return error.Unauthorised) catch return error.Unauthorised,
        },
        .token = protocol.decodeHex(@sizeOf(protocol.Token), values.get(.challenge) orelse return error.Unauthorised) catch return error.Unauthorised,
        .signature = protocol.decodeHex(protocol.signature_size, values.get(.signature) orelse return error.Unauthorised) catch return error.Unauthorised,
    };
}

fn status(err: anyerror) std.http.Status {
    return switch (err) {
        error.InvalidRequest => .bad_request,
        error.BodyTooLarge => .payload_too_large,
        error.WrongMethod => .method_not_allowed,
        error.Unauthorised => .unauthorized,
        error.Forbidden => .forbidden,
        error.Missing => .not_found,
        error.Conflict, error.Stale => .conflict,
        error.Busy => .service_unavailable,
        error.RateLimited => .too_many_requests,
        else => .internal_server_error,
    };
}

fn reply(request: *Request, code: std.http.Status, body: []const u8) void {
    request.respond(body, .{
        .status = code,
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "cache-control", .value = "no-store" },
        },
    }) catch {};
}
