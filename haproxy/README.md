# HAProxy — TLS TCP (Mongo / Redis / Memcached)

Remplace **Stunnel** pour les fronts TLS publics utilisés par Cloud Functions et les clients externes.

## Ports

| Public TLS | Backend local | Certificat SNI |
|------------|---------------|----------------|
| `27018` | `127.0.0.1:27017` | `db.wise-eat.com` |
| `6381` | `127.0.0.1:6379` | `cache.wise-eat.com` |
| `6382` | `127.0.0.1:6380` | `cache.wise-eat.com` |
| `6383–6386` | réplicas Redis | `cache.wise-eat.com` |
| `11212` | `127.0.0.1:11211` | `cache.wise-eat.com` |

Les URIs apps (`.env.functions`) **ne changent pas**.

## Installation VPS

```bash
cd /opt/wise-eat
git pull

# DNS Cloudflare : A (+ AAAA) proxy.wise-eat.com — proxy orange OK (HTTPS UI)
# cache / db restent DNS only sur :6381–6386 / :11212 / :27018

sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh haproxy
# ou stack complète :
# sudo STUNNEL_TLS_EMAIL=help@wise-eat.com ./install.sh tls

sudo ./install.sh verify-tls
```

L’install :

1. Installe `haproxy`
2. Combine les PEM LE → `/etc/haproxy/certs/*.pem`
3. Arrête **socat** workaround + retire confs **Stunnel** des ports concernés
4. Démarre HAProxy
5. Expose l’UI stats via nginx : **https://proxy.wise-eat.com/stats** (basic auth)

## UI monitoring

- **Native HAProxy stats** : https://proxy.wise-eat.com/stats  
  Credentials : `/etc/wise-eat/haproxy-proxy.env` (généré au premier install)  
  Ou : `HAPROXY_PROXY_BASIC_AUTH_PASSWORD=… sudo ./install.sh haproxy-proxy`
- **Prometheus** : `http://127.0.0.1:8404/metrics` (job `haproxy` dans `monitoring/prometheus/prometheus.yml`)
- **Grafana** : dashboard folder `HAProxy/` → *HAProxy TLS fronts* (après `./install.sh monitoring` + reload Prometheus)

## Repair / renew

```bash
sudo ./install.sh repair-haproxy
# Renew LE : hook deploy resync les PEM + reload haproxy
```

## Legacy Stunnel

```bash
FORCE_STUNNEL_MONGODB_TLS=1 sudo ./install.sh mongodb-tls   # déconseillé
sudo ./install.sh stunnel                                   # legacy Redis/Memcached
```

Ne pas relancer `stunnel` / `mongodb-tls` Stunnel après HAProxy : ils réoccuperaient les ports.
