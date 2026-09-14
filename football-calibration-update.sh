#!/bin/bash
set -euo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo '请用 sudo bash'; exit 1; }
exec 9>/run/football-calibration-install.lock
flock -n 9 || exit 1
backup=/var/backups/football-calibration-$(date +%Y%m%d-%H%M%S)
mkdir -p "$backup"
cp -a /opt/football-web "$backup/web"
cp -a /opt/football-audit "$backup/audit"
audit_active=0
systemctl is-active --quiet football-quality-audit.timer && audit_active=1
systemctl stop football-quality-audit.timer
was_active=0
systemctl is-active --quiet football-context.timer && was_active=1
systemctl stop football-context.timer
resume(){ if [[ $audit_active -eq 1 ]]; then systemctl start football-quality-audit.timer; fi; if [[ $was_active -eq 1 ]]; then systemctl start football-context.timer; fi; }
rollback(){ cp -a "$backup/web/." /opt/football-web/; cp -a "$backup/audit/." /opt/football-audit/; systemctl restart football-web.service || true; resume; echo "更新失败，已恢复网页。备份：$backup"; }
trap rollback ERR
for unit in football-context football-quality-audit; do
for attempt in $(seq 1 90); do
 state=$(systemctl show "$unit.service" -p ActiveState --value)
 [[ "$state" != active && "$state" != activating ]] && break
 if [[ $attempt -eq 90 ]]; then resume; echo '状态发布任务仍在运行，请稍后再试'; exit 1; fi
 sleep 2
done
done
python3 - <<'PATCH'
from pathlib import Path
import os
files=[]
p=Path('/opt/football-audit/audit.py');s=p.read_text()
if '# calibration-report-v1' not in s:
 anchor="p=ROOT/'reports/quality-audit.json';"
 if s.count(anchor)!=1:raise RuntimeError('Audit version mismatch')
 s=s.replace(anchor,"# calibration-report-v1\nfrom calibration import calculate\nout['paper']['calibration']=calculate(logs)\n"+anchor);compile(s,str(p),'exec');files.append((p,s))
p=Path('/opt/football-web/app.js');s=p.read_text()
if '// calibration-view-v1' not in s:
 anchor="const comparison=section('新旧模型：同场比较');"
 if s.count(anchor)!=1:raise RuntimeError('Dashboard version mismatch')
 s=s.replace(anchor,"// calibration-view-v1\nconst cal=paper.calibration||{},calBox=section('预测概率与实际命中率');\ncalBox.append(node('p','每场只统计首次赛前留档中概率最高的选项，未结算不算输。模型版本分开；不使用事后重算预测。','muted'));\nconst versionSelect=node('select'),scopeSelect=node('select'),versionLabel=node('label','模型版本 '),scopeLabel=node('label',' 统计方向 '),output=node('div');\nfor(const v of cal.versions||[]){const option=node('option',v.version);option.value=v.version;versionSelect.append(option);}\nfor(const [value,label] of [['all','全部最高概率选项'],['home','最高概率为主胜'],['draw','最高概率为平局'],['away','最高概率为客胜']]){const option=node('option',label);option.value=value;scopeSelect.append(option);}\nversionLabel.append(versionSelect);scopeLabel.append(scopeSelect);calBox.append(versionLabel,scopeLabel,output);\nfunction drawCalibration(){output.replaceChildren();const v=(cal.versions||[]).find(v=>v.version===versionSelect.value);if(!v){output.append(node('p','暂无概率分档报告，等待下一次复盘发布。'));return;}\noutput.append(node('p','该版本留档 '+v.enrolled+' 场 · 已结算 '+v.settled+' 场 · 等待赛果 '+v.pending+' 场'+(v.invalid?' · 无效记录 '+v.invalid+' 场':'')));\noutput.append(table(['预测概率档','样本','赢 / 未中','平均预测','实际命中','实际－预测'],(v.bins[scopeSelect.value]||[]).map(b=>[b.lower+'%～'+(b.upper===100?'100%':'不足'+b.upper+'%'),b.n,b.wins+' / '+b.losses,pct(b.mean_prediction),pct(b.actual_rate),Number.isFinite(b.gap_pp)?(b.gap_pp>0?'+':'')+b.gap_pp.toFixed(1)+'个百分点':'—'])));\noutput.append(node('p','负差值表示实际命中低于预测。先看样本数，不能凭几场就认定某个概率档不准；不同档要比较比例，而非输球场数。','muted'));}\nversionSelect.addEventListener('change',drawCalibration);scopeSelect.addEventListener('change',drawCalibration);drawCalibration();review.append(calBox);\n"+'\n'+anchor);files.append((p,s))
