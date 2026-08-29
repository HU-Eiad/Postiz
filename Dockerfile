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
FROM ghcr.io/hu-eiad/postiz:v1.47.0

# If you would rather use Cloudflare R2 and skip the patched build entirely,
# use the official upstream image instead and leave S3_ENDPOINT unset:
# FROM ghcr.io/gitroomhq/postiz-app:v1.47.0

# nginx inside the image listens on 5000 (0.0.0.0) and proxies:
#   /         -> frontend  (Next.js, localhost:4200)
#   /api/     -> backend   (NestJS,  localhost:3000)
#   /uploads/ -> local disk (unused: media goes to S3)
#
# Set the CranL "Port" setting to 5000 so it matches.
EXPOSE 5000

# Inherited from the base image, restated because CranL requires the final
# image to declare a CMD or ENTRYPOINT. `pnpm run pm2` runs prisma db push
# (auto-migrate) and then starts backend + frontend + orchestrator under pm2.
CMD ["sh", "-c", "nginx && pnpm run pm2"]
