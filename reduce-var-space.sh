#!/bin/bash
docker system prune -a -f
truncate -s 0 /var/log/kern.log
truncate -s 0 /var/log/teamviewer15/TVNetwork.log
truncate -s 0 /var/log/syslog
journalctl --vacuum-size=10M
journalctl --vacuum-time=1d
