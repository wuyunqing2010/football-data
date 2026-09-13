#!/bin/bash
set -euo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo '请用 sudo bash'; exit 1; }
exec 9>/run/football-dashboard-install.lock
flock -n 9 || exit 1
backup=/var/backups/football-dashboard-$(date +%Y%m%d-%H%M%S)
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
import os,py_compile
changes=[]
def stage(path,marker,old,new):
 p=Path(path);s=next((v for q,v in reversed(changes) if q==p),p.read_text())
 if marker in s:return
 if s.count(old)!=1:raise RuntimeError('版本不匹配：'+path)
 s=s.replace(old,new)
 if p.suffix=='.py':compile(s,path,'exec')
 changes.append((p,s))
stage('/opt/football-web/publish_context.py','# dashboard-audit-v1'," p=Path('/opt/football-web/context-data.json');", """ # dashboard-audit-v1
 audit=read(ROOT/'reports/quality-audit.json')
 health['dashboard_audit']={k:audit[k] for k in ('at','paper','paired_evaluation','settlement_check') if k in audit}
 p=Path('/opt/football-web/context-data.json');""")
stage('/opt/football-web/web.py','# dashboard-audit-v1','  return result\n',"""  # dashboard-audit-v1
  from datetime import datetime as audit_datetime, timezone as audit_timezone
  try:
   cache=json.loads((BASE/'context-data.json').read_text())
   audit=cache.get('health',{}).get('dashboard_audit',{})
   age=(audit_datetime.now(audit_timezone.utc)-audit_datetime.fromisoformat(audit['at'])).total_seconds()
   audit['stale']=not 0<=age<=1800
  except (OSError,ValueError,KeyError,TypeError):audit={'stale':True}
  result['dashboard_audit']=audit
  return result
""")
stage('/opt/football-web/web.py',"'/api/v1/analysis','/download.json','/ui-api/data'", "path in ('/api/v1/analysis','/download.json')", "path in ('/api/v1/analysis','/download.json','/ui-api/data')")
stage('/opt/football-web/app.js','enhanceDashboard(d);',"$('download').href=", "enhanceDashboard(d);\n$('download').href=")
for p,s in changes:
 st=p.stat();t=p.with_suffix('.upgrade');t.write_text(s);os.chmod(t,st.st_mode);os.chown(t,st.st_uid,st.st_gid);os.replace(t,p)
