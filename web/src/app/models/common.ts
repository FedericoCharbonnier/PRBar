import { ActionFailure, type ActionError } from "../actions";
import type { AppContext } from "../context";
import { splitPRId } from "../format";
import type { PRHeaderVM } from "../../ui/screens/types";
import type { AppCommand, ResultOf } from "../../protocol/commands";
import type { RunOptions } from "../actions";

// Piezas que comparten los modelos de detalle de PR.

/** Manda un comando y muestra el error (salvo Face ID cancelado). Devuelve el resultado o `undefined`. */
export async function perform<C extends AppCommand, R = ResultOf<C>>(ctx: AppContext, command: C, options: RunOptions & {
  onError?: (error: ActionError) => boolean | void;
} = {}): Promise<R | undefined> {
  try {
    const result: unknown = await ctx.runner.run(command, options);
    return result as R;
  } catch (error) {
    const failure = error instanceof ActionFailure ? error.error : { kind: "failed" as const, message: String(error) };
    if (options.onError?.(failure) === true) return undefined;
    if (failure.kind !== "cancelled") ctx.ui.alert(failure.message);
    return undefined;
  }
}

/** `acme/api #317` + título (del PR en `home` o en su detalle). */
export function prHeader(ctx: AppContext, pr: string, title?: string): PRHeaderVM {
  const info = ctx.store.prInfo(pr);
  const { repo, number } = splitPRId(pr);
  return { repoFull: info?.repo ?? repo, number: info?.number ?? number, title: title ?? info?.title ?? "" };
}

/** Pregunta lo que pide la Mac (`confirmationRequired`) y, si acepta, manda `confirmed: true`. */
export async function undoWithConfirmation(ctx: AppContext, pr: string, after?: () => Promise<void> | void): Promise<void> {
  let question: string | null = null;
  const done = await perform(ctx, { chatUndo: { pr, confirmed: false } }, {
    onError: (error) => {
      if (error.kind !== "needsConfirmation") return false;
      question = error.message;
      return true;
    },
  });
  if (done) {
    await after?.();
    return;
  }
  if (question === null) return;
  const ok = await ctx.ui.confirm({ title: "Undo Claude’s changes?", message: question, confirmLabel: "Undo",
                                    cancelLabel: "Cancel", destructive: true });
  if (!ok) return;
  if (await perform(ctx, { chatUndo: { pr, confirmed: true } })) await after?.();
}
