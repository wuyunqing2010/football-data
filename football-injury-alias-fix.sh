#!/bin/bash
set -euo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo '请用 sudo bash'; exit 1; }
exec 9>/run/football-injury-alias-fix.lock
flock -n 9 || exit 1
test -s /opt/football-web/injury_view.py
backup=/var/backups/football-injury-alias-$(date +%Y%m%d-%H%M%S)
mkdir -p "$backup"
cp -a /opt/football-web/injury_view.py "$backup/injury_view.py"
rollback() {
 cp -a "$backup/injury_view.py" /opt/football-web/injury_view.py
 systemctl restart football-web.service || true
 echo '更新失败，已恢复原匹配程序。'
}
trap rollback ERR
python3 - <<'PATCH'
from pathlib import Path
import os,py_compile
p=Path('/opt/football-web/injury_view.py');s=p.read_text()
if '# injury-alias-fix-v1' not in s:
 if s.count('def norm(s):')!=1:raise RuntimeError('匹配程序版本不兼容')
 s=s.replace('def norm(s):',"# injury-alias-fix-v1\nfor group in [['仙台七夕', 'Vegalta Sendai'], ['札幌冈萨', '札幌冈萨多', 'Consadole Sapporo', 'Hokkaido Consadole Sapporo'], ['塞尔塔', '维戈塞尔塔', 'Celta Vigo'], ['马拉加', 'Malaga', 'Málaga'], ['哈马比', 'Hammarby FF', 'Hammarby'], ['布鲁马波', '布鲁马波卡纳', 'IF Brommapojkarna', 'Brommapojkarna'], ['埃沃斯堡', '埃尔沃斯堡', 'SV Elversberg', 'Elversberg'], ['赫塔费', 'Getafe'], ['拉科', '拉科鲁尼亚', 'Deportivo La Coruna', 'Deportivo La Coruña'], ['埃因霍温', 'PSV埃因霍温', 'PSV Eindhoven', 'PSV'], ['鹿斯巴达', '鹿特丹斯巴达', 'Sparta Rotterdam'], ['芝加哥', '芝加哥火焰', 'Chicago Fire'], ['新英格兰', '新英格兰革命', 'New England Revolution']]:\n for name in group: ALIASES[clean(name)]=clean(group[0])\n\n"+'def norm(s):')
 st=p.stat();t=p.with_suffix('.new');t.write_text(s);py_compile.compile(str(t),doraise=True)
 os.chmod(t,st.st_mode);os.chown(t,st.st_uid,st.st_gid);os.replace(t,p)
PATCH
systemctl restart football-web.service
python3 - <<'CHECK'
import json,time,urllib.request,collections
c=json.load(open('/etc/football-web/access.json'));op=urllib.request.build_opener(urllib.request.ProxyHandler({}))
for n in range(8):
 try:
  req=urllib.request.Request('http://127.0.0.1:8787/ui-api/data',headers={'Authorization':'Bearer '+c['api_key']})
  with op.open(req,timeout=25) as r:d=json.load(r)
  assert all('injuries' in m for m in d['matches'])
  print('INJURY_ALIAS_COUNTS '+json.dumps(dict(collections.Counter(m['injuries']['status'] for m in d['matches'])),ensure_ascii=False))
  print('仍未匹配：'+json.dumps([m['home']+'—'+m['away'] for m in d['matches'] if m['injuries']['status']=='unmatched'],ensure_ascii=False))
  break
 except Exception:
  if n==7:raise SystemExit('接口检查失败')
  time.sleep(1)
CHECK
trap - ERR
systemctl start --no-block football-injury-bridge.service
echo 'INJURY_ALIAS_FIX_OK：名称映射已更新，实际匹配数量见上方；加密同步已提交。'
echo '本次使用现有缓存，不额外请求伤停API；不能匹配的比赛仍保留未匹配状态。'
