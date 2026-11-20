//! Community-run game listings.
const std = @import("std");
const protocol = @import("protocol.zig");
const Registry = @import("registry.zig");
const Server = @import("http.zig");
const updates = @import("updates.zig");
const version = @import("version.zig");

const usage =
    \\Usage: openreliant-directory [--bind ADDRESS:PORT] [--trust-proxy]
    \\                             [--allow-game ID] [--allow-host PUBLIC-KEY]
    \\                             [--no-update-check]
    \\                             [--max-connections COUNT]
    \\                             [--allow-private-publishers]
    \\                             [--stun ENDPOINT] [--turn ENDPOINT]
    \\                             [--turn-host PUBLIC-KEY] [--turn-secret-file PATH]
    \\       openreliant-directory --version
    \\
    \\The default listener is 127.0.0.1:8080. Put an HTTPS proxy in front of a public instance.
    \\With --trust-proxy, the loopback proxy must replace X-Forwarded-For with the original IP.
    \\Omit --allow-game and --allow-host to accept any game and any verified host key.
    \\Use --no-update-check to skip checking for releases on GitHub at startup.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, usage);
        return 0;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "openreliant-directory " ++ version.string ++ "\n");
        return 0;
    }
    const settings = Settings.parse(args[1..]) catch |err| {
        std.log.err("invalid directory settings: {t}", .{err});
        return 1;
    };
    const registry = try init.gpa.create(Registry);
    defer init.gpa.destroy(registry);
    registry.* = .{ .policy = settings.policy };
    std.log.info("OpenReliant Directory {s}", .{version.string});
    var update_check: std.Io.Group = .init;
    defer update_check.cancel(init.io);
    if (settings.check_updates) {
        update_check.concurrent(init.io, updates.check, .{init.io}) catch |err|
            std.log.debug("could not start the release check: {t}", .{err});
    }
    const secret = if (settings.turn_secret_file) |path| try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(256)) else null;
    defer if (secret) |bytes| {
        std.crypto.secureZero(u8, bytes);
        init.gpa.free(bytes);
    };
    const turn_secret = if (secret) |bytes| std.mem.trim(u8, bytes, "\r\n") else null;
    if (turn_secret) |bytes| if (bytes.len < 32) return error.ShortTurnSecret;
    var server: Server = .{ .io = init.io, .trust_proxy = settings.trust_proxy, .allow_private_publishers = settings.allow_private_publishers, .stun = settings.stun, .turn = settings.turn, .turn_hosts = settings.turn_hosts[0..settings.turn_host_count], .turn_secret = turn_secret, .registry = registry, .max_connections = settings.max_connections };
    try server.serve(settings.bind);
    return 0;
}

const Settings = struct {
    bind: std.Io.net.IpAddress = .{ .ip4 = .loopback(8080) },
    trust_proxy: bool = false,
    allow_private_publishers: bool = false,
    check_updates: bool = true,
    stun: ?[]const u8 = null,
    turn: ?[]const u8 = null,
    turn_hosts: [64]protocol.Key = undefined,
    turn_host_count: usize = 0,
    turn_secret_file: ?[]const u8 = null,
    max_connections: usize = Server.default_connections,
    policy: Registry.Policy = .{},

    fn parse(args: []const [:0]const u8) !Settings {
        var settings: Settings = .{};
        var next: usize = 0;
        while (next < args.len) : (next += 1) {
            const argument = args[next];
            if (std.mem.eql(u8, argument, "--allow-private-publishers")) {
                settings.allow_private_publishers = true;
                continue;
            }
            if (std.mem.eql(u8, argument, "--no-update-check")) {
                settings.check_updates = false;
                continue;
            }
            if (std.mem.eql(u8, argument, "--trust-proxy")) {
                settings.trust_proxy = true;
                continue;
            }
            next += 1;
            if (next == args.len) return error.MissingValue;
            const value = args[next];
            if (std.mem.eql(u8, argument, "--stun") or std.mem.eql(u8, argument, "--turn")) {
                const prefix = if (std.mem.eql(u8, argument, "--stun")) "stun:" else "turn:";
                if (!std.mem.startsWith(u8, value, prefix) or value.len <= prefix.len or value.len > 255) return error.InvalidEndpoint;
                for (value) |c| if (!std.ascii.isAlphanumeric(c) and c != ':' and c != '.' and c != '-' and c != '[' and c != ']') return error.InvalidEndpoint;
                if (std.mem.eql(u8, argument, "--stun")) settings.stun = value else settings.turn = value;
            } else if (std.mem.eql(u8, argument, "--turn-host")) {
                if (settings.turn_host_count == settings.turn_hosts.len) return error.TooManyTurnHosts;
                settings.turn_hosts[settings.turn_host_count] = try protocol.decodeHex(protocol.public_key_size, value);
                settings.turn_host_count += 1;
            } else if (std.mem.eql(u8, argument, "--turn-secret-file")) {
                settings.turn_secret_file = value;
            } else if (std.mem.eql(u8, argument, "--max-connections")) {
                settings.max_connections = std.fmt.parseInt(usize, value, 10) catch return error.InvalidConnectionLimit;
                if (settings.max_connections == 0 or settings.max_connections > 1024) return error.InvalidConnectionLimit;
            } else if (std.mem.eql(u8, argument, "--bind")) {
                settings.bind = try .parseLiteral(value);
                if (settings.bind.getPort() == 0) return error.InvalidPort;
            } else if (std.mem.eql(u8, argument, "--allow-game")) {
                if (!protocol.identifier(value)) return error.InvalidGameId;
                settings.policy.game = value;
            } else if (std.mem.eql(u8, argument, "--allow-host")) {
                settings.policy.host = try protocol.decodeHex(protocol.public_key_size, value);
            } else return error.UnknownOption;
        }
        if (settings.trust_proxy and !Server.loopback(settings.bind)) return error.ProxyNeedsLoopback;
        if (settings.allow_private_publishers and !settings.trust_proxy) return error.PrivatePublishersNeedProxy;
        if ((settings.turn != null) != (settings.turn_host_count != 0) or (settings.turn != null) != (settings.turn_secret_file != null)) return error.IncompleteTurnSettings;
        return settings;
    }
};

test {
    std.testing.refAllDecls(protocol);
    std.testing.refAllDecls(Registry);
    _ = updates;
    _ = version;
}

test "TURN requires an endpoint, a secret and an authorised host" {
    try std.testing.expectError(error.IncompleteTurnSettings, Settings.parse(&.{ "--turn", "turn:relay.example:3478" }));
    try std.testing.expectError(error.InvalidEndpoint, Settings.parse(&.{ "--stun", "stun:user:secret@relay.example" }));
    const key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const settings = try Settings.parse(&.{ "--stun", "stun:relay.example:3478", "--turn", "turn:relay.example:3478", "--turn-host", key, "--turn-secret-file", "secret" });
    try std.testing.expectEqual(@as(usize, 1), settings.turn_host_count);
}
