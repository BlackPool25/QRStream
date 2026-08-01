import type { ComponentChildren } from 'preact'

interface IconProps {
  readonly size?: number
}

const STROKE = {
  fill: 'none',
  stroke: 'currentColor',
  strokeWidth: 2,
  strokeLinecap: 'round',
  strokeLinejoin: 'round',
} as const

function Svg({ size = 24, children }: IconProps & { readonly children: ComponentChildren }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      aria-hidden="true"
      focusable="false"
      {...STROKE}
    >
      {children}
    </svg>
  )
}

/** Expand to fullscreen (enter). */
export function IconFullscreen({ size = 24 }: IconProps) {
  return (
    <Svg size={size}>
      <path d="M8 3H5a2 2 0 0 0-2 2v3" />
      <path d="M21 8V5a2 2 0 0 0-2-2h-3" />
      <path d="M3 16v3a2 2 0 0 0 2 2h3" />
      <path d="M16 21h3a2 2 0 0 0 2-2v-3" />
    </Svg>
  )
}

/** Collapse out of fullscreen (exit). */
export function IconMinimize({ size = 24 }: IconProps) {
  return (
    <Svg size={size}>
      <path d="M8 3v3a2 2 0 0 1-2 2H3" />
      <path d="M21 8h-3a2 2 0 0 1-2-2V3" />
      <path d="M3 16h3a2 2 0 0 1 2 2v3" />
      <path d="M16 21v-3a2 2 0 0 1 2-2h3" />
    </Svg>
  )
}

/** Boost brightness (screen wake lock / max brightness hint). */
export function IconSun({ size = 24 }: IconProps) {
  return (
    <Svg size={size}>
      <circle cx="12" cy="12" r="4" />
      <path d="M12 2v2" />
      <path d="M12 20v2" />
      <path d="M4.93 4.93l1.41 1.41" />
      <path d="M17.66 17.66l1.41 1.41" />
      <path d="M2 12h2" />
      <path d="M20 12h2" />
      <path d="M6.34 17.66l-1.41 1.41" />
      <path d="M19.07 4.93l-1.41 1.41" />
    </Svg>
  )
}

/** Stop broadcast. */
export function IconStop({ size = 24 }: IconProps) {
  return (
    <Svg size={size}>
      <rect x="6" y="6" width="12" height="12" rx="2" fill="currentColor" stroke="none" />
    </Svg>
  )
}

/** Back / leave. */
export function IconBack({ size = 24 }: IconProps) {
  return (
    <Svg size={size}>
      <path d="M19 12H5" />
      <path d="M12 19l-7-7 7-7" />
    </Svg>
  )
}

/** Restart scan (rotate counter-clockwise). */
export function IconRestart({ size = 24 }: IconProps) {
  return (
    <Svg size={size}>
      <path d="M3 12a9 9 0 1 0 2.64-6.36L3 8" />
      <path d="M3 3v5h5" />
    </Svg>
  )
}

/** Camera lens. */
export function IconCamera({ size = 24 }: IconProps) {
  return (
    <Svg size={size}>
      <path d="M14.5 4h-5L7 7H4a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2h-3l-2.5-3z" />
      <circle cx="12" cy="13" r="3" />
    </Svg>
  )
}

/** Portrait tile glyph (1×3 column layout). */
export function IconPortrait({ size = 24 }: IconProps) {
  return (
    <Svg size={size}>
      <rect x="9" y="4" width="6" height="16" rx="1.5" fill="currentColor" stroke="none" />
    </Svg>
  )
}

/** Landscape tile glyph (3×1 row layout). */
export function IconLandscape({ size = 24 }: IconProps) {
  return (
    <Svg size={size}>
      <rect x="4" y="9" width="16" height="6" rx="1.5" fill="currentColor" stroke="none" />
    </Svg>
  )
}

/** Save / download. */
export function IconSave({ size = 24 }: IconProps) {
  return (
    <Svg size={size}>
      <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />
      <path d="M7 10l5 5 5-5" />
      <path d="M12 15V3" />
    </Svg>
  )
}
