const std = @import("std");

// Implements URI parsing roughly adhere to https://tools.ietf.org/html/rfc3986
// Does not do perfect grammar and character class checking, but should be robust against
// "wild" URIs

/// Stores separate parts of a URI.
pub const UriComponents = struct {
    scheme: ?[]const u8,
    user: ?[]const u8,
    password: ?[]const u8,
    host: ?[]const u8,
    port: ?u16,
    path: ?[]const u8,
    query: ?[]const u8,
    fragment: ?[]const u8,
};

/// Applies URI encoding and replaces all reserved characters with their respective %XX code.
pub fn escapeString(allocator: *std.mem.Allocator, input: []const u8) error{OutOfMemory}![]const u8 {
    var outsize: usize = 0;
    for (input) |c| {
        outsize += if (isUnreserved(c)) @as(usize, 1) else 3;
    }
    var output = try allocator.alloc(u8, outsize);
    var outptr: usize = 0;

    for (input) |c| {
        if (isUnreserved(c)) {
            output[outptr] = c;
            outptr += 1;
        } else {
            var buf: [2]u8 = undefined;
            _ = std.fmt.bufPrint(&buf, "{X:0>2}", .{c}) catch unreachable;

            output[outptr + 0] = '%';
            output[outptr + 1] = buf[0];
            output[outptr + 2] = buf[1];
            outptr += 3;
        }
    }
    return output;
}

/// Parses a URI string and unescapes all %XX where XX is a valid hex number. Otherwise, verbatim copies
/// them to the output.
pub fn unescapeString(allocator: *std.mem.Allocator, input: []const u8) error{OutOfMemory}![]const u8 {
    var outsize: usize = 0;
    var inptr: usize = 0;
    while (inptr < input.len) {
        if (input[inptr] == '%') {
            inptr += 1;
            if (inptr + 2 <= input.len) {
                _ = std.fmt.parseInt(u8, input[inptr..][0..2], 16) catch {
                    outsize += 3;
                    inptr += 2;
                    continue;
                };
                inptr += 2;
                outsize += 1;
            }
        } else {
            inptr += 1;
            outsize += 1;
        }
    }

    var output = try allocator.alloc(u8, outsize);
    var outptr: usize = 0;
    inptr = 0;
    while (inptr < input.len) {
        if (input[inptr] == '%') {
            inptr += 1;
            if (inptr + 2 <= input.len) {
                const value = std.fmt.parseInt(u8, input[inptr..][0..2], 16) catch {
                    output[outptr + 0] = input[inptr + 0];
                    output[outptr + 1] = input[inptr + 1];
                    inptr += 2;
                    outptr += 2;
                    continue;
                };

                output[outptr] = value;

                inptr += 2;
                outptr += 1;
            }
        } else {
            output[outptr] = input[inptr];
            inptr += 1;
            outptr += 1;
        }
    }
    return output;
}

pub const ParseError = error{ UnexpectedCharacter, InvalidFormat, InvalidPort };

