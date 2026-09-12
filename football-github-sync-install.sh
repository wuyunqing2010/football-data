#!/bin/bash
set -euo pipefail
umask 077
if [ "$(id -u)" -ne 0 ]; then echo '请使用 sudo bash 执行'; exit 1; fi
command -v python3 >/dev/null
command -v systemctl >/dev/null
test -f /etc/football-web/access.json || { echo '未找到已安装的足球网页配置'; exit 1; }
install -d -m 700 /etc/football-github-sync /opt/football-github-sync
if [ ! -s /etc/football-github-sync/token ]; then
 echo '请输入仅授权 wuyunqing2010/football-data、Contents 读写权限的 GitHub fine-grained token。输入不会显示。'
 python3 - <<'PY'
import getpass,os,pathlib
s=getpass.getpass('GitHub Token: ').strip()
if not s or any(c.isspace() for c in s):raise SystemExit('令牌为空或含空格')
p=pathlib.Path('/etc/football-github-sync/token');p.write_text(s+'\n');p.chmod(0o600)
PY
fi
cat > /opt/football-github-sync/sync.py <<'PYTHON_PAYLOAD'
import base64, datetime, fcntl, json, os, pathlib, sys, urllib.request, urllib.error
REPO='wuyunqing2010/football-data'
CONFIG=pathlib.Path('/etc/football-github-sync/token')
class NoRedirect(urllib.request.HTTPRedirectHandler):
 def redirect_request(self,*a,**kw): return None

def pick(d, keys):
 return {k:d[k] for k in keys.split() if k in d}

def market(d):
 out={}
 for k in ('spf','rqspf'):
  if isinstance(d.get(k),dict):
   v=d[k]; out[k]=pick(v,'single concede')
   out[k]['odds']=pick(v.get('odds',{}),'home draw away')
 for k in ('goals_slots','score_slots','half_full_slots'):
  if isinstance(d.get(k),dict): out[k]=pick(d[k],'raw_values mapping_status')
 return out

def public_export(d):
 out=pick(d,'at schema_version sale_date truncated_matches truncated_history truncated_odds_history')
 out['counts']=pick(d.get('counts',{}),'unique_matches pending_groups merged_records verified_results snapshots')
 out['history']=pick(d.get('history',{}),'history_start history_end history_cursor')
 out['history_days']=[pick(x,'status dates') for x in d.get('history_days',[])]
 out['sources']=[pick(x,'source name observed_at status records requested_date') for x in d.get('sources',[])]
 out['matches']=[]
 for m in d['matches']:
  item=pick(m,'canonical_id home away league kickoff cutoff sale_date home_goals away_goals result_published_at history_cutoff')
  item['odds_sources']=[]
  for s in m.get('odds_sources',[]):
   q=pick(s,'canonical_id source name home away cutoff observed_at last_seen age_minutes')
   q['markets']=market(s.get('markets',{})); item['odds_sources'].append(q)
  item['team_history']=[]
  for t in m.get('team_history',[]):
   q=pick(t,'side team');q['matches']=[pick(h,'canonical_id home away league kickoff home_goals away_goals published_at observed_at') for h in t.get('matches',[])]
   item['team_history'].append(q)
  out['matches'].append(item)
 out['odds_history']=[]
 for s in d.get('odds_history',[]):
  q=pick(s,'canonical_id source observed_at last_seen');q['markets']=market(s.get('markets',{}));out['odds_history'].append(q)
 out['export_info']={'version':1,'kind':'public_allowlisted_analysis','model_predictions_included':False,'injuries_included':False,'weather_included':False,
 'notes':['No model output, injuries or weather in this export version.','Source B native slots have unverified selection mapping.','Settlement SP is not historical prematch odds.','History is limited to sampled team history, not the full database.','Observed odds after the prediction cutoff must be excluded.','Pending conflicts and unverified empty dates are not resolved by this sync.']}
 return out

