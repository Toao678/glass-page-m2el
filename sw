// sw.js
const API_URL = "https://api.3658kj.com/api/v1/trend/getHistoryList?lotCode=10029&pageSize=100&pageNum=0";
const CHECK_INTERVAL = 10000;

let session = {
  records: [],
  aCorrect: 0, aWrong: 0,
  bCorrect: 0, bWrong: 0,
  cCorrect: 0, cWrong: 0,
};

let lastNbr = null;
let latestData = null;
let currentPrediction = null;
let aWindows = [0,0,0,0,0];
let historyCache = [];

function parseAPI(raw){
  return raw.data.list.map(item => {
    const nums = item.drawCode.split(",").map(Number);
    const sum = nums.reduce((a,b)=>a+b, 0);
    return {
      issue: parseInt(item.drawIssue),
      sum,
      code: item.drawCode,
      type: sum >= 14 ? (sum%2===0?"大双":"大单") : (sum%2===0?"小双":"小单"),
      time: item.drawTime
    };
  }).sort((a,b) => b.issue - a.issue);
}

function buildKill(resA, resB){
  const kills = new Set();
  if(resA.prediction) kills.add(resA.prediction);
  if(resB.prediction && resB.prediction !== "--") kills.add(resB.prediction);
  return { killedGroup: Array.from(kills).join("/") || null };
}

function modelA(history){
  const windows = [5,10,15,20,30];
  const scores = windows.map(w => {
    const slice = history.slice(0, w);
    const dist = {};
    slice.forEach(r => { dist[r.sum] = (dist[r.sum]||0)+1; });
    const max = Math.max(...Object.values(dist));
    const mode = parseInt(Object.keys(dist).find(k => dist[k] === max));
    const weight = w / 100;
    return { mode, weight, score: max * weight };
  });
  const totalScore = scores.reduce((a,b)=>a+b.score, 0);
  const best = scores.reduce((a,b) => b.score > a.score ? b : a);
  return { prediction: String(best.mode), scores, totalScore, windows: scores.map(s=>Math.round(s.score)) };
}

function modelB(history){
  if(history.length < 50) return { prediction: "--", error: "数据不足50期" };
  const seeds = [3,5,7,9,11];
  let best = { seed: 0, hits: 0, rate: 0, prediction: null };
  for(const seed of seeds){
    let hits = 0;
    const total = history.length - seed - 1;
    if(total <= 0) continue;
    for(let i = seed; i < history.length - 1; i++){
      const target = history[i];
      const window = history.slice(i+1, i+1+30);
      if(window.length < 10) continue;
      const dist = {};
      window.forEach(r => { dist[r.sum] = (dist[r.sum]||0)+1; });
      const max = Math.max(...Object.values(dist));
      const pred = parseInt(Object.keys(dist).find(k => dist[k] === max));
      if(pred === target.sum) hits++;
    }
    const rate = hits / total;
    if(hits > best.hits || (hits === best.hits && rate > best.rate)){
      best = { seed, hits, rate, prediction: null };
    }
  }
  const window = history.slice(0, 30);
  const dist = {};
  window.forEach(r => { dist[r.sum] = (dist[r.sum]||0)+1; });
  const max = Math.max(...Object.values(dist));
  best.prediction = String(parseInt(Object.keys(dist).find(k => dist[k] === max)));
  return { prediction: best.prediction, seed: best.seed, hits: best.hits, rate: best.rate };
}

function combo(resA, resB){
  if(!resA.prediction || resB.prediction === "--") return { advice: "数据不足", score: 0 };
  const scores = [resA, resB].map(r => {
    const n = parseInt(r.prediction);
    let s = 0;
    if(n >= 10 && n <= 18) s += 2;
    if(r.seed) s += r.seed > 5 ? 1 : 0;
    return s;
  });
  const total = scores.reduce((a,b)=>a+b, 0);
  let advice = "观望";
  if(total >= 4) advice = `主推 ${resA.prediction}/${resB.prediction}`;
  else if(total >= 2) advice = `轻仓 ${resA.prediction}/${resB.prediction}`;
  return { advice, score: total };
}

