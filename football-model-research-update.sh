#!/bin/bash
set -euo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo '请用 sudo bash'; exit 1; }
exec 9>/run/football-research-install.lock
flock -n 9 || exit 1
backup=/var/backups/football-research-$(date +%Y%m%d-%H%M%S)
mkdir -p "$backup"
for directory in football/app football-audit football-web; do mkdir -p "$backup/$directory"; cp -a "/opt/$directory/." "$backup/$directory/"; done
units='football-train football-predict football-quality-audit football-context football-model-status'
for unit in $units; do
 if systemctl is-active --quiet "$unit.timer"; then echo "$unit.timer" >> "$backup/timers"; fi
 systemctl stop "$unit.timer" 2>/dev/null || true
done
resume(){ if [[ -f "$backup/timers" ]]; then while read -r timer; do systemctl start "$timer"; done < "$backup/timers"; fi; }
rollback(){ for directory in football/app football-audit football-web; do cp -a "$backup/$directory/." "/opt/$directory/"; done; systemctl restart football-web.service || true; resume; echo "失败，已恢复代码：$backup"; }
trap rollback ERR
for unit in $units; do
 for attempt in $(seq 1 90); do
  state=$(systemctl show "$unit.service" -p ActiveState --value 2>/dev/null || true)
  [[ "$state" != active && "$state" != activating ]] && break
  if [[ $attempt -eq 90 ]]; then resume; echo '任务仍在运行，请稍后安装'; exit 1; fi
  sleep 2
 done
done
python3 - <<'PATCH'
from pathlib import Path
import os
changes=[]
def patch(path,marker,old,new):
 p=Path(path);s=next((v for q,v in reversed(changes) if q==p),p.read_text())
 if marker in s:return
 if s.count(old)!=1:raise RuntimeError('Unsupported version '+path)
 s=s.replace(old,new)
 if p.suffix=='.py':compile(s,path,'exec')
 changes.append((p,s))
