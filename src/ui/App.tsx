import { useSignal } from '@preact/signals'
import { SenderView } from './SenderView'
import { ReceiverView } from './ReceiverView'

type Mode = 'home' | 'send' | 'receive'

/** Decorative QR-style glyph: three finder patterns + scattered data modules. */
function QrGlyph() {
  const module = (x: number, y: number, s = 3) => <rect x={x} y={y} width={s} height={s} rx="0.5" />
  const finder = (x: number, y: number) => (
    <g>
      {module(x, y, 11)}
      {module(x + 4, y + 4, 3)}
    </g>
  )
  return (
    <svg width="56" height="56" viewBox="0 0 48 48" aria-hidden="true" focusable="false">
      {finder(2, 2)}
      {finder(35, 2)}
      {finder(2, 35)}
      {module(18, 2)}
      {module(23, 2)}
      {module(28, 7)}
      {module(33, 12)}
      {module(18, 7, 2)}
      {module(38, 24)}
      {module(38, 30)}
      {module(33, 36)}
      {module(28, 41)}
      {module(18, 41, 2)}
      {module(18, 36)}
      {module(23, 36)}
      {module(13, 30, 2)}
      {module(8, 24)}
      {module(13, 18, 2)}
      {module(18, 18)}
      {module(23, 23, 2)}
    </svg>
  )
}

function HomeView({
  onSend,
  onReceive,
}: {
  readonly onSend: () => void
  readonly onReceive: () => void
}) {
  return (
    <section className="home">
      <div className="brand-mark">
        <QrGlyph />
      </div>
      <h1>QRStream</h1>
      <p className="subtitle">
        Send files between devices, screen to camera. No pairing, no network, nothing leaves the
        room.
      </p>
      <div className="home-actions">
        <button
          type="button"
          className="btn btn-accent btn-lg"
          onClick={onSend}
          aria-label="Send a file"
        >
          SEND
        </button>
        <button
          type="button"
          className="btn btn-ghost btn-lg"
          onClick={onReceive}
          aria-label="Receive a file"
        >
          RECEIVE
        </button>
      </div>
      <p className="hint">
        Both devices stay offline. The sender broadcasts a QR stream; the receiver scans it.
      </p>
    </section>
  )
}

export function App() {
  const mode = useSignal<Mode>('home')
  const goHome = () => {
    mode.value = 'home'
  }
  return (
    <main className="app-shell">
      {mode.value === 'home' ? (
        <HomeView
          onSend={() => {
            mode.value = 'send'
          }}
          onReceive={() => {
            mode.value = 'receive'
          }}
        />
      ) : mode.value === 'send' ? (
        <SenderView onExit={goHome} />
      ) : (
        <ReceiverView onExit={goHome} />
      )}
    </main>
  )
}
