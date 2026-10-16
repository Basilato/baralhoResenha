import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { App } from '@/app/App'
import { applyMotion } from '@/lib/preferences'
import { unlockAudioOnFirstGesture } from '@/lib/sounds'
import './index.css'

applyMotion()
unlockAudioOnFirstGesture()

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