patch('/opt/football/app/model.py','# research-rates-v1','def rates(model,row):',"def rates(model,row):\n    # research-rates-v1\n    if model.get('algorithm')=='weighted_league_poisson_v1':\n        from research_model import rates as research_rates\n        return research_rates(model,row)")
patch('/opt/football-audit/reliability.py','# research-candidate-v1'," training=json.loads((ROOT/'reports/training.json').read_text())", " # research-candidate-v1\n training=json.loads((ROOT/'reports/research-training.json' if (ROOT/'reports/research-training.json').exists() else ROOT/'reports/training.json').read_text())")
patch('/opt/football-audit/audit.py','# full-review-v1',"p=ROOT/'reports/quality-audit.json';", "# full-review-v1\nfrom full_review import review as full_review\nout['paper']['full_review']=full_review(logs)\nout['paper']['research_training']=safe(ROOT/'reports/research-training.json')\np=ROOT/'reports/quality-audit.json';")
patch('/opt/football-web/app.js','// research-ui-v1',"const comparison=section('新旧模型：同场比较');","// research-ui-v1\nconst researchBox=section('候选模型实验与完整概率复盘');\nconst rr=paper.research_training||{};\nresearchBox.append(node('p',rr.version?'候选 '+rr.version+' · 训练 '+rr.train_matches+' 场 · 固定180天半衰期':'候选模型尚未生成或报告未发布'));\nresearchBox.append(node('small','近期比赛权重更高，联赛参数向整体水平收缩；仅实验，不自动替换当前模型。'));\nif(rr.validation)researchBox.append(table(['同训练数据诊断','验证概率损失','测试概率损失'],[['新候选',metric(rr.validation.wdl_log_loss),metric(rr.test_diagnostic?.wdl_log_loss)],['普通泊松对照',metric(rr.same_split_plain_validation?.wdl_log_loss),metric(rr.same_split_plain_test?.wdl_log_loss)]]));\nresearchBox.append(node('small','历史数据已被检查，以上不是独立的新验证；等后续赛前留档比较。'));\nfor(const v of paper.full_review?.versions||[]){const pane=node('details');pane.append(node('summary','完整概率复盘 · '+v.version+' · '+v.n+'场'));pane.append(node('p','胜平负 Brier 误差 '+metric(v.brier)+'；总进球概率损失 '+metric(v.goals_log_loss)+'（'+v.goals_n+'场）。越低越好。'));\nfor(const [key,label] of [['home','主胜'],['draw','平局'],['away','客胜']]){pane.append(node('h4',label+'：所有已结算比赛'));pane.append(table(['概率档','样本','平均预测','实际发生'],(v.wdl_bins[key]||[]).map((b,i)=>[i*10+'%～'+(i===9?'100%':'不足'+(i+1)*10+'%'),b.n,pct(b.n?b.p_sum/b.n:null),pct(b.n?b.hits/b.n:null)])));}\npane.append(node('h4','总进球：逐项发生比例'));pane.append(table(['进球','样本','平均预测','实际发生'],Object.entries(v.goals_bins||{}).map(([k,b])=>[k,b.n,pct(b.n?b.p_sum/b.n:null),pct(b.n?b.hits/b.n:null)])));\npane.append(node('p','前五比分覆盖：'+v.top5_hits+' / '+v.scores_n+'；平均预测覆盖 '+pct(v.scores_n?v.top5_probability_sum/v.scores_n:null)+'。前五比分没中不等于整场胜平负没中。'));researchBox.append(pane);}\nreview.append(researchBox);\n"+"\nconst comparison=section('新旧模型：同场比较');")
# Saved per-team training sample counts only; never substitute current database counts.
patch('/opt/football-web/publish_model_status.py','# sample-status-v1',"x.update(active=bool(m)","# sample-status-v1\nx['team_samples']=m.get('team_samples',{})\nx['alias_map']=m.get('alias_map',{})\nx['teams']=m.get('teams',[])\nx.update(active=bool(m)")
patch('/opt/football-web/prediction_view.py','# sample-view-v1',"    'probabilities':pick(p,'home draw away total_goals top5_scores expected_home_goals expected_away_goals score_grid_tail_probability')}","""    'probabilities':pick(p,'home draw away total_goals top5_scores expected_home_goals expected_away_goals score_grid_tail_probability')}
  # sample-view-v1
  import unicodedata
  counts={}
  for side in ('home','away'):
   name=''.join(unicodedata.normalize('NFKC',str(m[side])).split())
   team=status.get('alias_map',{}).get(name,name) if status.get('alias_map') else m[side]
   counts[side]=status.get('team_samples',{}).get(team)
  m['prediction']['training_samples']=counts
""")
patch('/opt/football-web/app.js','// sample-ui-v1',"detail.append(node('h4','让球胜平负（主队让球）'));", """// sample-ui-v1
  const counts=m.prediction?.training_samples||{};
  detail.append(node('h4','当前模型训练覆盖'));
  for(const side of ['home','away'])detail.append(node('p',m[side]+'：'+(Number.isInteger(counts[side])?counts[side]+'场'+(counts[side]<20?'（样本较少）':''):'该模型未保存球队样本数，不能用当前库内数量代替')));
  detail.append(node('small','20场仅为资料提示门槛，不代表预测可靠。'));
  detail.append(node('h4','让球胜平负（主队让球）'));""")
