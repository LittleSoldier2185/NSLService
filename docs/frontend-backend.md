# Frontend and backend files on the main server

`iot.sh bundle` prepares everything a dev machine needs for the two projects, so developers do not need the internet:

| Project | Source | What the server prepares |
|---|---|---|
| **frontend** (`evaluation-web`: Vue 3, Vue Router, Vuetify, axios, html2pdf.js, Vite) | built-in `package.json` | **A.** ready-made libraries in `frontend/static/` + **C.** npm registry mirror |
| **backend** (`evaluation-api`: Express 5, mysql2, JWT, multer, bcryptjs, nodemon) | built-in `package.json` | **C.** npm registry mirror (a backend has nothing to load in a `<script>` tag, so no static files) |

Both also get `package.json` and `package-lock.json` in the bundle, so a dev machine installs the same versions as the server.

## What is in the bundle

```
/srv/iot-bundle/
├── frontend/
│   ├── package.json  package-lock.json
│   └── static/        vue.global.prod.js  vue-router.global.prod.js  vuetify.min.js/.css
│                      axios.min.js  html2pdf.bundle.min.js  mdi/ (icons CSS + fonts)  example.html
└── backend/
    └── package.json  package-lock.json
```

All files are listed in `SHA256SUMS`. The npm registry mirror is a separate container, `npm-registry` (Verdaccio), on port **4873**.
It is read-only: sign-up is disabled and nobody can publish.

## 1. On the main server (has internet)

```bash
sudo bash iot.sh bundle
```

The end of the output prints the bundle URL (port 8000) and the registry URL (port 4873).
During `bundle` the server installs both projects once through the registry so every package is cached. It also caches the
platform binaries that Vite needs on Windows, macOS and Linux arm64 (esbuild, rollup), so dev machines on those systems work too.

Use your own `package.json` instead of the built-in ones:

```bash
FRONTEND_PKG=/path/to/web/package.json BACKEND_PKG=/path/to/api/package.json sudo -E bash iot.sh bundle
```

The static libraries use **the same versions as `package-lock.json`** (what `npm ci` installs), so method A and method C behave the same.
The versions used are printed during `bundle`. To force one: `FE_VUE=3.5.13 FE_VUETIFY=3.7.6 sudo -E bash iot.sh bundle`
(`FE_VUE FE_ROUTER FE_VUETIFY FE_AXIOS FE_HTML2PDF FE_MDI`). If the registry could not start, pinned fallback versions are used and a warning is shown.

## 2. On the dev machine

`iot.sh` is a bash script (Git Bash, WSL, Linux or macOS). It needs `curl` but not root.

```bash
curl -fO http://192.168.10.2:8000/iot.sh

bash iot.sh frontend --from http://192.168.10.2:8000 ./web     # frontend into ./web
bash iot.sh backend  --from http://192.168.10.2:8000 ./api     # backend  into ./api
```

For each project it downloads `package.json` and `package-lock.json` (plus `static/` for the frontend), verifies the
checksums, and writes a **project-local** `.npmrc` (`registry=http://192.168.10.2:4873/`). Your global npm settings are not touched.
Your own files are never overwritten: if `package.json` already exists, the server's copy is saved as `package.json.new`
and an existing `.npmrc` is kept.

Then work as usual:

```bash
cd web && npm ci && npm run dev
cd api && npm ci && npm run start
```

Without the script: `npm config set registry http://192.168.10.2:4873/`, or put that line in a `.npmrc`.
Packages come from the server; if the server has internet and a package is not cached yet, Verdaccio fetches and caches it on the way.

### Frontend without npm (method A)

`web/static/example.html` works by double-clicking it (Vue + Vuetify + icons, all local). In your own page:

```html
<link rel="stylesheet" href="static/mdi/css/materialdesignicons.min.css">
<link rel="stylesheet" href="static/vuetify.min.css">
<script src="static/vue.global.prod.js"></script>
<script src="static/vuetify.min.js"></script>
```

Load Vue before Vuetify, and keep the `mdi/css` and `mdi/fonts` folders together.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Cannot fetch .../SHA256SUMS` | Wrong URL/port, firewall (8000), or the `iot-bundle` service is down: `systemctl status iot-bundle` |
| `This bundle has no frontend files` | The bundle is older than this feature: run `sudo bash iot.sh bundle` again |
| `Checksum ... does not match` | The file changed after the bundle was built, or the download is corrupted: re-run `bundle`, download again |
| `npm ci` cannot reach the registry | Check `http://SERVER:4873/-/ping`, firewall (4873), `docker ps` shows `npm-registry` |
| `npm ci` says a package or binary is missing | It was not cached (for example another platform). The server needs internet once to fetch it; or re-run `bundle` |
| `npm ci` complains the lock file is out of sync | You changed `package.json`. Run `npm install` instead of `npm ci` |
| `Vue is not defined` in the browser | `vue.global.prod.js` must come before Vuetify and your own script |
| backend refuses to start | `engines` needs Node 24 or newer (`node -v`); the database settings are your app's, not this tool's |

## Notes

- `reset` does not remove the registry container or `/srv/npm-registry` (it belongs to the bundle server, not the installed stack).
  To remove it: `docker rm -f npm-registry && sudo rm -rf /srv/npm-registry`.
- The registry has no authentication for reading, so keep ports 8000 and 4873 on your internal network.
