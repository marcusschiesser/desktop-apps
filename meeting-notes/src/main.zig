const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");
const audio = @import("audio_writer.zig");
const notes = @import("notes.zig");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

pub const canvas_label = "meeting-notes-canvas";
pub const window_label = "main";
pub const settings_window_label = "settings";
pub const settings_canvas_label = "meeting-notes-settings-canvas";
const window_width: f32 = 640;
const window_height: f32 = 500;

const command_open = "app.open";
const command_settings = "app.settings";
const command_toggle_recording = "record.toggle";
const command_open_notes = "notes.open-folder";
const command_open_latest = "notes.open-latest";
const command_quit = "app.quit";

const key_capture: u64 = 10;
const key_whisper: u64 = 12;
const key_summarize: u64 = 14;
const key_open: u64 = 16;
const key_open_api_keys: u64 = 17;
const key_recording_timer: u64 = 100;
const key_microphone_access: u64 = 101;
const key_system_audio_access: u64 = 102;

const max_path = 2048;
const max_status = 768;
const max_api_key = 512;

extern fn meeting_notes_keychain_get(buffer: [*]u8, capacity: usize, length: *usize) c_int;
extern fn meeting_notes_keychain_set(secret: [*]const u8, length: usize) c_int;
extern fn meeting_notes_keychain_delete() c_int;
extern fn meeting_notes_keychain_last_status() c_int;

const app_permissions = [_][]const u8{
    native_sdk.security.permission_command,
    native_sdk.security.permission_view,
    native_sdk.security.permission_filesystem,
    native_sdk.security.permission_network,
    native_sdk.security.permission_credentials,
    native_sdk.security.permission_microphone,
    native_sdk.security.permission_system_audio,
};

const shell_views = [_]native_sdk.ShellView{
    .{
        .label = canvas_label,
        .kind = .gpu_surface,
        .fill = true,
        .role = "Meeting notes app",
        .accessibility_label = "Local Meeting Notes",
        .gpu_backend = .metal,
        .gpu_pixel_format = .bgra8_unorm,
        .gpu_present_mode = .timer,
        .gpu_alpha_mode = .@"opaque",
        .gpu_color_space = .srgb,
        .gpu_vsync = true,
    },
};

const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = window_label,
    .title = "Local Meeting Notes",
    .width = window_width,
    .height = window_height,
    .min_width = 580,
    .min_height = 460,
    .restore_state = false,
    .close_policy = .hide,
    .views = &shell_views,
}};

pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

pub fn FixedText(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        storage: [capacity]u8 = undefined,
        len: usize = 0,

        pub fn text(self: *const Self) []const u8 {
            return self.storage[0..self.len];
        }

        pub fn set(self: *Self, value: []const u8) void {
            var len = @min(value.len, capacity);
            if (len < value.len) {
                while (len > 0 and value[len] & 0xc0 == 0x80) {
                    len -= 1;
                }
            }
            @memcpy(self.storage[0..len], value[0..len]);
            self.len = len;
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        pub fn empty(self: *const Self) bool {
            return self.len == 0;
        }
    };
}

pub const Phase = enum {
    idle,
    starting,
    recording,
    stopping,
    transcribing,
    summarizing,
    saving,
    saved,
    failed,
};

pub const Msg = union(enum) {
    toggle_recording,
    retry_processing,
    open_window,
    open_settings,
    close_settings,
    settings_closed,
    open_notes_folder,
    open_latest_note,
    open_api_keys,
    quit,
    save_api_key,
    delete_api_key,
    api_key_changed: canvas.TextInputEvent,
    capture: native_sdk.EffectAudioCapture,
    capture_read: native_sdk.EffectAudioCaptureRead,
    capture_access: native_sdk.EffectAudioCaptureAccess,
    whisper_exited: native_sdk.EffectExit,
    summary_response: native_sdk.EffectResponse,
    recording_tick: native_sdk.EffectTimer,

    pub const view_unbound = .{
        "open_window",
        "open_settings",
        "close_settings",
        "settings_closed",
        "quit",
        "capture",
        "capture_read",
        "capture_access",
        "whisper_exited",
        "summary_response",
        "recording_tick",
    };
};

