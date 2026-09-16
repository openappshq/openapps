import { describe, expect, it } from "vite-plus/test";
import { paidProducts, products } from "../catalog";
import {
  brewCasksFrom,
  brewInstallCommand,
  checkoutUrl,
  DODO_CHECKOUT_ORIGINS,
  dodoConfigFrom,
  installCommand,
  installLabel,
  installScriptSourceUrl,
  installScriptUrl,
  licensingFor,
  macDownloadUrlsFrom,
} from "./licensing";

const liveEnv = {
  VITE_OPENREACTION_DODO_PAID_PRODUCT_ID: "pdt_orPaid",
  VITE_OPENKLACK_DODO_PAID_PRODUCT_ID: "pdt_okPaid",
  VITE_HERTZ_DODO_PAID_PRODUCT_ID: "pdt_hzPaid",
  VITE_MACPAPER_DODO_PAID_PRODUCT_ID: "pdt_mpPaid",
  VITE_OPENNOTES_DODO_PAID_PRODUCT_ID: "pdt_onPaid",
};
const casks = {
  openreaction: "openappshq/tap/openreaction",
  openklack: "openappshq/tap/openklack",
  hertz: "openappshq/tap/hertz",
  macpaper: "openappshq/tap/macpaper",
  opennotes: "openappshq/tap/opennotes",
};
const downloads = {
  openreaction: "https://downloads.example/OpenReaction.dmg",
  openklack: "https://downloads.example/OpenKlack.dmg",
  hertz: "https://downloads.example/Hertz.dmg",
  macpaper: "https://downloads.example/macPaper.dmg",
  opennotes: "https://downloads.example/OpenNotes.dmg",
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
  it("reads the paid product ID per app and defaults to live checkout", () => {
    const config = dodoConfigFrom(liveEnv);
    expect(config.checkoutOrigin).toBe(DODO_CHECKOUT_ORIGINS.live);
    expect(config.products).toEqual({
      openreaction: { paid: "pdt_orPaid" },
      openklack: { paid: "pdt_okPaid" },
      hertz: { paid: "pdt_hzPaid" },
      macpaper: { paid: "pdt_mpPaid" },
      opennotes: { paid: "pdt_onPaid" },
    });
  });

  it("uses test checkout when asked, ignoring a trailing slash and whitespace", () => {
    const config = dodoConfigFrom({
      ...liveEnv,
      VITE_DODO_CHECKOUT_ORIGIN: " https://test.checkout.dodopayments.com/ ",
    });
    expect(config.checkoutOrigin).toBe(DODO_CHECKOUT_ORIGINS.test);
    expect(Object.keys(config.products)).toHaveLength(5);
  });

  it("sells nothing when the checkout origin is not Dodo's", () => {
    const config = dodoConfigFrom({ ...liveEnv, VITE_DODO_CHECKOUT_ORIGIN: "https://evil.example" });
    expect(config.checkoutOrigin).toBe(DODO_CHECKOUT_ORIGINS.live);
    expect(config.products).toEqual({});
    expect(dodoConfigFrom({ ...liveEnv, VITE_DODO_CHECKOUT_ORIGIN: "///" }).products).toEqual({});
  });

  it("sells an app on its paid ID alone, skipping missing or malformed IDs", () => {
    const config = dodoConfigFrom({
      VITE_OPENREACTION_DODO_PAID_PRODUCT_ID: "pdt_orPaid",
      VITE_OPENKLACK_DODO_PAID_PRODUCT_ID: "not-an-id",
      VITE_OPENKLACK_DODO_TRIAL_PRODUCT_ID: "pdt_okTrial",
    });
    expect(config.products).toEqual({ openreaction: { paid: "pdt_orPaid" } });
    expect(dodoConfigFrom({}).products).toEqual({});
  });
});

describe("brewCasksFrom", () => {
  it("reads each app's cask as owner/tap/name, trimming whitespace", () => {
    expect(
      brewCasksFrom({
        VITE_OPENKLACK_BREW_CASK: ` ${casks.openklack} `,
        VITE_OPENREACTION_BREW_CASK: casks.openreaction,
        VITE_HERTZ_BREW_CASK: casks.hertz,
        VITE_MACPAPER_BREW_CASK: casks.macpaper,
        VITE_OPENNOTES_BREW_CASK: casks.opennotes,
      }),
    ).toEqual(casks);
    expect(brewCasksFrom({ VITE_OPENKLACK_BREW_CASK: "open-apps/tap-2/open-klack" })).toEqual({
      openklack: "open-apps/tap-2/open-klack",
    });
  });

  it.each([
    "",
    "openklack",
    "openappshq/openklack",
    "openappshq/tap/openklack/extra",
    "OpenAppsHQ/tap/openklack",
    "openappshq/tap/open klack",
    "openappshq/tap/openklack.rb",
    "openappshq/tap/openklack; rm -rf /",
    "/tap/openklack",
    "openappshq//openklack",
  ])("treats a malformed cask as unset: %j", (bad) => {
    expect(brewCasksFrom({ VITE_OPENKLACK_BREW_CASK: bad })).toEqual({});
  });

  it("writes the exact Homebrew line", () => {
    expect(brewInstallCommand(casks.openreaction)).toBe(
      "brew install --cask openappshq/tap/openreaction",
    );
  });
});

