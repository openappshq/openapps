import { runInNewContext } from "node:vm";
import { describe, expect, it } from "vite-plus/test";
import { CHECKOUT_CAPTURE_SCRIPT, CHECKOUT_GLOBAL } from "./checkoutCapture";

/** Runs the inline script against a fake window, location and history. */
function run(search: string, pathname = "/openreaction/thanks/", hash = "") {
  const replaced: string[] = [];
  const win: Record<string, unknown> = {};
  const location = { search, pathname, hash };
  const history = {
    state: { from: "checkout" },
    replaceState: (_state: unknown, _title: string, url: string) => replaced.push(url),
  };
  runInNewContext(CHECKOUT_CAPTURE_SCRIPT, { window: win, location, history, URLSearchParams });
  return { captured: win[CHECKOUT_GLOBAL] as Record<string, string> | undefined, replaced };
}

describe("checkout capture script", () => {
  it("moves the checkout parameters into memory and scrubs the address bar", () => {
    const { captured, replaced } = run(
      "?payment_id=pay_1&status=succeeded&license_key=LK-1%2CLK-2&email=a%40b.c",
    );
    expect(captured).toEqual({
      payment_id: "pay_1",
      status: "succeeded",
      license_key: "LK-1,LK-2",
      email: "a@b.c",
    });
    expect(replaced).toEqual(["/openreaction/thanks/"]);
  });

  it("keeps unrelated parameters and the hash", () => {
    const { replaced } = run("?license_key=LK&ref=newsletter", "/OpenKlack/thanks/", "#steps");
    expect(replaced).toEqual(["/OpenKlack/thanks/?ref=newsletter#steps"]);
  });

  it("does nothing on a plain visit", () => {
    const { captured, replaced } = run("");
    expect(captured).toBeUndefined();
    expect(replaced).toEqual([]);
  });

  it("is plain script that needs no imports", () => {
    expect(CHECKOUT_CAPTURE_SCRIPT).not.toMatch(/\bimport\b|\bexport\b|=>/);
  });
});