/// Parses the URI or returns an error.
/// The return value will have unescaped
pub fn parse(text: []const u8) ParseError!UriComponents {
    var uri = UriComponents{
        .scheme = null,
        .user = null,
        .password = null,
        .host = null,
        .port = null,
        .path = null,
        .query = null,
        .fragment = null,
    };

    var reader = SliceReader{ .slice = text };

    uri.scheme = reader.readWhile(isSchemeChar);

    // after the scheme, a ':' must appear
    if (reader.get()) |c| {
        if (c != ':')
            return error.UnexpectedCharacter;
    } else {
        return error.InvalidFormat;
    }

    if (reader.peekPrefix("//")) { // authority part
        std.debug.assert(reader.get().? == '/');
        std.debug.assert(reader.get().? == '/');

        const authority = reader.readUntil(isAuthoritySeparator);
        if (authority.len == 0)
            return error.InvalidFormat;

        var start_of_host: usize = 0;
        if (std.mem.indexOf(u8, authority, "@")) |index| {
            start_of_host = index + 1;
            const user_info = authority[0..index];

            if (std.mem.indexOf(u8, user_info, ":")) |idx| {
                uri.user = user_info[0..idx];
                if (idx < user_info.len - 1) { // empty password is also "no password"
                    uri.password = user_info[idx + 1 ..];
                }
            } else {
                uri.user = user_info;
                uri.password = null;
            }
        }

        var end_of_host: usize = authority.len;

        if (authority[start_of_host] == '[') { // IPv6
            end_of_host = std.mem.lastIndexOf(u8, authority, "]") orelse return error.InvalidFormat;
            end_of_host += 1;

            if (std.mem.lastIndexOf(u8, authority, ":")) |index| {
                if (index >= end_of_host) { // if not part of the V6 address field
                    end_of_host = std.math.min(end_of_host, index);
                    uri.port = std.fmt.parseInt(u16, authority[index + 1 ..], 10) catch return error.InvalidPort;
                }
            }
        } else if (std.mem.lastIndexOf(u8, authority, ":")) |index| {
            if (index >= start_of_host) { // if not part of the userinfo field
                end_of_host = std.math.min(end_of_host, index);
                uri.port = std.fmt.parseInt(u16, authority[index + 1 ..], 10) catch return error.InvalidPort;
            }
        }

        uri.host = authority[start_of_host..end_of_host];
    }

    uri.path = reader.readUntil(isPathSeparator);

    if ((reader.peek() orelse 0) == '?') { // query part
        std.debug.assert(reader.get().? == '?');
        uri.query = reader.readUntil(isQuerySeparator);
    }

    if ((reader.peek() orelse 0) == '#') { // fragment part
        std.debug.assert(reader.get().? == '#');
        uri.fragment = reader.readUntilEof();
    }

    return uri;
}

const SliceReader = struct {
    const Self = @This();

    slice: []const u8,
    offset: usize = 0,

    fn get(self: *Self) ?u8 {
        if (self.offset >= self.slice.len)
            return null;
        const c = self.slice[self.offset];
        self.offset += 1;
        return c;
    }

    fn peek(self: Self) ?u8 {
        if (self.offset >= self.slice.len)
            return null;
        return self.slice[self.offset];
    }

    fn readWhile(self: *Self, predicate: fn (u8) bool) []const u8 {
        const start = self.offset;
        var end = start;
        while (end < self.slice.len and predicate(self.slice[end])) {
            end += 1;
        }
        self.offset = end;
        return self.slice[start..end];
    }

    fn readUntil(self: *Self, predicate: fn (u8) bool) []const u8 {
        const start = self.offset;
        var end = start;
        while (end < self.slice.len and !predicate(self.slice[end])) {
            end += 1;
        }
        self.offset = end;
        return self.slice[start..end];
    }

    fn readUntilEof(self: *Self) []const u8 {
        const start = self.offset;
        self.offset = self.slice.len;
        return self.slice[start..];
    }

    fn peekPrefix(self: Self, prefix: []const u8) bool {
        if (self.offset + prefix.len > self.slice.len)
            return false;
        return std.mem.eql(u8, self.slice[self.offset..][0..prefix.len], prefix);
    }
};

/// scheme      = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )
fn isSchemeChar(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '+', '-', '.' => true,
        else => false,
    };
}

fn isAuthoritySeparator(c: u8) bool {
    return switch (c) {
        '/', '?', '#' => true,
        else => false,
    };
}

/// reserved    = gen-delims / sub-delims
fn isReserved(c: u8) bool {
    return isGenLimit(c) or isSubLimit(c);
}

/// gen-delims  = ":" / "/" / "?" / "#" / "[" / "]" / "@"
fn isGenLimit(c: u8) bool {
    return switch (c) {
        ':', ',', '?', '#', '[', ']', '@' => true,
        else => false,
    };
}

/// sub-delims  = "!" / "$" / "&" / "'" / "(" / ")"
///             / "*" / "+" / "," / ";" / "="
fn isSubLimit(c: u8) bool {
    return switch (c) {
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=' => true,
        else => false,
    };
}

/// unreserved  = ALPHA / DIGIT / "-" / "." / "_" / "~"
fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

fn isPathSeparator(c: u8) bool {
    return switch (c) {
        '?', '#' => true,
        else => false,
    };
}

fn isQuerySeparator(c: u8) bool {
    return switch (c) {
        '#' => true,
        else => false,
    };
}

test "should fail gracefully" {
    try std.testing.expectEqual(@as(ParseError!UriComponents, error.InvalidFormat), parse("foobar://"));
}

