import { MotionConfig, useReducedMotion } from "motion/react";
import { useEffect, type ReactNode } from "react";
import { withoutThemeTransitions } from "./theme";
import tokens from "../../design/tokens.json";

export function AppMotion({ children }: { children: ReactNode }) {
  const reduced = useReducedMotion();
  useEffect(() => {
    const system = matchMedia("(prefers-color-scheme: dark)");
    const change = () => withoutThemeTransitions(() => {});
    system.addEventListener("change", change);
    return () => system.removeEventListener("change", change);
  }, []);
  return (
    <MotionConfig
      reducedMotion="user"
      transition={{
        type: "tween",
        duration: reduced ? 0 : tokens.metrics["motion/standard"] / 1000,
        ease: [0.2, 0, 0, 1],
      }}
    >
      {children}
    </MotionConfig>
  );
}
