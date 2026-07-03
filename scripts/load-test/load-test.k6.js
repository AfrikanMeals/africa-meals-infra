/**
 * Wise Eat — charge API + WebSocket (STOMP).
 *
 * Prérequis : k6 (https://k6.io) — brew install k6
 *
 * Variables (voir .env.example) :
 *   LOAD_TEST_API_BASE, LOAD_TEST_WS_BASE, LOAD_TEST_EMAIL, LOAD_TEST_PASSWORD
 *   LOAD_TEST_VUS, LOAD_TEST_DURATION, LOAD_TEST_RAMP_UP, LOAD_TEST_RAMP_DOWN
 *   LOAD_TEST_TARGET=api|ws|both
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
const wsHoldSeconds = Number(__ENV.LOAD_TEST_WS_HOLD_SECONDS || 25);
const thinkTimeSeconds = Number(__ENV.LOAD_TEST_THINK_TIME_SECONDS || 1);

const vus = Number(__ENV.LOAD_TEST_VUS || 10);
const rampUp = __ENV.LOAD_TEST_RAMP_UP || '30s';
const duration = __ENV.LOAD_TEST_DURATION || '1m';
const rampDown = __ENV.LOAD_TEST_RAMP_DOWN || '15s';

const apiHealthDuration = new Trend('api_health_duration', true);
const apiMeDuration = new Trend('api_me_duration', true);
const wsConnectDuration = new Trend('ws_stomp_connect_duration', true);
const wsConnectFailures = new Counter('ws_stomp_connect_failures');
const loginFailures = new Rate('login_setup_failures');

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
    http_req_failed: ['rate<0.10'],
    http_req_duration: ['p(95)<3000'],
    login_setup_failures: ['rate<0.01'],
    ws_stomp_connect_failures: ['count<100000'],
  },
};

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
      tags: { name: 'setup_login' },
      timeout: '30s',
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
  group('api', () => {
    const healthRes = http.get(`${apiBase}/health`, {
      tags: { name: 'GET /health' },
      timeout: '15s',
    });
    apiHealthDuration.add(healthRes.timings.duration);
    check(healthRes, {
      'api health 200': (r) => r.status === 200,
    });

    const meRes = http.get(`${apiBase}/auth/me`, {
      headers: {
        Authorization: `Bearer ${authToken}`,
        Accept: 'application/json',
      },
      tags: { name: 'GET /auth/me' },
      timeout: '15s',
    });
    apiMeDuration.add(meRes.timings.duration);
    check(meRes, {
      'api me 200': (r) => r.status === 200,
    });

    const wsHealthRes = http.get(`${wsBase}/api/health`, {
      tags: { name: 'GET ws /api/health' },
      timeout: '15s',
    });
    check(wsHealthRes, {
      'ws health 200': (r) => r.status === 200,
    });
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
        socket.close();
      }, wsHoldSeconds * 1000);
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

export function handleSummary(summary) {
  const lines = [
    '',
    '=== Wise Eat load test ===',
    `Cible API : ${apiBase}`,
    `Cible WS  : ${stompUrl()}`,
    `VU max    : ${vus} | durée plateau : ${duration}`,
    `Scénario  : ${target}`,
    '',
    `http p95  : ${summary.metrics.http_req_duration?.values?.['p(95)']?.toFixed(1) ?? 'n/a'} ms`,
    `http fail : ${((summary.metrics.http_req_failed?.values?.rate ?? 0) * 100).toFixed(2)} %`,
    `ws fail   : ${summary.metrics.ws_stomp_connect_failures?.values?.count ?? 0}`,
    '',
  ];
  return {
    stdout: lines.join('\n'),
  };
}