function verifyOne(history){
  const pending = session.records.filter(r => r.status === "待验证");
  if(pending.length === 0) return null;
  const earliest = pending.sort((a,b) => a.target - b.target)[0];
  const actual = history.find(h => h.issue === earliest.target);
  if(!actual) return null;

  const aHit = earliest.predA ? parseInt(earliest.predA) === actual.sum : false;
  const bHit = earliest.predB && earliest.predB !== "--" ? parseInt(earliest.predB) === actual.sum : false;
  const cHit = aHit || bHit;

  earliest.status = "已验证";
  earliest.aHit = aHit; earliest.bHit = bHit; earliest.cHit = cHit;

  if(aHit){ session.aCorrect++; } else { session.aWrong++; }
  if(bHit){ session.bCorrect++; } else { session.bWrong++; }
  if(cHit){ session.cCorrect++; } else { session.cWrong++; }

  const verified = session.aCorrect + session.aWrong;
  if(verified >= 100){
    session.aCorrect = 0; session.aWrong = 0;
    session.bCorrect = 0; session.bWrong = 0;
    session.cCorrect = 0; session.cWrong = 0;
    broadcast({ type: "auto_reset" });
  }

  return { target: earliest.target, aHit, bHit, cHit, actual: actual.sum };
}

function getStats(){
  return {
    verified: session.aCorrect + session.aWrong,
    aCorrect: session.aCorrect, aVerified: session.aCorrect + session.aWrong,
    aRate: session.aCorrect + session.aWrong > 0 ? Math.round(session.aCorrect/(session.aCorrect+session.aWrong)*100) : 0,
    bCorrect: session.bCorrect, bVerified: session.bCorrect + session.bWrong,
    bRate: session.bCorrect + session.bWrong > 0 ? Math.round(session.bCorrect/(session.bCorrect+session.bWrong)*100) : 0,
    cCorrect: session.cCorrect, cVerified: session.cCorrect + session.cWrong,
    cRate: session.cCorrect + session.cWrong > 0 ? Math.round(session.cCorrect/(session.cCorrect+session.cWrong)*100) : 0,
  };
}

function broadcast(msg){
  self.clients.matchAll().then(clients => {
    clients.forEach(c => c.postMessage(msg));
  });
}

async function tick(){
  try{
    const res = await fetch(API_URL, { cache: "no-store" });
    const raw = await res.json();
    if(raw.code !== 0) return;

    const history = parseAPI(raw);
    if(history.length === 0) return;

    const newest = history[0];
    const nbr = newest.issue;

    if(lastNbr !== null && nbr !== lastNbr){
      const vr = verifyOne(history);
      if(vr) broadcast({ type: "verified", ...vr });
    }
    lastNbr = nbr;

    const target = nbr + 1;
    const existingRec = session.records.find(r => r.target === target);

    if(!existingRec){
      const resA = modelA(history);
      const resB = modelB(history);
      aWindows = resA.windows;

      if(resA.prediction && resB.prediction !== "--"){
        const kill = buildKill(resA, resB);
        session.records.push({
          target, predA: resA.prediction, predB: resB.prediction,
          killed: kill.killedGroup, status: "待验证"
        });
      }
      currentPrediction = {
        target,
        predA: resA.prediction || "--",
        predB: resB.prediction || "--",
        killGroup: buildKill(resA, resB).killedGroup || "--",
        comboAdv: combo(resA, resB).advice
      };
    }

    latestData = { issue: String(newest.issue), sum: newest.sum, code: newest.code, type: newest.type };
    historyCache = history;

    broadcast({ type: "tick", latest: latestData, prediction: currentPrediction, stats: getStats(), history: historyCache, records: session.records, aWindows });
  }catch(e){
    broadcast({ type: "sw_error", msg: e.message });
  }
}

self.addEventListener("install", e => { self.skipWaiting(); });

self.addEventListener("activate", e => {
  e.waitUntil(self.clients.claim().then(() => {
    broadcast({ type: "sw_ready" });
    tick();
    self.tickTimer = setInterval(tick, CHECK_INTERVAL);
  }));
});

self.addEventListener("message", e => {
  const d = e.data;
  if(!d) return;
  if(d.type === "get_state"){
    broadcast({ type: "tick", latest: latestData, prediction: currentPrediction, stats: getStats(), history: historyCache, records: session.records, aWindows });
  }
  if(d.type === "reset_stats"){
    session.aCorrect = 0; session.aWrong = 0;
    session.bCorrect = 0; session.bWrong = 0;
    session.cCorrect = 0; session.cWrong = 0;
    broadcast({ type: "tick", latest: latestData, prediction: currentPrediction, stats: getStats(), history: historyCache, records: session.records, aWindows });
  }
});
