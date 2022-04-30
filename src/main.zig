const std = @import("std");
const os = std.os;
const builtin = @import("builtin");

pub const HTTPDate = struct {
    /// 1970...9999
    year: u16,
    /// 0...59
    sec: u8,
    /// 0...59
    min: u8,
    /// 0...23
    hour: u8,
    /// 1...12
    mon: u8,
    /// 1...31
    day: u8,
    /// 1...7
    wday: u8,

    fn is_valid(self: *HTTPDate) bool {
        return self.sec < 60 and
            self.min < 60 and
            self.hour < 24 and
            self.day > 0 and
            self.day < 32 and
            self.mon > 0 and
            self.mon <= 12 and
            self.year >= 1970 and
            self.year <= 9999;
    }

    pub fn from(system: SystemTime) HTTPDate {
        const secs_since_epoch = system.seconds();
        // 2000-03-01 (mod 400 year, immediately after feb29
        const LEAPOCH: i64 = 11017;
        const DAYS_PER_400Y: i64 = 365 * 400 + 97;
        const DAYS_PER_100Y: i64 = 365 * 100 + 24;
        const DAYS_PER_4Y: i64 = 365 * 4 + 1;

        const days = @intCast(i64, (secs_since_epoch / 86400)) - LEAPOCH;
        const secs_of_day = secs_since_epoch % 86400;

        var qc_cycles = @divTrunc(days, DAYS_PER_400Y);
        var remdays = @rem(days, DAYS_PER_400Y);
        if (remdays < 0) {
            remdays += DAYS_PER_400Y;
            qc_cycles -= 1;
        }
        var c_cycles = @divTrunc(remdays, DAYS_PER_100Y);
        if (c_cycles == 4) {
            c_cycles -= 1;
        }
        remdays -= c_cycles * DAYS_PER_100Y;

        var q_cycles = @divTrunc(remdays, DAYS_PER_4Y);
        if (q_cycles == 25) {
            q_cycles -= 1;
        }
        remdays -= q_cycles * DAYS_PER_4Y;

        var remyears = @divTrunc(remdays, 365);
        if (remyears == 4) {
            remyears -= 1;
        }
        remdays -= remyears * 365;
        var year = 2000 + remyears + 4 * q_cycles + 100 * c_cycles + 400 * qc_cycles;
        const months = [_]i64{ 31, 30, 31, 30, 31, 31, 30, 31, 30, 31, 31, 29 };
        var mon: i64 = 0;
        for (months) |mon_len| {
            mon += 1;
            if (remdays < mon_len) {
                break;
            }
            remdays -= mon_len;
        }
        const mday = remdays + 1;
        if (mon + 2 > 12) {
            year += 1;
            mon = mon - 10;
        } else {
            mon = mon + 2;
        }
        var wday = @rem((3 + days), 7);
        if (wday <= 0) {
            wday += 7;
        }
        return HTTPDate{
            .sec = @truncate(u8, (secs_of_day % 60)),
            .min = @truncate(u8, ((secs_of_day % 3600) / 60)),
            .hour = @truncate(u8, (secs_of_day / 3600)),
            .day = @truncate(u8, @bitCast(u64, mday)),
            .mon = @truncate(u8, @bitCast(u64, mon)),
            .year = @truncate(u16, @bitCast(u64, year)),
            .wday = @truncate(u8, @bitCast(u64, wday)),
        };
    }

    pub fn parse(s: []const u8) !HTTPDate {
        var h: ?HTTPDate = null;
        h = parse_imf_fixdate(s) catch null;
        if (h == null) {
            h = parse_rfc850_date(s) catch null;
        }
        if (h == null) {
            h = try parse_asctime(s);
        }
        if (!h.?.is_valid()) {
            return error.InvailidDate;
        }
        return h.?;
    }

    pub fn format(
        self: HTTPDate,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        const wday = switch (self.wday) {
            1 => "Mon",
            2 => "Tue",
            3 => "Wed",
            4 => "Thu",
            5 => "Fri",
            6 => "Sat",
            7 => "Sun",
            else => unreachable,
        };
        const mon = switch (self.mon) {
            1 => "Jan",
            2 => "Feb",
            3 => "Mar",
            4 => "Apr",
            5 => "May",
            6 => "Jun",
            7 => "Jul",
            8 => "Aug",
            9 => "Sep",
            10 => "Oct",
            11 => "Nov",
            12 => "Dec",
            else => unreachable,
        };
        var buf: [29]u8 = undefined;
        std.mem.copy(u8, &buf, "   , 00     0000 00:00:00 GMT");
        buf[0] = wday[0];
        buf[1] = wday[1];
        buf[2] = wday[2];
        buf[5] = @as(u8, '0') + (self.day / 10);
        buf[6] = @as(u8, '0') + (self.day % 10);
        buf[8] = mon[0];
        buf[9] = mon[1];
        buf[10] = mon[2];
        buf[12] = @as(u8, '0') + @truncate(u8, (self.year / 1000));
        buf[13] = @as(u8, '0') + @truncate(u8, (self.year / 100 % 10));
        buf[14] = @as(u8, '0') + @truncate(u8, (self.year / 10 % 10));
        buf[15] = @as(u8, '0') + @truncate(u8, (self.year % 10));
        buf[17] = @as(u8, '0') + (self.hour / 10);
        buf[18] = @as(u8, '0') + (self.hour % 10);
        buf[20] = @as(u8, '0') + (self.min / 10);
        buf[21] = @as(u8, '0') + (self.min % 10);
        buf[23] = @as(u8, '0') + (self.sec / 10);
        buf[24] = @as(u8, '0') + (self.sec % 10);
        _ = try writer.write(&buf);
    }
};

