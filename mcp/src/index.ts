#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

type KittyFarmConfig = {
  baseURL: string;
  token: string;
};

type JsonRecord = Record<string, unknown>;

const configPath = join(homedir(), "Library", "Application Support", "KittyFarm", "control-api.json");

const server = new McpServer(
  {
    name: "kittyfarm",
    version: "0.1.0",
  },
  {
    instructions:
      "Control and inspect KittyFarm-managed iOS simulators and Android emulators. Start the KittyFarm app before calling tools.",
  },
);

function textResult(value: unknown) {
  const text = typeof value === "string" ? value : JSON.stringify(value, null, 2);
  return { content: [{ type: "text" as const, text }] };
}

function imageResult(image: { base64: string; mimeType: string; width: number; height: number; deviceId: string }) {
  return {
    content: [
      {
        type: "image" as const,
        data: image.base64,
        mimeType: image.mimeType,
      },
      {
        type: "text" as const,
        text: JSON.stringify(
          {
            deviceId: image.deviceId,
            width: image.width,
            height: image.height,
            mimeType: image.mimeType,
          },
          null,
          2,
        ),
      },
    ],
  };
}

async function readConfig(): Promise<KittyFarmConfig> {
  try {
    const raw = await readFile(configPath, "utf8");
    const parsed = JSON.parse(raw) as Partial<KittyFarmConfig>;
    if (!parsed.baseURL || !parsed.token) {
      throw new Error("config is missing baseURL or token");
    }
    return { baseURL: parsed.baseURL, token: parsed.token };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`Could not read KittyFarm MCP config at ${configPath}: ${message}. Start KittyFarm first.`);
  }
}

async function callKittyFarm(path: string, init: RequestInit = {}): Promise<unknown> {
  const config = await readConfig();
  const url = `${config.baseURL}${path}`;
  const response = await fetch(url, {
    ...init,
    headers: {
      Authorization: `Bearer ${config.token}`,
      "Content-Type": "application/json",
      ...(init.headers ?? {}),
    },
  });

  const text = await response.text();
  let body: unknown = text;
  if (text.length > 0) {
    try {
      body = JSON.parse(text) as unknown;
    } catch {
      body = text;
    }
  }

  if (!response.ok) {
    const error = typeof body === "object" && body && "error" in body ? String((body as JsonRecord).error) : text;
    throw new Error(error || `KittyFarm API returned HTTP ${response.status}`);
  }

  return body;
}

async function get(path: string) {
  return callKittyFarm(path);
}

async function post(path: string, body: unknown) {
  return callKittyFarm(path, {
    method: "POST",
    body: JSON.stringify(body ?? {}),
  });
}

function query(params: Record<string, string | number | undefined>) {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined && value !== "") {
      search.set(key, String(value));
    }
  }
  const encoded = search.toString();
  return encoded ? `?${encoded}` : "";
}

const DeviceId = z.string().min(1).describe("KittyFarm deviceId from kittyfarm_list_devices.");
const BundleId = z.string().optional().describe("Optional iOS app bundle identifier. Ignored for Android.");
const Query = z.string().min(1).describe("Accessibility label, identifier, or value to resolve.");

server.registerTool(
  "kittyfarm_status",
  {
    title: "KittyFarm Status",
    description: "Check whether KittyFarm's local API is available and return high-level app state.",
  },
  async () => textResult(await get("/status")),
);

server.registerTool(
  "kittyfarm_list_devices",
  {
    title: "List KittyFarm Devices",
    description: "List available and active iOS simulators and Android emulators known to KittyFarm.",
  },
  async () => textResult(await get("/devices")),
);

server.registerTool(
  "kittyfarm_connect_device",
  {
    title: "Connect Device",
    description: "Activate and connect a KittyFarm device by deviceId.",
    inputSchema: { deviceId: DeviceId },
  },
  async (args) => textResult(await post("/devices/connect", args)),
);

server.registerTool(
  "kittyfarm_disconnect_device",
  {
    title: "Disconnect Device",
    description: "Remove an active device from KittyFarm by deviceId.",
    inputSchema: { deviceId: DeviceId },
  },
  async (args) => textResult(await post("/devices/disconnect", args)),
);

server.registerTool(
  "kittyfarm_screenshot",
  {
    title: "Device Screenshot",
    description: "Return the latest rendered frame for a device as an MCP image.",
    inputSchema: { deviceId: DeviceId },
  },
  async (args) => {
    const result = (await get(`/screenshot${query({ deviceId: args.deviceId })}`)) as {
      base64: string;
      mimeType: string;
      width: number;
      height: number;
      deviceId: string;
    };
    return imageResult(result);
  },
);

server.registerTool(
  "kittyfarm_accessibility_tree",
  {
    title: "Accessibility Tree",
    description: "Return the current accessibility tree for a device.",
    inputSchema: { deviceId: DeviceId, bundleId: BundleId },
  },
  async (args) => textResult(await get(`/accessibility${query({ deviceId: args.deviceId, bundleId: args.bundleId })}`)),
);