pub const Model = struct {
    io: std.Io = undefined,
    audio_writer: audio.Writer = undefined,
    replaying: bool = false,
    phase: Phase = .idle,
    api_key_present: bool = false,
    keychain_checked: bool = false,
    settings_open: bool = false,
    quit_after_save: bool = false,
    summary_failed: bool = false,
    capture_completed: bool = false,
    capture_requested: bool = false,
    capture_read_pending: bool = false,
    capture_terminal_seen: bool = false,
    capture_terminal_failed: bool = false,
    cancel_start: bool = false,
    elapsed_seconds: u64 = 0,
    system_gap_frames: u64 = 0,
    microphone_gap_frames: u64 = 0,
    summary_offset: usize = 0,
    summary_transcript_len: usize = 0,
    summary_chunks: u32 = 0,

    status_detail: FixedText(max_status) = .{},
    capture_error: FixedText(max_status) = .{},
    summary_error: FixedText(320) = .{},
    notes_dir: FixedText(max_path) = .{},
    whisper_cli_path: FixedText(max_path) = .{},
    whisper_model_path: FixedText(max_path) = .{},
    note_path: FixedText(max_path) = .{},
    audio_path: FixedText(max_path) = .{},
    whisper_audio_path: FixedText(max_path) = .{},
    transcript_root: FixedText(max_path) = .{},
    transcript_path: FixedText(max_path) = .{},
    summary_draft: FixedText(notes.max_draft_bytes) = .{},
    latest_note_path: FixedText(max_path) = .{},
    latest_audio_path: FixedText(max_path) = .{},

    api_key: FixedText(max_api_key) = .{},
    api_key_buffer: canvas.TextBuffer(max_api_key) = .{},

    // These fields back derived view methods or belong exclusively to
    // the recording/effect state machine.
    pub const view_unbound = .{
        "phase",
        "io",
        "audio_writer",
        "replaying",
        "api_key_present",
        "keychain_checked",
        "settings_open",
        "quit_after_save",
        "summary_failed",
        "capture_completed",
        "capture_requested",
        "capture_read_pending",
        "capture_terminal_seen",
        "capture_terminal_failed",
        "cancel_start",
        "elapsed_seconds",
        "system_gap_frames",
        "microphone_gap_frames",
        "summary_offset",
        "summary_transcript_len",
        "summary_chunks",
        "canStart",
        "status_detail",
        "capture_error",
        "summary_error",
        "notes_dir",
        "whisper_cli_path",
        "whisper_model_path",
        "note_path",
        "audio_path",
        "whisper_audio_path",
        "transcript_root",
        "transcript_path",
        "summary_draft",
        "latest_note_path",
        "latest_audio_path",
        "api_key",
        "api_key_buffer",
    };

    pub fn statusTitle(model: *const Model) []const u8 {
        return switch (model.phase) {
            .idle => "Ready",
            .starting => "Starting recording",
            .recording => "Recording",
            .stopping => "Finalizing audio",
            .transcribing => "Transcribing locally",
            .summarizing => "Summarizing with GPT-5.6 Luna",
            .saving => "Saving meeting note",
            .saved => "Saved",
            .failed => "Needs attention",
        };
    }

    pub fn recorderTitle(model: *const Model) []const u8 {
        return switch (model.phase) {
            .idle, .saved => "Ready to record",
            .starting => "Starting capture",
            .recording => "Recording in progress",
            .stopping => "Finishing recording",
            .transcribing => "Creating transcript",
            .summarizing => "Creating meeting note",
            .saving => "Saving meeting note",
            .failed => "Recording needs attention",
        };
    }

    pub fn detail(model: *const Model) []const u8 {
        return model.status_detail.text();
    }

    pub fn canStart(model: *const Model) bool {
        if (!model.keychain_checked or !model.api_key_present) return false;
        return switch (model.phase) {
            .idle, .saved, .failed => true,
            else => false,
        };
    }

    pub fn canStop(model: *const Model) bool {
        return model.phase == .starting or model.phase == .recording;
    }

    pub fn isBusy(model: *const Model) bool {
        return switch (model.phase) {
            .starting, .recording, .stopping, .transcribing, .summarizing, .saving => true,
            else => false,
        };
    }

    pub fn isRecording(model: *const Model) bool {
        return model.phase == .recording;
    }

    pub fn hasLatest(model: *const Model) bool {
        return !model.latest_note_path.empty();
    }

    pub fn hasFailure(model: *const Model) bool {
        return model.phase == .failed;
    }

    pub fn canRetry(model: *const Model) bool {
        return model.phase == .failed and
            model.capture_completed and
            !model.whisper_audio_path.empty();
    }

    pub fn keyStatus(model: *const Model) []const u8 {
        if (!model.keychain_checked) return "Checking macOS Keychain…";
        return if (model.api_key_present)
            "Saved securely in macOS Keychain"
        else
            "No OpenAI API key saved";
    }

    pub fn apiKeyDraft(model: *const Model) []const u8 {
        return model.api_key_buffer.text();
    }

    pub fn isCheckingSetup(model: *const Model) bool {
        return !model.keychain_checked;
    }

    pub fn showOnboarding(model: *const Model) bool {
        return model.keychain_checked and !model.api_key_present;
    }

    pub fn areKeyControlsDisabled(model: *const Model) bool {
        return model.isBusy();
    }

    pub fn latestNote(model: *const Model) []const u8 {
        return model.latest_note_path.text();
    }

    pub fn notesDirectory(model: *const Model) []const u8 {
        return model.notes_dir.text();
    }

    pub fn elapsed(model: *const Model, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "{d}:{d:0>2}", .{
            model.elapsed_seconds / 60,
            model.elapsed_seconds % 60,
        }) catch "0:00";
    }

    fn clearCurrentMeeting(model: *Model) void {
        model.audio_writer.discard();
        model.note_path.clear();
        model.audio_path.clear();
        model.whisper_audio_path.clear();
        model.transcript_root.clear();
        model.transcript_path.clear();
        model.summary_draft.clear();
        model.capture_error.clear();
        model.summary_error.clear();
        model.summary_failed = false;
        model.capture_completed = false;
        model.capture_requested = false;
        model.capture_read_pending = false;
        model.capture_terminal_seen = false;
        model.capture_terminal_failed = false;
        model.cancel_start = false;
        model.elapsed_seconds = 0;
        model.system_gap_frames = 0;
        model.microphone_gap_frames = 0;
        model.summary_offset = 0;
        model.summary_transcript_len = 0;
        model.summary_chunks = 0;
    }

    fn fail(model: *Model, detail_text: []const u8) void {
        model.phase = .failed;
        model.status_detail.set(detail_text);
    }
};