for path,content in {'/opt/football/app/research_model.py': '"""Fixed experimental Poisson specification. Never promotes itself."""\nimport math\nfrom datetime import datetime\nimport numpy as np\nfrom scipy.optimize import minimize\nALGORITHM=\'weighted_league_poisson_v1\'\ndef weights(rows,anchor,half_life=180):\n return np.array([2**(-max(0,(anchor-r[\'kickoff\']).total_seconds()/86400)/half_life) for r in rows])\ndef fit(rows,anchor,half_life=180):\n teams=sorted({r[k] for r in rows for k in (\'home\',\'away\')});leagues=sorted({r[\'league\'] for r in rows})\n ti={t:i for i,t in enumerate(teams)};li={t:i for i,t in enumerate(leagues)};n=len(teams);q=len(leagues)\n h=np.array([ti[r[\'home\']] for r in rows]);a=np.array([ti[r[\'away\']] for r in rows]);l=np.array([li[r[\'league\']] for r in rows])\n hg=np.array([r[\'hg\'] for r in rows]);ag=np.array([r[\'ag\'] for r in rows]);w=weights(rows,anchor,half_life)\n offset=2+2*n;x=np.zeros(offset+2*q);x[0]=np.log(max(.1,np.average(ag,weights=w)));x[1]=np.log(max(.1,np.average(hg,weights=w)))-x[0]\n penalty=np.array([0.,0.]+[3.]*(2*n)+[12.]*(2*q))\n def objective(x):\n  lh=x[0]+x[1]+x[2+h]+x[2+n+a]+x[offset+l]+x[offset+q+l]\n  la=x[0]+x[2+a]+x[2+n+h]+x[offset+l]\n  mh=np.exp(lh);ma=np.exp(la);dh=w*(mh-hg);da=w*(ma-ag)\n  loss=np.sum(w*(mh-hg*lh+ma-ag*la))+np.sum(penalty*x*x)\n  g=2*penalty*x;g[0]+=sum(dh)+sum(da);g[1]+=sum(dh)\n  for indices,v in [(2+h,dh),(2+a,da),(2+n+a,dh),(2+n+h,da),(offset+l,dh+da),(offset+q+l,dh)]:np.add.at(g,indices,v)\n  return loss,g\n res=minimize(objective,x,jac=True,method=\'L-BFGS-B\',bounds=[(-2,2),(-1,1)]+[(-2,2)]*(2*n)+[(-1,1)]*(2*q),options={\'maxiter\':500})\n if not res.success:raise RuntimeError(\'research_optimizer_failed\')\n return {\'algorithm\':ALGORITHM,\'teams\':teams,\'leagues\':leagues,\'coef\':res.x.tolist(),\'half_life_days\':half_life,\'weight_anchor\':anchor.isoformat(),\'baseline_home\':float(np.average(hg,weights=w)),\'baseline_away\':float(np.average(ag,weights=w)),\'team_samples\':{t:sum(t in (r[\'home\'],r[\'away\']) for r in rows) for t in teams},\'team_weighted_samples\':{t:float(sum(w[i] for i,r in enumerate(rows) if t in (r[\'home\'],r[\'away\']))) for t in teams},\'league_samples\':{t:sum(r[\'league\']==t for r in rows) for t in leagues}}\ndef rates(model,row):\n from model import normalize_model_team\n teams={t:i for i,t in enumerate(model[\'teams\'])};leagues={t:i for i,t in enumerate(model[\'leagues\'])};x=model[\'coef\'];n=len(teams);q=len(leagues);offset=2+2*n\n h=teams.get(normalize_model_team(model,row[\'home\']));a=teams.get(normalize_model_team(model,row[\'away\']));l=leagues.get(row.get(\'league\'))\n attack=lambda i:x[2+i] if i is not None else 0\n defense=lambda i:x[2+n+i] if i is not None else 0\n base=x[0]+(x[offset+l] if l is not None else 0);home=x[1]+(x[offset+q+l] if l is not None else 0)\n return float(np.clip(math.exp(base+home+attack(h)+defense(a)),.05,10)),float(np.clip(math.exp(base+attack(a)+defense(h)),.05,10))\ndef coverage(model,row):\n from model import normalize_model_team\n out={}\n for side in (\'home\',\'away\'):\n  team=normalize_model_team(model,row[side]);n=model.get(\'team_samples\',{}).get(team)\n  out[side]={\'samples\':n,\'weighted_samples\':model.get(\'team_weighted_samples\',{}).get(team),\'status\':\'unseen\' if team not in model[\'teams\'] else \'unknown\' if n is None else \'limited\' if n<20 else \'available\'}\n out[\'note\']=\'20场仅为资料提示门槛，不代表概率已经可靠；加权样本量是权重之和。\'\n return out\n', '/opt/football/app/train_research.py': "import sys,json,hashlib\nfrom pathlib import Path\nfrom datetime import timedelta\nsys.path.insert(0,'/opt/football/app')\nimport football,model,research_model\nfrom psycopg.rows import dict_row\nROOT=Path('/opt/football')\ndef main():\n report=ROOT/'reports/research-training.json'\n if report.exists() and json.loads(report.read_text()).get('algorithm')==research_model.ALGORITHM:\n  print('RESEARCH_ALREADY_TRAINED frozen candidate retained');return\n with football.connect() as db:\n  if not db.execute('SELECT pg_try_advisory_lock(70220260910)').fetchone()[0]:raise RuntimeError('collector_busy_retry_later')\n  with db.cursor(row_factory=dict_row) as cur:\n   cur.execute('''SELECT m.source_id,m.sale_date,m.home,m.away,m.league,m.kickoff,m.cutoff,r.home_goals AS hg,r.away_goals AS ag,r.published_at,r.observed_at FROM canonical_matches m JOIN canonical_results r USING(canonical_id,source,source_id) WHERE m.source='source_a' AND m.kickoff<now() AND r.published_at<=now() ORDER BY m.sale_date,m.kickoff,m.source_id''');rows,excluded=model.clean_rows(cur.fetchall())\n dates=sorted({r['sale_date'] for r in rows})\n if len(rows)<500 or len(dates)<90:raise RuntimeError('insufficient_training_data')\n vd=dates[int(len(dates)*.7)];td=dates[int(len(dates)*.85)];vc=min(r['cutoff'] for r in rows if r['sale_date']>=vd)-timedelta(hours=2);tc=min(r['cutoff'] for r in rows if r['sale_date']>=td)-timedelta(hours=2)\n train=[r for r in rows if r['sale_date']<vd and r['published_at']<vc and r['kickoff']<vc];val=[r for r in rows if vd<=r['sale_date']<td and r['published_at']<tc and r['kickoff']<tc];test=[r for r in rows if r['sale_date']>=td]\n if min(len(train),len(val),len(test))<30:raise RuntimeError('insufficient_split')\n candidate=research_model.fit(train,vc)\n from dedup import ALIASES\n candidate['alias_map']=dict(ALIASES)\n stamp=football.now();version='research-'+stamp.strftime('%Y%m%dT%H%M%SZ')\n fingerprint=hashlib.sha256(json.dumps(rows,default=str,sort_keys=True).encode()).hexdigest()\n candidate.update(version=version,trained_at=stamp.isoformat(),train_end=max(r['published_at'] for r in train).isoformat(),training_matches=len(train),data_hash=fingerprint)\n comparator=model.fit(train);comparator['alias_map']=dict(ALIASES)\n # Same training split controls data differences. Historical results were already inspected,\n # so every retrospective metric is diagnostic only, with no promotion rule.\n result={'algorithm':research_model.ALGORITHM,'status':'candidate_only','version':version,'at':stamp.isoformat(),'train_matches':len(train),'excluded':excluded,'half_life_days':180,'validation':model.evaluate(candidate,val),'same_split_plain_validation':model.evaluate(comparator,val),'test_diagnostic':model.evaluate(candidate,test),'same_split_plain_test':model.evaluate(comparator,test),'auto_promotion':False,'note':'固定180天半衰期与联赛收缩参数，未按本次成绩调参。历史数据已被检查，结果仅诊断；后续同场赛前比较才是新增证据。联赛基础进球差异不等于已解决跨联赛实力。'}\n football.atomic(ROOT/'models'/version/'model.json',candidate)\n football.atomic(ROOT/'models'/version/'evaluation.json',result)\n football.atomic(ROOT/'models'/version/'training-records.json',{'train':train,'validation':val,'test':test})\n football.atomic(report,result)\n print('RESEARCH_CANDIDATE_OK version='+version+' train='+str(len(train)))\nif __name__=='__main__':main()\n", '/opt/football-audit/full_review.py': "import math\nK=('home','draw','away')\ndef review(records):\n groups={};seen=set()\n for r in records:\n  key=r.get('canonical_id');version=r.get('model_version');res=r.get('result')\n  if not key or key in seen or not version:continue\n  seen.add(key)\n  if not res:continue\n  p=r.get('probabilities',{})\n  if not all(isinstance(p.get(k),(float,int)) and math.isfinite(p[k]) and 0<=p[k]<=1 for k in K) or abs(sum(p[k] for k in K)-1)>1e-5:continue\n  h,a=res.get('home_goals'),res.get('away_goals')\n  if type(h) is not int or type(a) is not int or min(h,a)<0:continue\n  y='home' if h>a else 'away' if h<a else 'draw'\n  g=groups.setdefault(version,{'version':version,'n':0,'brier_sum':0.,'wdl_bins':{k:[{'n':0,'hits':0,'p_sum':0.} for _ in range(10)] for k in K},'goals_n':0,'goals_loss_sum':0.,'goals_bins':{str(k):{'n':0,'hits':0,'p_sum':0.} for k in range(7)}|{'7+':{'n':0,'hits':0,'p_sum':0.}},'scores_n':0,'top5_hits':0,'top5_probability_sum':0.})\n  g['n']+=1;g['brier_sum']+=sum((p[k]-int(y==k))**2 for k in K)\n  for k in K:\n   b=g['wdl_bins'][k][min(9,int(p[k]*10))];b['n']+=1;b['hits']+=int(y==k);b['p_sum']+=p[k]\n  goals=r.get('total_goals') or {};label=str(h+a) if h+a<7 else '7+'\n  if all(type(goals.get(k)) in (int,float) and math.isfinite(goals[k]) and 0<=goals[k]<=1 for k in g['goals_bins']) and abs(sum(goals[k] for k in g['goals_bins'])-1)<1e-5:\n   g['goals_n']+=1;g['goals_loss_sum']-=math.log(max(1e-12,goals[label]))\n   for k,b in g['goals_bins'].items():b['n']+=1;b['hits']+=int(k==label);b['p_sum']+=goals[k]\n  scores=r.get('top5_scores') or {}\n  if len(scores)==5 and all(type(v) in (float,int) and math.isfinite(v) and 0<=v<=1 for v in scores.values()) and sum(scores.values())<=1+1e-5:\n   g['scores_n']+=1;g['top5_hits']+=int(f'{h}:{a}' in scores);g['top5_probability_sum']+=sum(scores.values())\n for g in groups.values():\n  g['brier']=g.pop('brier_sum')/g['n'];g['goals_log_loss']=g.pop('goals_loss_sum')/g['goals_n'] if g['goals_n'] else None\n return {'versions':list(groups.values()),'note':'主胜、平局、客胜分别对所有已结算比赛统计；三个方向样本相关，不能相加当独立比赛。比分只评估已留档的前五比分覆盖率，不伪造完整比分分布。'}\n"}.items():
 p=Path(path);compile(content,path,'exec');changes.append((p,content))
