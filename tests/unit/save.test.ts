import { afterEach, describe, expect, it, vi } from 'vitest'
import { mimeFromFilename, sanitizeFilename, saveFile, SaveError } from '../../src/receiver/save'

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('sanitizeFilename', () => {
  it('turns path separators into underscores', () => {
    expect(sanitizeFilename('a/b/c.txt')).toBe('a_b_c.txt')
    expect(sanitizeFilename('a\\b.txt')).toBe('a_b.txt')
    expect(sanitizeFilename('..\\evil.txt')).toBe('_evil.txt')
  })

  it('strips leading dots (hidden files / traversal)', () => {
    expect(sanitizeFilename('..evil')).toBe('evil')
    expect(sanitizeFilename('.hidden')).toBe('hidden')
    expect(sanitizeFilename('....')).toBe('file')
  })

  it('strips control characters', () => {
    expect(sanitizeFilename('a\u0000b\u001fc.txt')).toBe('abc.txt')
    expect(sanitizeFilename('na\u007fme.txt')).toBe('name.txt')
  })

  it('truncates over-long names to 180 chars keeping the extension', () => {
    const long = 'x'.repeat(300) + '.txt'
    const sanitized = sanitizeFilename(long)
    expect(sanitized.length).toBe(180)
    expect(sanitized.endsWith('.txt')).toBe(true)
    expect(sanitized.slice(0, 176)).toBe('x'.repeat(176))
  })

  it('keeps short names intact', () => {
    expect(sanitizeFilename('photo.jpg')).toBe('photo.jpg')
  })
})

describe('mimeFromFilename', () => {
  it('maps known extensions case-insensitively', () => {
    expect(mimeFromFilename('x.png')).toBe('image/png')
    expect(mimeFromFilename('x.mp4')).toBe('video/mp4')
    expect(mimeFromFilename('x.PDF')).toBe('application/pdf')
    expect(mimeFromFilename('archive.tar.gz.txt')).toBe('text/plain')
  })

  it('defaults to application/octet-stream for unknown or missing extensions', () => {
    expect(mimeFromFilename('noext')).toBe('application/octet-stream')
    expect(mimeFromFilename('thing.zzz')).toBe('application/octet-stream')
    expect(mimeFromFilename('trailing.')).toBe('application/octet-stream')
  })
})

describe('saveFile (File System Access API)', () => {
  it('writes via showSaveFilePicker when available and returns the saved name', async () => {
    const writable = {
      write: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
    }
    const handle = { name: 'out.txt', createWritable: vi.fn().mockResolvedValue(writable) }
    const showSaveFilePicker = vi.fn().mockResolvedValue(handle)
    vi.stubGlobal('window', { showSaveFilePicker })

    const bytes = new Uint8Array([1, 2, 3])
    const result = await saveFile({
      bytes,
      filename: 'in.bin',
      mime: 'application/octet-stream',
      preferredSaveName: 'out.txt',
    })

    expect(result).toEqual({ method: 'fsa', name: 'out.txt' })
    expect(showSaveFilePicker).toHaveBeenCalledWith(
      expect.objectContaining({ suggestedName: 'out.txt' }),
    )
    expect(writable.write).toHaveBeenCalledWith(bytes)
    expect(writable.close).toHaveBeenCalledTimes(1)
  })

  it('sanitizes the suggested name for the picker', async () => {
    const writable = {
      write: vi.fn().mockResolvedValue(undefined),
      close: vi.fn().mockResolvedValue(undefined),
    }
    const handle = { name: 'safe.txt', createWritable: vi.fn().mockResolvedValue(writable) }
    const showSaveFilePicker = vi.fn().mockResolvedValue(handle)
    vi.stubGlobal('window', { showSaveFilePicker })

    const result = await saveFile({
      bytes: new Uint8Array(0),
      filename: 'a/b/secret.txt',
      mime: 'text/plain',
    })

    expect(result).toEqual({ method: 'fsa', name: 'safe.txt' })
    expect(showSaveFilePicker).toHaveBeenCalledWith(
      expect.objectContaining({ suggestedName: 'a_b_secret.txt' }),
    )
  })

  it('maps a cancelled picker to SaveError("aborted")', async () => {
    vi.stubGlobal('window', {
      showSaveFilePicker: vi.fn().mockRejectedValue(new DOMException('cancelled', 'AbortError')),
    })
    await expect(
      saveFile({ bytes: new Uint8Array(0), filename: 'x.bin', mime: 'application/octet-stream' }),
    ).rejects.toMatchObject({ name: 'SaveError', code: 'aborted' })
  })

  it('maps a denied picker to SaveError("denied")', async () => {
    vi.stubGlobal('window', {
      showSaveFilePicker: vi.fn().mockRejectedValue(new DOMException('blocked', 'NotAllowedError')),
    })
    await expect(
      saveFile({ bytes: new Uint8Array(0), filename: 'x.bin', mime: 'application/octet-stream' }),
    ).rejects.toMatchObject({ name: 'SaveError', code: 'denied' })
  })

  it('maps a write failure to SaveError("failed")', async () => {
    const writable = {
      write: vi.fn().mockRejectedValue(new Error('disk full')),
      close: vi.fn().mockResolvedValue(undefined),
    }
    const handle = { name: 'x.bin', createWritable: vi.fn().mockResolvedValue(writable) }
    vi.stubGlobal('window', { showSaveFilePicker: vi.fn().mockResolvedValue(handle) })
    await expect(
      saveFile({ bytes: new Uint8Array(0), filename: 'x.bin', mime: 'application/octet-stream' }),
    ).rejects.toMatchObject({ name: 'SaveError', code: 'failed' })
  })
})

describe('saveFile (download fallback)', () => {
  function stubDom() {
    const click = vi.fn()
    const remove = vi.fn()
    const anchor = { href: '', download: '', style: { display: '' }, click, remove }
    vi.stubGlobal('document', {
      createElement: vi.fn(() => anchor),
      body: { appendChild: vi.fn() },
    })
    vi.stubGlobal('URL', {
      createObjectURL: vi.fn(() => 'blob:mock'),
      revokeObjectURL: vi.fn(),
    })
    return { anchor, click, remove }
  }

  it('clicks a download anchor when the picker is unavailable', async () => {
    const { anchor, click, remove } = stubDom()
    // No `window` in this environment, so the fallback path is taken.

    const result = await saveFile({
      bytes: new Uint8Array([9]),
      filename: 'x.txt',
      mime: 'text/plain',
    })

    expect(result).toEqual({ method: 'download', name: 'x.txt' })
    expect(document.createElement).toHaveBeenCalledWith('a')
    expect(anchor.download).toBe('x.txt')
    expect(anchor.href).toBe('blob:mock')
    expect(anchor.style.display).toBe('none')
    expect(click).toHaveBeenCalledTimes(1)
    expect(remove).toHaveBeenCalledTimes(1)
    expect(URL.revokeObjectURL).toHaveBeenCalledWith('blob:mock')
  })

  it('throws SaveError("failed") with no DOM at all', async () => {
    // Neither window nor document exists in this environment.
    await expect(
      saveFile({ bytes: new Uint8Array(0), filename: 'x.txt', mime: 'text/plain' }),
    ).rejects.toBeInstanceOf(SaveError)
  })
})
