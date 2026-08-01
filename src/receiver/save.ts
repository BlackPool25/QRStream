/**
 * Receiver-side file saving: File System Access API when available (secure
 * context), `<a download>` fallback otherwise. Pure filename/MIME helpers are
 * exported separately so they are fully Node-testable; the DOM-only paths
 * guard every `window`/`document` reference so importing this module is safe
 * under Node (vitest) and in workers.
 */

export type SaveMethod = 'fsa' | 'download'

export interface SaveResult {
  /** How the file was saved (fsa = native picker, download = anchor click). */
  readonly method: SaveMethod
  /** The actual saved name (the picker may have renamed an fsa save). */
  readonly name: string
}

export type SaveErrorCode = 'denied' | 'aborted' | 'failed'

/** Typed save error; inspect via .code, never message text. */
export class SaveError extends Error {
  override readonly name = 'SaveError'
  readonly code: SaveErrorCode

  constructor(code: SaveErrorCode, message: string) {
    super(message)
    this.code = code
  }
}

export interface SaveFileOptions {
  readonly bytes: Uint8Array
  /** Default file name (from metadata). Sanitized before use. */
  readonly filename: string
  /** MIME type used for the blob and the picker type hint. */
  readonly mime: string
  /** Optional user-chosen name that overrides `filename`. */
  readonly preferredSaveName?: string
}

/**
 * The File System Access API save-picker methods. Not part of the TS DOM lib
 * (still vendor-prefixed/behind flags in places), so declared here; the
 * structural shapes match the runtime API.
 */
declare global {
  interface Window {
    showSaveFilePicker(options?: SaveFilePickerOptions): Promise<FileSystemFileHandle>
  }
  interface SaveFilePickerOptions {
    suggestedName?: string
    types?: SaveFilePickerAcceptType[]
  }
  interface SaveFilePickerAcceptType {
    description?: string
    accept: Record<string, string | readonly string[]>
  }
}

const MAX_FILENAME_LEN = 180

/** A conservative fallback name when sanitization empties the input. */
const FALLBACK_NAME = 'file'

/**
 * Sanitizes a received file name: path separators become underscores, control
 * characters and leading dots are stripped, and the name (extension intact) is
 * truncated to at most 180 characters. Never throws.
 */
export function sanitizeFilename(name: string): string {
  // Deliberate control-character class: strips C0/C1/DEL from untrusted names.
  // eslint-disable-next-line no-control-regex
  const cleaned = name.replace(/[\u0000-\u001f\u007f-\u009f]/g, '')
  // Leading dots first, so a traversal-ish "../evil.txt" becomes "_evil.txt"
  // instead of surviving separator replacement as ".._evil.txt".
  const dotless = cleaned.replace(/^\.+/, '')
  const separated = dotless.replace(/[\\/]/g, '_')
  if (separated === '') {
    return FALLBACK_NAME
  }
  return truncateKeepingExtension(separated, MAX_FILENAME_LEN)
}

function truncateKeepingExtension(name: string, max: number): string {
  if (name.length <= max) {
    return name
  }
  const dot = name.lastIndexOf('.')
  if (dot > 0) {
    const ext = name.slice(dot)
    if (ext.length < max) {
      return name.slice(0, max - ext.length) + ext
    }
  }
  return name.slice(0, max)
}

const EXT_TO_MIME: Readonly<Record<string, string>> = {
  txt: 'text/plain',
  json: 'application/json',
  pdf: 'application/pdf',
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  gif: 'image/gif',
  webp: 'image/webp',
  mp4: 'video/mp4',
  mp3: 'audio/mpeg',
  zip: 'application/zip',
  csv: 'text/csv',
  md: 'text/markdown',
  html: 'text/html',
  htm: 'text/html',
  js: 'text/javascript',
  ts: 'application/typescript',
  svg: 'image/svg+xml',
  bin: 'application/octet-stream',
}

/**
 * Best-effort MIME type from a file name's extension (case-insensitive).
 * Unknown or missing extensions default to application/octet-stream.
 */
export function mimeFromFilename(name: string): string {
  const dot = name.lastIndexOf('.')
  if (dot < 0 || dot === name.length - 1) {
    return 'application/octet-stream'
  }
  const ext = name.slice(dot + 1).toLowerCase()
  return EXT_TO_MIME[ext] ?? 'application/octet-stream'
}

/**
 * Saves `bytes` under the given name. Prefers the File System Access API
 * (native save dialog, secure context only) and falls back to a programmatic
 * `<a download>` click. Rejections surface as a typed {@link SaveError}:
 * 'aborted' (user cancelled), 'denied' (permission/security), 'failed'.
 */
export async function saveFile(opts: SaveFileOptions): Promise<SaveResult> {
  const name = sanitizeFilename(opts.preferredSaveName ?? opts.filename)
  // Blob/write need an ArrayBuffer-backed view; callers may pass a subarray.
  const buffer = new Uint8Array(opts.bytes)

  if (typeof window !== 'undefined' && typeof window.showSaveFilePicker === 'function') {
    try {
      return await saveViaFsa(buffer, opts.mime, name)
    } catch (error) {
      throw toSaveError(error, name)
    }
  }

  if (typeof document === 'undefined' || typeof document.createElement !== 'function') {
    throw new SaveError('failed', 'no DOM available to save the file')
  }
  return saveViaDownload(buffer, opts.mime, name)
}

async function saveViaFsa(
  buffer: Uint8Array<ArrayBuffer>,
  mime: string,
  name: string,
): Promise<SaveResult> {
  const ext = extensionOf(name)
  const pickerOptions: SaveFilePickerOptions =
    ext === ''
      ? { suggestedName: name }
      : {
          suggestedName: name,
          types: [{ description: 'Received file', accept: { [mime]: [`.${ext}`] } }],
        }
  const handle = await window.showSaveFilePicker(pickerOptions)
  const writable = await handle.createWritable()
  try {
    await writable.write(buffer)
  } finally {
    await writable.close()
  }
  return { method: 'fsa', name: handle.name }
}

function saveViaDownload(buffer: Uint8Array<ArrayBuffer>, mime: string, name: string): SaveResult {
  const blob = new Blob([buffer], { type: mime })
  const url = URL.createObjectURL(blob)
  const anchor = document.createElement('a')
  anchor.href = url
  anchor.download = name
  anchor.style.display = 'none'
  document.body.appendChild(anchor)
  try {
    anchor.click()
  } finally {
    anchor.remove()
    URL.revokeObjectURL(url)
  }
  return { method: 'download', name }
}

/** "name.txt" -> "txt" (empty when the name has no extension). */
function extensionOf(name: string): string {
  const dot = name.lastIndexOf('.')
  return dot >= 0 && dot < name.length - 1 ? name.slice(dot + 1) : ''
}

function toSaveError(error: unknown, name: string): SaveError {
  if (error instanceof DOMException) {
    if (error.name === 'AbortError') {
      return new SaveError('aborted', `saving "${name}" was cancelled`)
    }
    if (error.name === 'NotAllowedError' || error.name === 'SecurityError') {
      return new SaveError('denied', `saving "${name}" was not permitted`)
    }
  }
  const detail = error instanceof Error ? error.message : String(error)
  return new SaveError('failed', `could not save "${name}": ${detail}`)
}
