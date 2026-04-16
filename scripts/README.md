# scripts/

Maintenance scripts deployed to `C:\GitLab-Runner\scripts\` during Phase 3.

| Script | Scheduled Task | Interval | Purpose |
|--------|---------------|----------|---------|
| `health-check.ps1` | (called by watchdogs) | Every 5 min | Checks Docker, Runner, disk, stale containers |
| `docker-watchdog.ps1` | Docker-Daemon-Watchdog | Every 5 min | Restarts Docker if unresponsive |
| `disk-monitor.ps1` | Disk-Space-Monitor | Every 30 min | Emergency prune if disk < 10 GB |
| `kill-stale-containers.ps1` | Docker-Stale-Container-Kill | Every 2 h | Kills containers running > 4 hours |
| `Register-ScheduledTasks.ps1` | (run once) | — | Creates all 10 scheduled tasks |

All scripts write to `C:\GitLab-Runner\logs\` and fire Windows Event Log entries under source `GitLabRunner`.
