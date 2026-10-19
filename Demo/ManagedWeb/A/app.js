(function () {
  'use strict';
  const bootstrap = window.__OFFLINE_DEMO_BOOTSTRAP__ || {};
  const report = {package:window.__PACKAGE_SENTINEL__, protocol:location.protocol, origin:location.origin,
    bootstrap:bootstrap.displayName === 'Synthetic Demo', apiBaseExplicit:bootstrap.apiBase.indexOf('http://127.0.0.1:') === 0};
  document.getElementById('version').textContent = '当前页面固定包 ' + report.package;
  try { localStorage.setItem('managed-demo', 'synthetic-preserved'); report.storageBefore = localStorage.getItem('managed-demo') === 'synthetic-preserved'; }
  catch (_) { report.storageBefore = false; report.storageUnavailable = true; }
  function getMessage(name) {
    const value = name === '_demoUser' ? bootstrap.user : bootstrap.device;
    if (value) return {value:value, source:'bootstrap'};
    try {
      const match = document.cookie.match(new RegExp('(?:^|; )' + name + '=([^;]*)'));
      return {value:match ? JSON.parse(decodeURIComponent(match[1])) : null, source:'cookie'};
    } catch (_) { return {value:null, source:'unavailable'}; }
  }
  const user = getMessage('_demoUser'), device = getMessage('_demoDevice');
  window._demoUser = user.value; window.device = device.value;
  report.userSource = user.source; report.deviceSource = device.source;
  report.userIdentity = window._demoUser ? window._demoUser.userID : null;
  report.deviceAdapted = !!window.device && window.device.plat === 'iOS';
  try { report.documentCookie = document.cookie.indexOf('_demoDevice=') >= 0; }
  catch (_) { report.documentCookie = false; }
  function request(url, headers, method, body) {
    return new Promise(resolve => {
      const xhr = new XMLHttpRequest();
      xhr.open(method || 'GET', url, true);
      xhr.timeout = 15000;
      for (const key in headers || {}) xhr.setRequestHeader(key, headers[key]);
      xhr.onload = () => resolve({status:xhr.status, text:xhr.responseText, range:xhr.getResponseHeader('Content-Range')});
      xhr.onerror = () => resolve({status:0, error:'xhr-network'});
      xhr.ontimeout = () => resolve({status:0, error:'xhr-timeout'});
      xhr.send(body || null);
    });
  }
  function script(path) {
    return new Promise(resolve => {
      const node = document.createElement('script'); node.src = path;
      node.onload = () => resolve(true); node.onerror = () => resolve(false);
      document.head.appendChild(node);
    });
  }
  function setupWebViewJavascriptBridge(callback) {
    if (window.WebViewJavascriptBridge) return callback(window.WebViewJavascriptBridge);
    if (window.WVJBCallbacks) return window.WVJBCallbacks.push(callback);
    window.WVJBCallbacks = [callback];
    const iframe = document.createElement('iframe'); iframe.style.display = 'none';
    iframe.src = 'https://__bridge_loaded__'; document.documentElement.appendChild(iframe);
    setTimeout(() => document.documentElement.removeChild(iframe), 0);
  }
  let bridge;
  const bridgeReady = new Promise(resolve => setupWebViewJavascriptBridge(value => {
    bridge = value;
    bridge.registerHandler('demoToJs', (data, callback) => { report.nativeToJS = data.kind === 'synthetic-native'; callback({received:true}); });
    bridge.callHandler('demoEcho', {kind:'synthetic-js'}, reply => { report.jsToNative = reply.kind === 'synthetic-native'; resolve(); });
  }));
  async function checks() {
    const local = await request('payload.json?case=initial');
    report.localXHR = local.status === 200 && JSON.parse(local.text || '{}').package === report.package;
    report.missingScript = await script('missing.js?case=missing');
    report.missingSource = window.__MISSING_SOURCE__;
    report.redirectScript = await script('redirect.js?case=redirect');
    report.redirectSource = window.__REDIRECT_SOURCE__;
    const range = await request('range.txt?case=range', {Range:'bytes=0-3'});
    report.range206 = range.status === 206 && range.text === '0123'; report.rangeStatus = range.status; report.rangeHeader = range.range;
    const api = await request(bootstrap.apiBase + '/api/echo', {
      'Content-Type':'application/json', 'X-AUTH-TOKEN':'synthetic-token', 'X-APP_VERSION':'synthetic-version',
      'X-APP-PLAT':'iOS', 'CONTAINER':'H5', 'X-THIRD-TOKEN':'synthetic-third', 'CHANNEL':'synthetic-channel'
    }, 'POST', JSON.stringify({requestId:'isolated-test', message:'synthetic'}));
    report.apiPOST = api.status === 200 && JSON.parse(api.text || '{}').accepted === true; report.apiStatus = api.status;
    await bridgeReady;
    bridge.callHandler('demoReport', Object.assign({kind:'initial'}, report));
    document.getElementById('result').textContent = JSON.stringify(report, null, 2);
  }
  window.runLaterProbe = async function (kind) {
    const response = await request('payload.json?case=' + encodeURIComponent(kind));
    let packageName = null; try { packageName = JSON.parse(response.text || '{}').package; } catch (_) {}
    let retained = false; try { retained = localStorage.getItem('managed-demo') === 'synthetic-preserved'; } catch (_) {}
    const result = {kind:kind, pagePackage:report.package, responsePackage:packageName, status:response.status, storageRetained:retained,
      bootstrapRetained:window.__OFFLINE_DEMO_BOOTSTRAP__.displayName === 'Synthetic Demo', userIdentity:window._demoUser ? window._demoUser.userID : null};
    bridge.callHandler('demoReport', result); return result;
  };
  checks().catch(() => { report.scriptFailure = true; if (bridge) bridge.callHandler('demoReport', Object.assign({kind:'initial'}, report)); });
})();
