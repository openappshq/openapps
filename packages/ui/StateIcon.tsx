import { AnimatePresence, motion, useReducedMotion } from "motion/react";
import type { ReactNode } from "react";

export function StateIcon({
  state,
  children,
  static: isStatic = false,
}: {
  state: string;
  children: ReactNode;
  static?: boolean;
}) {
  const reduced = useReducedMotion();
  return (
    <span className="state-icon" aria-hidden="true">
      {isStatic || reduced ? (
        children
      ) : (
        <AnimatePresence initial={false}>
          <motion.span
            key={state}
            initial={{ opacity: 0, scale: 0.25, filter: "blur(4px)" }}
            animate={{ opacity: 1, scale: 1, filter: "blur(0px)" }}
            exit={{ opacity: 0, scale: 0.25, filter: "blur(4px)" }}
            transition={{ type: "spring", duration: 0.3, bounce: 0 }}
          >
            {children}
          </motion.span>
        </AnimatePresence>
      )}
    </span>
  );
}
