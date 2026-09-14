export function withoutThemeTransitions(apply: () => void) {
  const style = document.createElement("style");
  style.textContent = "*,*::before,*::after{transition:none!important}";
  document.head.append(style);
  apply();
  void document.documentElement.offsetHeight;
  requestAnimationFrame(() => requestAnimationFrame(() => style.remove()));
}
