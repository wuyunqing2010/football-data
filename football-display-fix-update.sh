#!/bin/bash
set -euo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo '请用 sudo bash'; exit 1; }
exec 9>/run/football-display-fix-install.lock
flock -n 9 || exit 1
backup=/var/backups/football-display-fix-$(date +%Y%m%d-%H%M%S)
mkdir -p "$backup"
cp -a /opt/football-web "$backup/web"
was_active=0
systemctl is-active --quiet football-context.timer && was_active=1
systemctl stop football-context.timer
resume(){ if [[ $was_active -eq 1 ]]; then systemctl start football-context.timer; fi; }
rollback(){ cp -a "$backup/web/." /opt/football-web/; systemctl restart football-web.service || true; resume; echo "更新失败，已恢复网页。备份：$backup"; }
trap rollback ERR
for attempt in $(seq 1 45); do
 state=$(systemctl show football-context.service -p ActiveState --value)
 [[ "$state" != active && "$state" != activating ]] && break
 if [[ $attempt -eq 45 ]]; then resume; echo '状态发布任务仍在运行，请稍后再试'; exit 1; fi
 sleep 2
done
python3 - <<'PATCH'
from pathlib import Path
import os
changes=[]
def change(path,marker,replacements):
 p=Path(path);s=p.read_text()
 if marker in s:return
 for old,new in replacements:
  if s.count(old)!=1:raise RuntimeError('版本不匹配：'+path)
  s=s.replace(old,new)
 if p.suffix=='.py':compile(s,path,'exec')
 changes.append((p,s))
change('/opt/football-web/selection_view.py','# lifecycle-display-v1',[(" now=now or datetime.now(timezone.utc);reasons=[];",''' # lifecycle-display-v1
 now=now or datetime.now(timezone.utc)
 if all(type(m.get(k)) is int and m[k]>=0 for k in ('home_goals','away_goals')):
  return {'status':'review','reasons':['比赛已结束，以下用于赛后复盘；历史预测保留原时间。'],'automatic_combination':False}
 for field,status,note in [('kickoff','in_progress','已到开球时间，以下为历史记录；最终赛果待确认。'),('cutoff','closed','已经停售，以下仅供查看历史记录。')]:
  try:
   value=datetime.fromisoformat(str(m[field]).replace('Z','+00:00'))
   if value<=now:return {'status':status,'reasons':[note],'automatic_combination':False}
  except (KeyError,ValueError,TypeError):pass
 reasons=[];''')])
change('/opt/football-web/app.js','// lifecycle-display-v1',[("node('strong','分析筛选：暂不自动推荐')", "node('strong',({review:'赛后复盘',in_progress:'已到开球时间',closed:'已停售'})[sc.status]||'分析筛选：暂不自动推荐')"),("近期赛果覆盖（未确认完整）","近期赛果覆盖（截至当前，非赛前统计）"),("0场不等于球队没有比赛；缺少数据时降低近况参考权重。","可能包含本场已结束比赛；不代表完整赛程，也不能当作赛前近况。0场不等于球队没有比赛。"),("const inj=m.injuries", "// lifecycle-display-v1\nconst inj=m.injuries"),("ib.append(node('small',inj.note||'未用于模型；无记录不等于全员健康。'));", "ib.append(node('small',inj.status==='post_kickoff_snapshot'?'这是赛后查询记录，不用于还原赛前伤停；未用于模型。':inj.note||'未用于模型；无记录不等于全员健康。'));")])
p=Path('/opt/football-web/style.css');s=p.read_text()
if '/* lifecycle-display-v1 */' not in s:changes.append((p,s+'\n/* lifecycle-display-v1 */\n.odds>strong,.odds>small{display:block}.odds>small{margin-top:7px;line-height:1.65}\n'))
for p,s in changes:
 st=p.stat();t=p.with_suffix('.display-new');t.write_text(s);os.chmod(t,st.st_mode);os.chown(t,st.st_uid,st.st_gid);os.replace(t,p)

PATCH
systemctl start football-context.service
systemctl restart football-web.service
python3 - <<'VERIFY'
import json,time,urllib.request
c=json.load(open('/etc/football-web/access.json'));op=urllib.request.build_opener(urllib.request.ProxyHandler({}))
for i in range(8):
 try:
  req=urllib.request.Request('http://127.0.0.1:8787/ui-api/data',headers={'Authorization':'Bearer '+c['api_key']})
  with op.open(req,timeout=40) as response:d=json.load(response)
  assert 'dashboard_audit' in d and 'odds_history' in d
  assert all(m.get('analysis_screen',{}).get('status')=='review' for m in d['matches'] if all(type(m.get(k)) is int for k in ('home_goals','away_goals')))
  assert all('team_history' in m and 'analysis_screen' in m for m in d['matches'])
  print('DISPLAY_API_OK matches='+str(len(d['matches'])))
  break
 except Exception:
  if i==7:raise SystemExit('看板数据检查失败')
  time.sleep(1)
VERIFY
resume
trap - ERR
echo 'DISPLAY_FIX_OK：赛后提示、伤停分行与覆盖说明已修复。'
echo '刷新网页后点开比赛详情；数据有缺口会保留提示，不额外调用伤停API。'
echo "备份：$backup"
