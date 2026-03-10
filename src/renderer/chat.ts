import { streamChatCompletion, StreamOptions } from '@api/openai-stream';
import { setVisualizerState } from './visualizer';

const chatInput = document.getElementById('chat-input') as HTMLInputElement | null;
const sendButton = document.getElementById('send-button') as HTMLButtonElement | null;
const responseLog = document.getElementById('response-log') as HTMLDivElement | null;
const statusBadge = document.getElementById('chat-status') as HTMLDivElement | null;
const offlineBadge = document.getElementById('offline-badge') as HTMLDivElement | null;
const chatPanel = document.getElementById('chat-panel') as HTMLDivElement | null;

let isOnline = true;

function updateChatStatus(text: string) {
  if (statusBadge) {
    statusBadge.textContent = text;
  }
}

function updateOfflineState(online: boolean) {
  isOnline = online;
  if (offlineBadge) {
    offlineBadge.hidden = online;
  }

  if (chatPanel) {
    if (online) {
      chatPanel.classList.remove('chat-disabled');
    } else {
      chatPanel.classList.add('chat-disabled');
    }
  }

  if (sendButton) {
    sendButton.disabled = !online;
    sendButton.title = online ? '' : 'Connect to internet to send';
  }

  if (!online) {
    updateChatStatus('Offline');
  } else if (statusBadge?.textContent === 'Offline') {
    updateChatStatus('Idle');
  }
}

async function initializeNetworkStatus() {
  if (window.holoscape?.invoke) {
    try {
      const status = await window.holoscape.invoke('network:get-status');
      updateOfflineState(status.online);
    } catch (err) {
      console.warn('Failed to get initial network status:', err);
    }
  }

  if (window.holoscape?.on) {
    window.holoscape.on('network:status', (payload) => {
      updateOfflineState(payload.online);
    });
  }
}

async function loadChatHistory(): Promise<void> {
  if (!responseLog || !window.holoscape?.invoke) {
    return;
  }

  try {
    const history = await window.holoscape.invoke('chat:get-history');
    if (history && history.length > 0) {
      history.forEach((msg) => {
        responseLog.textContent += `[${msg.role}] ${msg.content}\n`;
      });
    }
  } catch (err) {
    console.warn('Failed to load chat history:', err);
  }
}

async function handleSend() {
  if (!chatInput || !responseLog || !sendButton) {
    return;
  }

  if (!isOnline) {
    updateChatStatus('Cannot send while offline');
    return;
  }

  const prompt = chatInput.value.trim();
  if (!prompt) {
    return;
  }

  sendButton.disabled = true;
  chatInput.blur();
  responseLog.textContent += `[user] ${prompt}\n`;
  updateChatStatus('Thinking...');
  setVisualizerState('thinking');

  let tokenStreamed = false;
  try {
    const streamOptions: StreamOptions = {
      messages: [{ role: 'user', content: prompt }],
    };

    for await (const chunk of streamChatCompletion(streamOptions)) {
      if (!tokenStreamed) {
        tokenStreamed = true;
        setVisualizerState('speaking');
        updateChatStatus('Speaking');
      }
      responseLog.textContent += chunk;
      responseLog.scrollTop = responseLog.scrollHeight;
    }

    updateChatStatus('Idle');
  } catch (error) {
    responseLog.textContent = `Error: ${(error as Error).message || 'stream failed'}`;
    console.error(error);
    updateChatStatus('Error');
    setVisualizerState('error');
  } finally {
    sendButton.disabled = !isOnline;
    setVisualizerState('idle');
  }
}

sendButton?.addEventListener('click', handleSend);
chatInput?.addEventListener('keydown', (event) => {
  if (event.key === 'Enter' && !event.shiftKey) {
    event.preventDefault();
    handleSend();
  }
});

initializeNetworkStatus();
loadChatHistory();
updateChatStatus('Idle');

if (window.holoscape?.on) {
  window.holoscape.on('chat:message-added', ({ message }) => {
    if (responseLog) {
      responseLog.textContent += `[${message.role}] ${message.content}\n`;
    }
  });
}
