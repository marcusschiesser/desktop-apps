const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const app_dirs = native_sdk.app_dirs;

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
const key_stop: u64 = 11;
const key_whisper: u64 = 12;
const key_summarize: u64 = 13;
const key_assemble: u64 = 14;
const key_open: u64 = 15;
const key_open_api_keys: u64 = 16;
const key_recording_timer: u64 = 100;

const max_path = 2048;
const max_status = 768;
const max_api_key = 512;

extern fn meeting_notes_keychain_get(buffer: [*]u8, capacity: usize, length: *usize) c_int;
extern fn meeting_notes_keychain_set(secret: [*]const u8, length: usize) c_int;
extern fn meeting_notes_keychain_delete() c_int;
extern fn meeting_notes_keychain_last_status() c_int;
extern fn meeting_notes_screen_capture_preflight() c_int;
extern fn meeting_notes_screen_capture_request() c_int;

const app_permissions = [_][]const u8{
    native_sdk.security.permission_command,
    native_sdk.security.permission_view,
    native_sdk.security.permission_filesystem,
    native_sdk.security.permission_network,
    native_sdk.security.permission_credentials,
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
    capture_line: native_sdk.EffectLine,
    capture_exited: native_sdk.EffectExit,
    stop_exited: native_sdk.EffectExit,
    whisper_exited: native_sdk.EffectExit,
    summarize_exited: native_sdk.EffectExit,
    assemble_exited: native_sdk.EffectExit,
    recording_tick: native_sdk.EffectTimer,

    pub const view_unbound = .{
        "open_window",
        "open_settings",
        "close_settings",
        "settings_closed",
        "quit",
        "capture_line",
        "capture_exited",
        "stop_exited",
        "whisper_exited",
        "summarize_exited",
        "assemble_exited",
        "recording_tick",
    };
};

