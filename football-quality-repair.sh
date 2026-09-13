#!/bin/bash
set -euo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo '请用 sudo bash 执行'; exit 1; }
exec 9>/run/football-quality-repair-install.lock
flock -n 9 || { echo '更新正在运行'; exit 1; }
test -s /opt/football/app/dedup.py
test -s /opt/football-web/injury_view.py
test -s /opt/football-audit/audit.py
backup=/var/backups/football-quality-repair-$(date +%Y%m%d-%H%M%S)
mkdir -p "$backup"
cp -a /opt/football/app "$backup/app"
cp -a /opt/football-web "$backup/web"
cp -a /opt/football-audit "$backup/audit"
# Preserve timer activity, including a user-paused history job.
units='football-collect football-history football-train football-predict football-quality-audit football-injury-view football-github-sync football-injury-bridge'
for unit in $units; do
 if systemctl is-active --quiet "$unit.timer"; then echo "$unit.timer" >> "$backup/active-timers"; fi
 systemctl stop "$unit.timer" 2>/dev/null || true
done
resume() { if [[ -f "$backup/active-timers" ]]; then while read -r timer; do systemctl start "$timer" || true; done < "$backup/active-timers"; fi; }
rollback() {
 echo "更新失败，恢复原代码。备份：$backup"
 systemctl disable --now football-recent-repair.timer 2>/dev/null || true
 systemctl stop football-recent-repair.service 2>/dev/null || true
 cp -a "$backup/app/." /opt/football/app/
 cp -a "$backup/web/." /opt/football-web/
 cp -a "$backup/audit/." /opt/football-audit/
 runuser -u football -- /opt/football/.venv/bin/python /opt/football/app/dedup.py || true
 systemctl restart football-web.service || true
 resume
}
trap rollback ERR
# Let already-running jobs finish, so collection and model files are not interrupted.
echo '等待正在运行的采集任务结束，随后更新。'
for unit in $units; do
 for attempt in $(seq 1 120); do
  state=$(systemctl show "$unit.service" -p ActiveState --value 2>/dev/null || true)
  [[ "$state" != activating && "$state" != active ]] && break
  if [[ $attempt -eq 120 ]]; then echo '现有任务仍在运行，暂缓更新'; resume; exit 1; fi
  sleep 2
 done
done
python3 - <<'PATCH_PY'
import json,os,grp,py_compile
from pathlib import Path
ALIASES={'桑坦德': '桑坦德竞技', '弗洛西诺': '弗洛西诺内', '门兴': '门兴格拉德巴赫', '布伦特': '布伦特福德', '维拉': '阿斯顿维拉', '诺丁汉': '诺丁汉森林', '伊普斯': '伊普斯维奇', '斯特拉斯': '斯特拉斯堡', '布赖合作': '布赖代合作', '利雅新月': '利雅得新月', '热刺': '托特纳姆热刺', '不来梅': '云达不来梅', '毕尔巴鄂': '毕尔巴鄂竞技', '福图纳': '福图纳锡塔德', '皇马': '皇家马德里', '札幌冈萨': '札幌冈萨多', '塞尔塔': '维戈塞尔塔', '布鲁马波': '布鲁马波卡纳', '曼城': '曼彻斯特城', '埃沃斯堡': '埃尔沃斯堡', '拉科': '拉科鲁尼亚', '埃因霍温': 'PSV埃因霍温', '鹿斯巴达': '鹿特丹斯巴达', '新英格兰': '新英格兰革命', '国际图尔': '国际图尔库', '盖斯': '哥德堡盖斯', '桑纳菲': '桑纳菲尤尔', '纽卡斯尔': '纽卡斯尔联', '比利亚雷': '比利亚雷亚尔', '贝蒂斯': '皇家贝蒂斯', '埃斯托里': '埃斯托里尔'}
def save(p,s):
 st=p.stat();t=p.with_suffix('.new');t.write_text(s)
 if p.suffix=='.py':py_compile.compile(str(t),doraise=True)
 os.chmod(t,st.st_mode);os.chown(t,st.st_uid,st.st_gid);os.replace(t,p)
