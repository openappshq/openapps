import { renderToStaticMarkup } from "react-dom/server";
import { expect, test } from "vite-plus/test";
import InstallCommand from "./InstallCommand";
import { InstallGuideContent } from "./InstallGuide";
import { brewCasksFrom, dodoConfigFrom, licensingFor } from "./licensing";

const dodo = dodoConfigFrom({
  VITE_OPENKLACK_DODO_PAID_PRODUCT_ID: "pdt_okPaid",
  VITE_OPENREACTION_DODO_PAID_PRODUCT_ID: "pdt_orPaid",
  VITE_HERTZ_DODO_PAID_PRODUCT_ID: "pdt_hzPaid",
  VITE_MACPAPER_DODO_PAID_PRODUCT_ID: "pdt_mpPaid",
});
const casks = brewCasksFrom({
  VITE_OPENKLACK_BREW_CASK: "openappshq/tap/openklack",
  VITE_OPENREACTION_BREW_CASK: "openappshq/tap/openreaction",
  VITE_HERTZ_BREW_CASK: "openappshq/tap/hertz",
  VITE_MACPAPER_BREW_CASK: "openappshq/tap/macpaper",
});

/**
 * The guide's content, as the catalog fills it in for one app. The overlay
 * itself only exists in a browser (it portals into the document), so the
 * dialog's own behaviour is checked there; this is what it says.
 */
function guideFor(app: string) {
  const licensing = licensingFor(app, { dodo, casks });
  return renderToStaticMarkup(
    <InstallGuideContent
      name={licensing.name}
      command={licensing.installCommand!}
      brewCommand={licensing.brewCommand}
      permissions={licensing.permissions}
    />,
  );
}

const headings = (html: string) => [...html.matchAll(/<h3>([^<]+)<\/h3>/g)].map((m) => m[1]);

test("closed, it is one text link above the command and nothing else", () => {
  const html = renderToStaticMarkup(
    <InstallCommand
      command="curl -fsSL https://openapps.space/install/openklack | sh"
      name="OpenKlack"
      sourceUrl="https://example.com/script"
      brewCommand="brew install --cask openappshq/tap/openklack"
      permissions={["Input Monitoring"]}
    />,
  );
  // A real button, keyboard-reachable, that says it opens something.
  const trigger = html.match(/<button [^>]*install-guide-link[^>]*>/)?.[0];
  expect(trigger).toBeDefined();
  expect(trigger).toContain('type="button"');
  expect(trigger).toContain('aria-expanded="false"');
  expect(html).toMatch(/install-guide-link[^>]*>.*How do I install this\?<\/button>/);
  expect(html.indexOf("How do I install this?")).toBeLessThan(html.indexOf("curl -fsSL"));
  // The dialog's content is not on the page until it opens: one Copy button, no steps.
  expect(html.match(/Copy</g)).toHaveLength(1);
  expect(html).not.toContain("Open Terminal");
  expect(html).not.toContain('role="dialog"');
});

test("OpenKlack: Terminal, copy, paste, wait, its one permission, then Homebrew, in that order", () => {
  const html = guideFor("openklack");
  expect(headings(html)).toEqual([
    "Open Terminal",
    "Copy the install line",
    "Paste it into Terminal",
    "Wait about ten seconds",
    "Say yes to macOS",
    "Prefer Homebrew?",
  ]);
  // Titled for the app, with the commands the catalog gives it; the line is copied from here too.
  expect(html).toContain("Install OpenKlack</h2>");
  expect(html).toContain(
    '<code tabindex="-1">curl -fsSL https://openapps.space/install/openklack | sh</code>',
  );
  expect(html).toContain('aria-label="Copy install command"');
  expect(html).toContain("<code>brew install --cask openappshq/tap/openklack</code>");
  expect(html).toContain("downloads OpenKlack, checks it, puts it in Applications and opens it");
  // The permission is named, and where help comes from.
  expect(html).toContain(
    "macOS will ask for <strong>Input Monitoring</strong> — OpenKlack’s setup guide walks you through it",
  );
  // The keys, as keys.
  expect(html).toContain("<kbd>⌘</kbd><kbd>Space</kbd>");
  expect(html).toContain("<kbd>⌘</kbd><kbd>V</kbd>");
  expect(html).toContain("<kbd>Return</kbd>");
});

test("OpenReaction's guide names both of its permissions", () => {
  const html = guideFor("openreaction");
  expect(headings(html)).toContain("Say yes to macOS");
  expect(html).toContain(
    "macOS will ask for <strong>Accessibility and Input Monitoring</strong> — OpenReaction’s setup guide",
  );
  expect(html).toContain("curl -fsSL https://openapps.space/install/openreaction | sh");
  expect(html).toContain("brew install --cask openappshq/tap/openreaction");
  expect(html).not.toContain("OpenKlack");
});

test.each(["hertz", "macpaper"])(
  "%s asks for nothing, so its guide has no permission step",
  (app) => {
    const html = guideFor(app);
    expect(headings(html)).toEqual([
      "Open Terminal",
      "Copy the install line",
      "Paste it into Terminal",
      "Wait about ten seconds",
      "Prefer Homebrew?",
    ]);
    expect(html).not.toContain("macOS will ask for");
    expect(html).toContain(`curl -fsSL https://openapps.space/install/${app} | sh`);
    expect(html).toContain(`brew install --cask openappshq/tap/${app}`);
  },
);

test("without a Homebrew line the last step goes too", () => {
  const html = renderToStaticMarkup(
    <InstallGuideContent
      name="Hertz"
      command="curl -fsSL https://openapps.space/install/hertz | sh"
    />,
  );
  expect(headings(html)).toHaveLength(4);
  expect(html).not.toContain("Prefer Homebrew?");
  expect(html).not.toContain("brew install");
});

test("the pictures are decorative; the steps carry the words", () => {
  const html = guideFor("openreaction");
  const scenes = html.match(/<svg class="ig-scene"[^>]*>/g) ?? [];
  expect(scenes).toHaveLength(4);
  for (const scene of scenes) expect(scene).toContain('aria-hidden="true"');
  // The heading is the dialog's label: react-aria wires `aria-labelledby` to this slot.
  expect(html).toMatch(/<h2[^>]*slot="title"[^>]*>Install OpenReaction<\/h2>/);
});
