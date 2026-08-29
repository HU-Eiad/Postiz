# Postiz on CranL

Deploys [Postiz](https://github.com/gitroomhq/postiz-app) `v2.23.0` as a single
CranL Application.

This repo is intentionally small. It holds a root `Dockerfile` (all CranL builds),
a one-patch overlay that lets Postiz store media in a CranL bucket, and a GitHub
Actions workflow that bakes the two together into an image. Everything else is
configuration you set in the CranL dashboard.

---

## Architecture

CranL runs **one container per Application**, with **one exposed port**, and has
**no `docker-compose` support** and **no private app-to-app networking**. Postiz
upstream ships a 9-service compose stack, so the pieces have to be split up:

| Piece | Where it runs | Notes |
|---|---|---|
| Postiz (frontend + backend + orchestrator) | **CranL Application** | One container: nginx on port `5000` fronting all three processes under pm2 |
| PostgreSQL | **CranL managed database** | Inject → `DATABASE_URL` |
| Redis | **CranL managed database** | Inject → `REDIS_URL` |
| Temporal server | **Temporal Cloud** (external) | See below — cannot run on CranL |
| Media storage | **CranL Storage bucket** | Needs a two-line source patch — see below |

### Why Temporal has to be external

Postiz v2.23 does not treat Temporal as optional. `apps/backend/src/app.module.ts`
imports `getTemporalModule(false)` in the root module, and `apps/orchestrator` is
a full Temporal worker that owns all scheduled posting. Without a Temporal server
the backend does not boot.

Self-hosting Temporal would mean a second CranL Application exposing gRPC on
`7233`, plus Elasticsearch and its own Postgres. CranL Applications are routed
over HTTP/CDN on a single port and the docs document no internal networking, so a
Postiz app could not reach it. Postiz already supports Temporal Cloud
(`TEMPORAL_TLS`, `TEMPORAL_API_KEY`, `TEMPORAL_NAMESPACE` in
`libraries/nestjs-libraries/src/temporal/temporal.module.ts`), so that is the
supported path.

### Using a CranL Storage bucket

CranL's buckets are S3-compatible, but stock Postiz cannot talk to them: its S3
client **hardcodes** the endpoint to
`https://${CLOUDFLARE_ACCOUNT_ID}.r2.cloudflarestorage.com`
(`libraries/nestjs-libraries/src/upload/r2.uploader.ts:48` and
`cloudflare.storage.ts:42`). There is no endpoint variable to set.

`patches/0001-configurable-s3-endpoint.patch` fixes that in two places, making
the client read `S3_ENDPOINT` and `S3_FORCE_PATH_STYLE`. It is backward
compatible — with `S3_ENDPOINT` unset, behaviour is identical to upstream.

The patch is applied at **image build time** by
`.github/workflows/build-image.yml`, which checks out upstream at a pinned tag,
applies it, and pushes to GHCR. There is no long-lived fork to maintain — this
repo carries only the patch file.

Local disk (`STORAGE_PROVIDER=local`) is not an alternative: CranL Applications
have no persistent volume, so uploaded media would be lost on every redeploy.

---

## Prerequisites

1. A CranL account with GitHub connected (Enterprise plan — unlimited apps/DBs).
2. A [Temporal Cloud](https://temporal.io/cloud) account (free tier is enough).
3. This repo pushed to your own GitHub account.

---

## Step 1 — Push this repo to GitHub

```sh
cd postiz
git init -b main
git add .
git commit -m "Postiz on CranL"
git remote add origin git@github.com:<you>/postiz.git
git push -u origin main
```

CranL only sees repos it has been granted access to — if it does not appear in
the repo picker, re-sync the GitHub integration in CranL settings.

## Step 2 — Build the patched image

**Actions → "Build patched Postiz image" → Run workflow**, leaving the version at
`v2.23.0`. It checks out upstream, applies
`patches/0001-configurable-s3-endpoint.patch`, builds, and pushes to
`ghcr.io/<you>/postiz`. Takes roughly 20 minutes.

Then:

1. Open the new package on your GitHub profile and set its visibility to
   **Public**. CranL has no documented way to supply private registry
   credentials. The image holds no secrets — all config is injected at runtime.
2. Edit `Dockerfile` and replace `changeme` with your GitHub owner
   name. Commit and push.

> Prefer Cloudflare R2 and want to skip this step? Point the `Dockerfile` at
> `ghcr.io/gitroomhq/postiz-app:v2.23.0`, leave `S3_ENDPOINT` unset, and fill in
> the R2 credentials instead. Everything else below is unchanged.

## Step 3 — Create the databases first

Create these **before** the app, so the connection strings can be injected.

- **Applications → New Database** → type `PostgreSQL`, name `postiz-postgres`,
  pick your region.
- Repeat for type `Redis`, name `postiz-redis`, in the **same region**.

## Step 4 — Create the Application

**Applications → New Application**

| Field | Value |
|---|---|
| Repository | `<you>/postiz` |
| Branch | `main` |
| Build Type | **Dockerfile** |
| Region | Same as your databases |

Then in the app's settings set **Port = `5000`**. This is the port nginx binds
inside the image; if it is left at the default the app will show `Error`.

The first deploy will crash-loop — expected, there are no env vars yet.

## Step 5 — Inject the database URLs

Open each database → set **Inject into App** → select your Postiz app. This adds
`DATABASE_URL` and `REDIS_URL` to the app's environment, which are exactly the
variable names Postiz expects. Do not also set them by hand.

## Step 6 — Set up Temporal Cloud

1. Create a namespace (note its full name, e.g. `postiz.a1b2c3`).
2. Create an **API key** and copy it.
3. Note the gRPC endpoint, e.g. `postiz.a1b2c3.us-east-1.aws.api.temporal.io:7233`.
4. **Create two custom Search Attributes on the namespace**, both of type `Text`:
   - `organizationId`
   - `postId`

   > This step is easy to miss and Postiz will misbehave without it. Postiz
   > auto-creates these attributes at boot **only when `TEMPORAL_TLS` is not
   > `true`** — `temporal.register.ts` returns early when TLS is on. Because
   > Temporal Cloud requires TLS, you must create them manually.

## Step 7 — Create the storage bucket

1. **Storage → New Bucket**, name it e.g. `postiz-media`.
2. On the bucket detail page, note the **endpoint URL** and the **CDN / public
   URL**.
3. **Credentials → Create Credentials** → copy the Access Key and Secret Key.
   The secret is shown only once.

Media must be publicly readable, since Postiz hands the browser a direct URL
(`CLOUDFLARE_BUCKET_URL` + filename) rather than proxying it.

## Step 8 — Set the environment variables

Copy `cranl.env.example`, fill in every `<<< FILL IN >>>`, then paste the result
into **App → Environment → Raw Mode**.

Generate the JWT secret with:

```sh
sh scripts/gen-secret.sh
```

Start with the free `*.cranl.net` subdomain in `MAIN_URL`, `FRONTEND_URL` and
`NEXT_PUBLIC_BACKEND_URL`. All three must point at the same https origin, and
`NEXT_PUBLIC_BACKEND_URL` must end in `/api`.

> CranL does **not** restart the app when variables change — trigger a redeploy.

## Step 9 — Deploy and verify

Redeploy, then watch the runtime logs. On a healthy first boot you should see
Prisma push the schema, then pm2 bring up `backend`, `frontend` and
`orchestrator`.

Open the app URL, register the first account, then set
`DISABLE_REGISTRATION=true` and redeploy so nobody else can sign up.

## Step 10 — Custom domain

**App → Domains → Add Domain**, then create the DNS record CranL shows you.

If the domain sits behind Cloudflare, set the record to **DNS only (grey cloud)**
until CranL has issued the certificate, then re-enable proxying if you want it.

After the domain is live, update `MAIN_URL`, `FRONTEND_URL` and
`NEXT_PUBLIC_BACKEND_URL` to the new origin and redeploy. Any social OAuth apps
you have already registered need their callback URLs updated to match.

---

## Upgrading Postiz

Re-run the **Build patched Postiz image** workflow with the new upstream tag,
then bump the tag in `Dockerfile`, commit and push — CranL redeploys.

```dockerfile
FROM ghcr.io/<you>/postiz:v1.48.0
```

If the workflow fails at the `git apply --check` step, upstream has changed the
storage code and the patch needs rebasing. The workflow fails loudly rather than
shipping an unpatched image that would silently write to Cloudflare instead of
your bucket.

Postiz runs `prisma db push --accept-data-loss` on every boot, so schema changes
apply automatically. **Take a database snapshot before a major version bump**,
and check the upstream release notes for migration steps first.

---

## Resource sizing

The single container runs nginx plus three Node processes (Next.js frontend,
NestJS backend, Temporal worker). CranL publishes 2 GB / 2 vCPU for Basic and
4 GB / 4 vCPU for Pro, but does not document the Enterprise tier — confirm with
CranL that your app gets **at least 4 GB**. Below that the frontend and
orchestrator will contend for memory and pm2 will restart-loop.

Because we pull a prebuilt image instead of compiling, the build itself is light
— the memory matters at runtime, not build time.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| App status `Error`, no logs | Port setting is not `5000` |
| `404` on register, or "browser got a 404 when trying to contact the API" | `NEXT_PUBLIC_BACKEND_URL` wrong, or missing the `/api` suffix |
| Backend crash-loops at boot | Temporal unreachable — check `TEMPORAL_ADDRESS`, `TEMPORAL_API_KEY`, and that `TEMPORAL_TLS=true` |
| Posts schedule but never publish | Orchestrator not connected, or the `organizationId` / `postId` search attributes were never created |
| Uploaded images 404 | Bucket not publicly readable, or `CLOUDFLARE_BUCKET_URL` has a trailing `/` (Postiz appends its own, giving `//`) |
| Logged out after every deploy | `JWT_SECRET` not set, so a new one is generated each boot |
| Prisma cannot connect | Database and app are in different regions, or the inject was never applied |
