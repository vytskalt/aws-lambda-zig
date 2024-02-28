const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Fetcher = @import("Fetcher.zig");

const API_VERSION = "2018-06-01";
const FMT_INIT_FAIL: []const u8 = "http://{s}/" ++ API_VERSION ++ "/runtime/init/error";
const FMT_INVOC_NEXT: []const u8 = "http://{s}/" ++ API_VERSION ++ "/runtime/invocation/next";
const FMT_INVOC_SUCCESS: []const u8 = "http://{s}/" ++ API_VERSION ++ "/runtime/invocation/{s}/response";
const FMT_INVOC_FAIL: []const u8 = "http://{s}/" ++ API_VERSION ++ "/runtime/invocation/{s}/error";

pub fn urlInitFail(allocator: Allocator, host: []const u8) std.fmt.AllocPrintError![]const u8 {
    return std.fmt.allocPrint(allocator, FMT_INIT_FAIL, .{host});
}

pub fn urlInvocationNext(gpa: Allocator, host: []const u8) std.fmt.AllocPrintError![]const u8 {
    return std.fmt.allocPrint(gpa, FMT_INVOC_NEXT, .{host});
}

pub fn urlInvocationSuccess(arena: Allocator, host: []const u8, request_id: []const u8) std.fmt.AllocPrintError![]const u8 {
    return std.fmt.allocPrint(arena, FMT_INVOC_SUCCESS, .{ host, request_id });
}

pub fn urlInvocationFail(arena: Allocator, host: []const u8, request_id: []const u8) std.fmt.AllocPrintError![]const u8 {
    return std.fmt.allocPrint(arena, FMT_INVOC_FAIL, .{ host, request_id });
}

pub const SendFetchError = error{ ParseError, ContainerError, UnknownStatus } || Fetcher.Error;

pub const InitFailResult = union(enum) {
    accepted: StatusResponse,
    forbidden: ErrorResponse,
};

/// Non-recoverable initialization error. Runtime should exit after reporting
/// the error. Error will be served in response to the first invoke.
///
/// `error_type` expects format _"category.reason"_ (example: _"Runtime.ConfigInvalid"_).
pub fn sendInitFail(
    allocator: Allocator,
    fetcher: *Fetcher,
    url: []const u8,
    error_type: ?[]const u8,
    error_body: ?ErrorRequest,
) SendFetchError!InitFailResult {
    const fetch = try fetchError(allocator, fetcher, url, error_type, error_body);
    return switch (fetch.status) {
        .accepted => .{ .accepted = StatusResponse{ .status = fetch.body } },
        .forbidden => .{ .forbidden = try ErrorResponse.parse(allocator, fetch.body) },
        .container_error => error.ContainerError,
        else => error.UnknownStatus,
    };
}

pub const InvocationNextResult = union(enum) {
    success: InvocationEvent,
    forbidden: ErrorResponse,
};

/// This is an iterator-style blocking API call. Runtime makes this request when
/// it is ready to process a new invoke.
pub fn sendInvocationNext(
    arena: Allocator,
    fetcher: *Fetcher,
    url: []const u8,
) SendFetchError!InvocationNextResult {
    var fetch = try fetcher.send(RuntimeStatus, .GET, url, .{});
    return switch (fetch.status) {
        .success => .{ .success = InvocationEvent.parse(&fetch.headers, fetch.body) },
        .forbidden => .{ .forbidden = try ErrorResponse.parse(arena, fetch.body) },
        .container_error => error.ContainerError,
        else => error.UnknownStatus,
    };
}

pub const InvocationEvent = struct {
    /// AWS request ID associated with the request.
    request_id: []const u8,

    /// X-Ray tracing id.
    xray_trace: []const u8,

    /// The function ARN requested.
    ///
    /// **This can be different in each invoke** that executes the same version.
    invoked_arn: []const u8,

    /// Function execution deadline counted in milliseconds since the _Unix epoch_.
    deadline_ms: u64,

    /// Information about the client application and device when invoked through the AWS Mobile SDK.
    client_context: []const u8 = &[_]u8{},

    /// Information about the Amazon Cognito identity provider when invoked through the AWS Mobile SDK.
    cognito_identity: []const u8 = &[_]u8{},

    /// JSON document specific to the invoking service’s event.
    payload: []const u8,

    pub fn parse(headers: *Fetcher.HeaderIterator, payload: []const u8) InvocationEvent {
        var event = InvocationEvent{
            .request_id = undefined,
            .xray_trace = undefined,
            .invoked_arn = undefined,
            .deadline_ms = undefined,
            .payload = payload,
        };

        while (headers.next()) |header| {
            if (std.mem.eql(u8, "Lambda-Runtime-Aws-Request-Id", header.name))
                event.request_id = header.value
            else if (std.mem.eql(u8, "Lambda-Runtime-Trace-Id", header.name))
                event.xray_trace = header.value
            else if (std.mem.eql(u8, "Lambda-Runtime-Invoked-Function-Arn", header.name))
                event.invoked_arn = header.value
            else if (std.mem.eql(u8, "Lambda-Runtime-Deadline-Ms", header.name))
                event.deadline_ms = std.fmt.parseInt(u64, header.value, 10) catch 0
            else if (std.mem.eql(u8, "Lambda-Runtime-Client-Context", header.name))
                event.client_context = header.value
            else if (std.mem.eql(u8, "Lambda-Runtime-Cognito-Identity", header.name))
                event.cognito_identity = header.value;
        }

        return event;
    }

    /// Remaining time in **milliseconds** before the function execution aborts.
    pub fn remaining(self: InvocationEvent) u64 {
        return @as(u64, @intCast(std.time.milliTimestamp())) - self.deadline_timestamp;
    }
};

