import qrcodegen from '@ribpay/qr-code-generator'

/**
 * QR error-correction level names, mapped to the qrcodegen port's Ecc
 * instances. Default is LOW: byte payloads get the largest data capacity,
 * which the two transfer profiles rely on (V27-L fits 1465 bytes).
 */
export type QrEcc = 'LOW' | 'MEDIUM' | 'QUARTILE' | 'HIGH'

export interface QrMatrix {
  /** Row-major module matrix; 1 = dark, 0 = light. Length = size * size. */
  modules: Uint8Array
  /** Side length in modules. */
  size: number
}

export interface EncodeOpts {
  /** Exact QR version to use; otherwise the smallest fitting version is picked. */
  version?: number
  /** Error-correction level, default 'LOW'. */
  ecc?: QrEcc
}

/** Largest byte payload a single QR code can hold (version 40, Ecc.LOW). */
export const MAX_CAPACITY = 2953

/** Version used by the grid profile (fits 1465 bytes at Ecc.LOW). */
export const GRID_VERSION = 27

/** Largest byte payload encodable at {@link GRID_VERSION} with Ecc.LOW. */
export const GRID_CAPACITY = 1465

/** Thrown when a payload does not fit in the requested (or maximum) version. */
export class DataTooLongError extends RangeError {
  constructor(
    readonly dataLen: number,
    readonly version: number,
  ) {
    super(`Data too long: ${dataLen} bytes do not fit in QR version ${version} at Ecc.LOW`)
    this.name = 'DataTooLongError'
  }
}

const ECC: Record<QrEcc, qrcodegen.QrCode.Ecc> = {
  LOW: qrcodegen.QrCode.Ecc.LOW,
  MEDIUM: qrcodegen.QrCode.Ecc.MEDIUM,
  QUARTILE: qrcodegen.QrCode.Ecc.QUARTILE,
  HIGH: qrcodegen.QrCode.Ecc.HIGH,
}

/**
 * The qrcodegen port throws `RangeError("Data too long")` (and nothing else)
 * when a payload exceeds a version's capacity. Narrow on that so real bugs are
 * not swallowed by the version-scan in {@link fitVersion}.
 */
function isDataTooLong(err: unknown): boolean {
  return err instanceof RangeError && /data too long/i.test(err.message)
}

function encodeAtVersion(data: Uint8Array, version: number, ecc: QrEcc): qrcodegen.QrCode {
  return qrcodegen.QrCode.encodeSegments(
    // the port types makeBytes as readonly number[]; spread the Uint8Array
    [qrcodegen.QrSegment.makeBytes([...data])],
    ECC[ecc],
    version,
    version,
    2, // forced mask: ~10x faster than auto-mask selection (0.77ms vs 8.3ms at V27)
    false, // boostEcl=false keeps the requested Ecc level
  )
}

/** Smallest version 1..40 that fits `dataLen` bytes at the given Ecc level. */
export function fitVersion(dataLen: number, ecc: QrEcc): number {
  // Byte-mode bit length is independent of the payload values, so zeroed
  // probe bytes have the same capacity requirement as any real payload.
  const probe = new Uint8Array(dataLen)
  for (let version = 1; version <= qrcodegen.QrCode.MAX_VERSION; version++) {
    try {
      encodeAtVersion(probe, version, ecc)
      return version
    } catch (err) {
      if (!isDataTooLong(err)) throw err
      // version too small; try the next one
    }
  }
  throw new DataTooLongError(dataLen, qrcodegen.QrCode.MAX_VERSION)
}

/**
 * Encode raw packet bytes into a QR module matrix.
 *
 * Byte-oriented (no DOM types) so it runs in Node tests and in the browser
 * sender loop alike.
 */
export function encodeQrBytes(data: Uint8Array, opts?: EncodeOpts): QrMatrix {
  const ecc = opts?.ecc ?? 'LOW'
  const version = opts?.version ?? fitVersion(data.length, ecc)
  let qr: qrcodegen.QrCode
  try {
    qr = encodeAtVersion(data, version, ecc)
  } catch (err) {
    if (isDataTooLong(err)) throw new DataTooLongError(data.length, version)
    throw err
  }
  const { size } = qr
  const modules = new Uint8Array(size * size)
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      modules[y * size + x] = qr.getModule(x, y) ? 1 : 0
    }
  }
  return { modules, size }
}
