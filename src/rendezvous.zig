//! Mailboxes that pass connection signals between a listed host and a player joining it. Each
//! side polls. The directory stores and hands over the signals, and never reads or dials them.
const std = @import("std");
const net = std.Io.net;
const protocol = @import("protocol.zig");
const Identity = protocol.Identity;
const Exchanges = @This();

/// The largest signal, in bytes. As base64 inside a request it stays under `protocol.max_body`.
pub const max_signal = 2880;
/// How many signals wait in each direction of one exchange.
pub const queue = 8;
/// How long an exchange lives, and how long it may go without a signal or a poll.
pub const lifetime_seconds = 60;
pub const idle_seconds = 30;
/// How many exchanges are open at once: in all, for one listing and from one source.
pub const capacity = 64;
pub const per_listing = 8;
pub const per_source = 4;

pub const Id = [16]u8;

pub const Side = enum { host, joiner };

const Signal = struct {
    bytes: [max_signal]u8 = undefined,
    len: u16 = 0,
};

/// Signals waiting for one side, oldest first.
const Mailbox = struct {
    signals: [queue]Signal = undefined,
    first: u8 = 0,
    count: u8 = 0,

    fn push(mailbox: *Mailbox, signal: []const u8) bool {
        if (mailbox.count == queue) return false;
        const slot = &mailbox.signals[(mailbox.first + mailbox.count) % queue];
        @memcpy(slot.bytes[0..signal.len], signal);
        slot.len = @intCast(signal.len);
        mailbox.count += 1;
        return true;
    }

    fn peek(mailbox: *const Mailbox) ?[]const u8 {
        if (mailbox.count == 0) return null;
        const slot = &mailbox.signals[mailbox.first];
        return slot.bytes[0..slot.len];
    }

    fn drop(mailbox: *Mailbox) void {
        mailbox.first = (mailbox.first + 1) % queue;
        mailbox.count -= 1;
    }
};

const Exchange = struct {
    id: Id,
    host: Identity,
    source: net.IpAddress,
    created: i64,
    touched: i64,
    to_host: Mailbox = .{},
    to_joiner: Mailbox = .{},

    fn live(exchange: *const Exchange, now: i64) bool {
        return now - exchange.created < lifetime_seconds and now - exchange.touched < idle_seconds;
    }

    fn mailbox(exchange: *Exchange, reader: Side) *Mailbox {
        return switch (reader) {
            .host => &exchange.to_host,
            .joiner => &exchange.to_joiner,
        };
    }
};

slots: [capacity]?Exchange = @splat(null),

pub const Error = error{ RateLimited, Missing, Full, InvalidRequest };

/// Opens an exchange with the host `host` for a joiner at `source`, with its first signal. A
/// listing that holds its share gives up its oldest exchange, and so does a full table, so
/// offers that are never followed up can't keep a new player out: a real join is over in a few
/// seconds, well before enough newer offers can push it out at the rate one source may make them.
pub fn offer(exchanges: *Exchanges, id: Id, host: Identity, source: net.IpAddress, signal: []const u8, now: i64) Error!void {
    if (signal.len == 0 or signal.len > max_signal) return error.InvalidRequest;
    var free: ?*?Exchange = null;
    var oldest: ?*?Exchange = null;
    var oldest_of_listing: ?*?Exchange = null;
    var for_listing: usize = 0;
    var from_source: usize = 0;
    for (&exchanges.slots) |*slot| {
        if (slot.*) |*exchange| {
            if (exchange.live(now)) {
                if (oldest == null or exchange.created < oldest.?.*.?.created) oldest = slot;
                if (exchange.host.eql(host)) {
                    for_listing += 1;
                    if (oldest_of_listing == null or exchange.created < oldest_of_listing.?.*.?.created) oldest_of_listing = slot;
                }
                if (protocol.sameSource(exchange.source, source)) from_source += 1;
                continue;
            }
        }
        if (free == null) free = slot;
    }
    if (from_source >= per_source) return error.RateLimited;
    // With no free slot every one is live, so there is an oldest.
    const slot = if (for_listing >= per_listing) oldest_of_listing.? else free orelse oldest.?;
    slot.* = .{ .id = id, .host = host, .source = source, .created = now, .touched = now };
    _ = slot.*.?.to_host.push(signal);
}

fn find(exchanges: *Exchanges, id: Id, now: i64) ?*Exchange {
    for (&exchanges.slots) |*slot| {
        const exchange = if (slot.*) |*open| open else continue;
        if (exchange.live(now) and std.mem.eql(u8, &exchange.id, &id)) return exchange;
    }
    return null;
}

/// Queues a signal from `from` in the exchange `id`. A host may only send in an exchange opened
/// with its own listing.
pub fn send(exchanges: *Exchanges, id: Id, from: Side, host: ?Identity, signal: []const u8, now: i64) Error!void {
    if (signal.len == 0 or signal.len > max_signal) return error.InvalidRequest;
    const exchange = exchanges.find(id, now) orelse return error.Missing;
    if (from == .host and !exchange.host.eql(host orelse return error.Missing)) return error.Missing;
    exchange.touched = now;
    const reader: Side = if (from == .host) .joiner else .host;
    if (!exchange.mailbox(reader).push(signal)) return error.Full;
}