for p,s in changes:
 st=p.stat() if p.exists() else Path('/opt/football/app/model.py' if '/app/' in str(p) else '/opt/football-audit/audit.py').stat()
 t=p.with_suffix('.research-new');t.write_text(s);os.chmod(t,st.st_mode);os.chown(t,st.st_uid,st.st_gid);os.replace(t,p)

PATCH
systemctl start football-model-status.service
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
  assert 'full_review' in d.get('dashboard_audit',{}).get('paper',{})
  print('RESEARCH_VIEW_OK matches='+str(len(d['matches'])))
  break
 except Exception:
  if i==7:raise SystemExit('看板检查失败')
  time.sleep(1)
VERIFY
cat > /etc/systemd/system/football-research-train.service <<'UNIT'
[Unit]
Description=Train frozen experimental model without promotion
[Service]
Type=oneshot
User=football
Group=football
ExecStart=/opt/football/.venv/bin/python /opt/football/app/train_research.py
TimeoutStartSec=15min
MemoryMax=1200M
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/football/models /opt/football/reports
UNIT
install -d -m 700 /opt/football-research
cat > /opt/football-research/finish.py <<'WORKER'
import subprocess,time,hashlib
from pathlib import Path
p=Path('/opt/football/models/active.json');before=hashlib.sha256(p.read_bytes()).hexdigest()
for i in range(3):
 r=subprocess.run(['systemctl','start','football-research-train.service'])
 if r.returncode==0:break
 if i==2:raise SystemExit('RESEARCH_TRAIN_FAILED see football-research-train.service logs')
 time.sleep(10)
if hashlib.sha256(p.read_bytes()).hexdigest()!=before:raise SystemExit('ACTIVE_MODEL_CHANGED_DURING_TRAIN_CHECK')
for unit in ['football-quality-audit','football-context','football-github-sync','football-injury-bridge']:
 subprocess.run(['systemctl','start',unit+'.service'],check=True)
print('RESEARCH_READY current model retained; candidate comparison and reports published',flush=True)
WORKER
cat > /etc/systemd/system/football-research-finish.service <<'UNIT'
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/football-research/finish.py
TimeoutStartSec=50min
UNIT
systemctl daemon-reload
resume
trap - ERR
systemctl start --no-block football-research-finish.service
echo 'RESEARCH_INSTALLED：完整概率复盘和球队样本提示已接入，候选训练在后台进行。'
echo '当前模型不自动替换；本次不调用伤停API。训练是否成功需查看后台结果。'
echo '查看：journalctl -u football-research-train.service -u football-research-finish.service -n 15 --no-pager'
echo "备份：$backup"
