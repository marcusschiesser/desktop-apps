const std = @import("std");

pub const sample_rate_hz: u32 = 48_000;
pub const whisper_sample_rate_hz: u32 = 16_000;
pub const channel_count: u8 = 2;
const bytes_per_sample: usize = 2;
const max_read_frames: usize = 4_800;
const max_path = 2048;
const max_wav_data_bytes: u64 = std.math.maxInt(u32) - 36;

const CTime = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};

const CalendarTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
};

extern fn localtime_r(timestamp: *const c_long, result: *CTime) ?*CTime;

pub const Writer = struct {
    io: std.Io,
    write_enabled: bool,
    retained: ?std.Io.File.Atomic = null,
    whisper: ?std.Io.File.Atomic = null,
    active: bool = false,
    retained_bytes: u64 = 0,
    whisper_bytes: u64 = 0,
    resample_sum: i64 = 0,
    resample_count: u8 = 0,
    base_buffer: [max_path]u8 = undefined,
    base_len: usize = 0,
    retained_path_buffer: [max_path]u8 = undefined,
    retained_path_len: usize = 0,
    whisper_path_buffer: [max_path]u8 = undefined,
    whisper_path_len: usize = 0,
    mix_buffer: [max_read_frames * channel_count * bytes_per_sample]u8 = undefined,
    whisper_buffer: [max_read_frames / 3 * bytes_per_sample + bytes_per_sample]u8 = undefined,

    pub fn init(io: std.Io, write_enabled: bool) Writer {
        return .{ .io = io, .write_enabled = write_enabled };
    }

    pub fn basePath(self: *const Writer) []const u8 {
        return self.base_buffer[0..self.base_len];
    }

    pub fn retainedPath(self: *const Writer) []const u8 {
        return self.retained_path_buffer[0..self.retained_path_len];
    }

    pub fn whisperPath(self: *const Writer) []const u8 {
        return self.whisper_path_buffer[0..self.whisper_path_len];
    }

    pub fn start(self: *Writer, notes_dir: []const u8, wall_ms: i64) ![]const u8 {
        self.discard();
        var cwd = std.Io.Dir.cwd();
        if (self.write_enabled) try cwd.createDirPath(self.io, notes_dir);
        const local = try localCalendarTime(wall_ms);

        var suffix: u16 = 1;
        while (suffix < 10_000) : (suffix += 1) {
            const candidate = try formatBasePath(&self.base_buffer, notes_dir, local, suffix);
            self.base_len = candidate.len;
            if (!self.write_enabled) break;

            var collision_buffer: [max_path]u8 = undefined;
            const note_path = try std.fmt.bufPrint(&collision_buffer, "{s}.md", .{candidate});
            if (try fileExists(self.io, note_path)) continue;
            const audio_path = try std.fmt.bufPrint(&collision_buffer, "{s}.wav", .{candidate});
            if (try fileExists(self.io, audio_path)) continue;
            break;
        } else return error.TooManyRecordings;

        const retained_path = try std.fmt.bufPrint(&self.retained_path_buffer, "{s}.wav", .{self.basePath()});
        self.retained_path_len = retained_path.len;
        const whisper_path = try std.fmt.bufPrint(&self.whisper_path_buffer, "{s}.whisper.wav", .{self.basePath()});
        self.whisper_path_len = whisper_path.len;

        if (self.write_enabled) {
            self.retained = try cwd.createFileAtomic(self.io, self.retainedPath(), .{
                .make_path = true,
                .replace = false,
            });
            errdefer self.discard();
            self.whisper = try cwd.createFileAtomic(self.io, self.whisperPath(), .{
                .make_path = true,
                .replace = false,
            });

            var retained_header = wavHeader(sample_rate_hz, channel_count, 0);
            try self.retained.?.file.writeStreamingAll(self.io, &retained_header);
            var whisper_header = wavHeader(whisper_sample_rate_hz, 1, 0);
            try self.whisper.?.file.writeStreamingAll(self.io, &whisper_header);
        }
        self.active = true;
        return self.basePath();
    }

    pub fn append(self: *Writer, system_pcm: []const u8, microphone_pcm: []const u8, frames: u32, channels: u8) !void {
        if (!self.active) return error.NotStarted;
        if (channels != channel_count or frames == 0 or frames > max_read_frames) return error.InvalidFormat;
        const expected = @as(usize, frames) * channels * bytes_per_sample;
        const has_system = system_pcm.len == expected;
        const has_microphone = microphone_pcm.len == expected;
        if ((!has_system and system_pcm.len != 0) or
            (!has_microphone and microphone_pcm.len != 0) or
            (!has_system and !has_microphone)) return error.InvalidBuffers;
        if (self.retained_bytes + expected > max_wav_data_bytes) return error.FileTooLarge;

        var whisper_len: usize = 0;
        for (0..frames) |frame| {
            var mixed_samples: [channel_count]i16 = undefined;
            for (0..channel_count) |channel| {
                const offset = (frame * channel_count + channel) * bytes_per_sample;
                const system_sample = if (has_system) readSample(system_pcm, offset) else 0;
                const microphone_sample = if (has_microphone) readSample(microphone_pcm, offset) else 0;
                const mixed: i16 = if (has_system and has_microphone)
                    @intCast(@divTrunc(@as(i32, system_sample) + @as(i32, microphone_sample), 2))
                else if (has_system)
                    system_sample
                else
                    microphone_sample;
                mixed_samples[channel] = mixed;
                writeSample(&self.mix_buffer, offset, mixed);
            }

            const mono: i16 = @intCast(@divTrunc(@as(i32, mixed_samples[0]) + @as(i32, mixed_samples[1]), 2));
            self.resample_sum += mono;
            self.resample_count += 1;
            if (self.resample_count == 3) {
                const downsampled: i16 = @intCast(@divTrunc(self.resample_sum, 3));
                writeSample(&self.whisper_buffer, whisper_len, downsampled);
                whisper_len += bytes_per_sample;
                self.resample_sum = 0;
                self.resample_count = 0;
            }
        }

        if (self.write_enabled) try self.retained.?.file.writeStreamingAll(self.io, self.mix_buffer[0..expected]);
        if (self.write_enabled and whisper_len > 0) {
            try self.whisper.?.file.writeStreamingAll(self.io, self.whisper_buffer[0..whisper_len]);
        }
        self.retained_bytes += expected;
        self.whisper_bytes += whisper_len;
    }

    pub fn finish(self: *Writer) !void {
        if (!self.active) return error.NotStarted;
        if (self.retained_bytes == 0) return error.NoAudio;
        if (self.resample_count > 0) {
            const sample: i16 = @intCast(@divTrunc(self.resample_sum, self.resample_count));
            writeSample(&self.whisper_buffer, 0, sample);
            if (self.write_enabled) try self.whisper.?.file.writeStreamingAll(self.io, self.whisper_buffer[0..bytes_per_sample]);
            self.whisper_bytes += bytes_per_sample;
            self.resample_sum = 0;
            self.resample_count = 0;
        }
        if (self.whisper_bytes == 0) return error.NoAudio;
        if (self.whisper_bytes > max_wav_data_bytes) return error.FileTooLarge;

        if (self.write_enabled) {
            var retained_header = wavHeader(sample_rate_hz, channel_count, @intCast(self.retained_bytes));
            try self.retained.?.file.writePositionalAll(self.io, &retained_header, 0);
            try self.retained.?.file.sync(self.io);
            var whisper_header = wavHeader(whisper_sample_rate_hz, 1, @intCast(self.whisper_bytes));
            try self.whisper.?.file.writePositionalAll(self.io, &whisper_header, 0);
            try self.whisper.?.file.sync(self.io);

            if (self.whisper) |*atomic| try atomic.link(self.io);
            errdefer std.Io.Dir.cwd().deleteFile(self.io, self.whisperPath()) catch {};
            if (self.retained) |*atomic| try atomic.link(self.io);
        }
        self.releaseAtomics();
        self.active = false;
    }

    pub fn discard(self: *Writer) void {
        self.releaseAtomics();
        self.active = false;
        self.retained_bytes = 0;
        self.whisper_bytes = 0;
        self.resample_sum = 0;
        self.resample_count = 0;
    }

    fn releaseAtomics(self: *Writer) void {
        if (self.retained) |*atomic| atomic.deinit(self.io);
        if (self.whisper) |*atomic| atomic.deinit(self.io);
        self.retained = null;
        self.whisper = null;
    }
};

