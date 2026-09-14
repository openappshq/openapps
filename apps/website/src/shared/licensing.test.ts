import { describe, expect, it } from "vite-plus/test";
import { products } from "../catalog";
import {
  checkoutUrl,
  dodoProducts,
  isPlaceholder,
  licensingFor,
  officialBuilds,
} from "./licensing";
import { activateUrl, cleanedUrl, parseCheckoutReturn, readCheckoutReturn } from "./thanks";
import { CHECKOUT_GLOBAL } from "./checkoutCapture";

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
  it("sells every catalogued app, and disables both buttons for one taken off sale", () => {
    for (const product of products) {
      expect(officialBuilds[product.id], product.id).toBe(true);
      expect(licensingFor(product.id).officialBuildAvailable, product.id).toBe(true);

      const offSale = licensingFor(product.id, { officialBuildAvailable: false });
      expect(offSale.buyUrl).toBeNull();
      expect(offSale.trialUrl).toBeNull();
    }
  });

  it("links live product IDs to kind-specific return pages once a build is available", () => {
    for (const product of products) {
      const licensing = licensingFor(product.id, { officialBuildAvailable: true });
      expect(dodoProducts[product.id], product.id).toBeDefined();
      expect(licensing.buyUrl, product.id).toContain(`/buy/${dodoProducts[product.id]!.paid}?`);
      expect(licensing.trialUrl, product.id).toContain(`/buy/${dodoProducts[product.id]!.trial}?`);
      expect(licensing.thanksUrl).toBe(`https://openapps.space${product.route}/thanks/`);
      expect(licensing.trialThanksUrl).toBe(`https://openapps.space${product.route}/thanks/trial/`);
      expect(licensing.buyUrl).toContain(encodeURIComponent(licensing.thanksUrl));
      expect(licensing.trialUrl).toContain(encodeURIComponent(licensing.trialThanksUrl));
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

  it("marks trial keys for the app", () => {
    expect(activateUrl("openreaction", "LK-T", "trial")).toBe(
      "openreaction://activate?key=LK-T&kind=trial",
    );
  });
});

describe("readCheckoutReturn", () => {
  it("prefers what the head script captured and leaves the URL alone", () => {
    const replaceState = () => {
      throw new Error("must not touch history");
    };
    const win = {
      [CHECKOUT_GLOBAL]: { license_key: "LK-1", email: "a@b.c", status: "succeeded" },
      location: {
        search: "",
        href: "https://openapps.space/thanks/",
        pathname: "/thanks/",
        hash: "",
      },
      history: { state: null, replaceState },
    } as unknown as Window;
    expect(readCheckoutReturn(win)).toEqual({
      keys: ["LK-1"],
      email: "a@b.c",
      status: "succeeded",
    });
  });

  it("falls back to the query string and scrubs it when the head script did not run", () => {
    const replaced: string[] = [];
    const win = {
      location: {
        search: "?license_key=LK-2&status=succeeded",
        href: "https://openapps.space/openreaction/thanks/?license_key=LK-2&status=succeeded",
        pathname: "/openreaction/thanks/",
        hash: "",
      },
      history: {
        state: null,
        replaceState: (_s: unknown, _t: string, url: string) => replaced.push(url),
      },
    } as unknown as Window;
    expect(readCheckoutReturn(win).keys).toEqual(["LK-2"]);
    expect(replaced).toEqual(["/openreaction/thanks/"]);
  });
});

describe("cleanedUrl", () => {
  it("removes checkout details but keeps the path, other params and hash", () => {
    expect(
      cleanedUrl(
        "https://openapps.space/openreaction/thanks/?payment_id=p&status=succeeded&license_key=LK&email=a%40b.c",
      ),
    ).toBe("/openreaction/thanks/");
    expect(cleanedUrl("https://openapps.space/openklack/thanks/?license_key=LK&ref=x#steps")).toBe(
      "/openklack/thanks/?ref=x#steps",
    );
  });
});
