const std = @import("std");
const main = @import("main.zig");

const testing = std.testing;

test "fixed text clamps without overflowing" {
    var value = main.FixedText(4){};
    value.set("meeting");
    try testing.expectEqualStrings("meet", value.text());
    value.clear();
    try testing.expect(value.empty());
}

test "fixed text truncation preserves UTF-8 boundaries" {
    var value = main.FixedText(4){};
    value.set("abcé");
    try testing.expectEqualStrings("abc", value.text());
    try testing.expect(std.unicode.utf8ValidateSlice(value.text()));
}

test "tray transport reflects recording state" {
    var model = main.Model{};
    model.keychain_checked = true;
    model.api_key_present = true;
    var scratch = main.MeetingApp.StatusItemScratch{};

    const idle = main.statusItem(&model, &scratch);
    try testing.expectEqualStrings("MN", idle.title);
    try testing.expectEqualStrings("Start Recording", idle.items[2].label);
    try testing.expectEqualStrings("Settings…", idle.items[4].label);
    try testing.expectEqualStrings("Open Notes Folder", idle.items[5].label);

    model.phase = .recording;
    model.elapsed_seconds = 65;
    const recording = main.statusItem(&model, &scratch);
    try testing.expectEqualStrings("REC 1:05", recording.title);
    try testing.expectEqualStrings("Stop Recording", recording.items[2].label);
}

test "first launch requires onboarding before recording" {
    var model = main.Model{};
    try testing.expect(model.isCheckingSetup());
    try testing.expect(!model.showOnboarding());
    try testing.expect(!model.canStart());

    model.keychain_checked = true;
    try testing.expect(model.showOnboarding());
    try testing.expect(!model.canStart());

    model.api_key_present = true;
    try testing.expect(!model.showOnboarding());
    try testing.expect(model.canStart());
}

test "settings window is declared only while open" {
    var model = main.Model{};
    var scratch = main.MeetingApp.WindowsScratch{};
    try testing.expectEqual(@as(usize, 0), main.windows(&model, &scratch).len);

    model.settings_open = true;
    const declared = main.windows(&model, &scratch);
    try testing.expectEqual(@as(usize, 1), declared.len);
    try testing.expectEqualStrings(main.settings_window_label, declared[0].label);
    try testing.expectEqualStrings(main.settings_canvas_label, declared[0].canvas_label);
}

test "retry is offered only after capture finalized" {
    var model = main.Model{};
    model.phase = .failed;
    model.whisper_audio_path.set("/tmp/meeting.whisper.wav");
    try testing.expect(!model.canRetry());

    model.capture_completed = true;
    try testing.expect(model.canRetry());
}