for name in ('/opt/football/app/dedup.py','/opt/football-web/dedup_aliases.py'):
 p=Path(name);s=p.read_text()
 if '# quality-alias-v1' not in s:
  if s.count('def norm(s):')!=1:raise RuntimeError('Alias code version mismatch')
  s=s.replace('def norm(s):','# quality-alias-v1\nALIASES.update('+repr(ALIASES)+')\n\ndef norm(s):');save(p,s)
p=Path('/opt/football/app/football.py');s=p.read_text()
if 'range(0,4)' in s:s=s.replace('range(0,4)','range(0,7)');save(p,s)
# Make audit history alias-aware and retain explicit completeness limitations.
p=Path('/opt/football-audit/audit.py');s=p.read_text()
if '# quality-audit-v1' not in s:
 old='WHERE (m.home=%s OR m.away=%s) AND m.kickoff<now() ORDER BY m.kickoff DESC LIMIT 20\"\"\",(g[side],g[side]))'
 if old not in s:raise RuntimeError('Audit version mismatch')
 s=s.replace('from dedup import norm','from dedup import norm,ALIASES\n# quality-audit-v1')
 s=s.replace("   h=rows(db,", "   names=sorted({g[side],norm(g[side])}|{a for a,t in ALIASES.items() if norm(t)==norm(g[side])})\n   h=rows(db,")
 s=s.replace(old,'WHERE (m.home=ANY(%s) OR m.away=ANY(%s)) AND m.kickoff<now() AND r.published_at<=now() ORDER BY m.kickoff DESC LIMIT 20\"\"\",(names,names))')
 s=s.replace("'Recent team counts use exact stored names; aliases are separately flagged.'","'Recent team counts combine confirmed aliases; source coverage remains unverified.'")
 s=s.replace("'recent_days':days", "'recent_repair':safe(ROOT/'reports/recent-repair.json'),'recent_days':days")
 save(p,s)
# Dashboard history: show available source records rather than implying completeness.
p=Path('/opt/football-web/web.py');s=p.read_text()
if '# quality-history-v1' not in s:
 anchor='  return result\n'
 if s.count(anchor)!=1:raise RuntimeError('Web version mismatch')
 block="""  # quality-history-v1
  from dedup_aliases import norm,ALIASES
  for m in rows:
   m['recent_coverage']={}
   for side in ('home','away'):
    names=sorted({m[side],norm(m[side])}|{a for a,t in ALIASES.items() if norm(t)==norm(m[side])})
    rec=query(db,'''SELECT count(*) AS n,max(m.kickoff) AS latest FROM canonical_matches m JOIN canonical_results r USING(canonical_id,source,source_id) WHERE (m.home=ANY(%s) OR m.away=ANY(%s)) AND m.kickoff<now() AND m.kickoff>=now()-interval '30 days' AND r.published_at<=now()''',(names,names))[0]
    m['recent_coverage'][side]={'records_30d':rec['n'],'latest':rec['latest'],'complete':False}
"""
 # This code must remain inside the read-only database context.
 s=s.replace(anchor,block+anchor);save(p,s)
p=Path('/opt/football-web/app.js');s=p.read_text()
if '// quality-history-v1' not in s:
 anchor='for(const s of m.odds_sources)'
 if s.count(anchor)!=1:raise RuntimeError('Frontend version mismatch')
 block="""// quality-history-v1
const coverage=node('div',undefined,'odds');coverage.append(node('strong','近期赛果覆盖（未确认完整）'));
for(const side of ['home','away']){const q=m.recent_coverage?.[side];if(q)coverage.append(node('p',m[side]+' · 近30天库内 '+q.records_30d+' 场 · 最近 '+format(q.latest)));}
coverage.append(node('small','0场不等于球队没有比赛；缺少数据时降低近况参考权重。'));card.append(coverage);
"""
 s=s.replace(anchor,block+anchor);save(p,s)

