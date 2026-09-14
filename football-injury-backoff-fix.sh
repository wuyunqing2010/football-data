#!/bin/bash
set -euo pipefail
umask 077
[[ $EUID -eq 0 ]] || exit 1
exec 9>/run/football-backoff-install.lock
flock -n 9 || exit 1
backup=/var/backups/football-backoff-$(date +%Y%m%d-%H%M%S)
mkdir -p "$backup"
cp -a /opt/football-injuries/collector.py "$backup/collector.py"
was_active=0
systemctl is-active --quiet football-injuries.timer && was_active=1
systemctl stop football-injuries.timer
resume(){ if [[ $was_active -eq 1 ]]; then systemctl start football-injuries.timer; fi; }
restore(){ cp -a "$backup/collector.py" /opt/football-injuries/collector.py; resume; echo "更新失败，已恢复：$backup"; }
trap restore ERR
for attempt in $(seq 1 120); do
 state=$(systemctl show football-injuries.service -p ActiveState --value)
 [[ "$state" != active && "$state" != activating ]] && break
 if [[ $attempt -eq 120 ]]; then resume; echo '采集仍在运行，请稍后'; exit 1; fi
 sleep 2
done
python3 - <<'PATCH'
from pathlib import Path
import os
p=Path('/opt/football-injuries/collector.py');s=p.read_text()
if '# endpoint-backoff-v1' not in s:
 replacements=[
 ("restricted = any(d['state'] in ('plan_or_season_restricted', 'provider_quota_limit') or d.get('http_status') in (401,403) for d in old.get('days', []))", "restricted = any(d['state'] == 'provider_quota_limit' for d in old.get('days', []))"),
 ("(restricted or old.get('account_check') != 'ok')", "(restricted or old.get('account_check') in ('plan_or_season_restricted','provider_quota_limit') or old.get('account_http_status') in (401,403))"),
 ("    def request(endpoint):", "    def uncached_request(endpoint):"),
 ("    status = request('status')", '''    # endpoint-backoff-v1
    db.execute('CREATE TABLE IF NOT EXISTS endpoint_backoff(endpoint TEXT PRIMARY KEY, at TEXT NOT NULL)')
    if previous.exists():
        old = json.loads(previous.read_text())
        for item in old.get('days', []):
            if item.get('state') == 'plan_or_season_restricted':
                endpoint = 'injuries?date=' + item['date'] + '&timezone=Asia%2FShanghai'
                db.execute('INSERT OR IGNORE INTO endpoint_backoff VALUES (?,?)', (endpoint, old['checked_at']))
        db.commit()
    def request(endpoint):
        cached = db.execute('SELECT at FROM endpoint_backoff WHERE endpoint=?', (endpoint,)).fetchone()
        if cached and dt.datetime.now(dt.timezone.utc)-dt.datetime.fromisoformat(cached[0]) < dt.timedelta(hours=24):
            return {'state':'plan_or_season_restricted', 'cached_restriction':True}
        result = uncached_request(endpoint)
        if result['state'] == 'plan_or_season_restricted':
            db.execute('INSERT OR REPLACE INTO endpoint_backoff VALUES (?,?)', (endpoint, dt.datetime.now(dt.timezone.utc).isoformat()))
        elif result['state'] == 'ok':
            db.execute('DELETE FROM endpoint_backoff WHERE endpoint=?', (endpoint,))
        db.commit()
        return result
    status = request('status')'''),
 ("    report['account_check'] = status['state']", "    report['account_check'] = status['state']\n    report['account_http_status'] = status.get('http_status')"),
 ("'records': len(rows) if isinstance(rows, list) else 0}", "'records': len(rows) if isinstance(rows, list) else 0, 'fixture_state':fs, 'fixture_records':len(fd.get('response',[])) if isinstance(fd.get('response'),list) else 0, 'cached_restriction':result.get('cached_restriction',False)}"),
 ("            if state not in ('ok', 'empty_unverified', 'partial_pagination'):", "            if state in ('provider_quota_limit','local_quota_limit') or result.get('http_status') in (401,403):")]
 for old,new in replacements:
  if s.count(old)!=1:raise RuntimeError('Collector version mismatch')
  s=s.replace(old,new)
 compile(s,str(p),'exec');st=p.stat();t=p.with_suffix('.backoff-new');t.write_text(s);os.chmod(t,st.st_mode);os.chown(t,st.st_uid,st.st_gid);os.replace(t,p)

PATCH
resume
trap - ERR
install -d -m 700 /opt/football-backoff
cat > /opt/football-backoff/refresh.py <<'PYWORK'
import subprocess
for unit in ['football-injuries','football-injury-view','football-weather','football-injury-bridge']:
 subprocess.run(['systemctl','start',unit+'.service'],check=True)
print('BACKOFF_REFRESH_DONE；仍需看各服务的数据状态，完成不等于全部匹配成功。',flush=True)
PYWORK
cat > /etc/systemd/system/football-backoff-refresh.service <<'UNIT'
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/football-backoff/refresh.py
TimeoutStartSec=20min
UNIT
systemctl daemon-reload
systemctl start --no-block football-backoff-refresh.service
echo 'BACKOFF_FIX_INSTALLED：单个日期权限限制不再暂停所有日期；后台刷新赛程、伤停、天气及同步。'
echo '原先受限的日期接口仍保留24小时退避；每日80次本地保护继续生效。'
echo '查看：journalctl -u football-injuries.service -u football-weather.service -u football-backoff-refresh.service -n 18 --no-pager'
echo "备份：$backup"