fn localCalendarTime(wall_ms: i64) !CalendarTime {
    const seconds = @divTrunc(wall_ms, 1_000);
    var timestamp = std.math.cast(c_long, seconds) orelse return error.InvalidTimestamp;
    var result: CTime = undefined;
    if (localtime_r(&timestamp, &result) == null) return error.InvalidTimestamp;
    return .{
        .year = std.math.cast(u16, result.tm_year + 1900) orelse return error.InvalidTimestamp,
        .month = std.math.cast(u8, result.tm_mon + 1) orelse return error.InvalidTimestamp,
        .day = std.math.cast(u8, result.tm_mday) orelse return error.InvalidTimestamp,
        .hour = std.math.cast(u8, result.tm_hour) orelse return error.InvalidTimestamp,
        .minute = std.math.cast(u8, result.tm_min) orelse return error.InvalidTimestamp,
    };
}

fn formatBasePath(buffer: []u8, notes_dir: []const u8, local: CalendarTime, suffix: u16) ![]const u8 {
    if (suffix == 1) {
        return std.fmt.bufPrint(buffer, "{s}/{d:0>4}-{d:0>2}-{d:0>2}-{d:0>2}{d:0>2}", .{
            notes_dir, local.year, local.month, local.day, local.hour, local.minute,
        });
    }
    return std.fmt.bufPrint(buffer, "{s}/{d:0>4}-{d:0>2}-{d:0>2}-{d:0>2}{d:0>2}-{d}", .{
        notes_dir, local.year, local.month, local.day, local.hour, local.minute, suffix,
    });
}

