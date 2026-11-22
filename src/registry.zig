//! Independent, bounded leases and one-use challenges. Times use the local monotonic clock.
const std = @import("std");
const net = std.Io.net;
const protocol = @import("protocol.zig");
const Registry = @This();
const Identity = protocol.Identity;
const Operation = protocol.Operation;
const Token = protocol.Token;
const Verified = protocol.Verified;

pub const renewal_seconds = 30;
pub const lease_seconds = 90;
pub const challenge_seconds = 30;
pub const page_size = 16;
const listing_capacity = 256;
const challenge_capacity = 128;

pub const Policy = struct {
    game: ?[]const u8 = null,
    host: ?protocol.Key = null,
    /// Hosts that may list an address other than the one they publish from.
    address_hosts: []const protocol.Key = &.{},

    fn mayNameAddress(policy: Policy, key: protocol.Key) bool {
        for (policy.address_hosts) |allowed| {
            if (std.mem.eql(u8, &allowed, &key)) return true;
        }
        return false;
    }

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

/// At most 120 requests per source per minute. When the table is full, the source whose minute
/// started first makes room, so a flood of new sources never turns other visitors away.
pub fn admit(registry: *Registry, address: net.IpAddress, now: i64) Error!void {
    const source = protocol.sourceOf(address);
    var free: ?*?Rate = null;
    var oldest: ?*?Rate = null;
    for (&registry.rates) |*entry| {
        if (entry.*) |*rate| {
            if (rate.until > now) {
                if (oldest == null or rate.until < oldest.?.*.?.until) oldest = entry;
                if (!rate.address.eql(&source)) continue;
                if (rate.requests >= 120) return error.RateLimited;
                rate.requests += 1;
                return;
            }
        }
        if (free == null) free = entry;
    }
    // With no free place, every entry is live, so there is an oldest one.
    const slot = free orelse oldest.?;
    slot.* = .{ .address = source, .until = now + 60, .requests = 1 };
}

test "a full rate table makes room for a new source" {
    const registry = try std.testing.allocator.create(Registry);
    defer std.testing.allocator.destroy(registry);
    registry.* = .{};
    const first = try net.IpAddress.parse("8.8.8.8", 0);
    try registry.admit(first, 0);
    for (0..registry.rates.len) |index| {
        var address = try net.IpAddress.parse("2606:4700::", 0);
        std.mem.writeInt(u16, address.ip6.bytes[4..6], @intCast(index), .big);
        try registry.admit(address, 1);
    }
    // The first source gave up its place and starts a new minute.
    try registry.admit(first, 2);
    try registry.admit(try net.IpAddress.parse("9.9.9.9", 0), 2);
    // An empty first place is taken before any live entry is replaced.
    registry.rates[0] = null;
    try registry.admit(try net.IpAddress.parse("1.1.1.1", 0), 2);
    try std.testing.expect(registry.rates[0] != null);
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
    var oldest: ?*?Pending = null;
    var source_count: usize = 0;
    for (&registry.pending) |*entry| {
        if (entry.*) |*pending| {
            if (pending.expires > now) {
                if (oldest == null or pending.expires < oldest.?.*.?.expires) oldest = entry;
                if (protocol.sameSource(pending.address, source)) source_count += 1;
                continue;
            }
        }
        if (first_free == null) first_free = entry;
    }
    if (source_count >= 8) return error.RateLimited;
    // A host uses its challenge within moments. When every slot is taken, the challenge that
    // has waited longest makes room, so unused challenges never stop a host from registering.
    const slot = first_free orelse oldest.?;
    slot.* = .{ .identity = who, .address = source, .operation = operation, .token = token, .expires = now + challenge_seconds };
}

/// Uses up the challenge a verified proof answers.
pub fn authorise(registry: *Registry, proof: Verified, source: net.IpAddress, now: i64) Error!void {
    for (&registry.pending) |*entry| {
        const pending = entry.* orelse continue;
        if (pending.expires <= now or pending.operation != proof.operation or !protocol.sameSource(pending.address, source) or
            !pending.identity.eql(proof.identity) or !std.mem.eql(u8, &pending.token, &proof.token)) continue;
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
    for (&registry.listings) |*entry| {
        if (entry.*) |*listing| {
            if (listing.expires > now) {
                if (std.mem.eql(u8, &who.key, &listing.identity.key)) {
                    previous = listing;
                    continue;
                }
                if (protocol.sameSource(listing.source, source)) source_count += 1;
                continue;
            }
        }
        if (first_free == null) first_free = entry;
    }
    if (source_count >= 16) return error.RateLimited;

    var address = source;
    if (ad.address) |text| {
        const named = protocol.publicAddress(net.IpAddress.parse(text, 0) catch return error.Forbidden) orelse return error.Forbidden;
        // Players' games ping every listed address. A host on a public address may only name
        // another one if the operator allows its key, so a listing can't aim those pings at a
        // third party. A host on a private address has to name one to be listed at all.
        if (!named.eql(&source) and protocol.publicAddress(source) != null and !registry.policy.mayNameAddress(who.key)) return error.Forbidden;
        address = named;
    }
    address.setPort(ad.port);
    if (previous) |listing| {
        if (!listing.identity.eql(who)) {
            if (operation == .renew) return error.Missing;
            put(listing, who, source, address, ad, body, now);
            return;
        }
        if (!std.mem.eql(u8, listing.game_id[0..listing.game_len], ad.game.id)) return error.Conflict;
        if (ad.revision < listing.revision) return error.Stale;
        if (ad.revision == listing.revision) {
            if (!source.eql(&listing.source) or !address.eql(&listing.address) or !std.mem.eql(u8, body, listing.payload())) return error.Conflict;
            listing.expires = now + lease_seconds;
        } else put(listing, who, source, address, ad, body, now);
        return;
    }

    if (operation == .renew) return error.Missing;
    const slot = first_free orelse registry.crowded(source, source_count, now) orelse return error.Busy;
    slot.* = .{ .identity = who, .address = address, .source = source, .revision = ad.revision, .expires = now + lease_seconds };
    put(&slot.*.?, who, source, address, ad, body, now);
}

/// With every slot taken, the source with the most listings gives one up to a source that would
/// still have fewer afterwards: the listing of its that expires first. A table of hosts with one
/// listing each stays as it is.
fn crowded(registry: *Registry, source: net.IpAddress, source_count: usize, now: i64) ?*?Listing {
    var most: usize = 0;
    var victim: ?*?Listing = null;
    for (&registry.listings) |*entry| {
        const listing = if (entry.*) |*item| item else continue;
        if (listing.expires <= now or protocol.sameSource(listing.source, source)) continue;
        var count: usize = 0;
        var first: *?Listing = entry;
        for (&registry.listings) |*other| {
            const peer = if (other.*) |*item| item else continue;
            if (peer.expires <= now or !protocol.sameSource(peer.source, listing.source)) continue;
            count += 1;
            if (peer.expires < first.*.?.expires) first = other;
        }
        if (count > most) {
            most = count;
            victim = first;
        }
    }
    return if (most > source_count + 1) victim else null;
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
    const proof: protocol.Proof = .{ .identity = who, .token = token, .signature = signature.toBytes() };
    try registry.challenge(who, source, .register, token, 1);
    try std.testing.expectEqual(null, proof.verified(.renew, body));
    try std.testing.expectEqual(null, proof.verified(.register, "{ }"));
    const verified = proof.verified(.register, body).?;
    var renewal = verified;
    renewal.operation = .renew;
    try std.testing.expectError(error.Unauthorised, registry.authorise(renewal, source, 2));
    try registry.authorise(verified, source, 2);
    try std.testing.expectError(error.Unauthorised, registry.authorise(verified, source, 2));
}

test "an IPv6 /64 shares the challenge and listing quotas, and a full challenge table makes room" {
    const registry = try std.testing.allocator.create(Registry);
    defer std.testing.allocator.destroy(registry);
    registry.* = .{};
    const who: Identity = .{ .key = @splat(3), .session = @splat(7) };
    for (0..8) |index| {
        var address = try net.IpAddress.parse("2606:4700:abcd:1234::", 0);
        address.ip6.bytes[15] = @intCast(index);
        try registry.challenge(who, address, .register, @splat(@intCast(index)), 0);
    }
    try std.testing.expectError(error.RateLimited, registry.challenge(who, try net.IpAddress.parse("2606:4700:abcd:1234::ffff", 0), .register, @splat(9), 0));

    // Other sources fill the rest of the table. The next challenge replaces the oldest one.
    for (8..challenge_capacity) |index| {
        var address = try net.IpAddress.parse("2606:4700::", 0);
        std.mem.writeInt(u16, address.ip6.bytes[4..6], @intCast(index), .big);
        try registry.challenge(who, address, .register, @splat(@intCast(index)), 1);
    }
    const key = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(14));
    const host: Identity = .{ .key = key.public_key.toBytes(), .session = @splat(7) };
    const source = try net.IpAddress.parse("8.8.8.8", 0);
    const token: Token = @splat(200);
    try registry.challenge(host, source, .register, token, 2);
    var bytes: [protocol.max_signed_message]u8 = undefined;
    const signature = try key.sign(try protocol.signedBytes(&bytes, .register, token, host.session, "{}"), null);
    const proof: protocol.Proof = .{ .identity = host, .token = token, .signature = signature.toBytes() };
    try registry.authorise(proof.verified(.register, "{}").?, source, 3);
    var live: usize = 0;
    for (registry.pending) |entry| {
        if (entry) |pending| if (pending.expires == challenge_seconds) {
            live += 1;
        };
    }
    try std.testing.expectEqual(7, live);

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
    };
    for (0..16) |index| {
        var address = try net.IpAddress.parse("2606:4700:abcd:1234::", 0);
        address.ip6.bytes[15] = @intCast(index);
        try registry.advertise(.register, .{ .key = @splat(@intCast(index)), .session = @splat(1) }, address, ad, "{}", 0);
    }
    try std.testing.expectError(error.RateLimited, registry.advertise(.register, .{ .key = @splat(16), .session = @splat(1) }, try net.IpAddress.parse("2606:4700:abcd:1234::ffff", 0), ad, "{}", 0));
}

