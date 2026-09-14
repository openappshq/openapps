import { describe, expect, it } from "vite-plus/test";
import { products } from "../catalog";
import { checkoutUrl, dodoProducts, isPlaceholder, licensingFor } from "./licensing";
import { activateUrl, cleanedUrl, parseCheckoutReturn } from "./thanks";

describe("checkoutUrl", () => {
  it("builds Dodo's static payment link with quantity and redirect", () => {
    expect(checkoutUrl("pdt_abc", "https://openapps.space/openreaction/thanks/")).toBe(
      "https://checkout.dodopayments.com/buy/pdt_abc?quantity=1&redirect_url=https%3A%2F%2Fopenapps.space%2Fopenreaction%2Fthanks%2F",
    );
    expect(checkoutUrl("pdt_abc", "https://x/", "https://test.checkout.dodopayments.com")).toMatch(
      /^https:\/\/test\.checkout\.dodopayments\.com\/buy\/pdt_abc\?/,
    );
  });

  it("returns null for placeholders and empty IDs so buttons render disabled", () => {
    expect(isPlaceholder("PLACEHOLDER_OPENREACTION_PAID")).toBe(true);
    expect(checkoutUrl("PLACEHOLDER_OPENREACTION_PAID", "https://x/")).toBeNull();
    expect(checkoutUrl("", "https://x/")).toBeNull();
  });
});

describe("licensingFor", () => {
  it("has live product IDs for every catalog app", () => {
    for (const product of products) {
      const licensing = licensingFor(product.id);
      expect(dodoProducts[product.id], product.id).toBeDefined();
      expect(licensing.buyUrl, product.id).toContain(`/buy/${dodoProducts[product.id]!.paid}?`);
      expect(licensing.trialUrl, product.id).toContain(`/buy/${dodoProducts[product.id]!.trial}?`);
      expect(licensing.thanksUrl).toBe(`https://openapps.space${product.route}/thanks/`);
      expect(licensing.buyUrl).toContain(encodeURIComponent(licensing.thanksUrl));
    }
  });

  it("rejects apps that are not in the catalog", () => {
    expect(() => licensingFor("nope")).toThrow("Unknown app");
  });
});

describe("parseCheckoutReturn", () => {
  it("reads a single key and the email", () => {
    expect(
      parseCheckoutReturn("?payment_id=pay_1&status=succeeded&license_key=LK-001&email=a%40b.c"),
    ).toEqual({
      keys: ["LK-001"],
      email: "a@b.c",
      status: "succeeded",
    });
  });

  it("splits comma-separated keys and drops blanks", () => {
    expect(parseCheckoutReturn("?license_key=LK-1,%20LK-2,,").keys).toEqual(["LK-1", "LK-2"]);
  });

  it("handles a missing key gracefully", () => {
    expect(parseCheckoutReturn("")).toEqual({ keys: [], email: null, status: null });
    expect(parseCheckoutReturn("?license_key=&email=").keys).toEqual([]);
  });
});

describe("activateUrl", () => {
  it("encodes keys with unusual characters", () => {
    expect(activateUrl("openreaction", "LK-001")).toBe("openreaction://activate?key=LK-001");
    expect(activateUrl("openklack", "a b&c=d/é")).toBe(
      "openklack://activate?key=a%20b%26c%3Dd%2F%C3%A9",
    );
  });
});

describe("cleanedUrl", () => {
  it("removes checkout details but keeps the path, other params and hash", () => {
    expect(
      cleanedUrl(
        "https://openapps.space/openreaction/thanks/?payment_id=p&status=succeeded&license_key=LK&email=a%40b.c",
      ),
    ).toBe("/openreaction/thanks/");
    expect(cleanedUrl("https://openapps.space/OpenKlack/thanks/?license_key=LK&ref=x#steps")).toBe(
      "/OpenKlack/thanks/?ref=x#steps",
    );
  });
});
