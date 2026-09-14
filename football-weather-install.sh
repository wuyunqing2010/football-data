#!/bin/bash
set -euo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo '请用 sudo bash'; exit 1; }
exec 9>/run/football-weather-install.lock
flock -n 9 || exit 1
backup=/var/backups/football-weather-$(date +%Y%m%d-%H%M%S)
mkdir -p "$backup"
cp -a /opt/football-web "$backup/web"
cp -a /opt/football-injury-bridge "$backup/bridge"
install -d -m 700 /opt/football-weather /var/lib/football-weather
units='football-injury-bridge football-weather'
for unit in $units; do
 if systemctl is-active --quiet "$unit.timer"; then echo "$unit.timer" >> "$backup/timers"; fi
 systemctl stop "$unit.timer" 2>/dev/null || true
done
resume(){ if [[ -f "$backup/timers" ]]; then while read -r timer; do systemctl start "$timer"; done < "$backup/timers"; fi; }
rollback(){ cp -a "$backup/web/." /opt/football-web/; cp -a "$backup/bridge/." /opt/football-injury-bridge/; systemctl restart football-web.service || true; resume; echo "更新失败，已恢复网页与同步代码：$backup"; }
trap rollback ERR
for unit in $units; do
 for attempt in $(seq 1 90); do
  state=$(systemctl show "$unit.service" -p ActiveState --value 2>/dev/null || true)
  [[ "$state" != active && "$state" != activating ]] && break
  if [[ $attempt -eq 90 ]]; then resume; echo '任务仍在运行，稍后再试'; exit 1; fi
  sleep 2
 done
done
python3 - <<'PATCH'
from pathlib import Path
import os,grp
changes=[]
def patch(path,marker,anchor,block):
 p=Path(path);s=next((x for q,x in reversed(changes) if q==p),p.read_text())
 if marker in s:return
 if s.count(anchor)!=1:raise RuntimeError('Version mismatch: '+path)
 s=s.replace(anchor,block)
 if p.suffix=='.py':compile(s,path,'exec')
 changes.append((p,s))