describe("installCommand", () => {
  it("writes the exact line a visitor pastes, fetching the served script", () => {
    expect(installScriptUrl("openreaction")).toBe("https://openapps.space/install/openreaction");
    expect(installCommand("openreaction")).toBe(
      "curl -fsSL https://openapps.space/install/openreaction | sh",
    );
    expect(installCommand("hertz")).toBe("curl -fsSL https://openapps.space/install/hertz | sh");
  });

  it("points at the committed script for reading", () => {
    expect(installScriptSourceUrl("hertz")).toBe(
      "https://github.com/openappshq/openapps/blob/main/apps/website/public/install/hertz",
    );
  });
});

describe("licensingFor", () => {
  const dodo = dodoConfigFrom(liveEnv);

  it("sells every app in the catalog; none is free today", () => {
    expect(paidProducts).toEqual(products);
    expect(products.some((product) => product.free)).toBe(false);
  });

  it("sells Hertz on the same gate as the others: its own product ID and cask, or nothing", () => {
    const live = licensingFor("hertz", { dodo, casks, downloads: {} });
    expect(live.available).toBe(true);
    expect(live.scheme).toBe("hertz");
    expect(live.brewCommand).toBe("brew install --cask openappshq/tap/hertz");
    expect(live.buyUrl).toContain(`${DODO_CHECKOUT_ORIGINS.live}/buy/pdt_hzPaid?`);
    expect(live.thanksUrl).toBe("https://openapps.space/hertz/thanks/");
    // Another app's variables never sell Hertz.
    const others = dodoConfigFrom({
      VITE_OPENKLACK_DODO_PAID_PRODUCT_ID: "pdt_okPaid",
      VITE_OPENREACTION_DODO_PAID_PRODUCT_ID: "pdt_orPaid",
    });
    const noHertzCask = brewCasksFrom({
      VITE_OPENKLACK_BREW_CASK: casks.openklack,
      VITE_OPENREACTION_BREW_CASK: casks.openreaction,
    });
    for (const override of [{ dodo: others }, { casks: noHertzCask }, { dodo: others, casks: noHertzCask }]) {
      const closed = licensingFor("hertz", { dodo, casks, ...override });
      expect(closed.available).toBe(false);
      expect(closed.buyUrl).toBeNull();
      expect(closed.brewCommand).toBeNull();
    }
  });

  it("sells an app once its paid product and cask are set, with the script as the install path and brew beside it", () => {
    for (const product of paidProducts) {
      const licensing = licensingFor(product.id, { dodo, casks, downloads: {} });
      expect(licensing.available, product.id).toBe(true);
      expect(licensing.buyUrl, product.id).not.toBeNull();
      expect(licensing.installCommand, product.id).toBe(
        `curl -fsSL https://openapps.space/install/${product.id} | sh`,
      );
      expect(licensing.installScriptSourceUrl, product.id).toBe(installScriptSourceUrl(product.id));
      expect(licensing.brewCask, product.id).toBe(casks[product.id as keyof typeof casks]);
      expect(licensing.brewCommand, product.id).toBe(
        `brew install --cask ${casks[product.id as keyof typeof casks]}`,
      );
      // No direct installer configured: the command is the only way in, and that is fine.
      expect(licensing.downloadUrl, product.id).toBeNull();
      expect(installLabel(licensing)).toBe("Install for Mac");
    }
  });

  it("adds the direct download beside the command when one is configured", () => {
    for (const product of paidProducts) {
      const licensing = licensingFor(product.id, { dodo, casks, downloads });
      expect(licensing.available, product.id).toBe(true);
      expect(licensing.installCommand, product.id).not.toBeNull();
      expect(licensing.brewCommand, product.id).not.toBeNull();
      expect(licensing.downloadUrl, product.id).toBe(downloads[product.id as keyof typeof downloads]);
      expect(installLabel(licensing)).toBe("Download for Mac");
    }
  });

  it.each([
    ["with no paid product ID (cask only)", { dodo: dodoConfigFrom({}) }],
    ["with a malformed paid product ID", { dodo: dodoConfigFrom({ VITE_OPENKLACK_DODO_PAID_PRODUCT_ID: "nope", VITE_OPENREACTION_DODO_PAID_PRODUCT_ID: "nope", VITE_HERTZ_DODO_PAID_PRODUCT_ID: "nope" }) }],
    ["with no cask (product only)", { casks: {} }],
    ["with a malformed cask", { casks: brewCasksFrom({ VITE_OPENKLACK_BREW_CASK: "openklack", VITE_OPENREACTION_BREW_CASK: "OpenAppsHQ/tap/openreaction", VITE_HERTZ_BREW_CASK: "hertz.rb" }) }],
    ["with neither product nor cask", { dodo: dodoConfigFrom({}), casks: {} }],
    ["with only a direct download", { dodo: dodoConfigFrom({}), casks: {}, downloads }],
    ["with a product and a download but no cask", { casks: {}, downloads }],
  ])("fails closed %s: no checkout, no command, no download, not available", (_, override) => {
    for (const product of paidProducts) {
      const licensing = licensingFor(product.id, { dodo, casks, downloads, ...override });
      expect(licensing.available, product.id).toBe(false);
      expect(licensing.buyUrl, product.id).toBeNull();
      expect(licensing.brewCask, product.id).toBeNull();
      expect(licensing.installCommand, product.id).toBeNull();
      expect(licensing.brewCommand, product.id).toBeNull();
      expect(licensing.downloadUrl, product.id).toBeNull();
    }
  });

  it("reads installer URLs from the environment, https only", () => {
    expect(
      macDownloadUrlsFrom({
        VITE_OPENKLACK_MAC_DOWNLOAD_URL: ` ${downloads.openklack} `,
        VITE_OPENREACTION_MAC_DOWNLOAD_URL: downloads.openreaction,
        VITE_HERTZ_MAC_DOWNLOAD_URL: downloads.hertz,
        VITE_MACPAPER_MAC_DOWNLOAD_URL: downloads.macpaper,
        VITE_OPENNOTES_MAC_DOWNLOAD_URL: downloads.opennotes,
      }),
    ).toEqual(downloads);
    for (const bad of ["", "http://x.example/a.dmg", "/OpenKlack.dmg", "javascript:alert(1)", "not a url"]) {
      expect(macDownloadUrlsFrom({ VITE_OPENKLACK_MAC_DOWNLOAD_URL: bad }), bad).toEqual({});
    }
  });

  it("offers no direct download for an http installer URL, but still sells via brew", () => {
    const http = macDownloadUrlsFrom({
      VITE_OPENKLACK_MAC_DOWNLOAD_URL: "http://downloads.example/OpenKlack.dmg",
      VITE_OPENREACTION_MAC_DOWNLOAD_URL: "http://downloads.example/OpenReaction.dmg",
      VITE_HERTZ_MAC_DOWNLOAD_URL: "http://downloads.example/Hertz.dmg",
    });
    for (const product of paidProducts) {
      const licensing = licensingFor(product.id, { dodo, casks, downloads: http });
      expect(licensing.available, product.id).toBe(true);
      expect(licensing.downloadUrl, product.id).toBeNull();
    }
  });

  it("links the configured product ID to the configured checkout", () => {
    const test = dodoConfigFrom({ ...liveEnv, VITE_DODO_CHECKOUT_ORIGIN: DODO_CHECKOUT_ORIGINS.test });
    const licensing = licensingFor("openreaction", { dodo: test, casks });
    expect(licensing.buyUrl).toMatch(/^https:\/\/test\.checkout\.dodopayments\.com\/buy\/pdt_orPaid\?/);
  });

  it("returns paid checkout to the thanks page and offers no trial checkout", () => {
    for (const product of paidProducts) {
      const licensing = licensingFor(product.id, { dodo, casks });
      const ids = dodo.products[product.id];
      expect(ids, product.id).toBeDefined();
      expect(licensing.buyUrl, product.id).toContain(`${DODO_CHECKOUT_ORIGINS.live}/buy/${ids!.paid}?`);
      expect(licensing.thanksUrl).toBe(`https://openapps.space${product.route}/thanks/`);
      expect(licensing.buyUrl).toContain(encodeURIComponent(licensing.thanksUrl));
      expect(licensing.downloadPageUrl).toBe(`${product.route}/download/`);
      expect(licensing).not.toHaveProperty("trialUrl");
      expect(licensing).not.toHaveProperty("trialThanksUrl");
    }
  });

  it("has no on/off list in code: the environment alone decides", () => {
    for (const product of paidProducts) {
      const licensing = licensingFor(product.id);
      // The test environment sets no VITE_ variables, so nothing is on sale.
      expect(licensing.available, product.id).toBe(false);
      expect(licensing).not.toHaveProperty("officialBuildAvailable");
    }
  });

  it("quotes each app's own price rather than one price for the catalogue", () => {
    for (const product of paidProducts) {
      expect(product.price, product.id).toMatch(/^\$\d/);
      expect(licensingFor(product.id).price, product.id).toBe(product.price);
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
