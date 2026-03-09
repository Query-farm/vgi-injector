const std = @import("std");
const posix = std.posix;
pub fn main() void {
    _ = posix.write(posix.STDERR_FILENO, "INJECTED BINARY RUNNING\n") catch {};
    while (true) {
        _ = posix.write(posix.STDERR_FILENO, "heartbeat from injected binary\n") catch {};
        std.Thread.sleep(3 * std.time.ns_per_s);
    }
}
