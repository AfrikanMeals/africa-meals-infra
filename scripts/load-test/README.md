# Test de charge — API + WebSocket

Simulation d’utilisateurs concurrents contre :

- `https://api.wise-eat.com/api` — `GET /health`, `GET /auth/me` (JWT)
- `https://ws.wise-eat.com` — `GET /api/health`, connexion STOMP `/stomp`

## Prérequis

- [k6](https://k6.io) (`brew install k6`)
- Compte de test **sans 2FA e-mail** (ou fournir `LOAD_TEST_AUTH_TOKEN`)

## Configuration

```bash
cd scripts/load-test
cp .env.example .env
chmod 600 .env
# Éditer LOAD_TEST_EMAIL / LOAD_TEST_PASSWORD
```

## Lancement

```bash
./run-load-test.sh
```

### Exemples

```bash
# 25 utilisateurs virtuels, 2 minutes de plateau, API seule
LOAD_TEST_VUS=25 LOAD_TEST_DURATION=2m LOAD_TEST_TARGET=api ./run-load-test.sh

# 50 connexions STOMP maintenues 60 s
LOAD_TEST_VUS=50 LOAD_TEST_TARGET=ws LOAD_TEST_WS_HOLD_SECONDS=60 ./run-load-test.sh

# JWT existant (évite le login)
LOAD_TEST_AUTH_TOKEN=eyJ... ./run-load-test.sh
```

Options k6 supplémentaires après `--` :

```bash
./run-load-test.sh --out json=results.json
```

## Limites production

- `/auth/login` : **15 requêtes / 15 min / IP** — le script ne login qu’**une fois** au `setup` k6.
- Préférer un compte dédié « load test », pas un compte personnel.
- Surveiller Grafana (dossiers **Servers**, **Request Stats**) pendant le test.

## Métriques k6

| Métrique | Description |
|----------|-------------|
| `http_req_duration` | Latence HTTP globale |
| `api_health_duration` | `GET /api/health` |
| `api_me_duration` | `GET /api/auth/me` |
| `ws_stomp_connect_duration` | Temps jusqu’au frame STOMP `CONNECTED` |
| `ws_stomp_connect_failures` | Échecs upgrade ou STOMP `ERROR` |
