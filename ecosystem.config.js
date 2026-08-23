// PM2 process definitions for the three Postiz apps.
//
// Each app is launched as `node` directly rather than through upstream's
// `pnpm start` -> `dotenv -e ../../.env -- node ...` chain. That chain costs
// two extra Node processes per app (~195 MB across all three) and buys
// nothing in this image: dotenv reads /app/.env, which we never create. The
// environment arrives from podman --env-file and the EnvironmentFile= line in
// postiz-app.service, both of which are already in the process environment by
// the time PM2 forks.
//
// max-old-space-size is set per app here instead of through a single global
// NODE_OPTIONS so each app gets a limit that matches what it actually does.
// A command-line flag beats an inherited NODE_OPTIONS, so this wins over
// whatever is in /etc/postiz/env. Resulting V8 ceiling is the flag + ~48 MB.
//
// The orchestrator's limit does double duty: the Temporal SDK derives its
// default maxCachedWorkflows from v8.getHeapStatistics().heap_size_limit (see
// @temporalio/worker/lib/worker-options.js), so capping the heap also bounds
// the sticky workflow cache. We set maxCachedWorkflows explicitly upstream in
// temporal.module.ts as well — this is belt and braces, not the primary lever.

const REQUIRE_MODULE = '--experimental-require-module';

module.exports = {
  apps: [
    {
      name: 'backend',
      cwd: '/app/apps/backend',
      script: './dist/apps/backend/src/main.js',
      interpreter: 'node',
      // 384, not 256. The backend's live working set reaches ~246 MB of
      // old-space and 256 killed it: it crash-looped 111 times in 21 minutes
      // with "Reached heap limit Allocation failed - JavaScript heap out of
      // memory", taking the API down (nginx 502 on /api/*) while the frontend
      // kept serving and looked healthy. 384 is the value it ran on for months
      // under the old global NODE_OPTIONS. Do not lower it without watching
      // `pm2 list` restart counts for several minutes under real traffic.
      interpreter_args: `${REQUIRE_MODULE} --max-old-space-size=384`,
    },
    {
      name: 'frontend',
      cwd: '/app/apps/frontend',
      // next's bin is a plain node script; run it under our own interpreter
      // so the heap flag applies to the server process itself.
      script: '/app/node_modules/.bin/next',
      args: 'start -p 4200',
      interpreter: 'node',
      interpreter_args: '--max-old-space-size=192',
    },
    {
      name: 'orchestrator',
      cwd: '/app/apps/orchestrator',
      script: './dist/apps/orchestrator/src/main.js',
      interpreter: 'node',
      interpreter_args: `${REQUIRE_MODULE} --max-old-space-size=256`,
    },
  ],
};
