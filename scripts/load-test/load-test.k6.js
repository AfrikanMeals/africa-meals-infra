/**
 * Wise Eat — charge API + WebSocket (STOMP) + panorama endpoints.
 *
 * Prérequis : k6 (https://k6.io) — brew install k6
 *
 * Variables (voir .env.example) :
 *   LOAD_TEST_API_BASE, LOAD_TEST_WS_BASE, LOAD_TEST_EMAIL, LOAD_TEST_PASSWORD
 *   LOAD_TEST_VUS, LOAD_TEST_DURATION, LOAD_TEST_RAMP_UP, LOAD_TEST_RAMP_DOWN
 *   LOAD_TEST_TARGET=api|ws|both
 *   LOAD_TEST_HTTP_TIMEOUT (défaut 60s), LOAD_TEST_WS_CONNECT_TIMEOUT_MS (défaut 60000)
 *   LOAD_TEST_WS_HOLD_SECONDS, LOAD_TEST_AUTH_TOKEN (optionnel, évite /auth/login)
 */
import http from 'k6/http';
import ws from 'k6/ws';
import { check, group, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const apiBase = (__ENV.LOAD_TEST_API_BASE || 'https://api.wise-eat.com/api').replace(
  /\/+$/,
  '',
);
const wsBase = (__ENV.LOAD_TEST_WS_BASE || 'https://ws.wise-eat.com').replace(/\/+$/, '');
const target = (__ENV.LOAD_TEST_TARGET || 'both').toLowerCase();
const httpTimeout = __ENV.LOAD_TEST_HTTP_TIMEOUT || '60s';
const wsConnectTimeoutMs = Number(__ENV.LOAD_TEST_WS_CONNECT_TIMEOUT_MS || 60_000);
const wsHoldSeconds = Number(__ENV.LOAD_TEST_WS_HOLD_SECONDS || 25);
const thinkTimeSeconds = Number(__ENV.LOAD_TEST_THINK_TIME_SECONDS || 1);

const vus = Number(__ENV.LOAD_TEST_VUS || 10);
const rampUp = __ENV.LOAD_TEST_RAMP_UP || '30s';
const duration = __ENV.LOAD_TEST_DURATION || '1m';
const rampDown = __ENV.LOAD_TEST_RAMP_DOWN || '15s';
const httpFailThreshold = Number(__ENV.LOAD_TEST_HTTP_FAIL_THRESHOLD || 0.1);
const httpP95ThresholdMs = Number(__ENV.LOAD_TEST_HTTP_P95_MS || 60000);
const dryRunEnabled =
  String(__ENV.LOAD_TEST_DRY_RUN || 'false').trim().toLowerCase() === 'true' ||
  String(__ENV.LOAD_TEST_DRY_RUN || '').trim() === '1';
const dryRunSecret = String(__ENV.LOAD_TEST_DRY_RUN_SECRET || '').trim();

const wsConnectDuration = new Trend('ws_stomp_connect_duration', true);
const wsConnectFailures = new Counter('ws_stomp_connect_failures');
const loginFailures = new Rate('login_setup_failures');

/** Endpoints API — lecture seule, parcours client mobile + config publique. */
const API_PUBLIC_ENDPOINTS = [
  { group: 'api-root', name: 'GET /', path: '/', ok: [200] },
  { group: 'api-health', name: 'GET /health', path: '/health', ok: [200] },
  {
    group: 'api-health',
    name: 'GET /health/infra',
    path: '/health/infra',
    ok: [200],
  },
  {
    group: 'platform',
    name: 'GET /platform/mobile-app-settings',
    path: '/platform/mobile-app-settings',
    ok: [200],
  },
  {
    group: 'platform',
    name: 'GET /platform/feature-modules',
    path: '/platform/feature-modules',
    ok: [200],
  },
  {
    group: 'platform',
    name: 'GET /platform/theme-settings',
    path: '/platform/theme-settings',
    ok: [200],
  },
  {
    group: 'platform',
    name: 'GET /platform/maintenance-mode',
    path: '/platform/maintenance-mode',
    ok: [200],
  },
  {
    group: 'platform',
    name: 'GET /platform/business-types',
    path: '/platform/business-types',
    ok: [200],
  },
  {
    group: 'platform',
    name: 'GET /platform/shipping-settings',
    path: '/platform/shipping-settings',
    ok: [200],
  },
  {
    group: 'catalog',
    name: 'GET /supported-countries',
    path: '/supported-countries',
    ok: [200],
  },
  {
    group: 'catalog',
    name: 'GET /supported-countries/region-settings',
    path: '/supported-countries/region-settings',
    ok: [200],
  },
  {
    group: 'search',
    name: 'GET /search (stores)',
    path: '/search?searchContent=stores&page=1&take=12',
    ok: [200],
  },
  {
    group: 'marketing',
    name: 'GET /marketing-offer-deals/feed',
    path: '/marketing-offer-deals/feed?take=5',
    ok: [200],
    auth: 'optional',
  },
];

const API_AUTH_ENDPOINTS = [
  { group: 'auth', name: 'GET /auth/me', path: '/auth/me', ok: [200] },
  {
    group: 'auth',
    name: 'GET /auth/me/rewards',
    path: '/auth/me/rewards',
    ok: [200],
  },
  { group: 'cart', name: 'GET /cart', path: '/cart', ok: [200] },
  {
    group: 'orders',
    name: 'GET /orders',
    path: '/orders?page=1&take=10',
    ok: [200],
  },
  {
    group: 'orders',
    name: 'GET /orders/cancel-reasons',
    path: '/orders/cancel-reasons',
    ok: [200],
  },
  {
    group: 'addresses',
    name: 'GET /addresses/me',
    path: '/addresses/me',
    ok: [200],
  },
  {
    group: 'notifications',
    name: 'GET /notifications/inbox',
    path: '/notifications/inbox?take=20',
    ok: [200],
  },
];

/** REST africa-meals-ws (même JWT que l’API). */
const WS_HTTP_ENDPOINTS = [
  {
    group: 'ws-health',
    name: 'GET ws /api/health',
    path: '/api/health',
    ok: [200],
  },
  {
    group: 'ws-chat',
    name: 'GET ws /api/chat/conversations',
    path: '/api/chat/conversations',
    auth: true,
    ok: [200],
  },
];

/** POST/PUT/PATCH/DELETE simulés si dry run actif côté serveur (pas d’écriture DB). */
const API_MUTATION_ENDPOINTS = [
  {
    group: 'notifications',
    name: 'POST /notifications/inbox/read-all',
    path: '/notifications/inbox/read-all',
    auth: true,
    method: 'POST',
    body: '{}',
    ok: [200, 201],
  },
  {
    group: 'cart',
    name: 'POST /cart/validate-checkout',
    path: '/cart/validate-checkout',
    auth: true,
    method: 'POST',
    body: '{}',
    ok: [200, 201, 400],
  },
];

const WS_MUTATION_ENDPOINTS = [
  {
    group: 'ws-chat',
    name: 'POST ws /api/chat/conversations/support',
    path: '/api/chat/conversations/support',
    auth: true,
    method: 'POST',
    body: '{}',
    ok: [200, 201],
  },
];

export const options = {
  scenarios: {
    load: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: rampUp, target: vus },
        { duration: duration, target: vus },
        { duration: rampDown, target: 0 },
      ],
      gracefulRampDown: '30s',
    },
  },
  thresholds: {
    http_req_failed: [`rate<${httpFailThreshold}`],
    http_req_duration: [`p(95)<${httpP95ThresholdMs}`],
    login_setup_failures: ['rate<0.01'],
    ws_stomp_connect_failures: ['count<100000'],
  },
};