p=Path('/opt/football-web/app.js');s=p.read_text()
if '// dashboard-upgrade-v1' not in s:p.write_text("// dashboard-upgrade-v1\nconst openMatches=new Set();\nfunction enhanceDashboard(d){\n const pct=v=>Number.isFinite(v)?(v*100).toFixed(1)+'%':'暂无';\n const metric=v=>Number.isFinite(v)?v.toFixed(3):'暂无';\n const section=(title)=>{const el=node('section',undefined,'match');el.append(node('h3',title));return el;};\n const table=(headers,rows)=>{const scroll=node('div',undefined,'table-scroll'),t=node('table'),head=node('tr');for(const h of headers)head.append(node('th',h));const thead=node('thead');thead.append(head);t.append(thead);const body=node('tbody');for(const values of rows){const tr=node('tr');for(const value of values)tr.append(node('td',value??'—'));body.append(tr);}t.append(body);scroll.append(t);return scroll;};\n const audit=d.dashboard_audit||{},paper=audit.paper||{},pair=audit.paired_evaluation||{};\n const overview=section('今天的数据能不能用');overview.append(node('p','程序运行正常 ≠ 资料完整 ≠ 预测可靠','muted'));\n const services=d.system_health?.services||{};const names={'football-collect':'比赛采集','football-predict':'模型预测','football-github-sync':'公开数据同步','football-injuries':'伤停采集','football-injury-bridge':'伤停加密同步','football-quality-audit':'复盘检查'};\n overview.append(table(['任务','最近执行','状态'],Object.entries(names).map(([k,n])=>[n,services[k]?.ExecMainExitTimestamp||'暂无',services[k]?.Result==='success'?'执行成功':services[k]?.Result==='stale_or_never_finished'?'较旧或尚未完成':services[k]?.Result||'未知'])));\n overview.append(node('small','运行报告 '+format(d.system_health?.at)+' · '+(d.system_health?.status==='stale'?'报告已过期':'各任务时间独立显示')));\n const review=section('赛前留档与赛后复盘');review.append(node('p','留档 '+(paper.enrolled??'—')+' 场 · 已结算 '+(paper.settled??'—')+' 场 · 待结算 '+(Number.isFinite(paper.enrolled)&&Number.isFinite(paper.settled)?paper.enrolled-paper.settled:'—')+' 场'));\n review.append(node('p','全部已结算留档：胜平负准确率 '+pct(paper.accuracy)+' · 概率对数损失 '+metric(paper.log_loss)));\n review.append(node('small','对数损失越低越好；这些是全部符合留档条件的模拟记录，不是实际投注成绩。少量样本不能证明可靠。'));\n review.append(node('p','报告 '+format(audit.at)+(audit.stale?' · 已过期或不可用':''),'muted'));\n const states={settled:'已结算',waiting_for_source_result:'等待来源赛果',waiting_for_match:'等待比赛及赛果',canonical_mapping_missing:'比赛匹配待检查'};\n for(const [k,v] of Object.entries(audit.settlement_check?.counts||{}))review.append(node('p',(states[k]||k)+'：'+v));\n const comparison=section('新旧模型：同场比较');comparison.append(node('p','当前使用 '+(d.model?.version||'未知')),node('p','比较模型 '+(pair.incumbent||'暂无')+' / '+(pair.candidate||'暂无')),node('p','同场留档 '+(pair.enrolled??0)+' 场 · 已结算 '+(pair.settled??0)+' 场'));\n comparison.append(table(['同一批已结算比赛','概率对数损失'],[['旧模型',metric(pair.incumbent_log_loss)],['候选模型',metric(pair.candidate_log_loss)],['赔率参考',metric(pair.market_log_loss)]]));comparison.append(node('p',pair.status==='failed'?'比较任务失败，需检查日志':'正在积累未来比赛；不会据此自动替换模型。','muted'));\n $('matches').prepend(overview,review,comparison);\n const cards=d.matches.length?Array.from($('matches').querySelectorAll('article.match')).slice(-d.matches.length):[];\n for(let i=0;i<cards.length;i++){\n  const m=d.matches[i],card=cards[i],detail=node('details'),summary=node('summary','查看比赛详情：赔率、预测、伤停与复盘');detail.append(summary);detail.open=openMatches.has(m.canonical_id);detail.addEventListener('toggle',()=>{if(detail.open)openMatches.add(m.canonical_id);else openMatches.delete(m.canonical_id);});\n  const brief=node('p',(m.analysis_screen?.reasons||['资料完整性待核查']).join('；'),'warn');\n  const children=Array.from(card.children);for(const child of children.slice(2))detail.append(child);card.append(brief,detail);\n  detail.append(node('h4','让球胜平负（主队让球）'));\n  for(const s of m.odds_sources||[]){const market=s.markets?.rqspf;detail.append(node('p',s.name+' · 让球 '+(market?.concede??'未知')+' · 让胜 '+(market?.odds?.home??'—')+' / 让平 '+(market?.odds?.draw??'—')+' / 让负 '+(market?.odds?.away??'—')));}\n  detail.append(node('h4','实际采集的赔率变化'));\n  const history=(d.odds_history||[]).filter(x=>x.canonical_id===m.canonical_id).sort((a,b)=>new Date(b.observed_at)-new Date(a.observed_at));\n  detail.append(node('small','按采集时间倒序，最多展示最近60条。停售后的记录另行标注；缺口不插值，未采集的变化无法还原。'));\n  detail.append(table(['采集时间','来源','胜 / 平 / 负','让球','让胜 / 让平 / 让负'],history.slice(0,60).map(x=>{const p=x.markets?.spf?.odds||{},q=x.markets?.rqspf||{};return [format(x.observed_at)+(new Date(x.observed_at)>=new Date(m.cutoff)?'（停售后）':''),x.source==='source_a'?'A站':'B站',[p.home,p.draw,p.away].map(v=>v??'—').join(' / '),q.concede??'—',[q.odds?.home,q.odds?.draw,q.odds?.away].map(v=>v??'—').join(' / ')];})));\n  if(!history.length)detail.append(node('p','暂无赔率轨迹'));if(d.truncated_odds_history)detail.append(node('p','本次轨迹返回达到上限，记录可能不完整','warn'));\n  detail.append(node('h4','库内近期表现（并非完整近五场）'));\n  for(const side of m.team_history||[]){const games=(side.matches||[]).slice(0,5);detail.append(node('strong',side.team));detail.append(table(['开球时间','比赛','赛果'],games.map(g=>[format(g.kickoff),g.home+' — '+g.away,g.home_goals+':'+g.away_goals])));if(!games.length)detail.append(node('p','暂无已确认赛前可用赛果'));}\n  detail.append(node('small','历史数据截点 '+format(m.history_cutoff)+'；历史回填不能还原当时的所有消息。'));\n  detail.append(node('h4','本场赛前留档与赛后结果'));\n  const saved=(paper.recent_records||[]).find(x=>x.canonical_id===m.canonical_id);\n  if(saved){detail.append(node('p','留档 '+format(saved.enrolled_at)+' · 模型 '+saved.model_version));detail.append(node('p','留档概率：胜 '+pct(saved.probabilities?.home)+' / 平 '+pct(saved.probabilities?.draw)+' / 负 '+pct(saved.probabilities?.away)));detail.append(node('p',saved.result?'已结算：'+saved.result.home_goals+':'+saved.result.away_goals:'尚未结算'));}\n  else detail.append(node('p','当前报告未包含本场赛前留档，不用现在的预测补算历史成绩。'));\n  detail.append(node('p','天气、首发尚未接入；比分、总进球、半全场赔率位置未全部核实。模型概率尚未使用这些信息。','muted'));\n }\n}\n"+'\n'+s)
p=Path('/opt/football-web/style.css');s=p.read_text()
if '/* dashboard-upgrade-v1 */' not in s:p.write_text(s+'\n/* dashboard-upgrade-v1 */\n.table-scroll{overflow-x:auto;max-width:100%}table{border-collapse:collapse;width:100%;font-size:.85rem}th,td{text-align:left;padding:10px;border-bottom:1px solid #e7edf1;min-width:80px}summary{cursor:pointer;padding:14px 0;font-weight:600;color:#166078}details h4{margin-top:24px}.match{overflow-wrap:anywhere}summary:focus-visible{outline:3px solid #269dcd}\n')

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
  assert all('team_history' in m and 'analysis_screen' in m for m in d['matches'])
  print('DASHBOARD_API_OK matches='+str(len(d['matches'])))
  break
 except Exception:
  if i==7:raise SystemExit('看板数据检查失败')
  time.sleep(1)
VERIFY
resume
trap - ERR
echo 'DASHBOARD_UPDATE_OK：状态摘要、资料检查、复盘、双模型比较与比赛详情已接入。'
echo '刷新网页后点开比赛详情；数据有缺口会保留提示，不额外调用伤停API。'
echo "备份：$backup"
