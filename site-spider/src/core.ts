import { Cmd, asciiBytes } from "@native-sdk/core";
import {
  applyTextInputEvent,
  clampedInsertEvent,
  type TextEditState,
  type TextInputEvent,
} from "@native-sdk/core/text";

type Bytes = Uint8Array;

interface UrlDraft {
  readonly bytes: Bytes;
  readonly anchor: number;
  readonly focus: number;
  readonly compStart: number;
  readonly compEnd: number;
}

function emptyDraft(): UrlDraft {
  return {
    bytes: asciiBytes("https://example.com"),
    anchor: 19,
    focus: 19,
    compStart: -1,
    compEnd: -1,
  };
}

function draftState(draft: UrlDraft): TextEditState {
  return {
    text: draft.bytes,
    selection: { anchor: draft.anchor, focus: draft.focus },
    composition:
      draft.compStart >= 0
        ? { start: draft.compStart, end: draft.compEnd }
        : null,
  };
}

function applyDraft(draft: UrlDraft, event: TextInputEvent): UrlDraft {
  const state = draftState(draft);
  let next = applyTextInputEvent(state, event, 2048);
  if (next === null) {
    const clamped = clampedInsertEvent(state, event, 2048);
    if (clamped === null) return draft;
    next = applyTextInputEvent(state, clamped, 2048);
    if (next === null) return draft;
  }
  const nextStart = next.composition === null ? -1 : next.composition.start;
  const nextEnd = next.composition === null ? -1 : next.composition.end;
  return {
    bytes: next.text,
    anchor: next.selection.anchor,
    focus: next.selection.focus,
    compStart:
      nextStart >= -1 && nextStart <= 9007199254740991
        ? Math.trunc(nextStart)
        : -1,
    compEnd:
      nextEnd >= -1 && nextEnd <= 9007199254740991
        ? Math.trunc(nextEnd)
        : -1,
  };
}

export interface Model {
  readonly url: UrlDraft;
  readonly acknowledged: boolean;
  readonly maxPages: number;
  readonly running: boolean;
  readonly reportAvailable: boolean;
  readonly status: Bytes;
  readonly reportStatus: Bytes;
}

export type Msg =
  | { readonly kind: "url_edited"; readonly edit: TextInputEvent }
  | { readonly kind: "toggle_permission" }
  | { readonly kind: "limit_25" }
  | { readonly kind: "limit_100" }
  | { readonly kind: "limit_250" }
  | { readonly kind: "start_crawl" }
  | { readonly kind: "cancel_crawl" }
  | { readonly kind: "crawl_line"; readonly line: Bytes }
  | { readonly kind: "crawl_exit"; readonly code: number }
  | { readonly kind: "crawl_error"; readonly error: Bytes }
  | { readonly kind: "open_report" }
  | { readonly kind: "report_line"; readonly line: Bytes }
  | { readonly kind: "report_exit"; readonly code: number }
  | { readonly kind: "report_error"; readonly error: Bytes };

export const viewUnbound = [
  "url",
  "crawl_line",
  "crawl_exit",
  "crawl_error",
  "report_line",
  "report_exit",
  "report_error",
] as const;

export function initialModel(): Model {
  return {
    url: emptyDraft(),
    acknowledged: false,
    maxPages: 100,
    running: false,
    reportAvailable: false,
    status: asciiBytes("Ready. Enter a site you own or are authorized to audit."),
    reportStatus: asciiBytes("No report generated in this session."),
  };
}

export function urlText(model: Model): Bytes {
  return model.url.bytes;
}

export function startDisabled(model: Model): boolean {
  return model.running || !model.acknowledged || model.url.bytes.length === 0;
}

export function openDisabled(model: Model): boolean {
  return model.running || !model.reportAvailable;
}

export function cancelDisabled(model: Model): boolean {
  return !model.running;
}

export function permissionLabel(model: Model): Bytes {
  return model.acknowledged
    ? asciiBytes("Permission acknowledged")
    : asciiBytes("Acknowledge permission");
}

export function limit25Selected(model: Model): boolean {
  return model.maxPages === 25;
}

export function limit100Selected(model: Model): boolean {
  return model.maxPages === 100;
}

export function limit250Selected(model: Model): boolean {
  return model.maxPages === 250;
}

function limitArg(model: Model): Bytes {
  if (model.maxPages === 25) return asciiBytes("25");
  if (model.maxPages === 250) return asciiBytes("250");
  return asciiBytes("100");
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "url_edited":
      if (model.running) return model;
      return { ...model, url: applyDraft(model.url, msg.edit) };
    case "toggle_permission":
      if (model.running) return model;
      return { ...model, acknowledged: !model.acknowledged };
    case "limit_25":
      if (model.running) return model;
      return { ...model, maxPages: 25 };
    case "limit_100":
      if (model.running) return model;
      return { ...model, maxPages: 100 };
    case "limit_250":
      if (model.running) return model;
      return { ...model, maxPages: 250 };
    case "start_crawl":
      if (startDisabled(model)) return model;
      return [
        {
          ...model,
          running: true,
          reportAvailable: false,
          status: asciiBytes("Starting permissioned crawl..."),
          reportStatus: asciiBytes("A new report is being generated."),
        },
        Cmd.spawn<Msg>(
          [
            asciiBytes("assets/bin/seo-spider-helper"),
            asciiBytes("crawl"),
            model.url.bytes,
            limitArg(model),
            asciiBytes("--permission-acknowledged"),
          ],
          {
            key: "seo-crawl",
            line: "crawl_line",
            exit: "crawl_exit",
            err: "crawl_error",
          },
        ),
      ];
    case "cancel_crawl":
      if (!model.running) return model;
      return [
        { ...model, status: asciiBytes("Cancelling crawl...") },
        Cmd.cancel("seo-crawl"),
      ];
    case "crawl_line":
      return { ...model, status: msg.line };
    case "crawl_exit":
      if (msg.code === 0) {
        return {
          ...model,
          running: false,
          reportAvailable: true,
          status: asciiBytes("Audit complete. CSV and HTML report are ready."),
          reportStatus: asciiBytes("Latest report can be opened from this window."),
        };
      }
      return {
        ...model,
        running: false,
        status: asciiBytes("Crawl stopped before a report was completed."),
        reportStatus: asciiBytes("Review the status above, fix the input, and retry."),
      };
    case "crawl_error":
      return {
        ...model,
        running: false,
        status: msg.error,
        reportStatus: asciiBytes("The helper could not start or was interrupted."),
      };
    case "open_report":
      if (openDisabled(model)) return model;
      return [
        { ...model, reportStatus: asciiBytes("Opening latest HTML report...") },
        Cmd.spawn<Msg>(
          [asciiBytes("assets/bin/seo-spider-helper"), asciiBytes("open-latest")],
          {
            key: "seo-open-report",
            line: "report_line",
            exit: "report_exit",
            err: "report_error",
          },
        ),
      ];
    case "report_line":
      return { ...model, reportStatus: msg.line };
    case "report_exit":
      return {
        ...model,
        reportStatus:
          msg.code === 0
            ? asciiBytes("Opened the latest HTML report in your default browser.")
            : asciiBytes("Could not open the latest report."),
      };
    case "report_error":
      return { ...model, reportStatus: msg.error };
  }
}
