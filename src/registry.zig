//! Independent, bounded leases and one-use challenges. Times use the local monotonic clock.
const std = @import("std");
const net = std.Io.net;
const protocol = @import("protocol.zig");
const Registry = @This();
const Identity = protocol.Identity;
const Operation = protocol.Operation;
const Token = protocol.Token;
const Proof = protocol.Proof;

pub const renewal_seconds = 30;
pub const lease_seconds = 90;
pub const challenge_seconds = 30;
pub const page_size = 16;
const listing_capacity = 256;
const challenge_capacity = 128;

pub const Policy = struct {
    game: ?[]const u8 = null,
    host: ?protocol.Key = null,

    fn allows(policy: Policy, key: protocol.Key, id: []const u8) bool {
        if (policy.host) |allowed| if (!std.mem.eql(u8, &allowed, &key)) return false;
        if (policy.game) |allowed| if (!std.mem.eql(u8, allowed, id)) return false;
        return true;
    }
};

const Pending = struct {
    identity: Identity,
    address: net.IpAddress,
    operation: Operation,
    token: Token,
    expires: i64,
};

const Listing = struct {
    identity: Identity,
    address: net.IpAddress,
    source: net.IpAddress,
    revision: u64,
    expires: i64,
    game_id: [protocol.max_game_id]u8 = undefined,
    game_len: usize = 0,
    body: [protocol.max_body]u8 = undefined,
    body_len: usize = 0,

    fn payload(listing: *const Listing) []const u8 {
        return listing.body[0..listing.body_len];
    }

    fn write(listing: *const Listing, now: i64, out: *std.Io.Writer) !void {
        var room: [96]u8 = undefined;
        const address = try std.fmt.bufPrint(&room, "{f}", .{listing.address});
        var json: std.json.Stringify = .{ .writer = out };
        try json.beginObject();
        try json.objectField("key");
        try json.write(std.fmt.bytesToHex(listing.identity.key, .lower));
        try json.objectField("session");
        try json.write(std.fmt.bytesToHex(listing.identity.session, .lower));
        try json.objectField("expires_in_seconds");
        try json.write(listing.expires - now);
        try json.objectField("address");
        try json.write(address);
        try json.objectField("reachability");
        try json.write("unverified");
        try json.objectField("advertisement");
        // The request parser has already checked that this is one complete JSON value.
        try json.print("{s}", .{listing.payload()});
        try json.endObject();
    }
};

const Rate = struct {
    address: net.IpAddress,
    until: i64,
    requests: u16 = 0,
};

policy: Policy = .{},
pending: [challenge_capacity]?Pending = @splat(null),
listings: [listing_capacity]?Listing = @splat(null),
rates: [512]?Rate = @splat(null),

pub const Error = error{ Busy, RateLimited, Unauthorised, Forbidden, Missing, Stale, Conflict };

/// At most 120 requests per source per minute. A full rate table remains bounded.
pub fn admit(registry: *Registry, address: net.IpAddress, now: i64) Error!void {
    var network = address;
    if (network == .ip6) @memset(network.ip6.bytes[8..], 0);
    var free: ?*?Rate = null;
    for (&registry.rates) |*entry| {
        if (entry.*) |*rate| {
            if (rate.until > now) {
                if (!rate.address.eql(&network)) continue;
                if (rate.requests >= 120) return error.RateLimited;
                rate.requests += 1;
                return;
            }
        }
        if (free == null) free = entry;
    }
    const slot = free orelse return error.Busy;
    slot.* = .{ .address = network, .until = now + 60, .requests = 1 };
}

test "IPv6 addresses in one subnet share the request allowance" {
    const registry = try std.testing.allocator.create(Registry);
    defer std.testing.allocator.destroy(registry);
    registry.* = .{};
    for (0..120) |index| {
        var address = try net.IpAddress.parse("2606:4700:abcd:1234::", 0);
        address.ip6.bytes[15] = @intCast(index);
        try registry.admit(address, 0);
    }
    try std.testing.expectError(error.RateLimited, registry.admit(try net.IpAddress.parse("2606:4700:abcd:1234::ffff", 0), 0));
    try registry.admit(try net.IpAddress.parse("2606:4700:abcd:1235::1", 0), 0);
}

