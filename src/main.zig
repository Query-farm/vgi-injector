// Copyright 2026 Query.Farm LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");
const posix = std.posix;
const http = std.http;
const crypto = std.crypto;

const build_options = @import("build_options");
const ca_pem = @embedFile("ca-certificates.crt");

fn log(msg: []const u8) void {
    _ = posix.write(posix.STDERR_FILENO, msg) catch {};
}

pub fn main() void {
    run() catch posix.exit(1);
}

fn run() !void {
    const allocator = std.heap.page_allocator;

    log("vgi-injector: Copyright 2026 Query.Farm LLC — https://query.farm\n");
    log("vgi-injector: version ");
    log(build_options.version);
    log("\n");

    const url_str = posix.getenv("VGI_INJECTOR_URL") orelse {
        log("error: VGI_INJECTOR_URL environment variable is not set\n");
        posix.exit(1);
    };

    log("vgi-injector: url=");
    log(url_str);
    log("\n");

    const uri = std.Uri.parse(url_str) catch {
        log("error: invalid URL\n");
        posix.exit(1);
    };

    const hostname = if (uri.host) |h| h.percent_encoded else {
        log("error: URL has no host\n");
        posix.exit(1);
    };
    const port: u16 = uri.port orelse 443;

    const dns_server_str = posix.getenv("VGI_INJECTOR_DNS") orelse "1.1.1.1";

    log("vgi-injector: resolving ");
    log(hostname);
    log(" via ");
    log(dns_server_str);
    log("\n");

    const dns_addr = parseDnsAddr(dns_server_str) orelse {
        log("error: invalid VGI_INJECTOR_DNS address: ");
        log(dns_server_str);
        log("\n");
        posix.exit(1);
    };

    const resolved_ip = dnsResolveWithRetry(hostname, dns_addr, 3) orelse {
        log("error: failed to resolve ");
        log(hostname);
        log(" after 3 attempts\n");
        posix.exit(1);
    };
    var ip_buf: [46]u8 = undefined;
    const ip_str = ipToString(resolved_ip, &ip_buf);
    log("vgi-injector: resolved to ");
    log(ip_str);
    log("\n");

    // Download
    const body = downloadWithRetry(allocator, uri, hostname, ip_str, port, 3) orelse {
        log("error: failed to download binary\n");
        posix.exit(1);
    };

    if (body.len == 0) {
        log("error: downloaded binary is empty\n");
        posix.exit(1);
    }

    var size_buf: [20]u8 = undefined;
    log("vgi-injector: download complete, ");
    log(std.fmt.bufPrint(&size_buf, "{d}", .{body.len}) catch "?");
    log(" bytes, writing to memfd\n");

    // Create memfd, write binary, exec from /proc/self/fd/N
    const memfd = posix.memfd_createZ("vgi", 0) catch {
        log("error: memfd_create failed\n");
        posix.exit(1);
    };

    const memfile = std.fs.File{ .handle = memfd };
    memfile.writeAll(body) catch {
        log("error: failed to write to memfd\n");
        posix.exit(1);
    };

    // Build /proc/self/fd/N path
    var fd_path_buf: [64]u8 = undefined;
    const fd_path = std.fmt.bufPrintZ(&fd_path_buf, "/proc/self/fd/{d}", .{memfd}) catch {
        log("error: fd path too long\n");
        posix.exit(1);
    };

    log("vgi-injector: exec'ing from memfd\n");

    var argv_buf: [256:null]?[*:0]const u8 = @splat(null);
    var argc: usize = 0;
    argv_buf[0] = fd_path;
    argc = 1;

    var arg_iter = std.process.argsWithAllocator(allocator) catch posix.exit(1);
    _ = arg_iter.skip();
    while (arg_iter.next()) |arg| {
        if (argc >= 255) break;
        argv_buf[argc] = arg;
        argc += 1;
    }

    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.os.environ.ptr);
    _ = posix.execveZ(fd_path, &argv_buf, envp) catch {};
    log("error: failed to exec\n");
    posix.exit(1);
}

