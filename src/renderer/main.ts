import './visualizer';
import './chat';
import './preferences';
import { initSettings } from './settings';
import { initSecurityIndicator } from './security-indicator';
import { initRedSwitch } from './red-switch';
import { initConnectionSwitcher } from './connection-switcher';

// Initialize settings panel
initSettings();

// Initialize security components
initSecurityIndicator();
initRedSwitch();

// Initialize connection switcher
initConnectionSwitcher();

// Listen for preferences:open event to show settings
window.holoscape.on('preferences:open', () => {
  const settingsPanel = document.getElementById('settings-panel');
  if (settingsPanel) {
    settingsPanel.classList.toggle('hidden');
  }
});
