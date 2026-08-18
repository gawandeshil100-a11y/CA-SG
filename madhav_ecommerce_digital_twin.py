"""Scenario digital twin for the Madhav e-commerce analytics project."""
from __future__ import annotations
import argparse,json
from dataclasses import dataclass,asdict
from pathlib import Path
import numpy as np,pandas as pd
@dataclass(frozen=True)
class Policy:
 name:str; demand_change:float=0; inventory_cover:float=1.10; price_change:float=0; return_rate:float=.05; replenishment_multiplier:float=1.0
POLICIES={"baseline":Policy("baseline"),"growth":Policy("growth",.15,1.15,-.05,.06,1.10),"margin_guard":Policy("margin_guard",-.04,1.08,.03,.04,.98),"inventory_optimized":Policy("inventory_optimized",.05,1.25,-.02,.04,1.12),"stress":Policy("stress",.25,.90,-.03,.08,.90)}
def load(orders,details):
 o=pd.read_csv(orders); d=pd.read_csv(details); ro={"Order ID","Order Date","CustomerName","State","City"}; rd={"Order ID","Amount","Profit","Quantity","Category","Sub-Category","PaymentMode"}
 if not ro<=set(o) or not rd<=set(d): raise ValueError("Input schemas do not match Orders.csv and Details.csv")
 o["Order Date"]=pd.to_datetime(o["Order Date"],format="%d-%m-%Y",errors="raise")
 x=d.merge(o,on="Order ID",how="inner",validate="many_to_one"); x["month"]=x["Order Date"].dt.month
 if len(x)!=len(d): raise ValueError("Orphan detail rows found")
 return x
def base_table(x):
 g=x.groupby(["Category","Sub-Category","month"],as_index=False).agg(quantity=("Quantity","sum"),sales=("Amount","sum"),profit=("Profit","sum"))
 g["asp"]=g.sales/g.quantity; g["unit_cost"]=(g.sales-g.profit)/g.quantity
 allidx=pd.MultiIndex.from_product([x.Category.unique(),x["Sub-Category"].unique(),range(1,13)],names=["Category","Sub-Category","month"])
 valid=x[["Category","Sub-Category"]].drop_duplicates(); g=g.set_index(["Category","Sub-Category","month"]).reindex(allidx).reset_index(); g=g.merge(valid.assign(valid=1),on=["Category","Sub-Category"],how="left"); g=g[g.valid==1].drop(columns="valid")
 for c in ["quantity","sales","profit"]: g[c]=g[c].fillna(0)
 for c in ["asp","unit_cost"]: g[c]=g.groupby("Sub-Category")[c].transform(lambda s:s.fillna(s[s>0].median() if (s>0).any() else 0))
 return g
def simulate_one(base,p,horizon,seed):
 rng=np.random.default_rng(seed); rows=[]
 for (cat,sub),g in base.groupby(["Category","Sub-Category"]):
  monthly=max(.2,g.quantity.mean()); asp=float(g.asp[g.asp>0].median()); cost=float(g.unit_cost[g.unit_cost>=0].median()); inv=monthly*p.inventory_cover; pipeline=0
  season=g.set_index("month").quantity/monthly; season=season.replace(0,.35).clip(.25,3)
  for step in range(horizon):
   m=step%12+1; inv+=pipeline; demand=max(0,rng.poisson(monthly*float(season.get(m,1))*(1+p.demand_change)))
   sold=min(inv,demand); lost=demand-sold; inv-=sold; returned=rng.binomial(int(sold),p.return_rate); net=sold-returned
   price=asp*(1+p.price_change); revenue=net*price; cogs=sold*cost; handling=returned*price*.08; profit=revenue-cogs-handling
   target=monthly*float(season.get((m%12)+1,1))*p.inventory_cover; pipeline=max(0,(target-inv)*p.replenishment_multiplier)
   rows.append(dict(scenario=p.name,month=step+1,category=cat,sub_category=sub,demand_units=demand,gross_units_sold=sold,returned_units=returned,net_units=net,lost_units=lost,ending_inventory=inv,replenishment_order=pipeline,revenue=revenue,cogs=cogs,return_handling_cost=handling,profit=profit))
 out=pd.DataFrame(rows); demanded=out.demand_units.sum(); sold=out.gross_units_sold.sum()
 met=dict(scenario=p.name,revenue=out.revenue.sum(),profit=out.profit.sum(),units_sold=sold,lost_units=out.lost_units.sum(),fill_rate_pct=100*sold/max(demanded,1),return_rate_pct=100*out.returned_units.sum()/max(sold,1),avg_inventory=out.ending_inventory.mean(),inventory_turns=out.cogs.sum()/max(out.ending_inventory.mean()*base.unit_cost.mean(),1))
 return met,out
def run(x,ps,horizon,runs,seed):
 b=base_table(x); raw=[]; states=[]
 for pi,p in enumerate(ps):
  for r in range(runs):
   m,s=simulate_one(b,p,horizon,seed+pi*100000+r); m["run"]=r+1; raw.append(m)
   if r==0: states.append(s)
 raw=pd.DataFrame(raw); vals=[c for c in raw if c not in {"scenario","run"}]; summary=[]
 for n,g in raw.groupby("scenario"):
  z={"scenario":n}
  for c in vals:z.update({f"{c}_mean":g[c].mean(),f"{c}_std":g[c].std(),f"{c}_p05":g[c].quantile(.05),f"{c}_p95":g[c].quantile(.95)})
  summary.append(z)
 return raw,pd.DataFrame(summary),pd.concat(states,ignore_index=True)
def main():
 a=argparse.ArgumentParser(); a.add_argument("--orders",type=Path,required=True); a.add_argument("--details",type=Path,required=True); a.add_argument("--output-dir",type=Path,default=Path("ecommerce_twin_output")); a.add_argument("--months",type=int,default=12); a.add_argument("--runs",type=int,default=500); a.add_argument("--seed",type=int,default=42); a.add_argument("--scenarios",nargs="+",default=list(POLICIES),choices=list(POLICIES)); q=a.parse_args(); q.output_dir.mkdir(parents=True,exist_ok=True)
 x=load(q.orders,q.details); ps=[POLICIES[n] for n in q.scenarios]; raw,summary,state=run(x,ps,q.months,q.runs,q.seed); raw.to_csv(q.output_dir/"ecommerce_monte_carlo_runs.csv",index=False); summary.to_csv(q.output_dir/"ecommerce_scenario_summary.csv",index=False); state.to_csv(q.output_dir/"ecommerce_twin_monthly_state.csv",index=False); (q.output_dir/"ecommerce_twin_config.json").write_text(json.dumps({"months":q.months,"runs":q.runs,"seed":q.seed,"source_orders":x['Order ID'].nunique(),"source_lines":len(x),"policies":[asdict(p) for p in ps]},indent=2),encoding="utf-8"); print(summary.to_string(index=False))
if __name__=="__main__":main()