pub const MeetingApp = native_sdk.UiApp(Model, Msg);
pub const Effects = MeetingApp.Effects;
pub const app_markup = @embedFile("app.native");
const SettingsView = canvas.CompiledMarkupView(Model, Msg, @embedFile("settings.native"));

pub fn windows(model: *const Model, scratch: *MeetingApp.WindowsScratch) []const MeetingApp.WindowDescriptor {
    if (!model.settings_open) return scratch.windows[0..0];
    scratch.windows[0] = .{
        .label = settings_window_label,
        .canvas_label = settings_canvas_label,
        .title = "Settings",
        .width = 520,
        .height = 400,
        .resizable = false,
        .min_width = 520,
        .min_height = 400,
        .on_close = .settings_closed,
    };
    return scratch.windows[0..1];
}

pub fn windowView(ui: *MeetingApp.Ui, model: *const Model, window_label_value: []const u8) MeetingApp.Ui.Node {
    std.debug.assert(std.mem.eql(u8, window_label_value, settings_window_label));
    return SettingsView.build(ui, model);
}

fn exitedSuccessfully(exit: native_sdk.EffectExit) bool {
    return exit.reason == .exited and exit.code == 0;
}

fn exitDetail(exit: native_sdk.EffectExit, fallback: []const u8) []const u8 {
    const stdout = std.mem.trim(u8, exit.output, " \t\r\n");
    if (stdout.len > 0) return stdout;
    const stderr = std.mem.trim(u8, exit.stderr_tail, " \t\r\n");
    if (stderr.len > 0) return stderr;
    return fallback;
}

fn setKeychainFailure(model: *Model, action: []const u8) void {
    var buffer: [max_status]u8 = undefined;
    const detail = std.fmt.bufPrint(&buffer, "Could not {s} the OpenAI API key in macOS Keychain (status {d}).", .{
        action,
        meeting_notes_keychain_last_status(),
    }) catch "macOS Keychain could not complete the requested operation.";
    model.status_detail.set(detail);
}

fn boot(model: *Model, fx: *Effects) void {
    _ = fx;
    var key_buffer: [max_api_key]u8 = undefined;
    var key_length: usize = 0;
    const result = meeting_notes_keychain_get(&key_buffer, key_buffer.len, &key_length);
    model.keychain_checked = true;
    if (result == 1) {
        model.api_key.set(key_buffer[0..key_length]);
        model.api_key_present = true;
        model.status_detail.set("Ready to capture your next meeting.");
    } else if (result == 0) {
        model.status_detail.set("Add your OpenAI API key to finish setup.");
    } else {
        setKeychainFailure(model, "read");
    }
}

fn startCapture(model: *Model, fx: *Effects) void {
    model.clearCurrentMeeting();
    model.phase = .starting;
    model.status_detail.set("Checking microphone access.");
    fx.audioCaptureAccess(.{
        .key = key_microphone_access,
        .source = .microphone,
        .action = .request,
        .on_event = Effects.audioCaptureAccessMsg(.capture_access),
    });
}