pub const SystemTime = struct {
    timestamp: if (is_posix) os.timespec else u64,

    // true if we should use clock_gettime()
    const is_posix = switch (builtin.os.tag) {
        .wasi => builtin.link_libc,
        .windows => false,
        .macos, .ios, .tvos, .watchos => false,
        else => builtin.os.tag != .darwin,
    };

    pub fn now() error{Unsupported}!SystemTime {
        switch (builtin.os.tag) {
            .macos, .ios, .tvos, .watchos => {
                var v: os.timeval = undefined;
                os.gettimeofday(&v, null);
                return SystemTime{
                    .timestamp = @intCast(u64, v.tv_sec),
                };
            },
            .linux => {
                var ts: os.timespec = undefined;
                os.clock_gettime(os.CLOCK.CLOCK_REALTIME, &ts) catch return error.Unsupported;
            },
            else => return error.Unsupported,
        }
    }

    fn seconds(self: SystemTime) u64 {
        switch (builtin.os.tag) {
            .macos, .ios, .tvos, .watchos => {
                return self.timestamp;
            },
            .linux => {
                return @intCast(u64, self.timestamp.tv_sec);
            },
            else => unreachable,
        }
    }

    pub fn from(v: HTTPDate) SystemTime {
        const leap_years =
            ((v.year - 1) - 1968) / 4 - ((v.year - 1) - 1900) / 100 + ((v.year - 1) - 1600) / 400;
        var ydays: u64 = @as(u64, switch (v.mon) {
            1 => 0,
            2 => 31,
            3 => 59,
            4 => 90,
            5 => 120,
            6 => 151,
            7 => 181,
            8 => 212,
            9 => 243,
            10 => 273,
            11 => 304,
            12 => 334,
            else => unreachable,
        }) + v.day - 1;
        if (is_leap_year(v.year) and v.mon > 2) {
            ydays += 1;
        }
        const days = (@intCast(u64, v.year) - 1970) * 365 + @intCast(u64, leap_years) + ydays;
        const ts = @intCast(u64, v.sec) + @intCast(u64, v.min) * 60 +
            @intCast(u64, v.hour) * 3600 + @intCast(u64, days) * 86400;
        return from_seconds(ts);
    }

    pub fn from_seconds(ts: u64) SystemTime {
        return switch (builtin.os.tag) {
            .macos, .ios, .tvos, .watchos => {
                return SystemTime{ .timestamp = ts };
            },
            .linux => {
                return SystemTime{ .timestamp = .{ .tv_sec = @intCast(os.time_t, ts) } };
            },
            else => unreachable,
        };
    }
};

