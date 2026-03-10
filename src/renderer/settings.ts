export async function initSettings(): Promise<void> {
  const settingsPanel = document.getElementById('settings-panel');
  if (!settingsPanel) return;

  // Check if OpenAI key is configured
  const hasKey = await window.holoscape.keychain.hasKey('openai');
  updateKeyStatus(hasKey);

  // API Key input
  const keyInput = document.getElementById('settings-api-key-input') as HTMLInputElement;
  const saveKeyBtn = document.getElementById('save-key-btn');
  const rotateKeyBtn = document.getElementById('rotate-key-btn');
  const deleteKeyBtn = document.getElementById('delete-key-btn');

  saveKeyBtn?.addEventListener('click', async () => {
    const key = keyInput.value.trim();
    if (!key) {
      showStatus('Please enter an API key', 'error');
      return;
    }

    try {
      await window.holoscape.keychain.setKey('openai', key);
      keyInput.value = '';
      updateKeyStatus(true);
      showStatus('API key saved securely', 'success');
    } catch (error) {
      console.error('Failed to save key:', error);
      showStatus('Failed to save key', 'error');
    }
  });

  rotateKeyBtn?.addEventListener('click', async () => {
    const key = keyInput.value.trim();
    if (!key) {
      showStatus('Please enter a new API key', 'error');
      return;
    }

    try {
      await window.holoscape.keychain.deleteKey('openai');
      await window.holoscape.keychain.setKey('openai', key);
      keyInput.value = '';
      showStatus('API key rotated', 'success');
    } catch (error) {
      console.error('Failed to rotate key:', error);
      showStatus('Failed to rotate key', 'error');
    }
  });

  deleteKeyBtn?.addEventListener('click', async () => {
    if (!confirm('Delete your OpenAI API key?')) return;

    try {
      await window.holoscape.keychain.deleteKey('openai');
      updateKeyStatus(false);
      showStatus('API key deleted', 'success');
    } catch (error) {
      console.error('Failed to delete key:', error);
      showStatus('Failed to delete key', 'error');
    }
  });

  // Panic button
  const panicBtn = document.getElementById('panic-btn');
  panicBtn?.addEventListener('click', async () => {
    if (!confirm('DELETE ALL API KEYS? This cannot be undone.')) return;
    if (!confirm('Are you absolutely sure?')) return;

    try {
      const count = await window.holoscape.keychain.deleteAllKeys();
      await window.holoscape.chat.clearHistory();
      await window.holoscape.settings.clearLogs();
      updateKeyStatus(false);
      showStatus(`Deleted ${count} keys, cleared history and logs`, 'success');
    } catch (error) {
      console.error('Panic wipe failed:', error);
      showStatus('Panic wipe failed', 'error');
    }
  });

  // Clear history button
  const clearHistoryBtn = document.getElementById('clear-history-btn');
  clearHistoryBtn?.addEventListener('click', async () => {
    if (!confirm('Clear all chat history?')) return;

    try {
      await window.holoscape.chat.clearHistory();
      showStatus('Chat history cleared', 'success');
    } catch (error) {
      console.error('Failed to clear history:', error);
      showStatus('Failed to clear history', 'error');
    }
  });

  // Clear logs button
  const clearLogsBtn = document.getElementById('clear-logs-btn');
  clearLogsBtn?.addEventListener('click', async () => {
    if (!confirm('Clear all logs?')) return;

    try {
      const count = await window.holoscape.settings.clearLogs();
      showStatus(`Cleared ${count} log files`, 'success');
    } catch (error) {
      console.error('Failed to clear logs:', error);
      showStatus('Failed to clear logs', 'error');
    }
  });
}

function updateKeyStatus(hasKey: boolean): void {
  const statusEl = document.getElementById('key-status');
  const rotateBtn = document.getElementById('rotate-key-btn');
  const deleteBtn = document.getElementById('delete-key-btn');

  if (statusEl) {
    statusEl.textContent = hasKey ? '✅ API key configured' : '❌ No API key';
    statusEl.className = hasKey ? 'status-ok' : 'status-missing';
  }

  if (rotateBtn) rotateBtn.style.display = hasKey ? 'inline-block' : 'none';
  if (deleteBtn) deleteBtn.style.display = hasKey ? 'inline-block' : 'none';
}

function showStatus(message: string, type: 'success' | 'error'): void {
  const statusEl = document.getElementById('settings-status');
  if (statusEl) {
    statusEl.textContent = message;
    statusEl.className = `status-message status-${type}`;
    setTimeout(() => {
      statusEl.textContent = '';
    }, 3000);
  }
}
