import { createRoot } from 'react-dom/client'
import { App } from './app'
import { DevBridge } from './dev-bridge'
import './styles.css'

const demo = !window.tern
const bridge = window.tern ?? new DevBridge()

createRoot(document.getElementById('root')!).render(
  <App bridge={bridge} demo={demo} />
)
