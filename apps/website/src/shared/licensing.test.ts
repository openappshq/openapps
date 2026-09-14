import { describe, expect, it } from "vite-plus/test";
import { products } from "../catalog";
import {
  checkoutUrl,
  DODO_CHECKOUT_ORIGINS,
  dodoConfigFrom,
  licensingFor,
  officialBuilds,
} from "./licensing";

const liveEnv = {
  VITE_OPENREACTION_DODO_PAID_PRODUCT_ID: "pdt_orPaid",
  VITE_OPENREACTION_DODO_TRIAL_PRODUCT_ID: "pdt_orTrial",
  VITE_OPENKLACK_DODO_PAID_PRODUCT_ID: "pdt_okPaid",
  VITE_OPENKLACK_DODO_TRIAL_PRODUCT_ID: "pdt_okTrial",
};
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

  it("returns null for missing or malformed IDs so buttons render disabled", () => {
    expect(checkoutUrl("PLACEHOLDER_OPENREACTION_PAID", "https://x/")).toBeNull();
    expect(checkoutUrl("", "https://x/")).toBeNull();
    expect(checkoutUrl(undefined, "https://x/")).toBeNull();
    expect(checkoutUrl("pdt_a/../b", "https://x/")).toBeNull();
  });
});

describe("dodoConfigFrom", () => {
  it("reads both product IDs per app and defaults to live checkout", () => {
    const config = dodoConfigFrom(liveEnv);
    expect(config.checkoutOrigin).toBe(DODO_CHECKOUT_ORIGINS.live);
    expect(config.products).toEqual({
      openreaction: { paid: "pdt_orPaid", trial: "pdt_orTrial" },
      openklack: { paid: "pdt_okPaid", trial: "pdt_okTrial" },
    });
  });

  it("uses test checkout when asked, ignoring a trailing slash and whitespace", () => {
    const config = dodoConfigFrom({
      ...liveEnv,
      VITE_DODO_CHECKOUT_ORIGIN: " https://test.checkout.dodopayments.com/ ",
    });
    expect(config.checkoutOrigin).toBe(DODO_CHECKOUT_ORIGINS.test);
    expect(Object.keys(config.products)).toHaveLength(2);
  });

  it("sells nothing when the checkout origin is not Dodo's", () => {
    const config = dodoConfigFrom({ ...liveEnv, VITE_DODO_CHECKOUT_ORIGIN: "https://evil.example" });
    expect(config.checkoutOrigin).toBe(DODO_CHECKOUT_ORIGINS.live);
    expect(config.products).toEqual({});
    expect(dodoConfigFrom({ ...liveEnv, VITE_DODO_CHECKOUT_ORIGIN: "///" }).products).toEqual({});
  });

  it("skips an app unless both of its IDs are present and well formed", () => {
    const config = dodoConfigFrom({
      VITE_OPENREACTION_DODO_PAID_PRODUCT_ID: "pdt_orPaid",
      VITE_OPENKLACK_DODO_PAID_PRODUCT_ID: "pdt_okPaid",
      VITE_OPENKLACK_DODO_TRIAL_PRODUCT_ID: "not-an-id",
    });
    expect(config.products).toEqual({});
    expect(dodoConfigFrom({}).products).toEqual({});
  });
});

describe("licensingFor", () => {
  const dodo = dodoConfigFrom(liveEnv);

  it("keeps both buttons disabled until an official build exists", () => {
    for (const product of products) {
      expect(officialBuilds[product.id], product.id).toBe(false);
      const licensing = licensingFor(product.id, { dodo });
      expect(licensing.officialBuildAvailable).toBe(false);
      expect(licensing.buyUrl).toBeNull();
      expect(licensing.trialUrl).toBeNull();
    }
  });

  it("keeps both buttons disabled when product IDs are not configured", () => {
    for (const product of products) {
      const licensing = licensingFor(product.id, {
        officialBuildAvailable: true,
        dodo: dodoConfigFrom({}),
      });
      expect(licensing.officialBuildAvailable).toBe(false);
      expect(licensing.buyUrl).toBeNull();
      expect(licensing.trialUrl).toBeNull();
    }
  });

  it("links configured product IDs to the configured checkout", () => {
    const test = dodoConfigFrom({ ...liveEnv, VITE_DODO_CHECKOUT_ORIGIN: DODO_CHECKOUT_ORIGINS.test });
    const licensing = licensingFor("openreaction", { officialBuildAvailable: true, dodo: test });
    expect(licensing.buyUrl).toMatch(/^https:\/\/test\.checkout\.dodopayments\.com\/buy\/pdt_orPaid\?/);
    expect(licensing.trialUrl).toMatch(/^https:\/\/test\.checkout\.dodopayments\.com\/buy\/pdt_orTrial\?/);
  });

  it("links product IDs to kind-specific return pages once a build is available", () => {
    for (const product of products) {
      const licensing = licensingFor(product.id, { officialBuildAvailable: true, dodo });
      const ids = dodo.products[product.id];
      expect(ids, product.id).toBeDefined();
      expect(licensing.buyUrl, product.id).toContain(`${DODO_CHECKOUT_ORIGINS.live}/buy/${ids!.paid}?`);
      expect(licensing.trialUrl, product.id).toContain(`${DODO_CHECKOUT_ORIGINS.live}/buy/${ids!.trial}?`);
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
    expect(cleanedUrl("https://openapps.space/OpenKlack/thanks/?license_key=LK&ref=x#steps")).toBe(
      "/OpenKlack/thanks/?ref=x#steps",
    );
  });
});
