/**
 * Orders the floating drag-to-grant helper's shows against its hides. A show is asked
 * asynchronously — after the permission request, behind whatever the window is already doing —
 * while a hide comes from leaving the guide's step right away. A hide asked after a show must
 * win even when that show has not had its turn yet: every show asked before the hide is stale
 * and does nothing when it runs, and the hide itself is queued behind them.
 */
export type Invoke = (command: string) => Promise<unknown>;

export class PermissionHelperFlow {
  private generation = 0;
  private readonly invoke: Invoke;
  constructor(invoke: Invoke) {
    this.invoke = invoke;
  }

  /** Open System Settings: asks macOS, then shows the helper unless a hide came in the meantime. */
  request(): () => Promise<void> {
    const wanted = this.token();
    return async () => {
      await this.invoke("request_input_permission");
      if (wanted()) await this.invoke("show_permission_helper");
    };
  }

  /** "Show the helper again": shows it unless a hide came in the meantime. */
  show(): () => Promise<void> {
    const wanted = this.token();
    return async () => {
      if (wanted()) await this.invoke("show_permission_helper");
    };
  }

  /**
   * Hides the helper. Every show asked before this call is stale from now on, whether or not it
   * has run; the returned task is for the queue, after them. A failed hide has nothing to tell
   * the user.
   */
  hide(): () => Promise<void> {
    this.generation += 1;
    return async () => {
      await this.invoke("hide_permission_helper").catch(() => {});
    };
  }

  private token(): () => boolean {
    const generation = this.generation;
    return () => generation === this.generation;
  }
}