test "scheme" {
    try std.testing.expectEqualSlices(u8, "http", (try parse("http:_")).scheme.?);
    try std.testing.expectEqualSlices(u8, "scheme-mee", (try parse("scheme-mee:_")).scheme.?);
    try std.testing.expectEqualSlices(u8, "a.b.c", (try parse("a.b.c:_")).scheme.?);
    try std.testing.expectEqualSlices(u8, "ab+", (try parse("ab+:_")).scheme.?);
    try std.testing.expectEqualSlices(u8, "X+++", (try parse("X+++:_")).scheme.?);
    try std.testing.expectEqualSlices(u8, "Y+-.", (try parse("Y+-.:_")).scheme.?);
}

test "authority" {
    try std.testing.expectEqualSlices(u8, "hostname", (try parse("scheme://hostname")).host.?);

    try std.testing.expectEqualSlices(u8, "hostname", (try parse("scheme://userinfo@hostname")).host.?);
    try std.testing.expectEqualSlices(u8, "userinfo", (try parse("scheme://userinfo@hostname")).user.?);
    try std.testing.expectEqual(@as(?[]const u8, null), (try parse("scheme://userinfo@hostname")).password);

    try std.testing.expectEqualSlices(u8, "hostname", (try parse("scheme://user:password@hostname")).host.?);
    try std.testing.expectEqualSlices(u8, "user", (try parse("scheme://user:password@hostname")).user.?);
    try std.testing.expectEqualSlices(u8, "password", (try parse("scheme://user:password@hostname")).password.?);

    try std.testing.expectEqualSlices(u8, "hostname", (try parse("scheme://hostname:0")).host.?);
    try std.testing.expectEqual(@as(u16, 1234), (try parse("scheme://hostname:1234")).port.?);

    try std.testing.expectEqualSlices(u8, "hostname", (try parse("scheme://userinfo@hostname:1234")).host.?);
    try std.testing.expectEqual(@as(u16, 1234), (try parse("scheme://userinfo@hostname:1234")).port.?);
    try std.testing.expectEqualSlices(u8, "userinfo", (try parse("scheme://userinfo@hostname:1234")).user.?);
    try std.testing.expectEqual(@as(?[]const u8, null), (try parse("scheme://userinfo@hostname:1234")).password);

    try std.testing.expectEqualSlices(u8, "hostname", (try parse("scheme://user:password@hostname:1234")).host.?);
    try std.testing.expectEqual(@as(u16, 1234), (try parse("scheme://user:password@hostname:1234")).port.?);
    try std.testing.expectEqualSlices(u8, "user", (try parse("scheme://user:password@hostname:1234")).user.?);
    try std.testing.expectEqualSlices(u8, "password", (try parse("scheme://user:password@hostname:1234")).password.?);
}

test "authority.password" {
    try std.testing.expectEqualSlices(u8, "username", (try parse("scheme://username@a")).user.?);
    try std.testing.expectEqual(@as(?[]const u8, null), (try parse("scheme://username@a")).password);

    try std.testing.expectEqualSlices(u8, "username", (try parse("scheme://username:@a")).user.?);
    try std.testing.expectEqual(@as(?[]const u8, null), (try parse("scheme://username:@a")).password);

    try std.testing.expectEqualSlices(u8, "username", (try parse("scheme://username:password@a")).user.?);
    try std.testing.expectEqualSlices(u8, "password", (try parse("scheme://username:password@a")).password.?);

    try std.testing.expectEqualSlices(u8, "username", (try parse("scheme://username::@a")).user.?);
    try std.testing.expectEqualSlices(u8, ":", (try parse("scheme://username::@a")).password.?);
}

fn testAuthorityHost(comptime hostlist: anytype) !void {
    inline for (hostlist) |hostname| {
        try std.testing.expectEqualSlices(u8, hostname, (try parse("scheme://" ++ hostname)).host.?);
    }
}

test "authority.dns-names" {
    try testAuthorityHost(.{
        "a",
        "a.b",
        "example.com",
        "www.example.com",
        "example.org.",
        "www.example.org.",
        "xn--nw2a.xn--j6w193g", // internationalization!
        "fe80--1ff-fe23-4567-890as3.ipv6-literal.net",
    });
    // still allowed…
}

test "authority.IPv4" {
    try testAuthorityHost(.{
        "127.0.0.1",
        "255.255.255.255",
        "0.0.0.0",
        "8.8.8.8",
        "1.2.3.4",
        "192.168.0.1",
        "10.42.0.0",
    });
}

