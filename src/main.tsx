import { render } from 'preact'
import { App } from './app'
import { wasmAssets } from './wasm-assets'
import './styles.css'

// Keep the codec wasm `?url` imports alive (anti-tree-shake) so both files
// reach dist/assets/ and the SW precache.
void wasmAssets

const container = document.getElementById('app')
if (container === null) {
  throw new Error('Missing #app mount point in index.html')
}

render(<App />, container)