fn populateRecordingPaths(model: *Model, base_path: []const u8) bool {
    var buffer: [max_path]u8 = undefined;
    const note = std.fmt.bufPrint(&buffer, "{s}.md", .{base_path}) catch return false;
    model.note_path.set(note);
    const retained_audio = std.fmt.bufPrint(&buffer, "{s}.wav", .{base_path}) catch return false;
    model.audio_path.set(retained_audio);
    const whisper_audio = std.fmt.bufPrint(&buffer, "{s}.whisper.wav", .{base_path}) catch return false;
    model.whisper_audio_path.set(whisper_audio);
    const transcript_root = std.fmt.bufPrint(&buffer, "{s}.transcript", .{base_path}) catch return false;
    model.transcript_root.set(transcript_root);
    const transcript = std.fmt.bufPrint(&buffer, "{s}.transcript.txt", .{base_path}) catch return false;
    model.transcript_path.set(transcript);
    return true;
}

fn failWithError(model: *Model, fallback: []const u8, err: anyerror) void {
    var buffer: [max_status]u8 = undefined;
    const detail = std.fmt.bufPrint(&buffer, "{s} ({s})", .{ fallback, @errorName(err) }) catch fallback;
    model.fail(detail);
}

fn beginNativeCapture(model: *Model, fx: *Effects) void {
    const base_path = model.audio_writer.start(model.notes_dir.text(), fx.wallMs()) catch |err| {
        failWithError(model, "Could not create the recording WAV files.", err);
        return;
    };
    if (!populateRecordingPaths(model, base_path)) {
        model.audio_writer.discard();
        model.fail("The generated recording path is too long.");
        return;
    }

    model.capture_requested = true;
    model.status_detail.set("Starting the Native SDK audio stream.");
    fx.startAudioCapture(.{
        .key = key_capture,
        .system_audio = true,
        .microphone = .default,
        .sample_rate_hz = 48_000,
        .channel_count = 2,
        .buffer_duration_ms = 5_000,
        .on_event = Effects.audioCaptureMsg(.capture),
    });
}

fn requestCaptureRead(model: *Model, fx: *Effects) void {
    if (model.capture_read_pending or !model.capture_requested) return;
    model.capture_read_pending = true;
    fx.readAudioCapture(.{
        .key = key_capture,
        .max_frames = 4_800,
        .on_read = Effects.audioCaptureReadMsg(.capture_read),
    });
}

fn requestStop(model: *Model, fx: *Effects) void {
    if (!(model.phase == .starting or model.phase == .recording)) return;
    model.phase = .stopping;
    model.status_detail.set("Stopping capture and draining buffered audio.");
    fx.cancelTimer(key_recording_timer);
    if (model.capture_requested) {
        fx.stopAudioCapture();
    } else {
        model.cancel_start = true;
    }
}

fn finishCapture(model: *Model, fx: *Effects) void {
    model.audio_writer.finish() catch |err| {
        model.capture_requested = false;
        model.audio_writer.discard();
        failWithError(model, "Could not finalize the recording WAV files.", err);
        if (model.quit_after_save) fx.quitApp();
        return;
    };
    model.capture_requested = false;
    model.capture_completed = true;
    if (model.capture_terminal_failed) {
        model.fail(if (model.capture_error.empty())
            "Audio capture failed, but a usable partial recording was preserved. Choose Retry to process it."
        else
            model.capture_error.text());
        if (model.quit_after_save) fx.quitApp();
    } else {
        startWhisper(model, fx);
    }
}

fn captureReasonDetail(reason: native_sdk.EffectAudioCaptureReason) []const u8 {
    return switch (reason) {
        .none => "Audio capture stopped unexpectedly.",
        .invalid_options => "The Native SDK rejected the audio capture options.",
        .permission_missing => "The app manifest does not grant the required audio permissions.",
        .permission_required => "Microphone and Screen & System Audio Recording access are required.",
        .already_recording => "Another audio capture is already active.",
        .device_not_found => "The selected microphone is no longer available.",
        .device_disconnected => "The microphone was disconnected during recording.",
        .capture_failed => "The native audio stream failed during recording.",
        .no_audio => "The capture stopped without receiving audio.",
        .consumer_too_slow => "Recording stopped because the app could not drain the reliable audio buffer in time.",
        .discarded => "The recording was discarded.",
        .unsupported => "Reliable system-audio capture requires macOS 15 or later.",
    };
}

fn failAndDiscardCapture(model: *Model, fx: *Effects, detail: []const u8) void {
    model.capture_requested = false;
    model.capture_read_pending = false;
    model.audio_writer.discard();
    model.fail(detail);
    if (model.quit_after_save) fx.quitApp();
}

fn startWhisper(model: *Model, fx: *Effects) void {
    model.phase = .transcribing;
    model.status_detail.set("whisper.cpp medium is running entirely on this Mac.");
    fx.spawn(.{
        .key = key_whisper,
        .argv = &.{
            model.whisper_cli_path.text(),
            "-m",
            model.whisper_model_path.text(),
            "-f",
            model.whisper_audio_path.text(),
            "-otxt",
            "-of",
            model.transcript_root.text(),
            "-l",
            "auto",
            "-ng",
            "-np",
        },
        .output = .collect,
        .on_exit = Effects.exitMsg(.whisper_exited),
    });
}