pub const InvocationSuccessResult = union(enum) {
    accepted: StatusResponse,
    bad_request: ErrorResponse,
    forbidden: ErrorResponse,
    payload_too_large: ErrorResponse,
};

/// Runtime makes this request in order to submit a response.
pub fn sendInvocationSuccess(
    arena: Allocator,
    fetcher: *Fetcher,
    url: []const u8,
    payload: []const u8,
) SendFetchError!InvocationSuccessResult {
    const fetch = try fetcher.send(RuntimeStatus, .POST, url, .{
        .payload = payload,
    });
    return switch (fetch.status) {
        .accepted => .{ .accepted = StatusResponse{ .status = fetch.body } },
        .bad_request => .{ .bad_request = try ErrorResponse.parse(arena, fetch.body) },
        .forbidden => .{ .forbidden = try ErrorResponse.parse(arena, fetch.body) },
        .payload_too_large => .{ .payload_too_large = try ErrorResponse.parse(arena, fetch.body) },
        .container_error => error.ContainerError,
        else => error.UnknownStatus,
    };
}

pub const InvocationFailResult = union(enum) {
    accepted: StatusResponse,
    bad_request: ErrorResponse,
    forbidden: ErrorResponse,
};

/// Runtime makes this request in order to submit an error response. It can be
/// either a function error, or a runtime error. Error will be served in
/// response to the invoke.
///
/// `error_type` expects format _"category.reason"_ (example: _"Runtime.ConfigInvalid"_).
pub fn sendInvocationFail(
    arena: Allocator,
    fetcher: *Fetcher,
    url: []const u8,
    error_type: ?[]const u8,
    error_body: ?ErrorRequest,
) SendFetchError!InvocationFailResult {
    const fetch = try fetchError(arena, fetcher, url, error_type, error_body);
    return switch (fetch.status) {
        .accepted => .{ .accepted = StatusResponse{ .status = fetch.body } },
        .bad_request => .{ .bad_request = try ErrorResponse.parse(arena, fetch.body) },
        .forbidden => .{ .forbidden = try ErrorResponse.parse(arena, fetch.body) },
        .container_error => error.ContainerError,
        else => error.UnknownStatus,
    };
}

const RuntimeStatus = enum(u9) {
    success = 200,
    accepted = 202,

    bad_request = 400,
    forbidden = 403,
    payload_too_large = 413,

    /// Non-recoverable state. **runtime should exit promptly.**
    container_error = 500,

    _,
};

pub const StatusResponse = struct {
    /// Status information.
    status: []const u8,
};

pub const ErrorRequest = struct {
    /// The textual description.
    message: []const u8,

    /// The semantic type.
    error_type: []const u8,

    /// The stack trace.
    stack_trace: []const []const u8 = &[_][]const u8{},
};

const ERROR_HEAD_TYPE = "Lambda-Runtime-Function-Error-Type";
const ERROR_CONTENT_TYPE = "application/vnd.aws.lambda.error+json";

pub const ErrorResponse = struct {
    /// The error message.
    message: []const u8,

    /// The error type.
    error_type: []const u8,

    pub fn parse(allocator: Allocator, json: []const u8) !ErrorResponse {
        const E = struct { errorMessage: []const u8, errorType: []const u8 };
        const parsed = std.json.parseFromSliceLeaky(E, allocator, json, .{
            .allocate = .alloc_if_needed,
        }) catch return error.ParseError;

        return ErrorResponse{
            .message = parsed.errorMessage,
            .error_type = parsed.errorType,
        };
    }
};

fn fetchError(
    arena: Allocator,
    fetcher: *Fetcher,
    url: []const u8,
    error_type: ?[]const u8,
    error_request: ?ErrorRequest,
) Fetcher.Error!Fetcher.Result(RuntimeStatus) {
    const headers: ?[]const Fetcher.Header = if (error_type) |val| &[_]Fetcher.Header{
        .{ .name = ERROR_HEAD_TYPE, .value = val },
    } else null;

    const payload: ?[]const u8 = if (error_request) |val|
        try std.json.stringifyAlloc(arena, val, .{})
    else
        null;

    return fetcher.send(RuntimeStatus, .POST, url, .{
        .request = .{
            .content_type = .{ .override = ERROR_CONTENT_TYPE },
        },
        .headers = headers,
        .payload = payload,
    });
}
