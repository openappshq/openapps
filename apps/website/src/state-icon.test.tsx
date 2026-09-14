import { renderToStaticMarkup } from "react-dom/server";
import { expect, test } from "vite-plus/test";
import { StateIcon } from "@openapps/ui/state-icon";

test("state icons remain visible on first render and without animation", () => {
  for (const isStatic of [false, true]) {
    const markup = renderToStaticMarkup(
      <StateIcon state="off" static={isStatic}>
        <svg data-icon="muted" />
      </StateIcon>,
    );
    expect(markup).toContain('data-icon="muted"');
    expect(markup).toContain('aria-hidden="true"');
    expect(markup).not.toMatch(/opacity:0|display:none|visibility:hidden/);
  }
});