fn startSummary(model: *Model, fx: *Effects) void {
    model.phase = .summarizing;
    model.summary_draft.clear();
    model.summary_offset = 0;
    model.summary_transcript_len = 0;
    model.summary_chunks = 0;
    model.status_detail.set("Reading the local transcript for summarization.");
    model.summary_transcript_len = notes.transcriptSize(model.io, model.transcript_path.text()) catch |err| {
        setSummaryFailure(model, if (err == error.FileNotFound)
            "Whisper did not produce the expected transcript file."
        else
            "The transcript could not be opened for summarization.");
        startAssemble(model, fx);
        return;
    };
    if (model.summary_transcript_len == 0) {
        setSummaryFailure(model, "Whisper produced an empty transcript.");
        startAssemble(model, fx);
        return;
    }
    fetchNextSummaryChunk(model, fx);
}

fn startAssemble(model: *Model, fx: *Effects) void {
    model.phase = .saving;
    model.status_detail.set("Writing Markdown and cleaning temporary transcription files.");
    notes.assemble(
        model.io,
        std.heap.page_allocator,
        model.note_path.text(),
        model.transcript_path.text(),
        model.whisper_audio_path.text(),
        if (model.summary_failed) null else model.summary_draft.text(),
        model.summary_error.text(),
        !model.replaying,
    ) catch |err| {
        failWithError(model, "Could not assemble the Markdown note.", err);
        if (model.quit_after_save) fx.quitApp();
        return;
    };
    markSaved(model, fx);
}

fn setSummaryFailure(model: *Model, detail: []const u8) void {
    model.summary_failed = true;
    model.summary_error.set(detail);
}

fn fetchNextSummaryChunk(model: *Model, fx: *Effects) void {
    if (model.summary_offset > model.summary_transcript_len) {
        setSummaryFailure(model, "The transcript changed while it was being summarized.");
        startAssemble(model, fx);
        return;
    }
    if (model.summary_offset == model.summary_transcript_len) {
        startAssemble(model, fx);
        return;
    }

    // The lookahead lets buildRequest stop before a UTF-8 code point that
    // crosses its preferred chunk boundary.
    var transcript_buffer: [notes.transcript_read_bytes]u8 = undefined;
    const expected = @min(transcript_buffer.len, model.summary_transcript_len - model.summary_offset);
    const transcript = notes.readTranscriptChunk(
        model.io,
        model.transcript_path.text(),
        model.summary_offset,
        transcript_buffer[0..expected],
    ) catch {
        setSummaryFailure(model, "The transcript could not be read for summarization.");
        startAssemble(model, fx);
        return;
    };
    if (transcript.len != expected) {
        setSummaryFailure(model, "The transcript changed while it was being summarized.");
        startAssemble(model, fx);
        return;
    }

    var body_buffer: [native_sdk.max_effect_fetch_payload_bytes]u8 = undefined;
    const request = notes.buildRequest(
        model.summary_draft.text(),
        transcript,
        &body_buffer,
    ) catch |err| {
        var detail_buffer: [320]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buffer, "Could not encode the next bounded OpenAI request ({s}).", .{@errorName(err)}) catch "Could not encode the next bounded OpenAI request.";
        setSummaryFailure(model, detail);
        startAssemble(model, fx);
        return;
    };
    model.summary_offset += request.transcript_bytes;
    model.summary_chunks += 1;

    var authorization_buffer: ["Bearer ".len + max_api_key]u8 = undefined;
    const authorization = std.fmt.bufPrint(&authorization_buffer, "Bearer {s}", .{model.api_key.text()}) catch {
        setSummaryFailure(model, "The OpenAI API key is too long to send safely.");
        startAssemble(model, fx);
        return;
    };
    const headers = [_]std.http.Header{
        .{ .name = "authorization", .value = authorization },
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "cache-control", .value = "no-store" },
    };
    var status_buffer: [max_status]u8 = undefined;
    const status = std.fmt.bufPrint(&status_buffer, "Summarizing transcript chunk {d} with OpenAI.", .{model.summary_chunks}) catch "Summarizing the next transcript chunk with OpenAI.";
    model.status_detail.set(status);
    fx.fetch(.{
        .key = key_summarize,
        .method = .POST,
        .url = "https://api.openai.com/v1/responses",
        .headers = &headers,
        .body = request.body,
        .timeout_ms = 600_000,
        .on_response = Effects.responseMsg(.summary_response),
    });
}

