// Bounded streams (docs/protocol.md, "Streams"): a method that yields many
// values, such as a location watch, read with `for await`. The host keeps
// the values in a bounded queue that drops the oldest, and the cell pulls
// them in batches with `stream.next`, so a slow cell costs a `dropped`
// count, not memory, and nothing has to push into the Worker: every
// message is an ordinary call, which cancel and interrupt already reach.

import type { CallOptions, DeviceTransport } from "./device.ts";
import { DeviceError } from "./errors.ts";

/**
 * Values from the host, in order, for `for await`. Leaving the loop
 * (`break`, `return`, a throw), aborting the signal, or interrupting the
 * kernel stops the host's source. An abort or interrupt rejects the
 * waiting `next()` with `cancelled` (`timeout` for `AbortSignal.timeout()`).
 */
export interface DeviceStream<T> extends AsyncIterableIterator<T> {
  /**
   * How many values the host dropped so far because the cell read them
   * slower than they came: it keeps the newest ones, up to a limit each
   * method sets.
   */
  readonly dropped: number;
  /** Stops the stream; `next()` then reports done. Same as leaving a `for await`. */
  return(): Promise<IteratorResult<T, undefined>>;
}

export interface StreamOptions extends CallOptions {
  /**
   * Aborted when the kernel interrupts the running cell (cdp-kernel's
   * `jupyter.signal`), so a stream stops even while the cell isn't waiting
   * on it. The `device` object fills it in; callers needn't.
   */
  cellSignal?: AbortSignal;
}

/**
 * Opens `method` as a stream on `transport`: the host answers the call
 * with `{ stream }`, then each `stream.next` with
 * `{ values, dropped, end? }`, and `stream.close` stops it. `read` checks
 * and converts each value. Nothing is sent until the first `next()`.
 */
export function openStream<T>(
  transport: DeviceTransport,
  method: string,
  params: Record<string, unknown>,
  options: StreamOptions = {},
  read: (value: unknown) => T = (value) => value as T,
): DeviceStream<T> {
  const signals = [options.signal, options.cellSignal].filter((s): s is AbortSignal => s !== undefined);
  const signal = signals.length === 0 ? undefined : signals.length === 1 ? signals[0] : AbortSignal.any(signals);
  let id: number | null = null;
  /** The host ended the stream (end, error, or a cancelled `stream.next`): nothing to close. */
  let hostEnded = false;
  let done = false;
  let dropped = 0;
  const buffer: unknown[] = [];
  /** One `next()` at a time, in order, as `for await` calls them. */
  let queue: Promise<unknown> = Promise.resolve();

  async function call(m: string, p: Record<string, unknown>, o?: CallOptions): Promise<unknown> {
    try {
      return await transport.call(m, p, o);
    } catch (err) {
      throw DeviceError.from(err);
    }
  }

  /** Tells the host to stop, once; quiet, since nothing waits on it. */
  function stop(): void {
    const wasOpen = !done;
    done = true;
    buffer.length = 0;
    signal?.removeEventListener("abort", onAbort);
    if (wasOpen && id !== null && !hostEnded) {
      hostEnded = true;
      void call("stream.close", { stream: id }).catch(() => {});
    }
  }

  // Between `next()` calls nothing is in flight for the abort to cancel,
  // so stop the source here; a `next()` in flight is cancelled by the
  // signal, and the host ends the stream for that.
  function onAbort(): void {
    if (pending > 0 || done) return;
    stop();
    stoppedByAbort = true;
  }
  /** Stopped by an abort between calls: the next `next()` rejects, as one in flight would have. */
  let stoppedByAbort = false;
  let pending = 0;
  signal?.addEventListener("abort", onAbort, { once: true });

  function aborted(): DeviceError {
    return DeviceError.from(signal?.reason ?? new DeviceError("cancelled", `${method} was cancelled`));
  }

  async function pull(): Promise<IteratorResult<T, undefined>> {
    while (true) {
      if (buffer.length > 0) return { done: false, value: read(buffer.shift()) };
      if (stoppedByAbort) throw aborted();
      // Ended by the host with nothing left to hand out, or stopped here.
      if (done || hostEnded) {
        stop();
        return { done: true, value: undefined };
      }
      if (signal?.aborted) {
        stop();
        throw aborted();
      }
      pending++;
      try {
        if (id === null) {
          const opened = await call(method, params, { signal });
          if (!isRecord(opened) || typeof opened.stream !== "number") {
            throw new DeviceError("failed", `the host's ${method} reply is malformed`);
          }
          id = opened.stream;
          // Stopped while it opened: close it now that it has an id.
          if (done) {
            void call("stream.close", { stream: id }).catch(() => {});
            hostEnded = true;
          }
          continue;
        }
        const batch = await call("stream.next", { stream: id }, { signal });
        if (done) continue;
        if (!isRecord(batch) || !Array.isArray(batch.values)) throw new DeviceError("failed", `the host's stream.next reply for ${method} is malformed`);
        if (typeof batch.dropped === "number") dropped = batch.dropped;
        buffer.push(...batch.values);
        // Values already sent are still read; then the stream is done.
        if (batch.end === true) hostEnded = true;
      } catch (err) {
        // A failed or cancelled call ends the stream on the host too.
        hostEnded = true;
        stop();
        throw err;
      } finally {
        pending--;
      }
    }
  }

  const stream: DeviceStream<T> = {
    get dropped() {
      return dropped;
    },
    next() {
      const result = queue.then(pull);
      queue = result.catch(() => {});
      return result;
    },
    async return() {
      stop();
      return { done: true, value: undefined };
    },
    [Symbol.asyncIterator]() {
      return this;
    },
  };
  return stream;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
