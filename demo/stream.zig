//! Stream a response to the client.
//!
//! 👉 Be sure to configure the Lambda function with URL enabled and RESPONSE_STREAM invoke mode.
const std = @import("std");
const lambda = @import("aws-lambda");

pub fn main() void {
    lambda.handleStream(handler, .{});
}

/// 0.5 seconds (in nanoseconds)
const HALF_SEC = 500_000_000;

fn handler(_: lambda.Context, _: []const u8, stream: lambda.Stream) !void {
    // Start a textual event stream.
    try stream.open("text/event-stream");

    // Append multiple to the stream’s buffer without publishing to the client.
    try stream.write("id: 0\n");
    try stream.writer().print("data: This is message number {d}\n\n", .{1});

    // Publish the buffered data to the client.
    try stream.flush();
    std.time.sleep(HALF_SEC);

    // Shortcut for both `write` and `flush` in one call.
    try stream.publish("id: 1\ndata: This is message number 2\n\n");
    std.time.sleep(HALF_SEC);

    // One last message to the client...
    try stream.writer().print("id: {d}\ndata: This is message number {d}\n\n", .{ 2, 3 });
    try stream.flush();

    // We can optionally let the runtime know we have finished the response.
    // If we don't have more work to do, we can return without calling `close()`.
    try stream.close();

    // Then we can proceed to other work.
    doSomeCleanup();
}

fn doSomeCleanup() void {
    // Some cleanup work...
}
