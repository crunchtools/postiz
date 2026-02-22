module.exports = {
  apps: [
    {
      name: 'backend',
      cwd: '/app/apps/backend',
      script: 'pnpm',
      args: 'start',
    },
    {
      name: 'frontend',
      cwd: '/app/apps/frontend',
      script: 'pnpm',
      args: 'start',
    },
    {
      name: 'orchestrator',
      cwd: '/app/apps/orchestrator',
      script: 'pnpm',
      args: 'start',
    },
  ],
};
