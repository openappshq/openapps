import { MotionConfig, useReducedMotion } from "motion/react";
import type { ReactNode } from "react";
import tokens from "../../design/tokens.json";

export function AppMotion({ children }: { children: ReactNode }) {
  const reduced = useReducedMotion();
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