/// Writes the signals waiting for the joiner of exchange `id` as a JSON array of base64 strings,
/// and takes them out of the mailbox. `room` bounds what one answer carries.
pub fn pollJoiner(exchanges: *Exchanges, id: Id, now: i64, out: *std.Io.Writer, room: usize) (Error || std.Io.Writer.Error)!void {
    const exchange = exchanges.find(id, now) orelse return error.Missing;
    exchange.touched = now;
    var left = room;
    try drain(&exchange.to_joiner, out, &left);
}

/// Writes every exchange open with the host `host` that has signals waiting, as a JSON array of
/// objects with the exchange's id and its signals, and takes those signals out.
pub fn pollHost(exchanges: *Exchanges, host: Identity, now: i64, out: *std.Io.Writer, room: usize) std.Io.Writer.Error!void {
    var left = room;
    var listed = false;
    try out.writeByte('[');
    for (&exchanges.slots) |*slot| {
        const exchange = if (slot.*) |*open| open else continue;
        if (!exchange.live(now) or !exchange.host.eql(host) or exchange.to_host.count == 0) continue;
        const next = exchange.to_host.peek().?;
        if (encoded(next.len) + 64 > left) break;
        left -= 64;
        if (listed) try out.writeByte(',');
        listed = true;
        try out.print("{{\"id\":\"{s}\",\"signals\":", .{std.fmt.bytesToHex(exchange.id, .lower)});
        try drain(&exchange.to_host, out, &left);
        try out.writeByte('}');
    }
    try out.writeByte(']');
}

fn encoded(len: usize) usize {
    return std.base64.standard.Encoder.calcSize(len) + 3;
}

fn drain(mailbox: *Mailbox, out: *std.Io.Writer, left: *usize) std.Io.Writer.Error!void {
    try out.writeByte('[');
    var written = false;
    while (mailbox.peek()) |signal| {
        if (encoded(signal.len) > left.*) break;
        left.* -= encoded(signal.len);
        if (written) try out.writeByte(',');
        written = true;
        try out.writeByte('"');
        try std.base64.standard.Encoder.encodeWriter(out, signal);
        try out.writeByte('"');
        mailbox.drop();
    }
    try out.writeByte(']');
}

/// Closes every exchange open with `host`, as its listing ends.
pub fn close(exchanges: *Exchanges, host: Identity) void {
    for (&exchanges.slots) |*slot| {
        if (slot.*) |exchange| if (exchange.host.eql(host)) {
            slot.* = null;
        };
    }
}

const testing = struct {
    const host: Identity = .{ .key = @splat(1), .session = @splat(2) };
    const other: Identity = .{ .key = @splat(3), .session = @splat(2) };

    fn source(last: u8) net.IpAddress {
        return .{ .ip4 = .{ .bytes = .{ 8, 8, 8, last }, .port = 0 } };
    }

    fn id(n: u8) Id {
        return @splat(n);
    }

    fn make() !*Exchanges {
        const exchanges = try std.testing.allocator.create(Exchanges);
        exchanges.* = .{};
        return exchanges;
    }
};

test "signals pass both ways, in order, and only once" {
    const exchanges = try testing.make();
    defer std.testing.allocator.destroy(exchanges);
    try exchanges.offer(testing.id(1), testing.host, testing.source(1), "hello", 0);
    try exchanges.send(testing.id(1), .joiner, null, "again", 1);
    try exchanges.send(testing.id(1), .host, testing.host, "welcome", 1);

    var buffer: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try exchanges.pollHost(testing.host, 2, &out, 4096);
    try std.testing.expectEqualStrings("[{\"id\":\"01010101010101010101010101010101\",\"signals\":[\"aGVsbG8=\",\"YWdhaW4=\"]}]", out.buffered());
    out = .fixed(&buffer);
    try exchanges.pollHost(testing.host, 2, &out, 4096);
    try std.testing.expectEqualStrings("[]", out.buffered());
    out = .fixed(&buffer);
    try exchanges.pollJoiner(testing.id(1), 2, &out, 4096);
    try std.testing.expectEqualStrings("[\"d2VsY29tZQ==\"]", out.buffered());
    out = .fixed(&buffer);
    try exchanges.pollJoiner(testing.id(1), 2, &out, 4096);
    try std.testing.expectEqualStrings("[]", out.buffered());
}