pub const Model = struct {
    phase: Phase = .idle,
    api_key_present: bool = false,
    keychain_checked: bool = false,
    settings_open: bool = false,
    quit_after_save: bool = false,
    summary_failed: bool = false,
    capture_completed: bool = false,
    elapsed_seconds: u64 = 0,

    status_detail: FixedText(max_status) = .{},
    capture_error: FixedText(max_status) = .{},
    summary_error: FixedText(320) = .{},
    notes_dir: FixedText(max_path) = .{},
    settings_dir: FixedText(max_path) = .{},
    helper_path: FixedText(max_path) = .{},
    whisper_cli_path: FixedText(max_path) = .{},
    whisper_model_path: FixedText(max_path) = .{},
    stop_path: FixedText(max_path) = .{},
    note_path: FixedText(max_path) = .{},
    audio_path: FixedText(max_path) = .{},
    whisper_audio_path: FixedText(max_path) = .{},
    transcript_root: FixedText(max_path) = .{},
    transcript_path: FixedText(max_path) = .{},
    summary_path: FixedText(max_path) = .{},
    latest_note_path: FixedText(max_path) = .{},
    latest_audio_path: FixedText(max_path) = .{},

    api_key: FixedText(max_api_key) = .{},
    api_key_buffer: canvas.TextBuffer(max_api_key) = .{},

    // These fields back derived view methods or belong exclusively to
    // the recording/effect state machine.
    pub const view_unbound = .{
        "phase",
        "api_key_present",
        "keychain_checked",
        "settings_open",
        "quit_after_save",
        "summary_failed",
        "capture_completed",
        "elapsed_seconds",
        "canStart",
        "status_detail",
        "capture_error",
        "summary_error",
        "notes_dir",
        "settings_dir",
        "helper_path",
        "whisper_cli_path",
        "whisper_model_path",
        "stop_path",
        "note_path",
        "audio_path",
        "whisper_audio_path",
        "transcript_root",
        "transcript_path",
        "summary_path",
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
        model.stop_path.clear();
        model.note_path.clear();
        model.audio_path.clear();
        model.whisper_audio_path.clear();
        model.transcript_root.clear();
        model.transcript_path.clear();
        model.summary_path.clear();
        model.capture_error.clear();
        model.summary_error.clear();
        model.summary_failed = false;
        model.capture_completed = false;
        model.elapsed_seconds = 0;
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

    if (meeting_notes_screen_capture_preflight() != 1 and
        meeting_notes_screen_capture_request() != 1)
    {
        model.fail("Screen & System Audio Recording access was not granted. Enable Local Meeting Notes in System Settings, then quit and reopen the app.");
        return;
    }

    model.phase = .starting;
    model.status_detail.set("Starting system-audio and microphone capture.");

    var stop_buffer: [max_path]u8 = undefined;
    const stop_path = std.fmt.bufPrint(&stop_buffer, "{s}/capture-{d}.stop", .{
        model.settings_dir.text(),
        fx.wallMs(),
    }) catch {
        model.fail("Could not create the recording control path.");
        return;
    };
    model.stop_path.set(stop_path);

    fx.spawn(.{
        .key = key_capture,
        .argv = &.{
            model.helper_path.text(),
            "record",
            "--notes-dir",
            model.notes_dir.text(),
            "--stop-file",
            model.stop_path.text(),
        },
        .max_line_bytes = 16 * 1024,
        .on_line = Effects.lineMsg(.capture_line),
        .on_exit = Effects.exitMsg(.capture_exited),
    });
}

fn requestStop(model: *Model, fx: *Effects) void {
    if (!(model.phase == .starting or model.phase == .recording)) return;
    model.phase = .stopping;
    model.status_detail.set("Finishing the system-audio and microphone tracks.");
    fx.cancelTimer(key_recording_timer);
    fx.spawn(.{
        .key = key_stop,
        .argv = &.{ model.helper_path.text(), "stop", "--file", model.stop_path.text() },
        .output = .collect,
        .on_exit = Effects.exitMsg(.stop_exited),
    });
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
    model.status_detail.set("Sending the transcript to OpenAI with store disabled.");
    fx.spawn(.{
        .key = key_summarize,
        .argv = &.{
            model.helper_path.text(),
            "summarize-openai",
            "--transcript",
            model.transcript_path.text(),
            "--output",
            model.summary_path.text(),
        },
        .stdin = model.api_key.text(),
        .output = .collect,
        .on_exit = Effects.exitMsg(.summarize_exited),
    });
}

fn startAssemble(model: *Model, fx: *Effects) void {
    model.phase = .saving;
    model.status_detail.set("Writing Markdown and cleaning temporary transcription files.");
    if (model.summary_failed) {
        fx.spawn(.{
            .key = key_assemble,
            .argv = &.{
                model.helper_path.text(),
                "assemble",
                "--summary",
                model.summary_path.text(),
                "--transcript",
                model.transcript_path.text(),
                "--note",
                model.note_path.text(),
                "--cleanup",
                model.whisper_audio_path.text(),
                "--summary-error",
                model.summary_error.text(),
            },
            .output = .collect,
            .on_exit = Effects.exitMsg(.assemble_exited),
        });
    } else {
        fx.spawn(.{
            .key = key_assemble,
            .argv = &.{
                model.helper_path.text(),
                "assemble",
                "--summary",
                model.summary_path.text(),
                "--transcript",
                model.transcript_path.text(),
                "--note",
                model.note_path.text(),
                "--cleanup",
                model.whisper_audio_path.text(),
            },
            .output = .collect,
            .on_exit = Effects.exitMsg(.assemble_exited),
        });
    }
}

fn parseCaptureLine(model: *Model, line: []const u8, fx: *Effects) void {
    if (std.mem.startsWith(u8, line, "STARTED\t")) {
        var fields = std.mem.splitScalar(u8, line, '\t');
        _ = fields.next();
        const note = fields.next() orelse return model.fail("Capture helper returned an incomplete note path.");
        const audio = fields.next() orelse return model.fail("Capture helper returned an incomplete audio path.");
        const whisper_audio = fields.next() orelse return model.fail("Capture helper returned an incomplete Whisper path.");
        const transcript_root = fields.next() orelse return model.fail("Capture helper returned an incomplete transcript root.");
        const transcript = fields.next() orelse return model.fail("Capture helper returned an incomplete transcript path.");
        const summary = fields.next() orelse return model.fail("Capture helper returned an incomplete summary path.");
        model.note_path.set(note);
        model.audio_path.set(audio);
        model.whisper_audio_path.set(whisper_audio);
        model.transcript_root.set(transcript_root);
        model.transcript_path.set(transcript);
        model.summary_path.set(summary);
        model.phase = .recording;
        model.status_detail.set("System audio and microphone are being captured.");
        fx.startTimer(.{
            .key = key_recording_timer,
            .interval_ms = 1000,
            .mode = .repeating,
            .on_fire = Effects.timerMsg(.recording_tick),
        });
        return;
    }
    if (std.mem.startsWith(u8, line, "ERROR\t")) {
        const detail = line["ERROR\t".len..];
        model.capture_error.set(detail);
        model.status_detail.set(detail);
    }
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
        .capture_line => |line| parseCaptureLine(model, line.line, fx),
        .stop_exited => |exit| {
            if (!exitedSuccessfully(exit)) {
                model.phase = .recording;
                model.status_detail.set(exitDetail(exit, "Could not signal the recorder to stop. Try Stop again."));
            }
        },
        .capture_exited => |exit| {
            fx.cancelTimer(key_recording_timer);
            if (exitedSuccessfully(exit) and !model.whisper_audio_path.empty()) {
                model.capture_completed = true;
                startWhisper(model, fx);
            } else {
                const fallback = if (model.capture_error.empty())
                    "Audio capture failed before producing a usable recording."
                else
                    model.capture_error.text();
                model.fail(exitDetail(exit, fallback));
                if (model.quit_after_save) fx.quitApp();
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
        .summarize_exited => |exit| {
            if (!exitedSuccessfully(exit)) {
                model.summary_failed = true;
                model.summary_error.set(exitDetail(exit, "The summarizer failed."));
            }
            startAssemble(model, fx);
        },
        .assemble_exited => |exit| {
            if (exitedSuccessfully(exit)) {
                model.phase = .saved;
                model.latest_note_path.set(model.note_path.text());
                model.latest_audio_path.set(model.audio_path.text());
                if (model.summary_failed) {
                    model.status_detail.set("Saved the transcript and audio. Summary generation failed; the note explains why.");
                } else {
                    model.status_detail.set("Markdown note and audio saved in ~/MeetingNotes.");
                }
                if (model.quit_after_save) fx.quitApp();
            } else {
                model.fail(exitDetail(exit, "Could not assemble the Markdown note."));
                if (model.quit_after_save) fx.quitApp();
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

    var data_dir_buffer: [max_path]u8 = undefined;
    const env = native_sdk.debug.envFromMap(init.environ_map);
    if (app_dirs.resolveOne(.{ .name = "Local Meeting Notes" }, app_dirs.currentPlatform(), env, .data, &data_dir_buffer)) |data_dir| {
        model.settings_dir.set(data_dir);
    } else |_| {
        model.settings_dir.set("/private/tmp/local-meeting-notes");
    }

    var executable_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const executable_len = std.process.executablePath(init.io, &executable_buffer) catch 0;
    const executable = executable_buffer[0..executable_len];
    const bin_dir = std.fs.path.dirname(executable) orelse "";
    const parent = std.fs.path.dirname(bin_dir) orelse "";
    if (std.mem.eql(u8, std.fs.path.basename(parent), "Contents")) {
        if (std.fmt.bufPrint(&buffer, "{s}/Helpers/meeting-notes-helper", .{parent})) |value| {
            model.helper_path.set(value);
        } else |_| {}
        if (std.fmt.bufPrint(&buffer, "{s}/Resources/bin/whisper-cli", .{parent})) |value| {
            model.whisper_cli_path.set(value);
        } else |_| {}
        if (std.fmt.bufPrint(&buffer, "{s}/Resources/models/ggml-medium.bin", .{parent})) |value| {
            model.whisper_model_path.set(value);
        } else |_| {}
    } else {
        const project_dir = std.fs.path.dirname(parent) orelse ".";
        if (std.fmt.bufPrint(&buffer, "{s}/assets/bin/meeting-notes-helper", .{project_dir})) |value| {
            model.helper_path.set(value);
        } else |_| {}
        if (std.fmt.bufPrint(&buffer, "{s}/assets/bin/whisper-cli", .{project_dir})) |value| {
            model.whisper_cli_path.set(value);
        } else |_| {}
        if (std.fmt.bufPrint(&buffer, "{s}/assets/models/ggml-medium.bin", .{project_dir})) |value| {
            model.whisper_model_path.set(value);
        } else |_| {}
    }
}

pub fn initialModel(init: std.process.Init) Model {
    var model = Model{};
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
}
