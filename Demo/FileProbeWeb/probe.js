(async function () {
  'use strict';
  const config = window.__PROBE;
  const log = document.getElementById('log');
  function emit(kind, fields) {
    const row = Object.assign({kind, mode: config.mode}, fields || {});
    window.webkit.messageHandlers.originProbe.postMessage(row);
    log.textContent += JSON.stringify(row) + '\n';
  }
  let cookie = '', cookieError = '';
  try { cookie = document.cookie; } catch (error) { cookieError = String(error); }
  document.getElementById('summary').textContent = config.mode + ' · location.origin = ' + location.origin;
  emit('document', {url: location.href, locationOrigin: location.origin, cookie,
    cookieReadError: cookieError, cookieInjectionError: window.__COOKIE_INJECTION_ERROR || '',
    userAgent: navigator.userAgent, secureContext: window.isSecureContext,
    cssLoaded: getComputedStyle(document.body).backgroundColor === 'rgb(240, 245, 250)'});
  const localURL = (base, path, name) => base + path + '?run=' + encodeURIComponent(config.runID) + '&mode=' + config.mode + '&case=' + name;
  function xhrCase(test) {
    return new Promise(resolve => {
      const xhr = new XMLHttpRequest();
      xhr.open(test.method, test.url, true);
      xhr.withCredentials = false;
      xhr.timeout = 12000;
      for (const [name, value] of Object.entries(test.headers || {})) xhr.setRequestHeader(name, value);
      const done = event => resolve({event, status: xhr.status, responseURL: xhr.responseURL || '',
        bodyPreview: String(xhr.responseText || '').slice(0, 400), readable: event === 'load'});
      xhr.onload = () => done('load');
      xhr.onerror = () => done('error');
      xhr.ontimeout = () => done('timeout');
      xhr.onabort = () => done('abort');
      xhr.send(test.body || null);
    });
  }
  async function fetchCase(test) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 12000);
    try {
      const response = await fetch(test.url, {method: test.method, headers: test.headers || {},
        body: test.body || undefined, credentials: 'omit', signal: controller.signal});
      return {event: 'load', status: response.status, responseURL: response.url,
        bodyPreview: (await response.text()).slice(0, 400), readable: true};
    } catch (error) { return {event: 'error', status: 0, error: String(error), readable: false}; }
    finally { clearTimeout(timer); }
  }
  const body = JSON.stringify({requestId: 'offline-origin-probe', message: 'synthetic', encoded: 'a&b=测试+%'});
  const cases = [
    {name: 'local-fetch-get-allow', transport: 'fetch', method: 'GET', path: '/echo/allow', headers: config.headers},
    {name: 'local-fetch-head-allow', transport: 'fetch', method: 'HEAD', path: '/echo/allow', headers: config.headers},
    {name: 'local-xhr-post-allow', transport: 'xhr', method: 'POST', path: '/echo/allow', headers: config.headers, body},
    {name: 'local-fetch-post-allow', transport: 'fetch', method: 'POST', path: '/echo/allow', headers: config.headers, body},
    {name: 'local-xhr-post-no-cors', transport: 'xhr', method: 'POST', path: '/echo/no-cors', headers: config.headers, body},
    {name: 'local-xhr-post-auth412', transport: 'xhr', method: 'POST', path: '/echo/auth', headers: config.headers, body}
  ];
  const servers = [{protocol: 'http', base: config.serverBase}];
  if (config.secureServerBase) servers.push({protocol: 'https', base: config.secureServerBase});
  const tests = servers.flatMap(server => cases.map(test => Object.assign({}, test, {
    name: server.protocol + '-' + test.name,
    url: localURL(server.base, test.path, server.protocol + '-' + test.name)
  })));
  for (const target of config.targets) tests.push({name: 'int-' + target.id, transport: 'xhr', method: 'POST',
    url: target.url, headers: config.headers, body: '{}'});
  for (const test of tests) {
    emit('case-start', {name: test.name, url: test.url, method: test.method, transport: test.transport});
    const start = performance.now();
    try {
      const result = await (test.transport === 'xhr' ? xhrCase(test) : fetchCase(test));
      emit('case-result', Object.assign({name: test.name, durationMs: Math.round(performance.now() - start)}, result));
    } catch (error) { emit('case-result', {name: test.name, event: 'exception', error: String(error), status: 0, readable: false}); }
  }
  emit('complete');
}());