def request(url,token=None,payload=None,local=False):
 headers={'Accept':'application/vnd.github+json','User-Agent':'football-vps-sync/1'}
 if token: headers['Authorization']='Bearer '+token
 if not local: headers['X-GitHub-Api-Version']='2022-11-28'
 body=None if payload is None else json.dumps(payload).encode()
 if body:headers['Content-Type']='application/json'
 handlers=[NoRedirect()]
 if local:handlers.append(urllib.request.ProxyHandler({}))
 op=urllib.request.build_opener(*handlers)
 req=urllib.request.Request(url,headers=headers,data=body,method='PUT' if body else 'GET')
 with op.open(req,timeout=45) as r:
  raw=r.read(16000001)
  if len(raw)>16000000:raise ValueError('Response too large')
  return json.loads(raw)

def main():
 lock=open('/run/football-github-sync.lock','w')
 try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 except BlockingIOError:print('SYNC_ALREADY_RUNNING');return
 token=CONFIG.read_text().strip()
 cfg=json.loads(pathlib.Path('/etc/football-web/access.json').read_text())
 d=request('http://127.0.0.1:8787/api/v1/analysis',cfg['api_key'],local=True)
 at=datetime.datetime.fromisoformat(d['at']);now=datetime.datetime.now(datetime.timezone.utc)
 if at.tzinfo is None or abs((now-at).total_seconds())>900:raise ValueError('Analysis export timestamp invalid or stale')
 out=public_export(d)
 data=json.dumps(out,ensure_ascii=False,separators=(',',':')).encode()
 for secret in (token,cfg.get('api_key'),cfg.get('password')):
  if secret and secret.encode() in data:raise ValueError('Secret detected; upload blocked')
 if len(data)>900000:raise ValueError('Export exceeds safe file size; upload blocked, not truncated')
 url='https://api.github.com/repos/'+REPO+'/contents/latest.json'
 sha=None
 try:sha=request(url+'?ref=main',token)['sha']
 except urllib.error.HTTPError as e:
  if e.code!=404:raise
 body={'message':'Update football analysis '+d['at'],'content':base64.b64encode(data).decode(),'branch':'main'}
 if sha:body['sha']=sha
 result=request(url,token,body)
 print('SYNC_OK data_at='+d['at']+' matches='+str(len(out['matches']))+' commit='+result['commit']['sha'],flush=True)

if __name__=='__main__':
 try:main()
 except urllib.error.HTTPError as e:
  print('SYNC_FAILED HTTP '+str(e.code)+' (401/403: token permissions or quota; 409: concurrent change; 422: branch/content)',file=sys.stderr);sys.exit(1)
 except Exception as e:
  print('SYNC_FAILED '+type(e).__name__+'; check local API, network, token and export size. No credentials logged.',file=sys.stderr);sys.exit(1)
PYTHON_PAYLOAD
chmod 600 /opt/football-github-sync/sync.py
cat > /etc/systemd/system/football-github-sync.service <<'UNIT'
[Unit]
Description=Export public football analysis to GitHub
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/football-github-sync/sync.py
TimeoutStartSec=240
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/run
MemoryMax=256M
UNIT
cat > /etc/systemd/system/football-github-sync.timer <<'UNIT'
[Unit]
Description=Sync football analysis every 30 minutes
[Timer]
OnCalendar=*-*-* *:00,30:00
Persistent=true
RandomizedDelaySec=30
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now football-github-sync.timer
systemctl start --no-block football-github-sync.service
echo 'SYNC_INSTALL_OK：后台首次同步已提交，断开终端也会继续。'
echo '查看结果：journalctl -u football-github-sync.service -n 20 --no-pager'
echo '成功标记是 SYNC_OK，安装完成不等于上传成功。'
echo '数据：https://github.com/wuyunqing2010/football-data/blob/main/latest.json'
echo '暂停：systemctl stop football-github-sync.timer'
echo '更换令牌：rm /etc/football-github-sync/token 后重新运行本安装脚本'