test "an advertised address keeps publisher quotas tied to its observed source" {
    const registry = try std.testing.allocator.create(Registry);
    defer std.testing.allocator.destroy(registry);
    registry.* = .{};
    // A publisher behind a provider's private address, which has to name its public one.
    const source = try net.IpAddress.parse("10.1.0.8", 0);
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

test "a host on a public address names another one only with the operator's leave" {
    const registry = try std.testing.allocator.create(Registry);
    defer std.testing.allocator.destroy(registry);
    const trusted: protocol.Key = @splat(5);
    registry.* = .{ .policy = .{ .address_hosts = &.{trusted} } };
    const source = try net.IpAddress.parse("8.8.8.8", 0);
    var ad: protocol.Advertisement = .{
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
    try std.testing.expectError(error.Forbidden, registry.advertise(.register, .{ .key = @splat(4), .session = @splat(1) }, source, ad, "{}", 0));
    try registry.advertise(.register, .{ .key = trusted, .session = @splat(1) }, source, ad, "{}", 0);
    // Naming the address it publishes from needs no leave.
    ad.address = "8.8.8.8";
    try registry.advertise(.register, .{ .key = @splat(4), .session = @splat(1) }, source, ad, "{}", 0);
}

test "a full listing table takes from the source with the most, and leaves single listings alone" {
    const registry = try std.testing.allocator.create(Registry);
    defer std.testing.allocator.destroy(registry);
    registry.* = .{};
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
    };
    const Fill = struct {
        fn identity(index: usize) Identity {
            var who: Identity = .{ .key = @splat(0), .session = @splat(1) };
            std.mem.writeInt(u16, who.key[0..2], @intCast(index), .big);
            return who;
        }
        fn source(index: usize) net.IpAddress {
            return .{ .ip4 = .{ .bytes = .{ 8, 8, @intCast(index / 256), @intCast(index % 256) }, .port = 0 } };
        }
    };
    // One listing a source: nobody gives one up.
    for (0..listing_capacity) |index| try registry.advertise(.register, Fill.identity(index), Fill.source(index), ad, "{}", 0);
    const late = try net.IpAddress.parse("9.9.9.9", 0);
    try std.testing.expectError(error.Busy, registry.advertise(.register, Fill.identity(1000), late, ad, "{}", 1));

    // Sixteen sources with sixteen listings each: a newcomer takes one of theirs.
    registry.listings = @splat(null);
    for (0..listing_capacity) |index| try registry.advertise(.register, Fill.identity(index), Fill.source(index / 16), ad, "{}", 0);
    try registry.advertise(.register, Fill.identity(1000), late, ad, "{}", 1);
    var held: usize = 0;
    for (registry.listings) |entry| {
        if (entry.?.source.eql(&late)) held += 1;
    }
    try std.testing.expectEqual(1, held);
    // The crowding sources can't take from each other.
    try std.testing.expectError(error.RateLimited, registry.advertise(.register, Fill.identity(1001), Fill.source(3), ad, "{}", 1));
}