fn summaryResponseFailure(model: *Model, response: native_sdk.EffectResponse) void {
    var detail_buffer: [320]u8 = undefined;
    const detail = if (response.outcome != .ok)
        std.fmt.bufPrint(&detail_buffer, "The OpenAI request failed ({s}).", .{@tagName(response.outcome)}) catch "The OpenAI request failed."
    else if (response.truncated)
        "The OpenAI response exceeded the SDK response limit."
    else
        std.fmt.bufPrint(&detail_buffer, "The OpenAI endpoint returned HTTP {d}.", .{response.status}) catch "The OpenAI endpoint returned an error.";
    setSummaryFailure(model, detail);
}

fn markSaved(model: *Model, fx: *Effects) void {
    model.phase = .saved;
    model.latest_note_path.set(model.note_path.text());
    model.latest_audio_path.set(model.audio_path.text());
    if (model.summary_failed) {
        model.status_detail.set("Saved the transcript and audio. Summary generation failed; the note explains why.");
    } else {
        model.status_detail.set("Markdown note and audio saved in ~/MeetingNotes.");
    }
    if (model.quit_after_save) fx.quitApp();
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .toggle_recording => {
            if (model.canStop()) {
                requestStop(model, fx);
            } else if (model.canStart()) {
                startCapture(model, fx);
            }
        },
        .retry_processing => if (model.canRetry()) startWhisper(model, fx),
        .open_window => fx.showWindow(window_label),
        .open_settings => {
            model.settings_open = true;
            fx.showWindow(settings_window_label);
        },
        .close_settings, .settings_closed => model.settings_open = false,
        .open_notes_folder => fx.spawn(.{
            .key = key_open,
            .argv = &.{ "/usr/bin/open", model.notes_dir.text() },
        }),
        .open_latest_note => if (model.hasLatest()) fx.spawn(.{
            .key = key_open,
            .argv = &.{ "/usr/bin/open", model.latest_note_path.text() },
        }),
        .open_api_keys => fx.spawn(.{
            .key = key_open_api_keys,
            .argv = &.{ "/usr/bin/open", "https://platform.openai.com/api-keys" },
        }),
        .quit => {
            if (model.isBusy()) {
                model.quit_after_save = true;
                if (model.canStop()) requestStop(model, fx);
                model.status_detail.set("The app will quit after the current note is safely saved.");
            } else {
                fx.quitApp();
            }
        },
        .api_key_changed => |event| model.api_key_buffer.apply(event),
        .save_api_key => {
            const key = std.mem.trim(u8, model.api_key_buffer.text(), " \t\r\n");
            if (key.len == 0) {
                model.status_detail.set("Enter an OpenAI API key, or use the link below to create one.");
                return;
            }
            if (meeting_notes_keychain_set(key.ptr, key.len) == 1) {
                model.api_key.set(key);
                model.api_key_present = true;
                model.keychain_checked = true;
                model.api_key_buffer.clear();
                model.status_detail.set("Setup complete. Ready to capture your next meeting.");
            } else {
                setKeychainFailure(model, "save");
            }
        },
        .delete_api_key => {
            if (meeting_notes_keychain_delete() == 1) {
                model.api_key.clear();
                model.api_key_present = false;
                model.keychain_checked = true;
                model.api_key_buffer.clear();
                model.status_detail.set("OpenAI API key deleted from macOS Keychain.");
            } else {
                setKeychainFailure(model, "delete");
            }
        },
        .capture_access => |event| {
            if (model.cancel_start) {
                model.cancel_start = false;
                model.phase = .idle;
                model.status_detail.set("Recording start cancelled.");
                if (model.quit_after_save) fx.quitApp();
                return;
            }
            if (model.phase != .starting) return;
            if (event.source == .microphone and event.status == .authorized) {
                model.status_detail.set("Checking Screen & System Audio Recording access.");
                fx.audioCaptureAccess(.{
                    .key = key_system_audio_access,
                    .source = .system_audio,
                    .action = .request,
                    .on_event = Effects.audioCaptureAccessMsg(.capture_access),
                });
            } else if (event.source == .system_audio and event.status == .authorized and !event.restart_required) {
                beginNativeCapture(model, fx);
            } else if (event.source == .microphone) {
                model.fail(switch (event.status) {
                    .denied, .restricted => "Microphone access was denied. Enable it in System Settings > Privacy & Security > Microphone.",
                    .unavailable => "Microphone capture is unavailable on this host.",
                    else => "Microphone access is required before recording can start.",
                });
            } else if (event.restart_required) {
                model.fail("Screen & System Audio Recording access changed. Quit and reopen Local Meeting Notes before recording.");
            } else {
                model.fail(switch (event.status) {
                    .unavailable => "System-audio capture is unavailable on this host.",
                    else => "Enable Local Meeting Notes in System Settings > Privacy & Security > Screen & System Audio Recording, then quit and reopen the app.",
                });
            }
        },
        .capture => |event| {
            if (!model.capture_requested) return;
            switch (event.state) {
                .started => {
                    if (model.phase == .stopping) {
                        fx.stopAudioCapture();
                    } else {
                        model.phase = .recording;
                        model.status_detail.set("System audio and microphone are streaming into the app.");
                        fx.startTimer(.{
                            .key = key_recording_timer,
                            .interval_ms = 1000,
                            .mode = .repeating,
                            .on_fire = Effects.timerMsg(.recording_tick),
                        });
                    }
                },
                .readable => requestCaptureRead(model, fx),
                .stopped => {
                    fx.cancelTimer(key_recording_timer);
                    model.capture_terminal_seen = true;
                    model.phase = .stopping;
                    requestCaptureRead(model, fx);
                },
                .failed => {
                    fx.cancelTimer(key_recording_timer);
                    model.capture_terminal_seen = true;
                    model.capture_terminal_failed = true;
                    model.capture_error.set(captureReasonDetail(event.reason));
                    model.phase = .stopping;
                    model.status_detail.set("Capture failed; preserving the buffered audio.");
                    requestCaptureRead(model, fx);
                },
                .rejected => failAndDiscardCapture(model, fx, captureReasonDetail(event.reason)),
            }
        },
        .capture_read => |event| {
            if (!model.capture_requested) return;
            model.capture_read_pending = false;
            switch (event.state) {
                .chunk => {
                    model.audio_writer.append(
                        event.system_pcm,
                        event.microphone_pcm,
                        event.frames,
                        2,
                    ) catch |err| {
                        fx.discardAudioCapture();
                        model.audio_writer.discard();
                        model.capture_requested = false;
                        failWithError(model, "Could not consume the captured PCM stream.", err);
                        if (model.quit_after_save) fx.quitApp();
                        return;
                    };
                    model.system_gap_frames += event.system_gap_frames;
                    model.microphone_gap_frames += event.microphone_gap_frames;
                    if (event.end_of_stream) {
                        finishCapture(model, fx);
                    } else if (event.remaining_frames > 0 or model.capture_terminal_seen) {
                        requestCaptureRead(model, fx);
                    }
                },
                .empty => if (model.capture_terminal_seen) requestCaptureRead(model, fx),
                .ended => finishCapture(model, fx),
                .rejected => failAndDiscardCapture(model, fx, "The Native SDK rejected an audio stream read."),
            }
        },
        .whisper_exited => |exit| {
            if (exitedSuccessfully(exit)) {
                startSummary(model, fx);
            } else {
                model.fail(exitDetail(exit, "The bundled whisper.cpp engine could not transcribe the recording."));
                if (model.quit_after_save) fx.quitApp();
            }
        },
        .summary_response => |response| {
            if (response.outcome != .ok or response.status < 200 or response.status >= 300 or response.truncated) {
                summaryResponseFailure(model, response);
                startAssemble(model, fx);
                return;
            }
            const summary = notes.extractSummary(std.heap.page_allocator, response.body) catch |err| {
                var detail_buffer: [320]u8 = undefined;
                const detail = std.fmt.bufPrint(&detail_buffer, "The OpenAI response could not be parsed ({s}).", .{@errorName(err)}) catch "The OpenAI response could not be parsed.";
                setSummaryFailure(model, detail);
                startAssemble(model, fx);
                return;
            };
            defer std.heap.page_allocator.free(summary);
            if (summary.len > notes.max_draft_bytes) {
                setSummaryFailure(model, "The evolving summary exceeded the app's bounded draft size.");
                startAssemble(model, fx);
                return;
            }
            model.summary_draft.set(summary);
            if (model.summary_offset < model.summary_transcript_len) {
                model.status_detail.set("Reading the next local transcript chunk.");
                fetchNextSummaryChunk(model, fx);
            } else {
                startAssemble(model, fx);
            }
        },
        .recording_tick => |timer| {
            if (timer.outcome == .fired and model.phase == .recording) {
                model.elapsed_seconds += 1;
            }
        },
    }
}