test "authority.IPv6" {
    try testAuthorityHost(.{
        "[2001:db8:0:0:0:0:2:1]",
        "[2001:db8::2:1]",
        "[2001:db8:0000:1:1:1:1:1]",
        "[2001:db8:0:1:1:1:1:1]",
        "[0:0:0:0:0:0:0:0]",
        "[0:0:0:0:0:0:0:1]",
        "[::1]",
        "[::]",
        "[2001:db8:85a3:8d3:1319:8a2e:370:7348]",
        "[fe80::1ff:fe23:4567:890a%25eth2]",
        "[fe80::1ff:fe23:4567:890a]",
        "[fe80::1ff:fe23:4567:890a%253]",
        "[fe80:3::1ff:fe23:4567:890a]",
    });
}

test "RFC example 1" {
    const uri = "foo://example.com:8042/over/there?name=ferret#nose";
    try std.testing.expectEqual(UriComponents{
        .scheme = uri[0..3],
        .user = null,
        .password = null,
        .host = uri[6..17],
        .port = 8042,
        .path = uri[22..33],
        .query = uri[34..45],
        .fragment = uri[46..50],
    }, try parse(uri));
}

test "RFX example 2" {
    const uri = "urn:example:animal:ferret:nose";
    try std.testing.expectEqual(UriComponents{
        .scheme = uri[0..3],
        .user = null,
        .password = null,
        .host = null,
        .port = null,
        .path = uri[4..],
        .query = null,
        .fragment = null,
    }, try parse(uri));
}

// source:
// https://en.wikipedia.org/wiki/Uniform_Resource_Identifier#Examples
test "Examples from wikipedia" {
    // these should all parse
    const list = [_][]const u8{
        "https://john.doe@www.example.com:123/forum/questions/?tag=networking&order=newest#top",
        "ldap://[2001:db8::7]/c=GB?objectClass?one",
        "mailto:John.Doe@example.com",
        "news:comp.infosystems.www.servers.unix",
        "tel:+1-816-555-1212",
        "telnet://192.0.2.16:80/",
        "urn:oasis:names:specification:docbook:dtd:xml:4.1.2",
        "http://a/b/c/d;p?q",
    };
    for (list) |uri| {
        _ = try parse(uri);
    }
}

// source:
// https://tools.ietf.org/html/rfc3986#section-5.4.1
test "Examples from RFC3986" {
    // these should all parse
    const list = [_][]const u8{
        "http://a/b/c/g",
        "http://a/b/c/g",
        "http://a/b/c/g/",
        "http://a/g",
        "http://g",
        "http://a/b/c/d;p?y",
        "http://a/b/c/g?y",
        "http://a/b/c/d;p?q#s",
        "http://a/b/c/g#s",
        "http://a/b/c/g?y#s",
        "http://a/b/c/;x",
        "http://a/b/c/g;x",
        "http://a/b/c/g;x?y#s",
        "http://a/b/c/d;p?q",
        "http://a/b/c/",
        "http://a/b/c/",
        "http://a/b/",
        "http://a/b/",
        "http://a/b/g",
        "http://a/",
        "http://a/",
        "http://a/g",
    };
    for (list) |uri| {
        _ = try parse(uri);
    }
}

test "Special test" {
    // This is for all of you code readers ♥
    _ = try parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ&feature=youtu.be&t=0");
}

test "URI escaping" {
    const input = "\\ö/ äöß ~~.adas-https://canvas:123/#ads&&sad";
    const expected = "%5C%C3%B6%2F%20%C3%A4%C3%B6%C3%9F%20~~.adas-https%3A%2F%2Fcanvas%3A123%2F%23ads%26%26sad";

    const actual = try escapeString(std.testing.allocator, input);
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "URI unescaping" {
    const input = "%5C%C3%B6%2F%20%C3%A4%C3%B6%C3%9F%20~~.adas-https%3A%2F%2Fcanvas%3A123%2F%23ads%26%26sad";
    const expected = "\\ö/ äöß ~~.adas-https://canvas:123/#ads&&sad";

    const actual = try unescapeString(std.testing.allocator, input);
    defer std.testing.allocator.free(actual);

    try std.testing.expectEqualSlices(u8, expected, actual);
}
