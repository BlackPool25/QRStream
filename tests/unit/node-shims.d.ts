// tsconfig restricts `types` to vite/client, so @types/node is not part of
// the program. These minimal ambient declarations cover the Node builtins
// that unit tests import (zxing wasm loading, raptorq fixture loading).
// Script-mode .d.ts (no imports/exports) so `declare module` creates new
// ambient modules instead of augmenting missing ones. The shapes mirror the
// real Node API surface these tests use, so the declarations merge cleanly
// if @types/node is ever added to the program.

declare module 'node:fs' {
  interface BufferLike extends Uint8Array {
    readonly buffer: ArrayBufferLike
    readonly byteOffset: number
    readonly byteLength: number
  }
  export function readFileSync(path: string | URL): BufferLike
}

declare module 'node:module' {
  interface RequireFn {
    (specifier: string): string
    resolve(specifier: string): string
  }
  export function createRequire(filename: string | URL): RequireFn
}

declare module 'node:url' {
  export function fileURLToPath(url: string | URL): string
}