function authHeaders(authToken, mode, withDryRun = true) {
  const headers = { Accept: 'application/json', 'Content-Type': 'application/json' };
  if (mode === 'optional' && authToken) {
    headers.Authorization = `Bearer ${authToken}`;
  } else if (mode === true || mode === 'required') {
    headers.Authorization = `Bearer ${authToken}`;
  }
  if (withDryRun && dryRunEnabled && dryRunSecret) {
    headers['X-Wise-Eat-Dry-Run'] = '1';
    headers['X-Wise-Eat-Dry-Run-Token'] = dryRunSecret;
  }
  return headers;
}

function hitEndpoint(baseUrl, endpoint, authToken, method = 'GET', body = null) {
  const url = `${baseUrl}${endpoint.path}`;
  const params = {
    headers: authHeaders(authToken, endpoint.auth),
    tags: {
      name: endpoint.name,
      endpoint_group: endpoint.group,
    },
    timeout: httpTimeout,
  };

  const m = (method || endpoint.method || 'GET').toUpperCase();
  let res;
  if (m === 'GET') {
    res = http.get(url, params);
  } else if (m === 'POST') {
    res = http.post(url, body ?? endpoint.body ?? '{}', params);
  } else if (m === 'PUT') {
    res = http.put(url, body ?? endpoint.body ?? '{}', params);
  } else if (m === 'PATCH') {
    res = http.patch(url, body ?? endpoint.body ?? '{}', params);
  } else if (m === 'DELETE') {
    res = http.del(url, null, params);
  } else {
    res = http.request(m, url, body, params);
  }

  check(res, {
    [`${endpoint.name} ok`]: (r) => endpoint.ok.includes(r.status),
  });

  return res;
}

