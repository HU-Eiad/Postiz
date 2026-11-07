# ---------------------------------------------------------------------------
# Postiz on CranL
# ---------------------------------------------------------------------------
# CranL builds the `Dockerfile` at the root of the connected GitHub repo.
#
# We do NOT build Postiz from source here. Its Nx build runs with
# NODE_OPTIONS=--max-old-space-size=4096 and takes ~20 minutes, which will OOM
# on a CranL app. Instead we pull a prebuilt image, so a CranL deploy is just
# an image pull.
#
# This points at OUR patched image, built by .github/workflows/build-image.yml,
# which adds the S3_ENDPOINT support Postiz lacks upstream. That is what lets
# media live in a CranL Storage bucket instead of Cloudflare R2.
#
# Before the first deploy:
#   1. Run the "Build patched Postiz image" workflow in this repo (Actions tab).
#   2. Make the resulting GHCR package PUBLIC — CranL has no documented way to
#      pass private registry credentials.
#   3. Owner is set to hu-eiad (GHCR requires lowercase; the repo is HU-Eiad/Postiz).
#
# Upgrading: re-run the workflow with the new upstream tag, bump the tag here,
# commit, push. CranL redeploys automatically.
# ---------------------------------------------------------------------------
# --- INTERIM: official upstream image, no build required ------------------
# Use this while storage is STORAGE_PROVIDER=local. Uploads are lost on every
# redeploy (CranL apps have no persistent volume), which is fine for kicking
# the tyres but not for real use.
FROM ghcr.io/gitroomhq/postiz-app:v2.11.3

# --- TARGET: our patched image, once MinIO is up ---------------------------
# Adds S3_ENDPOINT / S3_FORCE_PATH_STYLE support, which stock Postiz lacks.
# Build it via Actions -> "Build patched Postiz image" (v2.11.3), then swap
# the two FROM lines. The patch is backward compatible, so this image also
# behaves identically to upstream when S3_ENDPOINT is unset.
# FROM ghcr.io/hu-eiad/postiz:v2.11.3

# nginx inside the image listens on 5000 (0.0.0.0) and proxies:
#   /         -> frontend  (Next.js, localhost:4200)
#   /api/     -> backend   (NestJS,  localhost:3000)
#   /uploads/ -> local disk (unused: media goes to S3)
#
# Set the CranL "Port" setting to 5000 so it matches.
EXPOSE 5000

# Inherited from the base image, restated because CranL requires the final
# image to declare a CMD or ENTRYPOINT. `pnpm run pm2` runs prisma db push
# (auto-migrate) and then starts backend + frontend + workers + cron under pm2.
#
# PORT=3000: CranL injects PORT=5000 (the app's Port setting), and the backend
# listens on process.env.PORT || 3000 -- so without this it collides with nginx
# on 5000 (EADDRINUSE). nginx still owns 5000 and proxies /api/ to 3000.
CMD ["sh", "-c", "nginx && PORT=3000 pnpm run pm2"]