pub fn challenge(registry: *Registry, who: Identity, source: net.IpAddress, operation: Operation, token: Token, now: i64) Error!void {
    if (registry.policy.host) |allowed| {
        if (!std.mem.eql(u8, &allowed, &who.key)) return error.Forbidden;
    }
    var first_free: ?*?Pending = null;
    var source_count: usize = 0;
    for (&registry.pending) |*entry| {
        if (entry.*) |*pending| {
            if (pending.expires > now) {
                if (pending.address.eql(&source)) source_count += 1;
                continue;
            }
        }
        if (first_free == null) first_free = entry;
    }
    if (source_count >= 8) return error.RateLimited;
    const slot = first_free orelse return error.Busy;
    slot.* = .{ .identity = who, .address = source, .operation = operation, .token = token, .expires = now + challenge_seconds };
}

pub fn authorise(registry: *Registry, proof: Proof, source: net.IpAddress, operation: Operation, body: []const u8, now: i64) Error!void {
    for (&registry.pending) |*entry| {
        const pending = entry.* orelse continue;
        if (pending.expires <= now or pending.operation != operation or !pending.address.eql(&source) or
            !pending.identity.eql(proof.identity) or !std.mem.eql(u8, &pending.token, &proof.token)) continue;
        if (!proof.verify(operation, body)) return error.Unauthorised;
        entry.* = null;
        return;
    }
    return error.Unauthorised;
}

pub fn advertise(
    registry: *Registry,
    operation: Operation,
    who: Identity,
    source: net.IpAddress,
    ad: protocol.Advertisement,
    body: []const u8,
    now: i64,
) Error!void {
    if (!registry.policy.allows(who.key, ad.game.id)) return error.Forbidden;
    var first_free: ?*?Listing = null;
    var previous: ?*Listing = null;
    var source_count: usize = 0;
    var key_count: usize = 0;
    for (&registry.listings) |*entry| {
        if (entry.*) |*listing| {
            if (listing.expires > now) {
                if (listing.identity.eql(who)) {
                    previous = listing;
                    continue;
                }
                if (listing.source.eql(&source)) source_count += 1;
                if (std.mem.eql(u8, &who.key, &listing.identity.key)) key_count += 1;
                continue;
            }
        }
        if (first_free == null) first_free = entry;
    }
    if (source_count >= 16 or key_count >= 4) return error.RateLimited;

    var address = if (ad.address) |text| protocol.publicAddress(net.IpAddress.parse(text, 0) catch return error.Forbidden) orelse return error.Forbidden else source;
    address.setPort(ad.port);
    if (previous) |listing| {
        if (!std.mem.eql(u8, listing.game_id[0..listing.game_len], ad.game.id)) return error.Conflict;
        if (ad.revision < listing.revision) return error.Stale;
        if (ad.revision == listing.revision) {
            if (!source.eql(&listing.source) or !address.eql(&listing.address) or !std.mem.eql(u8, body, listing.payload())) return error.Conflict;
            listing.expires = now + lease_seconds;
        } else put(listing, who, source, address, ad, body, now);
        return;
    }

    if (operation == .renew) return error.Missing;
    const slot = first_free orelse return error.Busy;
    slot.* = .{ .identity = who, .address = address, .source = source, .revision = ad.revision, .expires = now + lease_seconds };
    put(&slot.*.?, who, source, address, ad, body, now);
}

fn put(listing: *Listing, who: Identity, source: net.IpAddress, address: net.IpAddress, ad: protocol.Advertisement, body: []const u8, now: i64) void {
    listing.* = .{ .identity = who, .address = address, .source = source, .revision = ad.revision, .expires = now + lease_seconds };
    @memcpy(listing.game_id[0..ad.game.id.len], ad.game.id);
    listing.game_len = ad.game.id.len;
    @memcpy(listing.body[0..body.len], body);
    listing.body_len = body.len;
}

pub fn withdraw(registry: *Registry, who: Identity) void {
    for (&registry.listings) |*entry| {
        if (entry.*) |*listing| if (listing.identity.eql(who)) {
            entry.* = null;
            return;
        };
    }
}

