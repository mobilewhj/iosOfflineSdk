const bootstrap = window.__OFFLINE_DEMO_BOOTSTRAP__;
fetch('payload.json').then(response => response.json()).then(payload => {
  document.getElementById('result').textContent = `Local JS, CSS and JSON loaded. User: ${bootstrap.displayName}`;
  window.webkit.messageHandlers.demoReady.postMessage({ready: payload.ok === true, injected: bootstrap.displayName === 'Demo User', origin: location.origin});
}).catch(error => window.webkit.messageHandlers.demoReady.postMessage({ready: false, error: String(error)}));
