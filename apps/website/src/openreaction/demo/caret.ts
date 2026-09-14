const MIRRORED = [
  "boxSizing",
  "width",
  "borderTopWidth",
  "borderRightWidth",
  "borderBottomWidth",
  "borderLeftWidth",
  "paddingTop",
  "paddingRight",
  "paddingBottom",
  "paddingLeft",
  "fontFamily",
  "fontSize",
  "fontWeight",
  "fontStyle",
  "letterSpacing",
  "lineHeight",
  "textTransform",
  "wordSpacing",
  "tabSize",
] as const;

export interface CaretRect {
  left: number;
  top: number;
  height: number;
}

/**
 * Measures the caret position inside a textarea or input, relative to the
 * element's border box, by laying out the same text in a hidden mirror.
 */
export function caretRect(field: HTMLTextAreaElement | HTMLInputElement, index: number): CaretRect {
  const style = getComputedStyle(field);
  const mirror = document.createElement("div");
  for (const prop of MIRRORED) mirror.style[prop] = style[prop];
  const singleLine = field instanceof HTMLInputElement;
  Object.assign(mirror.style, {
    position: "absolute",
    visibility: "hidden",
    top: "0",
    left: "-9999px",
    whiteSpace: singleLine ? "pre" : "pre-wrap",
    overflowWrap: "break-word",
    overflow: "hidden",
  });
  mirror.textContent = field.value.slice(0, index);
  const marker = document.createElement("span");
  marker.textContent = field.value.slice(index) || ".";
  mirror.appendChild(marker);
  document.body.appendChild(mirror);
  const lineHeight = parseFloat(style.lineHeight) || parseFloat(style.fontSize) * 1.4;
  const rect = {
    left: marker.offsetLeft - field.scrollLeft,
    top: marker.offsetTop - field.scrollTop,
    height: lineHeight,
  };
  mirror.remove();
  return rect;
}
