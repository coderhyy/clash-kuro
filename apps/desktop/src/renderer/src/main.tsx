import { createRoot } from 'react-dom/client'
import { App } from './app'
import { DevBridge } from './dev-bridge'
import './styles.css'

const demo = !window.kuro
const bridge = window.kuro ?? new DevBridge()

createRoot(document.getElementById('root')!).render(
  <App bridge={bridge} demo={demo} />
)