pub fn browse(registry: *const Registry, game: []const u8, cursor: usize, now: i64, out: *std.Io.Writer) !void {
    try out.writeAll("{\"listings\":[");
    var count: usize = 0;
    var next: ?usize = null;
    for (registry.listings[@min(cursor, listing_capacity)..], @min(cursor, listing_capacity)..) |*entry, index| {
        const listing = if (entry.*) |*item| item else continue;
        if (listing.expires <= now or !std.mem.eql(u8, game, listing.game_id[0..listing.game_len])) continue;
        if (count == page_size) {
            next = index;
            break;
        }
        if (count != 0) try out.writeByte(',');
        try listing.write(now, out);
        count += 1;
    }
    try out.writeAll("],\"next\":");
    try std.json.Stringify.value(next, .{}, out);
    try out.writeByte('}');
}

test "leases expire independently and renewals cannot recreate one" {
    const allocator = std.testing.allocator;
    const registry = try allocator.create(Registry);
    defer allocator.destroy(registry);
    registry.* = .{};
    const source = try net.IpAddress.parse("8.8.8.8", 0);
    const who: Identity = .{ .key = @splat(3), .session = @splat(7) };
    const ad: protocol.Advertisement = .{
        .game = .{ .id = "org.example.racer", .name = "Racer" },
        .revision = 1,
        .name = "Free race",
        .hosting = .dedicated,
        .players = 0,
        .capacity = 8,
        .accepting = true,
        .protocol = 1,
        .release = "0.1",
        .port = 27020,
    };
    try registry.advertise(.register, who, source, ad, "{}", 1);
    var buffer: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try registry.browse(ad.game.id, 0, 90, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"expires_in_seconds\":1") != null);
    out = .fixed(&buffer);
    try registry.browse(ad.game.id, 0, 91, &out);
    try std.testing.expectEqualStrings("{\"listings\":[],\"next\":null}", out.buffered());
    try std.testing.expectError(error.Missing, registry.advertise(.renew, who, source, ad, "{}", 91));
}

test "a proof is bound to its directory challenge and operation" {
    const allocator = std.testing.allocator;
    const registry = try allocator.create(Registry);
    defer allocator.destroy(registry);
    registry.* = .{};
    const source = try net.IpAddress.parse("8.8.8.8", 0);
    const key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(14));
    const who: Identity = .{ .key = key.public_key.toBytes(), .session = @splat(7) };
    const token: Token = @splat(9);
    const body = "{}";
    var bytes: [protocol.max_signed_message]u8 = undefined;
    const signature = try key.sign(try protocol.signedBytes(&bytes, .register, token, who.session, body), null);
    const proof: Proof = .{ .identity = who, .token = token, .signature = signature.toBytes() };
    try registry.challenge(who, source, .register, token, 1);
    try std.testing.expectError(error.Unauthorised, registry.authorise(proof, source, .renew, body, 2));
    try registry.authorise(proof, source, .register, body, 2);
    try std.testing.expectError(error.Unauthorised, registry.authorise(proof, source, .register, body, 2));
}

test "an advertised address keeps publisher quotas tied to its observed source" {
    const registry = try std.testing.allocator.create(Registry);
    defer std.testing.allocator.destroy(registry);
    registry.* = .{};
    const source = try net.IpAddress.parse("8.8.8.8", 0);
    const ad: protocol.Advertisement = .{
        .game = .{ .id = "org.example.game", .name = "Game" },
        .revision = 1,
        .name = "Server",
        .hosting = .dedicated,
        .players = 0,
        .capacity = 8,
        .accepting = true,
        .protocol = 1,
        .release = "1.0.0",
        .port = 27020,
        .address = "1.1.1.1",
    };
    for (0..16) |index| {
        const who: Identity = .{ .key = @splat(@intCast(index)), .session = @splat(1) };
        try registry.advertise(.register, who, source, ad, "{}", 0);
    }
    const extra: Identity = .{ .key = @splat(16), .session = @splat(1) };
    try std.testing.expectError(error.RateLimited, registry.advertise(.register, extra, source, ad, "{}", 0));
    var buffer: [8192]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try registry.browse(ad.game.id, 0, 1, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "1.1.1.1:27020") != null);
    var private = ad;
    private.address = "127.0.0.1";
    try std.testing.expect(!private.valid());
}