test "an exchange belongs to its host and its id, and ends on time" {
    const exchanges = try testing.make();
    defer std.testing.allocator.destroy(exchanges);
    try exchanges.offer(testing.id(1), testing.host, testing.source(1), "hello", 0);
    var buffer: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    // Another host can neither read it nor write into it, and a wrong id finds nothing.
    try exchanges.pollHost(testing.other, 1, &out, 4096);
    try std.testing.expectEqualStrings("[]", out.buffered());
    try std.testing.expectError(error.Missing, exchanges.send(testing.id(1), .host, testing.other, "x", 1));
    try std.testing.expectError(error.Missing, exchanges.send(testing.id(1), .host, null, "x", 1));
    try std.testing.expectError(error.Missing, exchanges.send(testing.id(9), .joiner, null, "x", 1));
    try std.testing.expectError(error.Missing, exchanges.pollJoiner(testing.id(9), 1, &out, 4096));
    // It ends after its idle time, and whatever happens after its lifetime.
    try exchanges.send(testing.id(1), .joiner, null, "x", idle_seconds - 1);
    try std.testing.expectError(error.Missing, exchanges.send(testing.id(1), .joiner, null, "x", 2 * idle_seconds));
    try exchanges.offer(testing.id(2), testing.host, testing.source(1), "hello", 100);
    for (0..lifetime_seconds / 10) |step| {
        const now: i64 = 100 + @as(i64, @intCast(step)) * 10;
        out = .fixed(&buffer);
        try exchanges.pollJoiner(testing.id(2), now, &out, 4096);
    }
    try std.testing.expectError(error.Missing, exchanges.pollJoiner(testing.id(2), 100 + lifetime_seconds, &out, 4096));
    // Closing a host's listing closes its exchanges.
    try exchanges.offer(testing.id(3), testing.host, testing.source(1), "hello", 200);
    exchanges.close(testing.host);
    try std.testing.expectError(error.Missing, exchanges.send(testing.id(3), .joiner, null, "x", 200));
}

test "signals and mailboxes are bounded" {
    const exchanges = try testing.make();
    defer std.testing.allocator.destroy(exchanges);
    const big: [max_signal + 1]u8 = @splat('x');
    try std.testing.expectError(error.InvalidRequest, exchanges.offer(testing.id(1), testing.host, testing.source(1), &big, 0));
    try std.testing.expectError(error.InvalidRequest, exchanges.offer(testing.id(1), testing.host, testing.source(1), "", 0));
    try exchanges.offer(testing.id(1), testing.host, testing.source(1), big[0..max_signal], 0);
    try std.testing.expectError(error.InvalidRequest, exchanges.send(testing.id(1), .joiner, null, &big, 0));
    for (1..queue) |_| try exchanges.send(testing.id(1), .joiner, null, "x", 0);
    try std.testing.expectError(error.Full, exchanges.send(testing.id(1), .joiner, null, "x", 0));
    // An answer carries what fits its room and leaves the rest for the next poll.
    const buffer = try std.testing.allocator.alloc(u8, 2 * encoded(max_signal));
    defer std.testing.allocator.free(buffer);
    var out: std.Io.Writer = .fixed(buffer);
    try exchanges.pollHost(testing.host, 0, &out, encoded(max_signal) + 64);
    try std.testing.expectEqual(queue - 1, exchanges.slots[0].?.to_host.count);
}

test "one listing and one source hold a share, and a full table drops its oldest exchange" {
    const exchanges = try testing.make();
    defer std.testing.allocator.destroy(exchanges);
    // A listing at its share gives up its own oldest exchange, and no other listing's.
    try exchanges.offer(testing.id(100), testing.other, testing.source(100), "x", 0);
    for (0..per_listing) |n| try exchanges.offer(testing.id(@intCast(n)), testing.host, testing.source(@intCast(n)), "x", @intCast(n));
    try exchanges.offer(testing.id(200), testing.host, testing.source(200), "x", per_listing);
    try std.testing.expectError(error.Missing, exchanges.send(testing.id(0), .joiner, null, "x", per_listing));
    try exchanges.send(testing.id(1), .joiner, null, "x", per_listing);
    try exchanges.send(testing.id(100), .joiner, null, "x", per_listing);
    try exchanges.send(testing.id(200), .joiner, null, "x", per_listing);
    exchanges.slots = @splat(null);
    for (0..per_source) |n| try exchanges.offer(testing.id(@intCast(n)), .{ .key = @splat(@intCast(n)), .session = @splat(0) }, testing.source(1), "x", 0);
    try std.testing.expectError(error.RateLimited, exchanges.offer(testing.id(200), testing.other, testing.source(1), "x", 0));

    exchanges.slots = @splat(null);
    for (0..capacity) |n| {
        const host: Identity = .{ .key = @splat(@intCast(n)), .session = @splat(0) };
        try exchanges.offer(testing.id(@intCast(n)), host, testing.source(@intCast(n)), "x", @intCast(n / 8));
    }
    try exchanges.offer(testing.id(250), testing.other, testing.source(250), "x", 9);
    try std.testing.expectError(error.Missing, exchanges.send(testing.id(0), .joiner, null, "x", 9));
    try exchanges.send(testing.id(250), .joiner, null, "x", 9);
    try exchanges.send(testing.id(1), .joiner, null, "x", 9);
}
