import { Cmd, asciiBytes } from "@native-sdk/core";

export interface Model {
  readonly status: Uint8Array;
  readonly helperRunning: boolean;
  readonly restartPending: boolean;
  readonly restarts: number;
  readonly diagnostic: Uint8Array;
  readonly configAction: Uint8Array;
}

export const viewUnbound = [
  "restartPending",
  "helper_line",
  "helper_exit",
  "helper_error",
  "config_line",
  "config_exit",
  "config_error",
  "diagnostic_line",
  "diagnostic_exit",
  "diagnostic_error",
] as const;

export type Msg =
  | { readonly kind: "helper_line"; readonly line: Uint8Array }
  | { readonly kind: "helper_exit"; readonly code: number }
  | { readonly kind: "helper_error"; readonly error: Uint8Array }
  | { readonly kind: "restart" }
  | { readonly kind: "open_config" }
  | { readonly kind: "config_line"; readonly line: Uint8Array }
  | { readonly kind: "config_exit"; readonly code: number }
  | { readonly kind: "config_error"; readonly error: Uint8Array }
  | { readonly kind: "run_diagnostics" }
  | { readonly kind: "diagnostic_line"; readonly line: Uint8Array }
  | { readonly kind: "diagnostic_exit"; readonly code: number }
  | { readonly kind: "diagnostic_error"; readonly error: Uint8Array };

export function initialModel(): Model | [Model, Cmd<Msg>] {
  const model: Model = {
    status: asciiBytes("Starting background helper..."),
    helperRunning: true,
    restartPending: false,
    restarts: 0,
    diagnostic: asciiBytes("Not run yet"),
    configAction: asciiBytes("Config has not been opened in this session"),
  };
  return [
    model,
    Cmd.spawn<Msg>(
      [asciiBytes("assets/bin/flow-helper"), asciiBytes("serve")],
      {
        key: "flow-helper",
        line: "helper_line",
        exit: "helper_exit",
        err: "helper_error",
      },
    ),
  ];
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "helper_line":
      return {
        ...model,
        status: msg.line,
        helperRunning: true,
        restartPending: false,
      };
    case "helper_exit":
      return {
        ...model,
        status: asciiBytes("Background helper stopped"),
        helperRunning: false,
        restartPending: false,
      };
    case "helper_error":
      if (model.restartPending) {
        const next: Model = {
          ...model,
          status: asciiBytes("Restarting background helper..."),
          helperRunning: true,
          restartPending: false,
          restarts: model.restarts + 1,
        };
        return [
          next,
          Cmd.spawn<Msg>(
            [asciiBytes("assets/bin/flow-helper"), asciiBytes("serve")],
            {
              key: "flow-helper",
              line: "helper_line",
              exit: "helper_exit",
              err: "helper_error",
            },
          ),
        ];
      }
      return {
        ...model,
        status: msg.error,
        helperRunning: false,
        restartPending: false,
      };
    case "restart":
      if (model.helperRunning) {
        return [
          {
            ...model,
            status: asciiBytes("Stopping helper before restart..."),
            restartPending: true,
          },
          Cmd.cancel("flow-helper"),
        ];
      }
      return [
        {
          ...model,
          status: asciiBytes("Starting background helper..."),
          helperRunning: true,
          restartPending: false,
          restarts: model.restarts + 1,
        },
        Cmd.spawn<Msg>(
          [asciiBytes("assets/bin/flow-helper"), asciiBytes("serve")],
          {
            key: "flow-helper",
            line: "helper_line",
            exit: "helper_exit",
            err: "helper_error",
          },
        ),
      ];
    case "open_config":
      return [
        {
          ...model,
          configAction: asciiBytes("Opening config.json..."),
        },
        Cmd.spawn<Msg>(
          [asciiBytes("assets/bin/flow-helper"), asciiBytes("open-config")],
          {
            key: "flow-open-config",
            line: "config_line",
            exit: "config_exit",
            err: "config_error",
          },
        ),
      ];
    case "config_line":
      return { ...model, configAction: msg.line };
    case "config_exit":
      return {
        ...model,
        configAction:
          msg.code === 0
            ? asciiBytes("Opened config.json in the default editor")
            : asciiBytes("Could not open config.json"),
      };
    case "config_error":
      return { ...model, configAction: msg.error };
    case "run_diagnostics":
      return [
        { ...model, diagnostic: asciiBytes("Running helper self-test...") },
        Cmd.spawn<Msg>(
          [asciiBytes("assets/bin/flow-helper"), asciiBytes("self-test")],
          {
            key: "flow-diagnostics",
            line: "diagnostic_line",
            exit: "diagnostic_exit",
            err: "diagnostic_error",
          },
        ),
      ];
    case "diagnostic_line":
      return { ...model, diagnostic: msg.line };
    case "diagnostic_exit":
      return {
        ...model,
        diagnostic:
          msg.code === 0
            ? asciiBytes("All helper self-tests passed")
            : asciiBytes("Helper self-test failed"),
      };
    case "diagnostic_error":
      return { ...model, diagnostic: msg.error };
  }
}
