"""Urban mobility digital twin for the Enterprise Mobility Intelligence project.

Simulates monthly demand, fleet capacity, service delivery, farebox coverage,
shared trips, capacity pressure, and an operational emissions proxy by license
class. Outputs are stable CSV/JSON contracts designed for Power BI ingestion.
"""
from __future__ import annotations
import argparse, json
from dataclasses import asdict, dataclass
from pathlib import Path
import numpy as np
import pandas as pd

REQ={"month_year","license_class","trips_per_day","farebox_per_day","unique_drivers","unique_vehicles","vehicles_per_day","avg_hours_per_day_per_vehicle","avg_minutes_per_trip","trips_per_day_shared"}

@dataclass(frozen=True)
class Policy:
    name:str; demand_change:float=0; active_vehicle_change:float=0; driver_supply_change:float=0
    trip_time_change:float=0; productivity_change:float=0; shared_trip_change:float=0; emission_factor_change:float=0

POLICIES={
 "baseline":Policy("baseline"),
 "balanced":Policy("balanced",.03,.04,.03,-.05,.06,.10,-.08),
 "transit_priority":Policy("transit_priority",.04,.05,.03,-.08,.08,.08,-.10),
 "sustainability":Policy("sustainability",.02,-.03,.01,-.03,.04,.25,-.22),
 "disruption":Policy("disruption",-.05,-.15,-.12,.12,-.05,0,.10),
}

def load(path:Path):
 d=pd.read_csv(path); missing=sorted(REQ-set(d.columns))
 if missing: raise ValueError(f"Missing required columns: {missing}")
 d["month_year"]=pd.to_datetime(d["month_year"],errors="coerce")
 for c in REQ-{"month_year","license_class"}: d[c]=pd.to_numeric(d[c],errors="coerce")
 critical=["month_year","license_class","trips_per_day","unique_drivers","unique_vehicles","vehicles_per_day","avg_hours_per_day_per_vehicle","avg_minutes_per_trip"]
 if d[critical].isna().any().any(): raise ValueError("Critical source fields contain invalid or missing values")
 if d.duplicated(["month_year","license_class"]).any(): raise ValueError("Duplicate month/license_class keys found")
 return d.sort_values(["license_class","month_year"])

def calibrate(g:pd.DataFrame):
 g=g.sort_values("month_year"); recent=g.tail(36); last=g.iloc[-1]
 y=np.log1p(recent.trips_per_day.to_numpy()); x=np.arange(len(y)); slope=np.polyfit(x,y,1)[0] if len(y)>2 else 0
 slope=float(np.clip(slope,-.025,.025))
 ratios=[]
 trend=np.exp(np.polyval(np.polyfit(x,y,1),x))-1 if len(y)>2 else np.repeat(g.trips_per_day.mean(),len(g))
 tmp=recent.assign(ratio=recent.trips_per_day.to_numpy()/np.maximum(trend,1),month=recent.month_year.dt.month)
 seas=tmp.groupby("month").ratio.mean(); seas=seas/seas.mean()
 tpv=float(last.trips_per_day/max(last.vehicles_per_day,1)); fare_per_trip=float(last.farebox_per_day/last.trips_per_day) if pd.notna(last.farebox_per_day) and last.trips_per_day>0 else np.nan
 shared=float(last.trips_per_day_shared/last.trips_per_day) if pd.notna(last.trips_per_day_shared) and last.trips_per_day>0 else 0
 return dict(last=last,slope=slope,seas=seas,tpv=tpv,fare_per_trip=fare_per_trip,shared=shared)

