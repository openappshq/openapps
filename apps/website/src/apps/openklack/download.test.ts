import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { expect, test } from "vite-plus/test";
import DownloadPage from "./pages/Download";

const command = "brew install --cask openappshq/tap/openklack";

test("download page says the release is coming soon and offers nothing without a cask", () => {
  for (const brewCommand of [undefined, null]) {
    const pending = renderToStaticMarkup(createElement(DownloadPage, { brewCommand }));
    expect(pending).toContain("Mac release is coming soon");
    expect(pending).not.toContain("brew install");
    expect(pending).not.toContain("Start it manually");
    expect(pending).not.toContain("download=");
    expect(pending).not.toContain("/releases");
  }
});

test("download page leads with the brew command and a Copy button when only the cask is set", () => {
  const html = renderToStaticMarkup(createElement(DownloadPage, { brewCommand: command }));
  expect(html).toContain(`<code tabindex="-1">${command}</code>`);
  expect(html).toContain('aria-label="Copy install command"');
  expect(html).toContain('href="https://brew.sh"');
  expect(html).toContain("Paste this into Terminal");
  // No disk image to drag: Homebrew opens the app itself.
  expect(html).not.toContain("Drag it in");
  expect(html).toContain("Homebrew puts OpenKlack in your Applications folder");
  expect(html).not.toContain("Start it manually");
  expect(html).not.toContain("download=");
  expect(html).not.toContain("coming soon");
  expect(html).not.toContain("/releases");
});

test("download page offers the direct file beside the brew command when both are set", () => {
  const html = renderToStaticMarkup(
    createElement(DownloadPage, {
      brewCommand: command,
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

test("download page never offers a direct file without the cask", () => {
  const html = renderToStaticMarkup(
    createElement(DownloadPage, { brewCommand: null, downloadUrl: "https://example.com/OpenKlack.dmg" }),
  );
  expect(html).toContain("Mac release is coming soon");
  expect(html).not.toContain("https://example.com/OpenKlack.dmg");
});