pub fn command(name: []const u8) ?Msg {
    if (std.mem.eql(u8, name, command_open)) return .open_window;
    if (std.mem.eql(u8, name, command_settings)) return .open_settings;
    if (std.mem.eql(u8, name, command_toggle_recording)) return .toggle_recording;
    if (std.mem.eql(u8, name, command_open_notes)) return .open_notes_folder;
    if (std.mem.eql(u8, name, command_open_latest)) return .open_latest_note;
    if (std.mem.eql(u8, name, command_quit)) return .quit;
    return null;
}

const initial_tray_items = [_]native_sdk.TrayMenuItem{
    .{ .id = 1, .label = "Open Local Meeting Notes", .command = command_open },
    .{ .separator = true },
    .{ .id = 2, .label = "Start Recording", .command = command_toggle_recording },
    .{ .separator = true },
    .{ .id = 6, .label = "Settings…", .command = command_settings },
    .{ .id = 3, .label = "Open Notes Folder", .command = command_open_notes },
    .{ .separator = true },
    .{ .id = 4, .label = "Quit", .command = command_quit },
};

pub fn statusItem(model: *const Model, scratch: *MeetingApp.StatusItemScratch) MeetingApp.StatusItemState {
    var count: usize = 0;
    scratch.items[count] = .{ .id = 1, .label = "Open Local Meeting Notes", .command = command_open };
    count += 1;
    scratch.items[count] = .{ .separator = true };
    count += 1;

    scratch.items[count] = .{
        .id = 2,
        .label = if (model.canStop()) "Stop Recording" else "Start Recording",
        .command = command_toggle_recording,
        .enabled = model.canStop() or model.canStart(),
    };
    count += 1;
    scratch.items[count] = .{ .separator = true };
    count += 1;

    scratch.items[count] = .{ .id = 6, .label = "Settings…", .command = command_settings };
    count += 1;
    scratch.items[count] = .{ .id = 3, .label = "Open Notes Folder", .command = command_open_notes };
    count += 1;
    if (model.hasLatest()) {
        scratch.items[count] = .{ .id = 5, .label = "Open Latest Note", .command = command_open_latest };
        count += 1;
    }
    scratch.items[count] = .{ .separator = true };
    count += 1;
    scratch.items[count] = .{ .id = 4, .label = if (model.isBusy()) "Quit After Saving" else "Quit", .command = command_quit };
    count += 1;

    const title = if (model.phase == .recording)
        std.fmt.bufPrint(&scratch.title_buffer, "REC {d}:{d:0>2}", .{
            model.elapsed_seconds / 60,
            model.elapsed_seconds % 60,
        }) catch "REC"
    else if (model.isBusy())
        "MN ..."
    else
        "MN";

    return .{ .title = title, .items = scratch.items[0..count] };
}

