//! Check the latest published directory release once at startup.
const std = @import("std");
const Io = std.Io;
const version = @import("version.zig");
const log = std.log.scoped(.updates);

const latest_url = "https://api.github.com/repos/OpenReliant/openreliant-directory/releases/latest";
const release_page = "https://github.com/OpenReliant/openreliant-directory/releases/latest";
const timeout: Io.Duration = .fromSeconds(5);
const max_response = 128 * 1024;

pub fn check(io: Io) void {
    const Event = union(enum) { request: anyerror!void, deadline: Io.Cancelable!void };
    var events: [2]Event = undefined;
    var select: Io.Select(Event) = .init(io, &events);
    defer select.cancelDiscard();
    select.concurrent(.deadline, Io.sleep, .{ io, timeout, .awake }) catch return;
    select.concurrent(.request, checkLatest, .{io}) catch return;
    switch (select.await() catch return) {
        .request => |result| result catch |err| log.debug("could not check for updates: {t}", .{err}),
        .deadline => log.debug("the release check timed out", .{}),
    }
}

fn checkLatest(io: Io) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    var body_buffer: [max_response]u8 = undefined;
    var body: Io.Writer = .fixed(&body_buffer);
    const response = try client.fetch(.{
        .location = .{ .url = latest_url },
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{ .user_agent = .{ .override = "OpenReliant Directory" } },
        .extra_headers = &.{.{ .name = "Accept", .value = "application/vnd.github+json" }},
        .response_writer = &body,
    });
    switch (response.status) {
        .not_found => {
            log.debug("GitHub has no published directory release yet", .{});
            return;
        },
        .ok => {},
        else => return error.ReleaseLookupFailed,
    }
    if (try newerRelease(allocator, body.buffered(), version.semantic)) |latest| {
        log.warn("OpenReliant Directory {f} is available (running {s}). {s}", .{ latest, version.string, release_page });
    }
}

fn newerRelease(allocator: std.mem.Allocator, body: []const u8, current: std.SemanticVersion) !?std.SemanticVersion {
    const Release = struct { tag_name: []const u8, draft: bool = false, prerelease: bool = false };
    const release = try std.json.parseFromSliceLeaky(Release, allocator, body, .{ .ignore_unknown_fields = true });
    if (release.draft or release.prerelease) return null;
    const tag = std.mem.cutPrefix(u8, release.tag_name, "v") orelse return error.InvalidReleaseTag;
    const latest = try std.SemanticVersion.parse(tag);
    return if (latest.pre == null and latest.order(current) == .gt) latest else null;
}

test "only a newer stable release prompts an update" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const current = try std.SemanticVersion.parse("0.9.0+4.g1234567.dirty");
    const newer = try std.SemanticVersion.parse("0.10.0");
    try std.testing.expectEqual(newer, (try newerRelease(allocator, "{\"tag_name\":\"v0.10.0\",\"assets\":[]}", current)).?);
    for ([_][]const u8{
        "{\"tag_name\":\"v0.9.0\"}",
        "{\"tag_name\":\"v0.8.9\"}",
        "{\"tag_name\":\"v0.10.0-rc.1\"}",
        "{\"tag_name\":\"v0.10.0\",\"prerelease\":true}",
        "{\"tag_name\":\"v0.10.0\",\"draft\":true}",
    }) |body| try std.testing.expectEqual(null, try newerRelease(allocator, body, current));
    try std.testing.expectError(error.InvalidReleaseTag, newerRelease(allocator, "{\"tag_name\":\"latest\"}", current));
}