fn fileExists(io: std.Io, path: []const u8) !bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn readSample(bytes: []const u8, offset: usize) i16 {
    return std.mem.readInt(i16, bytes[offset..][0..2], .little);
}

fn writeSample(bytes: []u8, offset: usize, sample: i16) void {
    std.mem.writeInt(i16, bytes[offset..][0..2], sample, .little);
}

fn wavHeader(rate: u32, channels: u16, data_bytes: u32) [44]u8 {
    var header: [44]u8 = @splat(0);
    @memcpy(header[0..4], "RIFF");
    std.mem.writeInt(u32, header[4..8], 36 + data_bytes, .little);
    @memcpy(header[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, header[16..20], 16, .little);
    std.mem.writeInt(u16, header[20..22], 1, .little);
    std.mem.writeInt(u16, header[22..24], channels, .little);
    std.mem.writeInt(u32, header[24..28], rate, .little);
    std.mem.writeInt(u32, header[28..32], rate * channels * @as(u32, bytes_per_sample), .little);
    std.mem.writeInt(u16, header[32..34], channels * @as(u16, bytes_per_sample), .little);
    std.mem.writeInt(u16, header[34..36], 16, .little);
    @memcpy(header[36..40], "data");
    std.mem.writeInt(u32, header[40..44], data_bytes, .little);
    return header;
}

test "paired PCM is mixed and downsampled into two atomic WAV files" {
    const testing = std.testing;
    const directory = ".zig-cache/meeting-notes-audio-writer-test";
    std.Io.Dir.cwd().deleteTree(testing.io, directory) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, directory) catch {};

    var writer = Writer.init(testing.io, true);
    _ = try writer.start(directory, 1_767_333_840_000);
    const system_samples = [_]i16{ 1000, -1000, 32767, -32768, 3000, 3000 };
    const microphone_samples = [_]i16{ 1000, 1000, -32767, 32766, -1000, -1000 };
    var system_bytes: [system_samples.len * 2]u8 = undefined;
    var microphone_bytes: [microphone_samples.len * 2]u8 = undefined;
    for (system_samples, 0..) |sample, index| writeSample(&system_bytes, index * 2, sample);
    for (microphone_samples, 0..) |sample, index| writeSample(&microphone_bytes, index * 2, sample);
    try writer.append(&system_bytes, &microphone_bytes, 3, 2);
    const retained_path = try testing.allocator.dupe(u8, writer.retainedPath());
    defer testing.allocator.free(retained_path);
    const whisper_path = try testing.allocator.dupe(u8, writer.whisperPath());
    defer testing.allocator.free(whisper_path);
    try writer.finish();

    const retained = try std.Io.Dir.cwd().readFileAlloc(testing.io, retained_path, testing.allocator, .limited(1024));
    defer testing.allocator.free(retained);
    try testing.expectEqual(@as(usize, 56), retained.len);
    try testing.expectEqualStrings("RIFF", retained[0..4]);
    try testing.expectEqual(@as(u32, 12), std.mem.readInt(u32, retained[40..44], .little));
    const expected = [_]i16{ 1000, 0, 0, -1, 1000, 1000 };
    for (expected, 0..) |sample, index| {
        try testing.expectEqual(sample, readSample(retained, 44 + index * 2));
    }

    const whisper = try std.Io.Dir.cwd().readFileAlloc(testing.io, whisper_path, testing.allocator, .limited(1024));
    defer testing.allocator.free(whisper);
    try testing.expectEqual(@as(usize, 46), whisper.len);
    try testing.expectEqual(@as(u32, whisper_sample_rate_hz), std.mem.readInt(u32, whisper[24..28], .little));
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, whisper[22..24], .little));
    try testing.expectEqual(@as(i16, 500), readSample(whisper, 44));
}

test "recording stems use supplied local calendar fields" {
    var buffer: [128]u8 = undefined;
    const path = try formatBasePath(&buffer, "/notes", .{
        .year = 2026,
        .month = 1,
        .day = 2,
        .hour = 7,
        .minute = 4,
    }, 2);
    try std.testing.expectEqualStrings("/notes/2026-01-02-0704-2", path);
}

test "replay writer consumes PCM without touching the filesystem" {
    const testing = std.testing;
    const directory = ".zig-cache/meeting-notes-audio-replay-test";
    std.Io.Dir.cwd().deleteTree(testing.io, directory) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, directory) catch {};

    var writer = Writer.init(testing.io, false);
    _ = try writer.start(directory, 1_767_333_840_000);
    const samples = [_]u8{0} ** 12;
    try writer.append(&samples, &samples, 3, 2);
    try writer.finish();
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(testing.io, directory, .{}));
}
