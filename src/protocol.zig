//! Listings protocol v1. Game and mode identifiers belong to the game package.
const std = @import("std");
const net = std.Io.net;
const Ed25519 = std.crypto.sign.Ed25519;

pub const max_body = 4096;
pub const max_signed_message = max_body + 160;
pub const max_game_id = 64;
pub const public_key_size = Ed25519.PublicKey.encoded_length;
pub const signature_size = Ed25519.Signature.encoded_length;
pub const Session = [16]u8;
pub const Token = [32]u8;
pub const Key = [public_key_size]u8;
pub const Operation = enum { register, renew, withdraw };

pub const Identity = struct {
    key: Key,
    session: Session,

    pub fn eql(a: Identity, b: Identity) bool {
        return std.mem.eql(u8, &a.key, &b.key) and std.mem.eql(u8, &a.session, &b.session);
    }
};

pub const ChallengeRequest = struct {
    key: []const u8,
    session: []const u8,
    operation: Operation,
};

pub const Label = struct {
    id: []const u8,
    name: []const u8,
};

pub const Advertisement = struct {
    game: Label,
    revision: u64,
    name: []const u8,
    description: []const u8 = "",
    hosting: enum { dedicated, player_hosted },
    mode: ?Label = null,
    scenario: ?Label = null,
    players: u16,
    capacity: u16,
    accepting: bool,
    password: bool = false,
    protocol: u32,
    release: []const u8,
    content: []const u8 = "",
    port: u16,

    pub fn valid(ad: Advertisement) bool {
        return labelValid(ad.game) and ad.revision != 0 and textValid(ad.name, 96, false) and
            textValid(ad.description, 512, true) and
            (ad.mode == null or labelValid(ad.mode.?)) and
            (ad.scenario == null or labelValid(ad.scenario.?)) and ad.capacity != 0 and
            ad.players <= ad.capacity and ad.protocol != 0 and ad.port != 0 and
            textValid(ad.release, 64, false) and textValid(ad.content, 256, true);
    }
};

fn labelValid(label: Label) bool {
    return identifier(label.id) and textValid(label.name, 96, false);
}

pub fn identifier(text: []const u8) bool {
    if (text.len == 0 or text.len > max_game_id) return false;
    for (text) |byte| switch (byte) {
        'a'...'z', '0'...'9', '-', '_', '.' => {},
        else => return false,
    };
    return std.ascii.isAlphanumeric(text[0]) and std.ascii.isAlphanumeric(text[text.len - 1]);
}

fn textValid(text: []const u8, limit: usize, empty: bool) bool {
    if (text.len == 0) return empty;
    if (text.len > limit or !std.unicode.utf8ValidateSlice(text) or std.mem.trim(u8, text, " ").len == 0) return false;
    for (text) |byte| if (byte < 32 or byte == 127) return false;
    return true;
}

/// Require a single wire spelling so keys and sessions compare the same on every instance.
pub fn decodeHex(comptime size: usize, text: []const u8) ![size]u8 {
    if (text.len != size * 2) return error.InvalidHex;
    for (text) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return error.InvalidHex,
    };
    var bytes: [size]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, text);
    return bytes;
}

pub const Proof = struct {
    identity: Identity,
    token: Token,
    signature: [signature_size]u8,

    pub fn verify(proof: Proof, operation: Operation, body: []const u8) bool {
        if (body.len > max_body) return false;
        var buffer: [max_signed_message]u8 = undefined;
        const text = signedBytes(&buffer, operation, proof.token, proof.identity.session, body) catch return false;
        const key = Ed25519.PublicKey.fromBytes(proof.identity.key) catch return false;
        Ed25519.Signature.fromBytes(proof.signature).verify(text, key) catch return false;
        return true;
    }
};

pub fn signedBytes(
    buffer: *[max_signed_message]u8,
    operation: Operation,
    token: Token,
    session: Session,
    body: []const u8,
) ![]const u8 {
    return std.fmt.bufPrint(buffer, "OpenReliant Directory v1\n{t}\n{s}\n{s}\n{s}", .{
        operation, std.fmt.bytesToHex(token, .lower), std.fmt.bytesToHex(session, .lower), body,
    });
}

/// Use the observed IP. The signed advertisement supplies only the UDP port.
pub fn publicAddress(address: net.IpAddress) ?net.IpAddress {
    if (net.Ip4Address.fromAny(address)) |ip| {
        const a, const b, const c, _ = ip.bytes;
        if (a == 0 or a == 10 or a == 127 or a >= 224) return null;
        if ((a == 100 and b >= 64 and b < 128) or (a == 169 and b == 254) or
            (a == 172 and b >= 16 and b < 32) or (a == 192 and b == 168) or
            (a == 192 and (b == 0 or (b == 88 and c == 99))) or
            (a == 198 and (b == 18 or b == 19 or (b == 51 and c == 100))) or
            (a == 203 and b == 0 and c == 113)) return null;
        return .{ .ip4 = ip };
    }
    const ip = address.ip6;
    const a, const b, const c, const d = ip.bytes[0..4].*;
    if (a & 0xe0 != 0x20 or (a == 0x20 and b == 2)) return null;
    if ((a == 0x20 and b == 1 and (c < 2 or (c == 0x0d and d == 0xb8))) or
        (a == 0x3f and b == 0xff and c < 16)) return null;
    if (ip.interface.index != 0) return null;
    return address;
}

test "public endpoints reject local, mapped private and documentation addresses" {
    for ([_][]const u8{ "127.0.0.1", "10.1.0.8", "100.64.0.1", "192.0.2.8", "::1", "::ffff:192.168.0.4", "2001:db8::2", "3fff::1" }) |text| {
        try std.testing.expect(publicAddress(try net.IpAddress.parse(text, 0)) == null);
    }
    try std.testing.expect(publicAddress(try net.IpAddress.parse("8.8.8.8", 0)) != null);
}