fn downloadWithRetry(allocator: std.mem.Allocator, uri: std.Uri, hostname: []const u8, ip_str: []const u8, port: u16, max_attempts: u32) ?[]const u8 {
    var attempt: u32 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        if (attempt > 0) {
            var buf1: [4]u8 = undefined;
            var buf2: [4]u8 = undefined;
            const n = std.fmt.bufPrint(&buf1, "{d}", .{attempt + 1}) catch "?";
            const m = std.fmt.bufPrint(&buf2, "{d}", .{max_attempts}) catch "?";
            log("vgi-injector: retry ");
            log(n);
            log("/");
            log(m);
            log("\n");

            const backoff_ns: u64 = @as(u64, 1) << @intCast(attempt - 1);
            std.Thread.sleep(backoff_ns * std.time.ns_per_s);
        }

        const result = doFetch(allocator, uri, hostname, ip_str, port) catch |err| {
            log("vgi-injector: fetch error: ");
            log(@errorName(err));
            log("\n");
            continue;
        };
        return result;
    }
    return null;
}

fn doFetch(allocator: std.mem.Allocator, uri: std.Uri, hostname: []const u8, ip_str: []const u8, port: u16) ![]const u8 {
    var client: http.Client = .{ .allocator = allocator };
    defer client.deinit();

    // Load embedded CA certs
    client.ca_bundle = .{};
    try addPemCerts(&client.ca_bundle, allocator);
    client.next_https_rescan_certs = false;

    // Connect to the resolved IP, but use hostname for TLS SNI
    log("vgi-injector: connecting to ");
    log(ip_str);
    log(":");
    var port_buf: [6]u8 = undefined;
    log(std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch "?");
    log("\n");

    const conn = try client.connectTcpOptions(.{
        .host = ip_str,
        .port = port,
        .protocol = .tls,
        .proxied_host = hostname,
        .proxied_port = port,
    });

    var req = try client.request(.GET, uri, .{
        .connection = conn,
        .headers = .{ .host = .{ .override = hostname } },
    });
    defer req.deinit();

    try req.sendBodiless();

    var response = try req.receiveHead(&.{});

    if (response.head.status != .ok) return error.BadStatus;

    var transfer_buf: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buf);

    const max_body_size = 100 * 1024 * 1024; // 100 MB
    var body: std.ArrayListUnmanaged(u8) = .empty;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&buf) catch |err| switch (err) {
            error.ReadFailed => break,
        };
        if (n == 0) break;
        if (body.items.len + n > max_body_size) return error.BodyTooLarge;
        try body.appendSlice(allocator, buf[0..n]);
    }

    return body.items;
}

fn addPemCerts(bundle: *crypto.Certificate.Bundle, gpa: std.mem.Allocator) !void {
    const begin_marker = "-----BEGIN CERTIFICATE-----";
    const end_marker = "-----END CERTIFICATE-----";
    const now_sec = std.time.timestamp();

    var start_index: usize = 0;
    while (std.mem.indexOfPos(u8, ca_pem, start_index, begin_marker)) |begin_marker_start| {
        const cert_start = begin_marker_start + begin_marker.len;
        const cert_end = std.mem.indexOfPos(u8, ca_pem, cert_start, end_marker) orelse break;
        start_index = cert_end + end_marker.len;
        const encoded_cert = std.mem.trim(u8, ca_pem[cert_start..cert_end], " \t\r\n");

        const decoded_start: u32 = @intCast(bundle.bytes.items.len);
        // Compute max decoded size
        const max_decoded = encoded_cert.len / 4 * 3 + 4;
        try bundle.bytes.ensureUnusedCapacity(gpa, max_decoded);
        const dest_buf = bundle.bytes.allocatedSlice()[decoded_start..];
        const decoder = std.base64.standard.decoderWithIgnore(" \t\r\n");
        bundle.bytes.items.len += decoder.decode(dest_buf, encoded_cert) catch continue;
        bundle.parseCert(gpa, decoded_start, now_sec) catch {
            bundle.bytes.items.len = decoded_start;
            continue;
        };
    }
}

const DnsAddr = union(enum) {
    ipv4: u32,
    ipv6: [16]u8,
};

fn parseDnsAddr(s: []const u8) ?DnsAddr {
    // Try IPv4 first
    if (parseIpv4(s)) |v4| return .{ .ipv4 = v4 };
    // Try IPv6
    if (parseIpv6(s)) |v6| return .{ .ipv6 = v6 };
    return null;
}