pub fn parse_http_date(s: []const u8) !SystemTime {
    const h = try HTTPDate.parse(s);
    return SystemTime.from(h);
}

fn is_leap_year(y: u16) bool {
    return y % 4 == 0 and (y % 100 != 0 or y % 400 == 0);
}

fn toint_1(x: u8) !u8 {
    const v = x - '0';
    if (v < 10) return v;
    return error.InvaildInt;
}

fn toint_2(s: []const u8) !u8 {
    const high = s[0] - '0';
    const low = s[1] - '0';
    if (high < 10 and low < 10) return high * 10 + low;
    return error.InvaildInt;
}

fn toint_4(s: []const u8) !u16 {
    const a = @intCast(u16, s[0] - '0');
    const b = @intCast(u16, s[1] - '0');
    const c = @intCast(u16, s[2] - '0');
    const d = @intCast(u16, s[3] - '0');
    if (a < 10 and b < 10 and c < 10 and d < 10) return (a * 1000 + b * 100 + c * 10 + d);
    return error.InvaildInt;
}

fn parse_imf_fixdate(s: []const u8) !HTTPDate {
    // Example: `Sun, 06 Nov 1994 08:49:37 GMT`
    if (s.len != 29 or !std.mem.eql(u8, s[25..], " GMT") or
        s[16] != ' ' or s[19] != ':' or s[22] != ':')
    {
        return error.InvailidDate;
    }
    const sec = toint_2(s[23..25]) catch return error.InvailidDate;
    const min = toint_2(s[20..22]) catch return error.InvailidDate;
    const hour = toint_2(s[17..19]) catch return error.InvailidDate;
    const day = toint_2(s[5..7]) catch return error.InvailidDate;
    const mon_slice = s[7..12];
    var mon: u8 = 0;
    const months = &[_][]const u8{
        " Jan ", " Feb ",
        " Mar ", " Apr ",
        " May ", " Jun ",
        " Jul ", " Aug ",
        " Sep ", " Oct ",
        " Nov ", " Dec ",
    };
    for (months) |m, i| {
        if (std.mem.eql(u8, mon_slice, m)) {
            mon = @truncate(u8, i) + 1;
            break;
        }
    }
    if (mon == 0) {
        return error.InvailidDate;
    }
    const year = toint_4(s[12..16]) catch return error.InvailidDate;
    var wday: u8 = 0;
    const wday_slice = s[0..5];
    const wdays = [_][]const u8{
        "Mon, ", "Tue, ", "Wed, ",
        "Thu, ", "Fri, ", "Sat, ",
        "Sun, ",
    };
    for (wdays) |w, i| {
        if (std.mem.eql(u8, wday_slice, w)) {
            wday = @truncate(u8, i) + 1;
            break;
        }
    }
    if (wday == 0) {
        return error.InvailidDate;
    }
    return HTTPDate{
        .year = year,
        .sec = sec,
        .min = min,
        .hour = hour,
        .mon = mon,
        .day = day,
        .wday = wday,
    };
}