p=Path('/opt/football-audit/calibration.py')
compile('"""Calibration of immutable prospective paper records, grouped by model version."""\nimport math\nKEYS=(\'home\',\'draw\',\'away\')\ndef calculate(records):\n groups={};seen=set();excluded=0\n for r in records:\n  key=r.get(\'canonical_id\');version=r.get(\'model_version\')\n  if not key or not version or key in seen:excluded+=1;continue\n  seen.add(key)\n  g=groups.setdefault(version,{\'version\':version,\'enrolled\':0,\'settled\':0,\'pending\':0,\'invalid\':0,\'bins\':{}});g[\'enrolled\']+=1\n  if r.get(\'result\') is None:g[\'pending\']+=1;continue\n  try:\n   p=r[\'probabilities\'];res=r[\'result\']\n   if not all(type(p[k]) in (int,float) and math.isfinite(p[k]) and 0<=p[k]<=1 for k in KEYS) or abs(sum(p[k] for k in KEYS)-1)>1e-5:raise ValueError()\n   if not all(type(res[k]) is int and res[k]>=0 for k in (\'home_goals\',\'away_goals\')):raise ValueError()\n   choice=max(KEYS,key=lambda k:p[k]);prob=p[choice]\n   y=\'home\' if res[\'home_goals\']>res[\'away_goals\'] else \'away\' if res[\'home_goals\']<res[\'away_goals\'] else \'draw\'\n   slot=min(9,int(prob*10));g[\'settled\']+=1\n   for scope in (\'all\',choice):\n    b=g[\'bins\'].setdefault(scope,{}).setdefault(slot,{\'n\':0,\'wins\':0,\'sum_probability\':0.})\n    b[\'n\']+=1;b[\'wins\']+=int(choice==y);b[\'sum_probability\']+=prob\n  except (KeyError,TypeError,ValueError):g[\'invalid\']+=1\n for g in groups.values():\n  for scope in (\'all\',*KEYS):\n   values=[]\n   for slot in range(3,10):\n    b=g[\'bins\'].get(scope,{}).get(slot,{\'n\':0,\'wins\':0,\'sum_probability\':0.});n=b[\'n\'];avg=b[\'sum_probability\']/n if n else None;actual=b[\'wins\']/n if n else None\n    values.append({\'lower\':slot*10,\'upper\':(slot+1)*10,\'n\':n,\'wins\':b[\'wins\'],\'losses\':n-b[\'wins\'],\'mean_prediction\':avg,\'actual_rate\':actual,\'gap_pp\':(actual-avg)*100 if n else None})\n   g[\'bins\'][scope]=values\n return {\'rule\':\'每场首次赛前留档中概率最高的胜平负选项；平概率按主胜、平、客胜顺序选一项。按模型版本分开；方向筛选仅保留该方向是最高概率的比赛。\',\'versions\':list(groups.values()),\'excluded_records\':excluded,\'note\':\'使用全部留档，不限最近100条。未结算不算输；小样本波动大，命中率不等于盈利率。\'}\n',str(p),'exec');files.append((p,'"""Calibration of immutable prospective paper records, grouped by model version."""\nimport math\nKEYS=(\'home\',\'draw\',\'away\')\ndef calculate(records):\n groups={};seen=set();excluded=0\n for r in records:\n  key=r.get(\'canonical_id\');version=r.get(\'model_version\')\n  if not key or not version or key in seen:excluded+=1;continue\n  seen.add(key)\n  g=groups.setdefault(version,{\'version\':version,\'enrolled\':0,\'settled\':0,\'pending\':0,\'invalid\':0,\'bins\':{}});g[\'enrolled\']+=1\n  if r.get(\'result\') is None:g[\'pending\']+=1;continue\n  try:\n   p=r[\'probabilities\'];res=r[\'result\']\n   if not all(type(p[k]) in (int,float) and math.isfinite(p[k]) and 0<=p[k]<=1 for k in KEYS) or abs(sum(p[k] for k in KEYS)-1)>1e-5:raise ValueError()\n   if not all(type(res[k]) is int and res[k]>=0 for k in (\'home_goals\',\'away_goals\')):raise ValueError()\n   choice=max(KEYS,key=lambda k:p[k]);prob=p[choice]\n   y=\'home\' if res[\'home_goals\']>res[\'away_goals\'] else \'away\' if res[\'home_goals\']<res[\'away_goals\'] else \'draw\'\n   slot=min(9,int(prob*10));g[\'settled\']+=1\n   for scope in (\'all\',choice):\n    b=g[\'bins\'].setdefault(scope,{}).setdefault(slot,{\'n\':0,\'wins\':0,\'sum_probability\':0.})\n    b[\'n\']+=1;b[\'wins\']+=int(choice==y);b[\'sum_probability\']+=prob\n  except (KeyError,TypeError,ValueError):g[\'invalid\']+=1\n for g in groups.values():\n  for scope in (\'all\',*KEYS):\n   values=[]\n   for slot in range(3,10):\n    b=g[\'bins\'].get(scope,{}).get(slot,{\'n\':0,\'wins\':0,\'sum_probability\':0.});n=b[\'n\'];avg=b[\'sum_probability\']/n if n else None;actual=b[\'wins\']/n if n else None\n    values.append({\'lower\':slot*10,\'upper\':(slot+1)*10,\'n\':n,\'wins\':b[\'wins\'],\'losses\':n-b[\'wins\'],\'mean_prediction\':avg,\'actual_rate\':actual,\'gap_pp\':(actual-avg)*100 if n else None})\n   g[\'bins\'][scope]=values\n return {\'rule\':\'每场首次赛前留档中概率最高的胜平负选项；平概率按主胜、平、客胜顺序选一项。按模型版本分开；方向筛选仅保留该方向是最高概率的比赛。\',\'versions\':list(groups.values()),\'excluded_records\':excluded,\'note\':\'使用全部留档，不限最近100条。未结算不算输；小样本波动大，命中率不等于盈利率。\'}\n'))
for p,s in files:
 st=p.stat() if p.exists() else Path('/opt/football-audit/audit.py').stat();t=p.with_suffix('.cal-new');t.write_text(s);os.chmod(t,st.st_mode);os.chown(t,st.st_uid,st.st_gid);os.replace(t,p)

PATCH
systemctl start football-quality-audit.service
systemctl start football-context.service
systemctl restart football-web.service
python3 - <<'VERIFY'
import json,time,urllib.request
c=json.load(open('/etc/football-web/access.json'));op=urllib.request.build_opener(urllib.request.ProxyHandler({}))
for i in range(8):
 try:
  req=urllib.request.Request('http://127.0.0.1:8787/ui-api/data',headers={'Authorization':'Bearer '+c['api_key']})
  with op.open(req,timeout=40) as response:d=json.load(response)
  assert 'calibration' in d.get('dashboard_audit',{}).get('paper',{})
  assert all('team_history' in m and 'analysis_screen' in m for m in d['matches'])
  print('CALIBRATION_API_OK matches='+str(len(d['matches'])))
  break
 except Exception:
  if i==7:raise SystemExit('看板数据检查失败')
  time.sleep(1)
VERIFY
resume
trap - ERR
echo 'CALIBRATION_UPDATE_OK：概率分档复盘已接入，可按模型版本和预测方向查看。'
echo '刷新网页后点开比赛详情；数据有缺口会保留提示，不额外调用伤停API。'
echo "备份：$backup"