PATCH_PY
python3 - <<'FILES_PY'
import base64,os,grp,py_compile
from pathlib import Path
for name,data in {'/opt/football-web/publish_injuries.py': 'aW1wb3J0IHNxbGl0ZTMsanNvbixvcyxncnAKZnJvbSBwYXRobGliIGltcG9ydCBQYXRoCkRCPVBhdGgoJy92YXIvbGliL2Zvb3RiYWxsLWluanVyaWVzL2luanVyaWVzLnNxbGl0ZScpCmRlZiBkZWR1cGxpY2F0ZShwbGF5ZXJzKToKIGdyb3Vwcz17fQogZm9yIHAgaW4gcGxheWVyczoKICBpZGVudGl0eT0ocFsnZml4dHVyZV9pZCddLHBbJ3RlYW1faWQnXSwoJ2lkJyxwWydwbGF5ZXJfaWQnXSkgaWYgcC5nZXQoJ3BsYXllcl9pZCcpIGVsc2UgKCduYW1lJyxwWyduYW1lJ10pKQogIGdyb3Vwcy5zZXRkZWZhdWx0KGlkZW50aXR5LFtdKS5hcHBlbmQocCkKIG91dD1bXQogZm9yIHZhbHVlcyBpbiBncm91cHMudmFsdWVzKCk6CiAgcD1kaWN0KHZhbHVlc1swXSk7dmFyaWFudHM9c29ydGVkKHsoc3RyKHguZ2V0KCd0eXBlJykgb3IgJycpLHN0cih4LmdldCgncmVhc29uJykgb3IgJycpKSBmb3IgeCBpbiB2YWx1ZXN9KQogIGlmIGxlbih2YXJpYW50cyk+MToKICAgcFsndHlwZSddPSfnirbmgIHlhrLnqoHvvIzlvoXmoLjlrp4nO3BbJ3JlYXNvbiddPScgLyAnLmpvaW4odCsnOiAnK3IgZm9yIHQsciBpbiB2YXJpYW50cykKICBvdXQuYXBwZW5kKHApCiByZXR1cm4gb3V0CgpkZWYgbWFpbigpOgogZGF5cz1bXQogd2l0aCBzcWxpdGUzLmNvbm5lY3QoJ2ZpbGU6JytzdHIoREIpKyc/bW9kZT1ybycsdXJpPVRydWUpIGFzIGRiOgogIGZvciBhdCxkYXksc3RhdGUscGF5bG9hZCBpbiBkYi5leGVjdXRlKCdTRUxFQ1QgYXQsZGF5LHN0YXRlLHBheWxvYWQgRlJPTSBzbmFwc2hvdHMgV0hFUkUgcm93aWQgSU4gKFNFTEVDVCBtYXgocm93aWQpIEZST00gc25hcHNob3RzIEdST1VQIEJZIGRheSkgT1JERVIgQlkgZGF5IERFU0MgTElNSVQgNCcpOgogICBmcj1kYi5leGVjdXRlKCdTRUxFQ1Qgc3RhdGUscGF5bG9hZCBGUk9NIGZpeHR1cmVzIFdIRVJFIGRheT0/IEFORCBhdD0/IE9SREVSIEJZIHJvd2lkIERFU0MgTElNSVQgMScsKGRheSxhdCkpLmZldGNob25lKCkKICAgZml4dHVyZXM9W107cGxheWVycz1bXQogICBpZiBmciBhbmQgZnJbMF09PSdvayc6CiAgICBmb3IgciBpbiBqc29uLmxvYWRzKGZyWzFdKS5nZXQoJ3Jlc3BvbnNlJyxbXSk6CiAgICAgdHJ5OmZpeHR1cmVzLmFwcGVuZCh7J2lkJzpyWydmaXh0dXJlJ11bJ2lkJ10sJ2tpY2tvZmYnOnJbJ2ZpeHR1cmUnXVsnZGF0ZSddLCdob21lJzpyWyd0ZWFtcyddWydob21lJ11bJ25hbWUnXSwnYXdheSc6clsndGVhbXMnXVsnYXdheSddWyduYW1lJ10sJ2hvbWVfaWQnOnJbJ3RlYW1zJ11bJ2hvbWUnXVsnaWQnXSwnYXdheV9pZCc6clsndGVhbXMnXVsnYXdheSddWydpZCddfSkKICAgICBleGNlcHQgKEtleUVycm9yLFR5cGVFcnJvcik6Y29udGludWUKICAgaWYgc3RhdGU9PSdvayc6CiAgICBmb3IgciBpbiBqc29uLmxvYWRzKHBheWxvYWQpLmdldCgncmVzcG9uc2UnLFtdKToKICAgICB0cnk6cGxheWVycy5hcHBlbmQoeydmaXh0dXJlX2lkJzpyWydmaXh0dXJlJ11bJ2lkJ10sJ3RlYW1faWQnOnJbJ3RlYW0nXVsnaWQnXSwncGxheWVyX2lkJzpyWydwbGF5ZXInXS5nZXQoJ2lkJyksJ25hbWUnOnJbJ3BsYXllciddWyduYW1lJ10sJ3R5cGUnOnJbJ3BsYXllciddLmdldCgndHlwZScpLCdyZWFzb24nOnJbJ3BsYXllciddLmdldCgncmVhc29uJyl9KQogICAgIGV4Y2VwdCAoS2V5RXJyb3IsVHlwZUVycm9yKTpjb250aW51ZQogICBwbGF5ZXJzPWRlZHVwbGljYXRlKHBsYXllcnMpCiAgIGRheXMuYXBwZW5kKHsnYXQnOmF0LCdkYXknOmRheSwnc3RhdGUnOnN0YXRlLCdmaXh0dXJlX3N0YXRlJzpmclswXSBpZiBmciBlbHNlICdtaXNzaW5nJywnZml4dHVyZXMnOmZpeHR1cmVzLCdwbGF5ZXJzJzpwbGF5ZXJzfSkKIHA9UGF0aCgnL29wdC9mb290YmFsbC13ZWIvaW5qdXJ5LWRhdGEuanNvbicpO3Q9cC53aXRoX3N1ZmZpeCgnLnRtcCcpCiB0LndyaXRlX3RleHQoanNvbi5kdW1wcyh7J2RheXMnOmRheXN9LGVuc3VyZV9hc2NpaT1GYWxzZSkpO3QuY2htb2QoMG82NDApO29zLmNob3duKHQsMCxncnAuZ2V0Z3JuYW0oJ2Zvb3RiYWxsd2ViJykuZ3JfZ2lkKTtvcy5yZXBsYWNlKHQscCkKIHByaW50KCdJTkpVUllfVklFV19EQVRBX09LIGRheXM9JytzdHIobGVuKGRheXMpKSkKaWYgX19uYW1lX189PSdfX21haW5fXyc6bWFpbigpCg==', '/opt/football/app/recent_repair.py': 'IiIiRmluaXRlIDMwLWRheSBzb3VyY2UgcmVjaGVjaywgcmVzdGFydGFibGU7IG5vIGludmVudGVkIGNvbXBsZXRlIHNjaGVkdWxlcy4iIiIKaW1wb3J0IHN5cyxqc29uLHRpbWUKZnJvbSBwYXRobGliIGltcG9ydCBQYXRoCmZyb20gZGF0ZXRpbWUgaW1wb3J0IGRhdGV0aW1lLHRpbWVkZWx0YQpmcm9tIHpvbmVpbmZvIGltcG9ydCBab25lSW5mbwpzeXMucGF0aC5pbnNlcnQoMCwnL29wdC9mb290YmFsbC9hcHAnKQppbXBvcnQgZm9vdGJhbGwKZnJvbSBkZWR1cCBpbXBvcnQgcmVmcmVzaApQPVBhdGgoJy9vcHQvZm9vdGJhbGwvcmVwb3J0cy9yZWNlbnQtcmVwYWlyLmpzb24nKQpkZWYgbWFpbigpOgogd2l0aCBmb290YmFsbC5jb25uZWN0KCkgYXMgZGI6CiAgaWYgbm90IGRiLmV4ZWN1dGUoJ1NFTEVDVCBwZ190cnlfYWR2aXNvcnlfbG9jayg3MDIyMDI2MDkxMCknKS5mZXRjaG9uZSgpWzBdOgogICBwcmludCgnUkVDRU5UX1JFUEFJUl9CVVNZIG5leHQgdGltZXIgd2lsbCByZXRyeScpO3JldHVybgogIGQ9anNvbi5sb2FkcyhQLnJlYWRfdGV4dCgpKSBpZiBQLmV4aXN0cygpIGVsc2UgeydzdGFydGVkX2F0Jzpmb290YmFsbC5ub3coKS5pc29mb3JtYXQoKSwnZW5kJzooZGF0ZXRpbWUubm93KFpvbmVJbmZvKCdBc2lhL1NoYW5naGFpJykpLmRhdGUoKS10aW1lZGVsdGEoZGF5cz0xKSkuaXNvZm9ybWF0KCksJ2RheXMnOnt9fQogIGVuZD1kYXRldGltZS5mcm9taXNvZm9ybWF0KGRbJ2VuZCddKS5kYXRlKCkKICB0YXJnZXRzPVsoZW5kLXRpbWVkZWx0YShkYXlzPWkpKS5pc29mb3JtYXQoKSBmb3IgaSBpbiByYW5nZSgzMCldCiAgdG9kbz1beCBmb3IgeCBpbiB0YXJnZXRzIGlmIHggbm90IGluIGRbJ2RheXMnXSBvciAoZFsnZGF5cyddW3hdWydzdGF0dXMnXT09J2ZldGNoX2ZhaWxlZCcgYW5kIGRbJ2RheXMnXVt4XS5nZXQoJ2F0dGVtcHRzJywwKTwzKV1bOjNdCiAgaWYgbm90IHRvZG86CiAgIHByaW50KCdSRUNFTlRfUkVQQUlSX0lETEUgY29tcGxldGU9JytzdHIoZC5nZXQoJ2NvbXBsZXRlJyxGYWxzZSkpKyc7IHVucmVzb2x2ZWQgZmFpbHVyZXMgcmVxdWlyZSByZXZpZXcnKTtyZXR1cm4KICBmb3IgZGF5IGluIHRvZG86CiAgIG9rPWZvb3RiYWxsLmNvbGxlY3Rfb25lKGRiLCdzb3VyY2VfYV9oaXN0b3J5JyxkYXkpCiAgIHJlY29yZD1kYi5leGVjdXRlKCdTRUxFQ1Qgc3RhdHVzLHJlY29yZHMsY2hlY2tlZF9hdCBGUk9NIGhpc3RvcnlfZGF5cyBXSEVSRSBkYXk9JXMnLChkYXksKSkuZmV0Y2hvbmUoKQogICBkWydkYXlzJ11bZGF5XT17J2F0dGVtcHRzJzpkWydkYXlzJ10uZ2V0KGRheSx7fSkuZ2V0KCdhdHRlbXB0cycsMCkrMSwnc3RhdHVzJzpyZWNvcmRbMF0gaWYgb2sgYW5kIHJlY29yZCBlbHNlICdmZXRjaF9mYWlsZWQnLCdyZWNvcmRzJzpyZWNvcmRbMV0gaWYgb2sgYW5kIHJlY29yZCBlbHNlIE5vbmUsJ2NoZWNrZWRfYXQnOmZvb3RiYWxsLm5vdygpLmlzb2Zvcm1hdCgpfQogICBkWydhdCddPWZvb3RiYWxsLm5vdygpLmlzb2Zvcm1hdCgpO2RbJ2NvbXBsZXRlJ109YWxsKHggaW4gZFsnZGF5cyddIGFuZCBkWydkYXlzJ11beF1bJ3N0YXR1cyddIT0nZmV0Y2hfZmFpbGVkJyBmb3IgeCBpbiB0YXJnZXRzKQogICBkWydub3RlJ109J+WujOaIkOS7heaMh+mHjeafpeeOsOacieadpea6kOi/kTMw5aSp77yb56m66L+U5Zue5LiN6K+B5piO5rKh5pyJ5q+U6LWb77yM5pyq6KaG55uW55qE5q2j5byP5q+U6LWb5LuN6ZyA54us56uL5p2l5rqQ5qC45a6e44CCJwogICBmb290YmFsbC5hdG9taWMoUCxkKQogICBpZiBub3Qgb2s6YnJlYWsKICAgdGltZS5zbGVlcChmb290YmFsbC5jb25maWcoKVsncmVxdWVzdF9kZWxheV9zZWNvbmRzJ10pCiAgcmVmcmVzaChkYikKICBwcmludCgnUkVDRU5UX1JFUEFJUl9QUk9HUkVTUyBjaGVja2VkPScrc3RyKGxlbihkWydkYXlzJ10pKSsnIHRvdGFsPTMwIGNvbXBsZXRlPScrc3RyKGQuZ2V0KCdjb21wbGV0ZScsRmFsc2UpKSkKaWYgX19uYW1lX189PSdfX21haW5fXyc6bWFpbigpCg=='}.items():
 p=Path(name);t=p.with_suffix('.new');t.write_bytes(base64.b64decode(data));py_compile.compile(str(t),doraise=True)
 t.chmod(0o640);os.chown(t,0,grp.getgrnam('footballweb' if '/football-web/' in name else 'football').gr_gid);os.replace(t,p)
