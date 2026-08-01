import { render } from 'preact'
import { App } from './app'
import './styles.css'

const container = document.getElementById('app')
if (container === null) {
  throw new Error('Missing #app mount point in index.html')
}

render(<App />, container)