function stompUrl() {
  if (wsBase.startsWith('https://')) {
    return wsBase.replace('https://', 'wss://') + '/stomp';
  }
  if (wsBase.startsWith('http://')) {
    return wsBase.replace('http://', 'ws://') + '/stomp';
  }
  return `wss://${wsBase}/stomp`;
}

function stompConnectFrame(token) {
  return (
    'CONNECT\n' +
    'accept-version:1.2\n' +
    'heart-beat:10000,10000\n' +
    `Authorization:Bearer ${token}\n` +
    `token:${token}\n` +
    '\n' +
    '\0'
  );
}

function resolveAuthToken() {
  const preset = String(__ENV.LOAD_TEST_AUTH_TOKEN || '').trim();
  if (preset) {
    return preset;
  }

  const email = String(__ENV.LOAD_TEST_EMAIL || '').trim();
  const password = String(__ENV.LOAD_TEST_PASSWORD || '').trim();
  if (!email || !password) {
    loginFailures.add(1);
    throw new Error(
      'LOAD_TEST_EMAIL + LOAD_TEST_PASSWORD requis (ou LOAD_TEST_AUTH_TOKEN)',
    );
  }

  const res = http.post(
    `${apiBase}/auth/login`,
    JSON.stringify({ source: 'email', email, password }),
    {
      headers: { 'Content-Type': 'application/json' },
      tags: { name: 'POST /auth/login (setup)', endpoint_group: 'auth' },
      timeout: httpTimeout,
    },
  );

  if (res.status !== 200 && res.status !== 201) {
    loginFailures.add(1);
    throw new Error(`Login HTTP ${res.status}: ${res.body?.slice(0, 300)}`);
  }

  let body;
  try {
    body = res.json();
  } catch {
    loginFailures.add(1);
    throw new Error(`Login JSON invalide: ${res.body?.slice(0, 300)}`);
  }

  if (body.requiresTwoFactor) {
    loginFailures.add(1);
    throw new Error(
      'Compte avec 2FA — désactiver email2fa sur le compte de test ou fournir LOAD_TEST_AUTH_TOKEN',
    );
  }

  if (!body.authToken) {
    loginFailures.add(1);
    throw new Error(`Pas de authToken: ${JSON.stringify(body).slice(0, 300)}`);
  }

  return body.authToken;
}

export function setup() {
  const authToken = resolveAuthToken();
  return { authToken };
}

function runApiLoad(authToken) {
  group('api_public', () => {
    for (const endpoint of API_PUBLIC_ENDPOINTS) {
      hitEndpoint(apiBase, endpoint, authToken);
    }
  });

  group('api_auth', () => {
    for (const endpoint of API_AUTH_ENDPOINTS) {
      hitEndpoint(apiBase, endpoint, authToken);
    }
    if (dryRunEnabled && dryRunSecret) {
      for (const endpoint of API_MUTATION_ENDPOINTS) {
        hitEndpoint(apiBase, endpoint, authToken, endpoint.method);
      }
    }
  });

  group('ws_http', () => {
    for (const endpoint of WS_HTTP_ENDPOINTS) {
      hitEndpoint(wsBase, endpoint, authToken);
    }
    if (dryRunEnabled && dryRunSecret) {
      for (const endpoint of WS_MUTATION_ENDPOINTS) {
        hitEndpoint(wsBase, endpoint, authToken, endpoint.method);
      }
    }
  });
}

