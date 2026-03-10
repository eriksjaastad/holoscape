const overlay = document.getElementById('prefs-overlay');
const closeButtons = Array.from(
  document.querySelectorAll('#prefs-close, #prefs-close-bottom')
) as HTMLButtonElement[];

function showPreferences(): void {
  if (!overlay) return;
  overlay.removeAttribute('hidden');
}

function hidePreferences(): void {
  if (!overlay) return;
  overlay.setAttribute('hidden', 'true');
}

closeButtons.forEach((button) => {
  button.addEventListener('click', hidePreferences);
});

document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') {
    hidePreferences();
  }
});

if (window.holoscape?.on) {
  window.holoscape.on('preferences:open', () => {
    showPreferences();
  });
}