fn parse_rfc850_date(x: []const u8) !HTTPDate {
    // Example: `Sunday, 06-Nov-94 08:49:37 GMT`
    var s = x;
    if (s.len < 23) return error.InvailidDate;
    const wdays = &[_][]const u8{
        "Monday, ",   "Tuesday, ", "Wednesday, ",
        "Thursday, ", "Friday",    "Saturday, ",
        "Sunday, ",
    };
    var wday: u8 = undefined;
    for (wdays) |w, i| {
        if (std.mem.startsWith(u8, s, w)) {
            wday = @truncate(u8, i) + 1;
            s = s[w.len..];
        }
    }
    if (s.len != 22 or s[12] != ':' or
        s[15] != ':' or std.mem.eql(u8, s[18..22], " GMT"))
    {
        return error.InvailidDate;
    }
    var year = toint_4(s[7..9]) catch return error.InvailidDate;
    if (year < 70) {
        year += 2000;
    } else {
        year += 1900;
    }
    var mon: u8 = 0;
    const mon_slice = s[2..7];
    const months = [_][]const u8{
        "-Jan-", "-Feb-", "-Mar-",
        "-Apr-", "-May-", "-Jun-",
        "-Jul-", "-Aug-", "-Sep-",
        "-Oct-", "-Nov-", "-Dec-",
    };
    for (months) |m, i| {
        if (std.mem.eql(u8, mon_slice, m)) {
            mon = @truncate(u8, i) + 1;
            break;
        }
    }
    const sec = toint_2(s[16..18]) catch return error.InvailidDate;
    const min = toint_2(s[13..15]) catch return error.InvailidDate;
    const hour = toint_2(s[10..12]) catch return error.InvailidDate;
    const day = toint_2(s[0..2]) catch return error.InvailidDate;
    return HTTPDate{
        .year = year,
        .sec = sec,
        .min = min,
        .hour = hour,
        .mon = mon,
        .day = day,
        .wday = wday,
    };
}

fn parse_asctime(s: []const u8) !HTTPDate {
    // Example: `Sun Nov  6 08:49:37 1994`
    if (s.len != 24 or
        s[10] != ' ' or s[13] != ':' or s[16] != ':' or s[19] != ' ')
    {
        return error.InvailidDate;
    }
    const sec = toint_2(s[17..19]) catch return error.InvailidDate;
    const min = toint_2(s[14..16]) catch return error.InvailidDate;
    const hour = toint_2(s[11..13]) catch return error.InvailidDate;
    var day: u8 = 0;
    {
        const x = s[8..10];
        if (x[0] == ' ') {
            day = toint_1(x[1]) catch return error.InvailidDate;
        } else {
            day = toint_2(x) catch return error.InvailidDate;
        }
    }
    var mon: u8 = 0;
    const mon_slice = s[4..8];
    const months = &[_][]const u8{
        " Jan ", " Feb ",
        " Mar ", " Apr ",
        " May ", " Jun ",
        " Jul ", " Aug ",
        " Sep ", " Oct ",
        " Nov ", " Dec ",
    };
    for (months) |m, i| {
        if (std.mem.eql(u8, mon_slice, m)) {
            mon = @truncate(u8, i) + 1;
            break;
        }
    }
    if (mon == 0) {
        return error.InvailidDate;
    }
    var wday: u8 = 0;
    const wday_slice = s[0..4];
    const wdays = [_][]const u8{
        "Mon ", "Tue ", "Wed ",
        "Thu ", "Fri ", "Sat ",
        "Sun ",
    };
    for (wdays) |w, i| {
        if (std.mem.eql(u8, wday_slice, w)) {
            wday = @truncate(u8, i) + 1;
            break;
        }
    }
    if (wday == 0) {
        return error.InvailidDate;
    }
    var year = toint_4(s[20..24]) catch return error.InvailidDate;
    return HTTPDate{
        .year = year,
        .sec = sec,
        .min = min,
        .hour = hour,
        .mon = mon,
        .day = day,
        .wday = wday,
    };
}

test "test_rfc_example" {
    try std.testing.expectEqual(
        SystemTime.from_seconds(784111777),
        try parse_http_date("Sun, 06 Nov 1994 08:49:37 GMT"),
    );
}

test "test2" {
    try std.testing.expectEqual(
        SystemTime.from_seconds(1475419451),
        try parse_http_date("Sun, 02 Oct 2016 14:44:11 GMT"),
    );

    try std.testing.expectError(
        error.InvailidDate,
        parse_http_date("Sun Nov 10 08:00:00 1000"),
    );
    try std.testing.expectError(
        error.InvailidDate,
        parse_http_date("Sun Nov 10 08*00:00 2000"),
    );
    try std.testing.expectError(
        error.InvailidDate,
        parse_http_date("Sunday, 06-Nov-94 08+49:37 GMT"),
    );
}