server.registerTool(
  "kittyfarm_find_element",
  {
    title: "Find Element",
    description: "Resolve an accessibility query to the best element and normalized tap coordinates.",
    inputSchema: { deviceId: DeviceId, query: Query, bundleId: BundleId },
  },
  async (args) => textResult(await post("/element/find", args)),
);

server.registerTool(
  "kittyfarm_tap",
  {
    title: "Tap Device",
    description: "Tap a device by accessibility query or normalized x/y coordinates.",
    inputSchema: {
      deviceId: DeviceId,
      query: z.string().optional(),
      x: z.number().min(0).max(1).optional(),
      y: z.number().min(0).max(1).optional(),
      bundleId: BundleId,
    },
  },
  async (args) => textResult(await post("/input/tap", args)),
);

server.registerTool(
  "kittyfarm_swipe",
  {
    title: "Swipe Device",
    description: "Swipe by direction, optional element query, or explicit normalized start/end coordinates.",
    inputSchema: {
      deviceId: DeviceId,
      direction: z.enum(["up", "down", "left", "right"]).optional(),
      query: z.string().optional(),
      startX: z.number().min(0).max(1).optional(),
      startY: z.number().min(0).max(1).optional(),
      endX: z.number().min(0).max(1).optional(),
      endY: z.number().min(0).max(1).optional(),
      bundleId: BundleId,
    },
  },
  async (args) => textResult(await post("/input/swipe", args)),
);

server.registerTool(
  "kittyfarm_type",
  {
    title: "Type Text",
    description: "Type text by setting pasteboard and sending paste; optionally taps a field first.",
    inputSchema: { deviceId: DeviceId, text: z.string(), query: z.string().optional(), bundleId: BundleId },
  },
  async (args) => textResult(await post("/input/type", args)),
);

server.registerTool(
  "kittyfarm_press_home",
  {
    title: "Press Home",
    description: "Press Home on a device.",
    inputSchema: { deviceId: DeviceId },
  },
  async (args) => textResult(await post("/input/home", args)),
);

server.registerTool(
  "kittyfarm_rotate",
  {
    title: "Rotate Device",
    description: "Rotate a device right.",
    inputSchema: { deviceId: DeviceId },
  },
  async (args) => textResult(await post("/input/rotate", args)),
);

server.registerTool(
  "kittyfarm_open_app",
  {
    title: "Open App",
    description: "Open an app by display name or bundle/application id.",
    inputSchema: { deviceId: DeviceId, app: z.string().min(1) },
  },
  async (args) => textResult(await post("/input/open-app", args)),
);

server.registerTool(
  "kittyfarm_assert_visible",
  {
    title: "Assert Visible",
    description: "Fail unless an accessibility element is visible.",
    inputSchema: { deviceId: DeviceId, query: Query, bundleId: BundleId },
  },
  async (args) => textResult(await post("/assert/visible", args)),
);

server.registerTool(
  "kittyfarm_assert_not_visible",
  {
    title: "Assert Not Visible",
    description: "Fail if an accessibility element is visible.",
    inputSchema: { deviceId: DeviceId, query: Query, bundleId: BundleId },
  },
  async (args) => textResult(await post("/assert/not-visible", args)),
);

server.registerTool(
  "kittyfarm_wait_for",
  {
    title: "Wait For Element",
    description: "Wait until an accessibility element appears.",
    inputSchema: { deviceId: DeviceId, query: Query, timeout: z.number().positive().optional(), bundleId: BundleId },
  },
  async (args) => textResult(await post("/wait-for", args)),
);

server.registerTool(
  "kittyfarm_discover_project",
  {
    title: "Discover Project",
    description: "Discover iOS and/or Android app project settings from a path.",
    inputSchema: { path: z.string().min(1), platform: z.enum(["ios", "android"]).optional() },
  },
  async (args) => textResult(await post("/project/discover", args)),
);

server.registerTool(
  "kittyfarm_build_and_run",
  {
    title: "Build And Run",
    description: "Build and launch selected or provided projects on KittyFarm active devices.",
    inputSchema: {
      iosProjectPath: z.string().optional(),
      androidProjectPath: z.string().optional(),
      deviceIds: z.array(DeviceId).optional(),
    },
  },
  async (args) => textResult(await post("/build/run", args)),
);

server.registerTool(
  "kittyfarm_get_logs",
  {
    title: "Get Logs",
    description: "Return recent KittyFarm build/runtime logs.",
    inputSchema: { limit: z.number().int().positive().max(1000).optional() },
  },
  async (args) => textResult(await get(`/logs${query({ limit: args.limit })}`)),
);

const transport = new StdioServerTransport();
await server.connect(transport);