patch('/opt/football-web/web.py','# weather-view-v1','  return result\n',"  # weather-view-v1\n  from weather_view import attach as attach_weather\n  attach_weather(rows)\n  return result\n")
patch('/opt/football-injury-bridge/sync_injuries.py','# weather-export-v1',"  out['matches'].append(item)","  # weather-export-v1\n  item['weather']=m.get('weather',{})\n  out['matches'].append(item)")
patch('/opt/football-web/app.js','// weather-ui-v1',"detail.append(node('h4','让球胜平负（主队让球）'));","// weather-ui-v1\nconst weather=m.weather||{status:'not_collected'},wb=node('div',undefined,'odds');\nconst wl={ok:'已取得预报',not_collected:'等待采集',venue_unverified:'场馆城市或位置待核实',query_failed:'查询失败',stale:'预报较旧',historical_forecast:'历史赛前预报',after_sales_cutoff:'停售后查询的预报',fixture_changed:'赛程变化，等待重查',invalid_data:'数据待核实',post_kickoff_unusable:'赛后查询，不作赛前依据'};\nwb.append(node('h4','比赛时段天气 · '+(wl[weather.status]||weather.status)));\nwb.append(node('p','位置：'+(weather.venue||'场馆未确认')+' · '+(weather.city||'城市待核实')));\nif(weather.location)wb.append(node('p','城市附近预报，未精确到球场：'+weather.location.name+' / '+weather.location.country));\nif(weather.queried_at)wb.append(node('small','查询 '+format(weather.queried_at)));\nfor(const h of weather.hours||[])wb.append(node('p',format(h.at)+' · '+h.temperature_2m+'℃ · 降水概率 '+h.precipitation_probability+'% · 前1小时降水 '+h.precipitation+'毫米 · 风速 '+h.wind_speed_10m+'公里/小时'));\nwb.append(node('small',weather.note||'暂无天气数据。'));\nconst credit=node('a','天气：Open-Meteo · CC BY 4.0');credit.href='https://open-meteo.com/';credit.target='_blank';credit.rel='noopener noreferrer';wb.append(credit,node('small','地理编码：GeoNames，经 Open-Meteo 提供。天气仅作参考，未用于模型；非球场实测，未判断顶棚状态。'));detail.append(wb);\n"+"\ndetail.append(node('h4','让球胜平负（主队让球）'));")
p=Path('/opt/football-web/app.js');s=next(x for q,x in reversed(changes) if q==p) if any(q==p for q,x in changes) else p.read_text()
s=s.replace('天气、首发尚未接入；比分、总进球、半全场赔率位置未全部核实。模型概率尚未使用这些信息。','首发尚未接入；比分、总进球、半全场赔率位置未全部核实。天气和伤停暂作补充，未用于模型。');changes.append((p,s))
for path,content in {'/opt/football-weather/weather_core.py': "import math,unicodedata\nfrom datetime import datetime,timezone,timedelta\nFIELDS=('temperature_2m','precipitation_probability','precipitation','wind_speed_10m')\ndef stamp(x):\n d=x if isinstance(x,datetime) else datetime.fromisoformat(str(x).replace('Z','+00:00'))\n if d.tzinfo is None:raise ValueError('timezone_missing')\n return d\n\ndef clean(s):return ''.join(c for c in unicodedata.normalize('NFKD',str(s)).casefold() if not unicodedata.combining(c) and c.isalnum())\ndef choose_city(data,city,country):\n country={'England':'United Kingdom','Scotland':'United Kingdom','Wales':'United Kingdom','Northern-Ireland':'United Kingdom','USA':'United States','South-Korea':'South Korea'}.get(country,country)\n candidates=[x for x in data.get('results',[]) if clean(x.get('name'))==clean(city) and clean(x.get('country'))==clean(country) and isinstance(x.get('latitude'),(int,float)) and isinstance(x.get('longitude'),(int,float))]\n unique={(round(x['latitude'],4),round(x['longitude'],4)):x for x in candidates}\n if len(unique)!=1:return None\n x=next(iter(unique.values()))\n if not (-90<=x['latitude']<=90 and -180<=x['longitude']<=180):return None\n return {'latitude':x['latitude'],'longitude':x['longitude'],'name':x['name'],'country':x['country'],'precision':'city_approximation','geocoding_id':x.get('id')}\n\ndef extract(data,kickoff):\n if data.get('utc_offset_seconds')!=0:raise ValueError('unexpected_timezone')\n units=data.get('hourly_units',{})\n if units.get('temperature_2m')!='°C' or units.get('precipitation')!='mm' or units.get('wind_speed_10m')!='km/h' or units.get('precipitation_probability')!='%':raise ValueError('unexpected_units')\n h=data['hourly'];times=h['time'];kick=stamp(kickoff);start=kick.replace(minute=0,second=0,microsecond=0);end=(kick+timedelta(hours=2)).replace(minute=0,second=0,microsecond=0)\n if not all(isinstance(h.get(k),list) and len(h[k])==len(times) for k in FIELDS):raise ValueError('invalid_hourly_arrays')\n out=[]\n for i,t in enumerate(times):\n  when=datetime.fromtimestamp(t,timezone.utc)\n  if not start<=when<=end:continue\n  values={k:h[k][i] for k in FIELDS}\n  if not all(type(v) in (float,int) and math.isfinite(v) for v in values.values()):raise ValueError('missing_hourly_value')\n  if not -100<=values['temperature_2m']<=65 or not 0<=values['precipitation_probability']<=100 or values['precipitation']<0 or values['wind_speed_10m']<0:raise ValueError('invalid_hourly_value')\n  out.append({'at':when.isoformat(),**values})\n expected=int((end-start).total_seconds()/3600)+1\n if len(out)!=expected or len({x['at'] for x in out})!=expected:raise ValueError('incomplete_match_window')\n return out\n\ndef present(record,match,now):\n if not record:return {'status':'not_collected','note':'暂无匹配的天气快照。'}\n r=dict(record)\n try:\n  if r.get('kickoff')!=stamp(match['kickoff']).isoformat():return {'status':'fixture_changed','note':'开球时间变化，等待重新采集。'}\n  if r.get('status')!='ok':return r\n  at=stamp(r['queried_at']);kick=stamp(match['kickoff']);cut=stamp(match['cutoff'])\n  if at>=kick:r.update(status='post_kickoff_unusable',hours=[])\n  elif now>=kick:r.update(status='historical_forecast',note='赛前保存的天气预报，不是赛后实测；'+('查询在停售后，不能用于停售前判断。' if at>=cut else '查询在停售前。'))\n  elif not 0<=(now-at).total_seconds()<=3*3600:r.update(status='stale',note='查询已超过3小时，暂不作最新天气。')\n  elif at>=cut:r.update(status='after_sales_cutoff',note='停售后查询的预报，不作停售前依据。')\n except (KeyError,ValueError,TypeError):return {'status':'invalid_data','note':'天气记录时间待核实。'}\n return r\n", '/opt/football-weather/collector.py': '"""Read cached fixture venues; query Open-Meteo only. Append weather snapshots."""\nimport json,sqlite3,os,grp,sys,fcntl,time,urllib.request,urllib.parse\nfrom pathlib import Path\nfrom datetime import datetime,timezone,timedelta\nfrom zoneinfo import ZoneInfo\nfrom weather_core import stamp,choose_city,extract\nsys.path.insert(0,\'/opt/football-web\')\nfrom injury_view import norm\nROOT=Path(\'/var/lib/football-weather\');OUT=Path(\'/opt/football-web/weather-data.json\')\ndef read(path,default):\n try:return json.loads(path.read_text())\n except (OSError,ValueError):return default\n\ndef request(url,local=False,key=None):\n headers={\'User-Agent\':\'MatchPulse-weather/1.0\',\'Accept\':\'application/json\'}\n if key:headers[\'Authorization\']=\'Bearer \'+key\n op=urllib.request.build_opener(urllib.request.ProxyHandler({})) if local else urllib.request.build_opener()\n with op.open(urllib.request.Request(url,headers=headers),timeout=12) as r:\n  raw=r.read(2000001)\n  if len(raw)>2000000:raise ValueError(\'oversized_response\')\n  return json.loads(raw)\n\ndef main():\n ROOT.mkdir(exist_ok=True);lock=open(ROOT/\'collector.lock\',\'w\')\n try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)\n except BlockingIOError:print(\'WEATHER_BUSY\');return\n db=sqlite3.connect(ROOT/\'weather.sqlite\')\n db.execute(\'CREATE TABLE IF NOT EXISTS snapshots(id INTEGER PRIMARY KEY, event_key TEXT, at TEXT, payload TEXT)\')\n db.execute(\'CREATE TABLE IF NOT EXISTS requests(at TEXT)\');db.execute(\'CREATE INDEX IF NOT EXISTS snapshot_event ON snapshots(event_key,id)\');db.commit()\n now=datetime.now(timezone.utc);used=db.execute(\'SELECT count(*) FROM requests WHERE at>?\',((now-timedelta(days=1)).isoformat(),)).fetchone()[0];calls=0\n def remote(url):\n  nonlocal used,calls\n  if used>=400 or calls>=30:raise RuntimeError(\'weather_quota\')\n  db.execute(\'INSERT INTO requests VALUES(?)\',(datetime.now(timezone.utc).isoformat(),));db.commit();used+=1;calls+=1\n  return request(url)\n config=read(Path(\'/etc/football-web/access.json\'),{})\n matches={};day=now.astimezone(ZoneInfo(\'Asia/Shanghai\')).date()\n for date in (day,day+timedelta(days=1)):\n  for m in request(\'http://127.0.0.1:8787/api/v1/today?date=\'+str(date),True,config[\'api_key\'])[\'matches\']:matches[m[\'canonical_id\']]=m\n fixture_db=sqlite3.connect(\'file:/var/lib/football-injuries/injuries.sqlite?mode=ro\',uri=True);fixtures={}\n for at,state,raw in fixture_db.execute(\'SELECT at,state,payload FROM fixtures WHERE rowid IN (SELECT max(rowid) FROM fixtures GROUP BY day)\'):\n  if state!=\'ok\' or not 0<=(now-stamp(at)).total_seconds()<86400:continue\n  for f in json.loads(raw).get(\'response\',[]):fixtures[f[\'fixture\'][\'id\']]=f\n fixture_db.close()\n geocache=read(ROOT/\'cities.json\',{});records=read(OUT,{}).get(\'matches\',{});counts={}\n for key,m in sorted(matches.items(),key=lambda kv:str(kv[1][\'kickoff\'])):\n  kickoff=stamp(m[\'kickoff\']);old=records.get(key)\n  if kickoff<=now:continue\n  if kickoff>now+timedelta(hours=48):continue\n  if old and old.get(\'status\')==\'ok\' and old.get(\'kickoff\')==kickoff.isoformat() and 0<=(now-stamp(old[\'queried_at\'])).total_seconds()<3600:continue\n  record={\'status\':\'venue_unverified\',\'kickoff\':kickoff.isoformat(),\'source\':\'Open-Meteo\',\'attribution_url\':\'https://open-meteo.com/\',\'license\':\'CC BY 4.0\',\'hours\':[],\'note\':\'场馆城市或位置尚未确认，不按球队名字猜天气。\'}\n  try:\n   f=fixtures.get(m.get(\'injuries\',{}).get(\'fixture_id\'))\n   if f and norm(f[\'teams\'][\'home\'][\'name\'])==norm(m[\'home\']) and norm(f[\'teams\'][\'away\'][\'name\'])==norm(m[\'away\']) and abs((stamp(f[\'fixture\'][\'date\'])-kickoff).total_seconds())<=300:\n    venue=f[\'fixture\'].get(\'venue\') or {};city=venue.get(\'city\');country=f.get(\'league\',{}).get(\'country\');record[\'venue\']=venue.get(\'name\');record[\'city\']=city\n    if city and country and country not in (\'World\',\'Europe\'):\n     cachekey=city+\'|\'+country;cached=geocache.get(cachekey)\n     if cached and 0<=(now-stamp(cached[\'at\'])).total_seconds()<7*86400:location=cached[\'location\']\n     else:\n      geo=remote(\'https://geocoding-api.open-meteo.com/v1/search?\'+urllib.parse.urlencode({\'name\':city,\'count\':100,\'language\':\'en\',\'format\':\'json\'}));location=choose_city(geo,city,country);geocache[cachekey]={\'at\':now.isoformat(),\'location\':location}\n     if location:\n      params={\'latitude\':location[\'latitude\'],\'longitude\':location[\'longitude\'],\'hourly\':\'temperature_2m,precipitation_probability,precipitation,wind_speed_10m\',\'forecast_days\':4,\'timezone\':\'GMT\',\'timeformat\':\'unixtime\',\'wind_speed_unit\':\'kmh\',\'temperature_unit\':\'celsius\',\'precipitation_unit\':\'mm\'}\n      data=remote(\'https://api.open-meteo.com/v1/forecast?\'+urllib.parse.urlencode(params));at=datetime.now(timezone.utc)\n      if at>=kickoff:raise ValueError(\'response_after_kickoff\')\n      record.update(status=\'ok\',queried_at=at.isoformat(),location=location,hours=extract(data,m[\'kickoff\']),note=\'比赛场馆所在城市附近的预报，不是球场实测；地理位置未精确到球场。降水值为该时刻之前一小时累计量。\')\n  except Exception as e:record.update(status=\'query_failed\',error_type=type(e).__name__,note=\'天气查询失败；不以旧预报冒充新数据。\')\n  record[\'attempted_at\']=datetime.now(timezone.utc).isoformat();records[key]=record\n  db.execute(\'INSERT INTO snapshots(event_key,at,payload) VALUES(?,?,?)\',(key,record[\'attempted_at\'],json.dumps(record,ensure_ascii=False)));db.commit()\n  counts[record[\'status\']]=counts.get(record[\'status\'],0)+1\n  if calls>=30:break\n # Keep 14 days on web, append-only SQLite retains pre-match forecasts independently.\n records={k:r for k,r in records.items() if stamp(r[\'kickoff\'])>now-timedelta(days=14)}\n for p,data in [(ROOT/\'cities.json\',geocache),(OUT,{\'at\':datetime.now(timezone.utc).isoformat(),\'matches\':records,\'counts\':counts,\'requests_24h\':used})]:\n  t=p.with_suffix(\'.tmp\');t.write_text(json.dumps(data,ensure_ascii=False));t.chmod(0o640 if p==OUT else 0o600)\n  if p==OUT:os.chown(t,0,grp.getgrnam(\'footballweb\').gr_gid)\n  os.replace(t,p)\n print(\'WEATHER_COLLECT_OK \'+json.dumps({\'counts\':counts,\'requests\':calls,\'cached_matches\':len(records)},ensure_ascii=False))\nif __name__==\'__main__\':main()\n', '/opt/football-web/weather_core.py': "import math,unicodedata\nfrom datetime import datetime,timezone,timedelta\nFIELDS=('temperature_2m','precipitation_probability','precipitation','wind_speed_10m')\ndef stamp(x):\n d=x if isinstance(x,datetime) else datetime.fromisoformat(str(x).replace('Z','+00:00'))\n if d.tzinfo is None:raise ValueError('timezone_missing')\n return d\n\ndef clean(s):return ''.join(c for c in unicodedata.normalize('NFKD',str(s)).casefold() if not unicodedata.combining(c) and c.isalnum())\ndef choose_city(data,city,country):\n country={'England':'United Kingdom','Scotland':'United Kingdom','Wales':'United Kingdom','Northern-Ireland':'United Kingdom','USA':'United States','South-Korea':'South Korea'}.get(country,country)\n candidates=[x for x in data.get('results',[]) if clean(x.get('name'))==clean(city) and clean(x.get('country'))==clean(country) and isinstance(x.get('latitude'),(int,float)) and isinstance(x.get('longitude'),(int,float))]\n unique={(round(x['latitude'],4),round(x['longitude'],4)):x for x in candidates}\n if len(unique)!=1:return None\n x=next(iter(unique.values()))\n if not (-90<=x['latitude']<=90 and -180<=x['longitude']<=180):return None\n return {'latitude':x['latitude'],'longitude':x['longitude'],'name':x['name'],'country':x['country'],'precision':'city_approximation','geocoding_id':x.get('id')}\n\ndef extract(data,kickoff):\n if data.get('utc_offset_seconds')!=0:raise ValueError('unexpected_timezone')\n units=data.get('hourly_units',{})\n if units.get('temperature_2m')!='°C' or units.get('precipitation')!='mm' or units.get('wind_speed_10m')!='km/h' or units.get('precipitation_probability')!='%':raise ValueError('unexpected_units')\n h=data['hourly'];times=h['time'];kick=stamp(kickoff);start=kick.replace(minute=0,second=0,microsecond=0);end=(kick+timedelta(hours=2)).replace(minute=0,second=0,microsecond=0)\n if not all(isinstance(h.get(k),list) and len(h[k])==len(times) for k in FIELDS):raise ValueError('invalid_hourly_arrays')\n out=[]\n for i,t in enumerate(times):\n  when=datetime.fromtimestamp(t,timezone.utc)\n  if not start<=when<=end:continue\n  values={k:h[k][i] for k in FIELDS}\n  if not all(type(v) in (float,int) and math.isfinite(v) for v in values.values()):raise ValueError('missing_hourly_value')\n  if not -100<=values['temperature_2m']<=65 or not 0<=values['precipitation_probability']<=100 or values['precipitation']<0 or values['wind_speed_10m']<0:raise ValueError('invalid_hourly_value')\n  out.append({'at':when.isoformat(),**values})\n expected=int((end-start).total_seconds()/3600)+1\n if len(out)!=expected or len({x['at'] for x in out})!=expected:raise ValueError('incomplete_match_window')\n return out\n\ndef present(record,match,now):\n if not record:return {'status':'not_collected','note':'暂无匹配的天气快照。'}\n r=dict(record)\n try:\n  if r.get('kickoff')!=stamp(match['kickoff']).isoformat():return {'status':'fixture_changed','note':'开球时间变化，等待重新采集。'}\n  if r.get('status')!='ok':return r\n  at=stamp(r['queried_at']);kick=stamp(match['kickoff']);cut=stamp(match['cutoff'])\n  if at>=kick:r.update(status='post_kickoff_unusable',hours=[])\n  elif now>=kick:r.update(status='historical_forecast',note='赛前保存的天气预报，不是赛后实测；'+('查询在停售后，不能用于停售前判断。' if at>=cut else '查询在停售前。'))\n  elif not 0<=(now-at).total_seconds()<=3*3600:r.update(status='stale',note='查询已超过3小时，暂不作最新天气。')\n  elif at>=cut:r.update(status='after_sales_cutoff',note='停售后查询的预报，不作停售前依据。')\n except (KeyError,ValueError,TypeError):return {'status':'invalid_data','note':'天气记录时间待核实。'}\n return r\n", '/opt/football-web/weather_view.py': "import json\nfrom pathlib import Path\nfrom datetime import datetime,timezone\nfrom weather_core import present\nP=Path('/opt/football-web/weather-data.json')\ndef attach(matches):\n try:data=json.loads(P.read_text()).get('matches',{})\n except (OSError,ValueError):data={}\n now=datetime.now(timezone.utc)\n for m in matches:m['weather']=present(data.get(m['canonical_id']),m,now)\n"}.items():
 p=Path(path);compile(content,path,'exec');changes.append((p,content))
