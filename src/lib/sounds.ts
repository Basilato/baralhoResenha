import { getPreferences } from './preferences'

/**
 * Sons da mesa, sintetizados na hora com a Web Audio API: sem arquivos para
 * baixar nem licenças. Respeitam o modo silencioso (preferences.ts).
 */
export type SoundName = 'card' | 'draw' | 'damage' | 'heal' | 'death' | 'revive' | 'turn' | 'win'

const VOLUME = 0.22

let context: AudioContext | null = null

function audio(): AudioContext | null {
  if (typeof window === 'undefined' || !('AudioContext' in window)) return null
  context ??= new AudioContext()
  // O navegador só libera o áudio depois de um toque na página.
  if (context.state === 'suspended') void context.resume().catch(() => {})
  return context
}

/**
 * O navegador só libera áudio depois de um toque ou tecla. Prepara o som no
 * primeiro gesto para que o primeiro efeito da mesa já toque.
 */
export function unlockAudioOnFirstGesture() {
  const unlock = () => {
    if (getPreferences().sound) audio()
    window.removeEventListener('pointerdown', unlock)
    window.removeEventListener('keydown', unlock)
  }
  window.addEventListener('pointerdown', unlock)
  window.addEventListener('keydown', unlock)
}

export function playSound(name: SoundName) {
  if (!getPreferences().sound) return
  const ctx = audio()
  if (!ctx || ctx.state !== 'running') return
  try {
    SOUNDS[name](ctx, ctx.currentTime)
  } catch (error) {
    // Som é enfeite: nunca pode quebrar a mesa.
    if (import.meta.env.DEV) console.warn(`Som "${name}" falhou`, error)
  }
}

function output(ctx: AudioContext) {
  const gain = ctx.createGain()
  gain.gain.value = VOLUME
  gain.connect(ctx.destination)
  return gain
}

/** Nota com ataque rápido e queda exponencial. */
function tone(
  ctx: AudioContext,
  at: number,
  {
    from,
    to = from,
    duration,
    type = 'sine',
    level = 1,
  }: { from: number; to?: number; duration: number; type?: OscillatorType; level?: number },
) {
  const osc = ctx.createOscillator()
  const env = ctx.createGain()
  osc.type = type
  osc.frequency.setValueAtTime(from, at)
  if (to !== from) osc.frequency.exponentialRampToValueAtTime(to, at + duration)
  env.gain.setValueAtTime(0.0001, at)
  env.gain.exponentialRampToValueAtTime(level, at + 0.01)
  env.gain.exponentialRampToValueAtTime(0.0001, at + duration)
  osc.connect(env).connect(output(ctx))
  osc.start(at)
  osc.stop(at + duration + 0.05)
}

/** Ruído filtrado: papel, carta deslizando, impacto. */
function noise(
  ctx: AudioContext,
  at: number,
  { duration, frequency, level = 1 }: { duration: number; frequency: number; level?: number },
) {
  const samples = Math.ceil(ctx.sampleRate * duration)
  const buffer = ctx.createBuffer(1, samples, ctx.sampleRate)
  const data = buffer.getChannelData(0)
  for (let i = 0; i < samples; i++) data[i] = Math.random() * 2 - 1
  const source = ctx.createBufferSource()
  source.buffer = buffer
  const filter = ctx.createBiquadFilter()
  filter.type = 'bandpass'
  filter.frequency.value = frequency
  const env = ctx.createGain()
  env.gain.setValueAtTime(level, at)
  env.gain.exponentialRampToValueAtTime(0.0001, at + duration)
  source.connect(filter).connect(env).connect(output(ctx))
  source.start(at)
}

const SOUNDS: Record<SoundName, (ctx: AudioContext, at: number) => void> = {
  // Carta batendo na mesa.
  card: (ctx, at) => {
    noise(ctx, at, { duration: 0.18, frequency: 2200, level: 0.8 })
    tone(ctx, at, { from: 180, to: 90, duration: 0.12, level: 0.5 })
  },
  // Cartas deslizando para a mão.
  draw: (ctx, at) => {
    noise(ctx, at, { duration: 0.08, frequency: 4000, level: 0.5 })
    noise(ctx, at + 0.09, { duration: 0.08, frequency: 4500, level: 0.5 })
  },
  // Pancada grave.
  damage: (ctx, at) => {
    tone(ctx, at, { from: 140, to: 50, duration: 0.3, type: 'triangle', level: 1 })
    noise(ctx, at, { duration: 0.12, frequency: 600, level: 0.7 })
  },
  // Duas notas brilhantes.
  heal: (ctx, at) => {
    tone(ctx, at, { from: 1047, duration: 0.35, level: 0.5 })
    tone(ctx, at + 0.1, { from: 1319, duration: 0.45, level: 0.5 })
  },
  // "Uuuu" de fantasma descendo.
  death: (ctx, at) => {
    tone(ctx, at, { from: 520, to: 140, duration: 1.1, type: 'triangle', level: 0.6 })
    tone(ctx, at + 0.05, { from: 530, to: 150, duration: 1.1, type: 'sine', level: 0.3 })
  },
  // Arpejo subindo.
  revive: (ctx, at) => {
    ;[523, 659, 784, 1047].forEach((frequency, index) =>
      tone(ctx, at + index * 0.09, { from: frequency, duration: 0.4, level: 0.5 }),
    )
  },
  // Sininho: é a sua vez.
  turn: (ctx, at) => {
    tone(ctx, at, { from: 880, duration: 0.6, level: 0.5 })
    tone(ctx, at, { from: 1760, duration: 0.4, level: 0.15 })
  },
  // Fanfarra curta.
  win: (ctx, at) => {
    ;[523, 659, 784].forEach((frequency, index) =>
      tone(ctx, at + index * 0.12, { from: frequency, duration: 0.3, type: 'square', level: 0.25 }),
    )
    tone(ctx, at + 0.4, { from: 1047, duration: 0.8, type: 'square', level: 0.3 })
  },
}
