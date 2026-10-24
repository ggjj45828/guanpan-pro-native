"""Point-in-time factors from explicitly supplied annual reports/valuations.
No data fetching, guessed fundamentals or forward-looking report availability.
Input per-share amounts and prices are CNY; output prices elsewhere remain 1e-4 CNY.
ETF look-through factors must be supplied separately, not derived as company EPS.
"""
import math

def finite(x):return type(x)in(int,float)and math.isfinite(x)

def derive(bundle,at):
    if not isinstance(bundle,dict)or bundle.get('asset')!='stock' or not bundle.get('source'):
        raise ValueError('company annual factors require stock and source')
    if type(at)is not int or not finite(bundle.get('price'))or bundle['price']<=0:raise ValueError('invalid valuation time or CNY price')
    for field,limit in (('reports',1000),('valuations',20000)):
        if not isinstance(bundle.get(field,[]),list)or len(bundle.get(field,[]))>limit or any(not isinstance(r,dict)for r in bundle.get(field,[])):raise ValueError('invalid annual report or valuation rows')
    reports=[r for r in bundle.get('reports',[])if type(r.get('publishedAt'))is int and r['publishedAt']<=at and type(r.get('periodEnd'))is int and r['periodEnd']<=at and r.get('period')=='annual']
    latest={}
    for r in sorted(reports,key=lambda r:r['publishedAt']):latest[r['periodEnd']]=r
    reports=sorted(latest.values(),key=lambda r:r['periodEnd'])
    result={'publishedAt':at,'method':'annual-pit-v1','source':bundle['source'],'missing':[]}
    if reports:
        r=reports[-1]
        for key in ('freeCashFlow',):
            if finite(r.get(key)):result[key]=r[key]
        dividend=r.get('dividendPerShare');eps=r.get('eps')
        if finite(dividend)and dividend>=0:
            result['dividendYield']=dividend/bundle['price']
            if finite(eps)and eps>0:result['payoutRatio']=dividend/eps
        if finite(r.get('operatingCashFlow'))and finite(r.get('netProfit'))and r['netProfit']>0:
            result['cashFlowQuality']=max(0,min(1,r['operatingCashFlow']/r['netProfit']))
        dividends=[r['dividendPerShare']for r in reports[-5:]if finite(r.get('dividendPerShare'))and r['dividendPerShare']>=0]
        if len(dividends)>=3:
            mean=sum(dividends)/len(dividends)
            result['dividendStability']=0 if mean==0 else max(0,1-math.sqrt(sum((x-mean)**2 for x in dividends)/len(dividends))/mean)
        result['latestReportPublishedAt']=r['publishedAt']
    metric=bundle.get('valuationMetric','pe')
    if metric not in ('pe','pb'):raise ValueError('valuation metric must be pe or pb')
    values=[v for v in bundle.get('valuations',[])if type(v.get('at'))is int and type(v.get('availableAt'))is int and v['at']<=v['availableAt']<=at and finite(v.get(metric))and v[metric]>0]
    unique={}
    for v in sorted(values,key=lambda v:v['availableAt']):unique[v['at']]=v
    values=sorted(unique.values(),key=lambda v:v['at'])
    if len(values)>=20:
        current=values[-1][metric]
        result['valuationPercentile']=sum(v[metric]<=current for v in values)/len(values)
        result['valuationMetric']=metric;result['valuationObservations']=len(values)
    result['missing']=[k for k in ('dividendYield','dividendStability','cashFlowQuality','valuationPercentile')if k not in result]
    return result