fn setInitialPaths(model: *Model, init: std.process.Init) void {
    const home = init.environ_map.get("HOME") orelse "/private/tmp";
    var buffer: [max_path]u8 = undefined;

    if (std.fmt.bufPrint(&buffer, "{s}/MeetingNotes", .{home})) |value| {
        model.notes_dir.set(value);
    } else |_| {}

    var executable_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const executable_len = std.process.executablePath(init.io, &executable_buffer) catch 0;
    const executable = executable_buffer[0..executable_len];
    const bin_dir = std.fs.path.dirname(executable) orelse "";
    const parent = std.fs.path.dirname(bin_dir) orelse "";
    if (std.mem.eql(u8, std.fs.path.basename(parent), "Contents")) {
        if (std.fmt.bufPrint(&buffer, "{s}/Resources/bin/whisper-cli", .{parent})) |value| {
            model.whisper_cli_path.set(value);
        } else |_| {}
        if (std.fmt.bufPrint(&buffer, "{s}/Resources/models/ggml-medium.bin", .{parent})) |value| {
            model.whisper_model_path.set(value);
        } else |_| {}
    } else {
        const project_dir = std.fs.path.dirname(parent) orelse ".";
        if (std.fmt.bufPrint(&buffer, "{s}/assets/bin/whisper-cli", .{project_dir})) |value| {
            model.whisper_cli_path.set(value);
        } else |_| {}
        if (std.fmt.bufPrint(&buffer, "{s}/assets/models/ggml-medium.bin", .{project_dir})) |value| {
            model.whisper_model_path.set(value);
        } else |_| {}
    }
}

pub fn initialModel(init: std.process.Init) Model {
    const replaying = init.environ_map.get("NATIVE_SDK_SESSION_REPLAY") != null;
    var model = Model{
        .io = init.io,
        .audio_writer = audio.Writer.init(init.io, !replaying),
        .replaying = replaying,
    };
    setInitialPaths(&model, init);
    return model;
}

pub fn main(init: std.process.Init) !void {
    const app_state = try MeetingApp.create(std.heap.page_allocator, .{
        .name = "meeting-notes",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .init_fx = boot,
        .on_command = command,
        .status_item = .{
            .title = "MN",
            .tooltip = "Local Meeting Notes",
            .items = &initial_tray_items,
        },
        .status_item_fn = statusItem,
        .windows_fn = windows,
        .window_view = windowView,
        .markup = .{
            .source = app_markup,
            .watch_path = "src/app.native",
            .io = init.io,
        },
    });
    defer app_state.destroy();
    app_state.model = initialModel(init);

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "meeting-notes",
        .window_title = "Local Meeting Notes",
        .bundle_id = "com.local.meetingnotes",
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{} },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
    _ = @import("audio_writer.zig");
    _ = @import("notes.zig");
}