FILES_PY
runuser -u football -- /opt/football/.venv/bin/python /opt/football/app/dedup.py
systemctl start football-injury-view.service
systemctl start football-quality-audit.service
systemctl restart football-web.service
python3 - <<'CHECK_PY'
import json,time,urllib.request
c=json.load(open('/etc/football-web/access.json'));op=urllib.request.build_opener(urllib.request.ProxyHandler({}))
for attempt in range(8):
 try:
  req=urllib.request.Request('http://127.0.0.1:8787/ui-api/data',headers={'Authorization':'Bearer '+c['api_key']})
  with op.open(req,timeout=30) as r:d=json.load(r)
  assert all('recent_coverage' in m for m in d['matches'])
  for m in d['matches']:
   ps=m.get('injuries',{}).get('players',[])
   keys=[(p['fixture_id'],p['team_id'],p.get('player_id') or p['name']) for p in ps]
   assert len(keys)==len(set(keys))
  print('QUALITY_REPAIR_API_OK matches='+str(len(d['matches']))+' pending='+str(d['counts']['pending_groups']))
  break
 except Exception:
  if attempt==7:raise SystemExit('看板验证失败')
  time.sleep(1)
CHECK_PY
cat > /etc/systemd/system/football-recent-repair.service <<'UNIT'
[Unit]
Description=Finite restartable recent 30-day results recheck
After=network-online.target
[Service]
Type=oneshot
User=football
Group=football
ExecStart=/opt/football/.venv/bin/python /opt/football/app/recent_repair.py
TimeoutStartSec=240
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/football
UNIT
cat > /etc/systemd/system/football-recent-repair.timer <<'UNIT'
[Unit]
Description=Process three remaining recent dates per run
[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now football-recent-repair.timer
resume
trap - ERR
systemctl start --no-block football-recent-repair.service football-github-sync.service football-injury-bridge.service
echo 'QUALITY_REPAIR_OK：别名与伤停去重已更新；近30天回查在后台继续，报告随GitHub同步。'
echo '回查完成不等于球队完整赛程已补齐；未确认覆盖的比赛仍有提示，模型没有重训。'
echo "备份：$backup"