fn parseIpv4(s: []const u8) ?u32 {
    var result: u32 = 0;
    var octet: u32 = 0;
    var dots: u8 = 0;
    var digits: u8 = 0;
    for (s) |c| {
        if (c == '.') {
            if (digits == 0 or octet > 255) return null;
            result = (result << 8) | octet;
            octet = 0;
            dots += 1;
            digits = 0;
        } else if (c >= '0' and c <= '9') {
            octet = octet * 10 + (c - '0');
            digits += 1;
        } else return null;
    }
    if (dots != 3 or digits == 0 or octet > 255) return null;
    return (result << 8) | octet;
}

fn parseIpv6(s: []const u8) ?[16]u8 {
    var result: [16]u8 = .{0} ** 16;
    var groups: [8]u16 = .{0} ** 8;
    var group_count: usize = 0;
    var double_colon_pos: ?usize = null;
    var current: u32 = 0;
    var digits: u8 = 0;
    var i: usize = 0;

    while (i < s.len) {
        const c = s[i];
        if (c == ':') {
            if (i + 1 < s.len and s[i + 1] == ':') {
                if (double_colon_pos != null) return null; // only one :: allowed
                if (digits > 0) {
                    if (group_count >= 8) return null;
                    groups[group_count] = @intCast(current);
                    group_count += 1;
                }
                double_colon_pos = group_count;
                current = 0;
                digits = 0;
                i += 2;
                continue;
            } else {
                if (digits == 0 and i > 0) return null;
                if (group_count >= 8) return null;
                groups[group_count] = @intCast(current);
                group_count += 1;
                current = 0;
                digits = 0;
            }
        } else if (hexVal(c)) |hv| {
            current = current * 16 + hv;
            if (current > 0xFFFF) return null;
            digits += 1;
            if (digits > 4) return null;
        } else return null;
        i += 1;
    }

    // Final group
    if (digits > 0) {
        if (group_count >= 8) return null;
        groups[group_count] = @intCast(current);
        group_count += 1;
    }

    // Expand ::
    if (double_colon_pos) |dcp| {
        if (group_count > 8) return null;
        const missing = 8 - group_count;
        var j: usize = 7;
        var src: usize = group_count;
        while (src > dcp) {
            src -= 1;
            groups[j] = groups[src];
            if (j == 0) break;
            j -= 1;
        }
        // Zero out the expanded region
        var k: usize = dcp;
        while (k < dcp + missing) : (k += 1) {
            groups[k] = 0;
        }
    } else {
        if (group_count != 8) return null;
    }

    // Convert to bytes
    for (groups, 0..) |g, gi| {
        result[gi * 2] = @intCast(g >> 8);
        result[gi * 2 + 1] = @intCast(g & 0xFF);
    }
    return result;
}

fn hexVal(c: u8) ?u32 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn dnsResolveWithRetry(hostname: []const u8, dns_addr: DnsAddr, max_attempts: u32) ?u32 {
    var attempt: u32 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        if (attempt > 0) {
            var buf1: [4]u8 = undefined;
            var buf2: [4]u8 = undefined;
            const n = std.fmt.bufPrint(&buf1, "{d}", .{attempt + 1}) catch "?";
            const m = std.fmt.bufPrint(&buf2, "{d}", .{max_attempts}) catch "?";
            log("vgi-injector: dns retry ");
            log(n);
            log("/");
            log(m);
            log("\n");
            const backoff_ns: u64 = @as(u64, 1) << @intCast(attempt - 1);
            std.Thread.sleep(backoff_ns * std.time.ns_per_s);
        }
        const result = dnsResolve(hostname, dns_addr) catch |err| {
            log("vgi-injector: dns error: ");
            log(@errorName(err));
            log("\n");
            continue;
        };
        return result;
    }
    return null;
}

