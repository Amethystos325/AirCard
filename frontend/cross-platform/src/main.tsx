import { createRoot } from 'react-dom/client';
import { Provider } from './state';
import App from './App';
import './theme.css';
if (import.meta.env.VITE_E2E === '1') await import('@wdio/tauri-plugin');
createRoot(document.getElementById('root')!).render(<Provider><App /></Provider>);
