import { type DecodeResult, type RgbaBuffer } from './decode'

/** Message a caller posts to a decode worker. */
export interface DecodeRequest {
  id: number
  data: RgbaBuffer
  width: number
  height: number
  formats: readonly ['QRCode']
}

/** Message a decode worker posts back. */
export interface DecodeWorkerResponse {
  id: number
  results: DecodeResult[]
  error?: string
}

/**
 * Worker count for a pool: leave one core to the main thread, cap at 4 (more
 * workers than that contend for the same wasm decode throughput), never fewer
 * than 2.
 */
export function poolSize(hwConcurrency?: number): number {
  const hardware = hwConcurrency ?? 1
  return Math.max(2, Math.min(4, Math.max(1, hardware - 1)))
}

interface PendingDecode {
  resolve: (results: DecodeResult[]) => void
  reject: (reason: unknown) => void
}

/**
 * A pool of `decode.worker.ts` workers. Decodes are dispatched round-robin,
 * correlated per-call by id, and returned as promises. The pool owns the
 * workers: call {@link dispose} when done.
 */
export class DecodePool {
  private readonly workers: Worker[]
  private readonly pending = new Map<number, PendingDecode>()
  private readonly pendingByWorker = new Map<Worker, Set<number>>()
  private nextId = 0
  private cursor = 0
  private disposed = false

  constructor(size?: number) {
    const workerCount = size === undefined ? poolSize(hardwareConcurrency()) : Math.max(2, size)
    this.workers = []
    for (let i = 0; i < workerCount; i++) {
      this.workers.push(this.spawnWorker())
    }
  }

  /**
   * Decodes QR codes from raw RGBA pixels. Transfers ownership of `data.buffer`
   * to the worker, so the buffer must not be reused after the call.
   */
  decode(data: RgbaBuffer, width: number, height: number): Promise<DecodeResult[]> {
    if (this.disposed) {
      return Promise.reject(new Error('DecodePool has been disposed'))
    }
    const id = this.nextId++
    const worker = this.nextWorker()
    const promise = new Promise<DecodeResult[]>((resolve, reject) => {
      this.pending.set(id, { resolve, reject })
      this.pendingByWorker.get(worker)?.add(id)
    })
    const request: DecodeRequest = { id, data, width, height, formats: ['QRCode'] }
    worker.postMessage(request, [data.buffer])
    return promise
  }

  /** Terminates all workers and rejects any in-flight decodes. */
  dispose(): void {
    if (this.disposed) {
      return
    }
    this.disposed = true
    for (const worker of this.workers) {
      worker.terminate()
    }
    this.workers.length = 0
    for (const pending of this.pending.values()) {
      pending.reject(new Error('DecodePool has been disposed'))
    }
    this.pending.clear()
  }

  private spawnWorker(): Worker {
    const worker = new Worker(new URL('../workers/decode.worker.ts', import.meta.url), {
      type: 'module',
    })
    this.pendingByWorker.set(worker, new Set())
    worker.onmessage = (event: MessageEvent<DecodeWorkerResponse>) =>
      this.handleMessage(worker, event)
    worker.onerror = () => this.handleWorkerError(worker)
    return worker
  }

  private nextWorker(): Worker {
    const worker = this.workers[this.cursor % this.workers.length]
    this.cursor++
    if (worker === undefined) {
      throw new Error('DecodePool has no workers')
    }
    return worker
  }

  private handleMessage(worker: Worker, event: MessageEvent<DecodeWorkerResponse>): void {
    const { id, results, error } = event.data
    const pending = this.pending.get(id)
    if (pending === undefined) {
      return
    }
    this.pending.delete(id)
    this.pendingByWorker.get(worker)?.delete(id)
    if (error !== undefined) {
      pending.reject(new Error(error))
    } else {
      pending.resolve(results)
    }
  }

  private handleWorkerError(worker: Worker): void {
    const ids = this.pendingByWorker.get(worker)
    if (ids === undefined) {
      return
    }
    for (const id of ids) {
      const pending = this.pending.get(id)
      this.pending.delete(id)
      pending?.reject(new Error('decode worker crashed'))
    }
    ids.clear()
  }
}

function hardwareConcurrency(): number | undefined {
  if (typeof navigator === 'undefined') {
    return undefined
  }
  return navigator.hardwareConcurrency
}