fn dnsResolve(hostname: []const u8, dns_addr: DnsAddr) !u32 {
    const af: u32 = switch (dns_addr) {
        .ipv4 => posix.AF.INET,
        .ipv6 => posix.AF.INET6,
    };
    const sock = try posix.socket(af, posix.SOCK.DGRAM, 0);
    defer posix.close(sock);

    const timeout = posix.timeval{ .sec = 5, .usec = 0 };
    posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

    // Build DNS query
    var query: [512]u8 = undefined;
    var qlen: usize = 0;

    // Header: ID=0x1234, flags=0x0100 (RD), QDCOUNT=1
    const header = [_]u8{ 0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    @memcpy(query[0..12], &header);
    qlen = 12;

    // Encode domain name as labels
    var start: usize = 0;
    for (hostname, 0..) |c, i| {
        if (c == '.') {
            const label_len = i - start;
            query[qlen] = @intCast(label_len);
            qlen += 1;
            @memcpy(query[qlen .. qlen + label_len], hostname[start..i]);
            qlen += label_len;
            start = i + 1;
        }
    }
    // Last label
    const last_len = hostname.len - start;
    query[qlen] = @intCast(last_len);
    qlen += 1;
    @memcpy(query[qlen .. qlen + last_len], hostname[start..]);
    qlen += last_len;

    // Null terminator + QTYPE=A (1) + QCLASS=IN (1)
    query[qlen] = 0;
    qlen += 1;
    query[qlen] = 0;
    query[qlen + 1] = 1;
    query[qlen + 2] = 0;
    query[qlen + 3] = 1;
    qlen += 4;

    // Send to DNS server
    switch (dns_addr) {
        .ipv4 => |ip| {
            const server = posix.sockaddr.in{
                .port = @byteSwap(@as(u16, 53)),
                .addr = @byteSwap(ip),
            };
            _ = try posix.sendto(sock, query[0..qlen], 0, @ptrCast(&server), @sizeOf(@TypeOf(server)));
        },
        .ipv6 => |addr| {
            const server = posix.sockaddr.in6{
                .port = @byteSwap(@as(u16, 53)),
                .flowinfo = 0,
                .addr = addr,
                .scope_id = 0,
            };
            _ = try posix.sendto(sock, query[0..qlen], 0, @ptrCast(&server), @sizeOf(@TypeOf(server)));
        },
    }

    var resp: [512]u8 = undefined;
    const rlen = try posix.recvfrom(sock, &resp, 0, null, null);

    if (rlen < 12) return error.DnsError;

    const ancount = (@as(u16, resp[6]) << 8) | resp[7];
    if (ancount == 0) return error.DnsError;

    // Skip question section
    var pos: usize = 12;
    while (pos < rlen and resp[pos] != 0) {
        if (resp[pos] & 0xC0 == 0xC0) {
            pos += 2;
            break;
        }
        const label_len = resp[pos];
        if (pos + 1 + label_len > rlen) return error.DnsError;
        pos += 1 + label_len;
    }
    if (pos < rlen and resp[pos] == 0) pos += 1;
    if (pos + 4 > rlen) return error.DnsError;
    pos += 4; // QTYPE + QCLASS

    // Find first A record
    var i: u16 = 0;
    while (i < ancount and pos < rlen) : (i += 1) {
        // Skip name (pointer or labels)
        if (pos >= rlen) return error.DnsError;
        if (resp[pos] & 0xC0 == 0xC0) {
            if (pos + 2 > rlen) return error.DnsError;
            pos += 2;
        } else {
            while (pos < rlen and resp[pos] != 0) {
                const label_len = resp[pos];
                if (pos + 1 + label_len > rlen) return error.DnsError;
                pos += 1 + label_len;
            }
            if (pos >= rlen) return error.DnsError;
            pos += 1;
        }

        if (pos + 10 > rlen) return error.DnsError;
        const rtype = (@as(u16, resp[pos]) << 8) | resp[pos + 1];
        const rdlength = (@as(u16, resp[pos + 8]) << 8) | resp[pos + 9];
        pos += 10;

        if (pos + rdlength > rlen) return error.DnsError;
        if (rtype == 1 and rdlength == 4) {
            return (@as(u32, resp[pos]) << 24) |
                (@as(u32, resp[pos + 1]) << 16) |
                (@as(u32, resp[pos + 2]) << 8) |
                resp[pos + 3];
        }
        pos += rdlength;
    }

    return error.DnsError;
}

fn ipToString(ip: u32, buf: *[46]u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
        (ip >> 24) & 0xFF,
        (ip >> 16) & 0xFF,
        (ip >> 8) & 0xFF,
        ip & 0xFF,
    }) catch "0.0.0.0";
}
