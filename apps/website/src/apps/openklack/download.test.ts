import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { expect, test } from "vite-plus/test";
import DownloadPage from "./pages/Download";

const command = "curl -fsSL https://openapps.space/install/openklack | sh";
const brewCommand = "brew install --cask openappshq/tap/openklack";

test("download page says the release is coming soon and offers nothing without the script", () => {
  for (const installCommand of [undefined, null]) {
    const pending = renderToStaticMarkup(
      createElement(DownloadPage, { installCommand, brewCommand: null }),
    );
    expect(pending).toContain("Mac release is coming soon");
    expect(pending).not.toContain("curl ");
    expect(pending).not.toContain("brew install");
    expect(pending).not.toContain("How do I install this?");
    expect(pending).not.toContain("Start it manually");
    expect(pending).not.toContain("download=");
    expect(pending).not.toContain("/releases");
  }
});

test("download page leads with the one-line install and a Copy button, Homebrew under it", () => {
  const html = renderToStaticMarkup(
    createElement(DownloadPage, { installCommand: command, brewCommand }),
  );
  expect(html).toContain(`<code tabindex="-1">${command}</code>`);
  expect(html).toContain('aria-label="Copy install command"');
  expect(html).toContain(`Prefer Homebrew? <code>${brewCommand}</code>`);
  expect(html).toContain("How do I install this?");
  expect(html.indexOf("How do I install this?")).toBeLessThan(html.indexOf(command));
  expect(html).toContain('href="https://github.com/openappshq/openapps/blob/main/apps/website/public/install/openklack"');
  expect(html).toContain("Paste this into Terminal");
  // No disk image to drag: the script opens the app itself.
  expect(html).not.toContain("Drag it in");
  expect(html).toContain("The command puts OpenKlack in your Applications folder");
  expect(html).not.toContain("Start it manually");
  expect(html).not.toContain("download=");
  expect(html).not.toContain("coming soon");
  expect(html).not.toContain("/releases");
});

test("download page offers the direct file beside the command when both are set", () => {
  const html = renderToStaticMarkup(
    createElement(DownloadPage, {
      installCommand: command,
      brewCommand,
      downloadUrl: "https://example.com/OpenKlack.dmg",
    }),
  );
  expect(html).toContain("Start it manually");
  expect(html).toContain('href="https://example.com/OpenKlack.dmg"');
  expect(html).toContain(command);
  expect(html).toContain("Drag it in");
  expect(html).not.toContain("coming soon");
  expect(html).not.toContain("/releases");
});

test("download page never offers a direct file without the script", () => {
  const html = renderToStaticMarkup(
    createElement(DownloadPage, {
      installCommand: null,
      brewCommand: null,
      downloadUrl: "https://example.com/OpenKlack.dmg",
    }),
  );
  expect(html).toContain("Mac release is coming soon");
  expect(html).not.toContain("https://example.com/OpenKlack.dmg");
});
