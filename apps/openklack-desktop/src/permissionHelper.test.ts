import { expect, test } from "vite-plus/test";
import { PermissionHelperFlow } from "./permissionHelper";

/** An `invoke` that records its calls and holds `request_input_permission` until released. */
function bridge() {
  const calls: string[] = [];
  let release = () => {};
  const held = new Promise<void>((resolve) => {
    release = resolve;
  });
  const flow = new PermissionHelperFlow(async (command) => {
    calls.push(command);
    if (command === "request_input_permission") await held;
  });
  return { calls, flow, release };
}

test("Open System Settings asks macOS, then shows the helper", async () => {
  const { calls, flow, release } = bridge();
  const request = flow.request()();
  release();
  await request;
  expect(calls).toEqual(["request_input_permission", "show_permission_helper"]);
});

test("a hide asked while the request is still pending wins over the show it would bring", async () => {
  const { calls, flow, release } = bridge();
  // Open System Settings is waiting on macOS; the user leaves the step meanwhile. The hide is
  // taken now and queued after the request, as the window's operation queue does.
  const request = flow.request()();
  const hide = flow.hide();
  release();
  await request;
  await hide();
  expect(calls).toEqual(["request_input_permission", "hide_permission_helper"]);
});

test("a show asked again after a hide is a fresh one and runs", async () => {
  const { calls, flow, release } = bridge();
  release();
  await flow.hide()();
  await flow.show()();
  expect(calls).toEqual(["hide_permission_helper", "show_permission_helper"]);
});

test("a queued Show the helper again is stale once the step has been left", async () => {
  const { calls, flow } = bridge();
  const show = flow.show();
  const hide = flow.hide();
  await show();
  await hide();
  expect(calls).toEqual(["hide_permission_helper"]);
});

test("a failed hide is swallowed: there is nothing to tell the user", async () => {
  const flow = new PermissionHelperFlow(() => Promise.reject(new Error("no window")));
  await expect(flow.hide()()).resolves.toBeUndefined();
});