function runWsLoad(authToken) {
  group('ws_stomp', () => {
    const url = stompUrl();
    const started = Date.now();
    let connected = false;

    const res = ws.connect(url, {}, (socket) => {
      socket.on('open', () => {
        socket.send(stompConnectFrame(authToken));
      });

      socket.on('message', (raw) => {
        const data = String(raw);
        if (!connected && data.startsWith('CONNECTED')) {
          connected = true;
          wsConnectDuration.add(Date.now() - started);
        }
        if (data.startsWith('ERROR')) {
          wsConnectFailures.add(1);
          socket.close();
        }
      });

      socket.on('error', () => {
        wsConnectFailures.add(1);
      });

      socket.setTimeout(() => {
        if (!connected) {
          wsConnectFailures.add(1);
          socket.close();
        }
      }, wsConnectTimeoutMs);

      socket.setTimeout(() => {
        socket.close();
      }, wsConnectTimeoutMs + wsHoldSeconds * 1000);
    });

    check(res, { 'ws upgrade 101': (r) => r && r.status === 101 });
    check(null, {
      'ws stomp connected': () => connected,
    });

    if (!connected) {
      wsConnectFailures.add(1);
    }
  });
}

export default function loadScenario(data) {
  const authToken = data.authToken;

  if (target === 'api' || target === 'both') {
    runApiLoad(authToken);
  }

  if (target === 'ws' || target === 'both') {
    runWsLoad(authToken);
  }

  if (thinkTimeSeconds > 0) {
    sleep(thinkTimeSeconds);
  }
}

function metricTagLines(summary, metricName) {
  const metric = summary.metrics[metricName];
  if (!metric?.submetrics) {
    return [];
  }

  const rows = [];
  for (const [tagKey, sub] of Object.entries(metric.submetrics)) {
    const nameMatch = tagKey.match(/name:([^,}]+)/);
    if (!nameMatch) {
      continue;
    }
    const p95 = sub?.values?.['p(95)'];
    const failRate = sub?.values?.rate;
    if (p95 == null && failRate == null) {
      continue;
    }
    rows.push({
      name: nameMatch[1],
      p95: p95 ?? 0,
      fail: (failRate ?? 0) * 100,
    });
  }

  rows.sort((a, b) => b.p95 - a.p95);
  return rows.slice(0, 20).map(
    (r) =>
      `  ${r.name.padEnd(42)} p95=${r.p95.toFixed(0).padStart(6)} ms  fail=${r.fail.toFixed(1).padStart(5)}%`,
  );
}

export function handleSummary(summary) {
  const endpointLines = metricTagLines(summary, 'http_req_duration');
  const lines = [
    '',
    '=== Wise Eat load test ===',
    `Cible API : ${apiBase}`,
    `Cible WS  : ${stompUrl()}`,
    `VU max    : ${vus} | durée plateau : ${duration}`,
    `Scénario  : ${target}`,
    `Timeout   : HTTP ${httpTimeout} | WS connect ${wsConnectTimeoutMs} ms`,
    `Dry run   : ${dryRunEnabled && dryRunSecret ? 'on (mutations simulées)' : 'off'}`,
    '',
    `http p95  : ${summary.metrics.http_req_duration?.values?.['p(95)']?.toFixed(1) ?? 'n/a'} ms`,
    `http fail : ${((summary.metrics.http_req_failed?.values?.rate ?? 0) * 100).toFixed(2)} %`,
    `ws fail   : ${summary.metrics.ws_stomp_connect_failures?.values?.count ?? 0}`,
    '',
    `Endpoints testés : ${API_PUBLIC_ENDPOINTS.length} public API + ${API_AUTH_ENDPOINTS.length} auth API + ${WS_HTTP_ENDPOINTS.length} WS REST`,
    '',
  ];

  if (endpointLines.length) {
    lines.push('Top latences par endpoint (p95) :');
    lines.push(...endpointLines);
    lines.push('');
  }

  return {
    stdout: lines.join('\n'),
  };
}