for p,s in changes:
 t=p.with_suffix('.weather-new');t.write_text(s)
 if p.exists():st=p.stat();os.chmod(t,st.st_mode);os.chown(t,st.st_uid,st.st_gid)
 else:t.chmod(0o640);os.chown(t,0,grp.getgrnam('footballweb' if '/football-web/' in str(p) else 'root').gr_gid)
 os.replace(t,p)

PATCH
systemctl restart football-web.service
python3 - <<'VERIFY'
import json,time,urllib.request
c=json.load(open('/etc/football-web/access.json'));op=urllib.request.build_opener(urllib.request.ProxyHandler({}))
for i in range(8):
 try:
  req=urllib.request.Request('http://127.0.0.1:8787/api/v1/today',headers={'Authorization':'Bearer '+c['api_key']})
  with op.open(req,timeout=30) as response:d=json.load(response)
  assert all('weather' in m for m in d['matches'])
  print('WEATHER_VIEW_OK matches='+str(len(d['matches'])))
  break
 except Exception:
  if i==7:raise SystemExit('天气接口展示检查失败')
  time.sleep(1)
VERIFY
cat > /etc/systemd/system/football-weather.service <<'UNIT'
[Unit]
Description=Collect cached-venue city weather forecasts from Open-Meteo
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/football-weather/collector.py
TimeoutStartSec=9min
MemoryMax=256M
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/football-weather /opt/football-web
UNIT
cat > /etc/systemd/system/football-weather.timer <<'UNIT'
[Timer]
OnBootSec=3min
OnUnitActiveSec=1h
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
resume
systemctl enable --now football-weather.timer
trap - ERR
systemctl start --no-block football-weather.service
echo 'WEATHER_INSTALLED：天气功能已接入，首次查询在后台进行，每小时更新。'
echo '使用场馆缓存中的城市；仅提供城市附近预报，位置不确定不猜测。不占伤停API额度。'
echo '免费接口按个人非商业用途使用；查询失败、数据过期和赛后记录分别提示。'
echo '查看结果：journalctl -u football-weather.service -n 10 --no-pager'
echo "备份：$backup"