def simulate_one(data,policy:Policy,horizon:int,seed:int):
 rng=np.random.default_rng(seed); daily=[]
 for klass,g in data.groupby("license_class"):
  c=calibrate(g); last=c["last"]; current=pd.Timestamp(last.month_year)
  for step in range(1,horizon+1):
   month=current+pd.offsets.MonthBegin(step); seasonal=float(c["seas"].get(month.month,1))
   base=float(last.trips_per_day*np.exp(c["slope"]*step)*seasonal)
   demand=max(0,rng.normal(base*(1+policy.demand_change),max(1,base*.045)))
   vehicles=max(1,rng.normal(last.vehicles_per_day*(1+policy.active_vehicle_change),max(1,last.vehicles_per_day*.025)))
   drivers=max(1,rng.normal(last.unique_drivers*(1+policy.driver_supply_change),max(1,last.unique_drivers*.02)))
   trip_minutes=max(1,rng.normal(last.avg_minutes_per_trip*(1+policy.trip_time_change),max(.1,last.avg_minutes_per_trip*.025)))
   time_gain=last.avg_minutes_per_trip/trip_minutes
   driver_limit=max(.45,min(1.1,drivers/max(last.unique_drivers,1)))
   capacity=vehicles*c["tpv"]*time_gain*(1+policy.productivity_change)*driver_limit
   served=min(demand,max(0,capacity)); unmet=max(0,demand-served); pressure=demand/max(capacity,1)
   shared=min(served,served*c["shared"]*(1+policy.shared_trip_change))
   fare=served*c["fare_per_trip"] if np.isfinite(c["fare_per_trip"]) else np.nan
   vehicle_hours=vehicles*last.avg_hours_per_day_per_vehicle
   emissions=vehicle_hours*(1+policy.emission_factor_change)*(1-shared/max(served,1)*.25)
   daily.append(dict(scenario=policy.name,month_year=month.date(),license_class=klass,demand_trips_per_day=demand,served_trips_per_day=served,unmet_trips_per_day=unmet,service_rate_pct=100*served/max(demand,1),active_vehicles_per_day=vehicles,drivers=drivers,avg_minutes_per_trip=trip_minutes,capacity_pressure=pressure,shared_trips_per_day=shared,farebox_per_day_covered=fare,emissions_index=emissions))
 out=pd.DataFrame(daily)
 m=dict(scenario=policy.name,served_trips_per_day_mean=out.served_trips_per_day.sum()/horizon,unmet_trips_per_day_mean=out.unmet_trips_per_day.sum()/horizon,service_rate_pct=100*out.served_trips_per_day.sum()/out.demand_trips_per_day.sum(),capacity_pressure_mean=np.average(out.capacity_pressure,weights=out.demand_trips_per_day),active_vehicles_per_day_mean=out.active_vehicles_per_day.sum()/horizon,shared_trips_per_day_mean=out.shared_trips_per_day.sum()/horizon,farebox_per_day_covered_mean=out.groupby("month_year").farebox_per_day_covered.sum(min_count=1).mean(),emissions_index_mean=out.emissions_index.sum()/horizon,avg_minutes_per_trip_weighted=np.average(out.avg_minutes_per_trip,weights=out.served_trips_per_day))
 return m,out

def run(data,policies,horizon,runs,seed):
 metrics=[]; states=[]
 for pi,p in enumerate(policies):
  for r in range(runs):
   m,s=simulate_one(data,p,horizon,seed+pi*100000+r); m["run"]=r+1; metrics.append(m)
   if r==0: states.append(s)
 raw=pd.DataFrame(metrics); vals=[c for c in raw if c not in {"scenario","run"}]
 parts=[]
 for name,g in raw.groupby("scenario"):
  row={"scenario":name}
  for c in vals: row.update({f"{c}_mean":g[c].mean(),f"{c}_std":g[c].std(),f"{c}_p05":g[c].quantile(.05),f"{c}_p95":g[c].quantile(.95)})
  parts.append(row)
 return raw,pd.DataFrame(parts),pd.concat(states,ignore_index=True)

def main():
 a=argparse.ArgumentParser(); a.add_argument("--input",type=Path,required=True); a.add_argument("--output-dir",type=Path,default=Path("mobility_twin_output")); a.add_argument("--months",type=int,default=12); a.add_argument("--runs",type=int,default=500); a.add_argument("--seed",type=int,default=42); a.add_argument("--scenarios",nargs="+",default=list(POLICIES),choices=list(POLICIES)); x=a.parse_args()
 x.output_dir.mkdir(parents=True,exist_ok=True); d=load(x.input); ps=[POLICIES[n] for n in x.scenarios]; raw,summary,state=run(d,ps,x.months,x.runs,x.seed)
 raw.to_csv(x.output_dir/"mobility_monte_carlo_runs.csv",index=False); summary.to_csv(x.output_dir/"mobility_scenario_summary.csv",index=False); state.to_csv(x.output_dir/"mobility_twin_monthly_state.csv",index=False)
 config={"months":x.months,"runs":x.runs,"seed":x.seed,"source_rows":len(d),"source_min_month":str(d.month_year.min().date()),"source_max_month":str(d.month_year.max().date()),"policies":[asdict(p) for p in ps]}; (x.output_dir/"mobility_twin_config.json").write_text(json.dumps(config,indent=2),encoding="utf-8"); print(summary.to_string(index=False))
if __name__=="__main__": main()
