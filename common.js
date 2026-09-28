/* =====================================================================
   진행자 화면(index.html)과 팀장 화면(team.html)이 함께 쓰는 코드
   ===================================================================== */

/* [1] 바꾸기 쉬운 숫자 모음 — 새 경매를 만들 때 이 값이 서버에 저장됩니다
   (이미 만든 경매의 규칙은 바뀌지 않아요. 바꾼 뒤 새 경매를 만드세요) */
const CONFIG = {
  teamCount: 5,          // 팀 수 (= 팀장 수)
  startPoints: 1000,     // 팀 시작 포인트
  bidStep: 5,            // 최소 입찰 단위 (직접 입력도 이 단위로만 가능)
  quickBids: [1, 2],     // 팀장 화면의 빠른 입찰 버튼: 입찰 단위의 1배, 2배 (단위 5면 +5, +10)
  teamSize: 5,           // 한 팀 인원 (팀장 포함)
  reservePerSlot: 5,     // 빈자리 1칸당 남겨 둬야 하는 최소 포인트
  startSeconds: 15,      // 선수 한 명당 처음 주어지는 시간(초)
  bidAddSeconds: 5,      // 입찰할 때마다 늘어나는 시간(초)
  maxSeconds: 15,        // 남은 시간 최대치(초) — 경매 설정에서 바꿀 수 있음
  maxUnsold: 2,          // 이 횟수만큼 유찰되면 빈자리 팀에 무작위 배정
  resultShowMs: 2200,    // 낙찰/유찰 화면을 보여 주는 시간(밀리초)
  peakWeight: 0.5,       // 티어 점수에서 최고 티어가 차지하는 비율 (0.5 = 최고·현재 반반)
  mottoMaxLength: 40,    // 각오 한마디 최대 글자 수
  photoSize: 240,        // 올린 사진을 이 크기(픽셀)의 정사각형으로 줄여 저장
  teamColors: ["#ff4655", "#4da3ff", "#3ddc97", "#ffc93c", "#b67cff", "#ff8a3d", "#39d0e0", "#ff6fb5"],
};

/* [2] 티어 점수표와 계산 방식 — 아이언1 = 1점, 한 칸 오를 때마다 +1점, 레디언트 = 25점 */
const TIER_GROUPS = [
  ["아이언", 3], ["브론즈", 3], ["실버", 3], ["골드", 3], ["플래티넘", 3],
  ["다이아몬드", 3], ["초월자", 3], ["불멸", 3], ["레디언트", 1],
];
const TIER_SCORE = {};
(() => {
  let s = 1;
  for (const [name, steps] of TIER_GROUPS) {
    if (steps === 1) TIER_SCORE[name] = s++;
    else for (let i = 1; i <= steps; i++) TIER_SCORE[`${name} ${i}`] = s++;
  }
})();
CONFIG.tierScores = { ...TIER_SCORE };
// 언랭(배치 전): 최고 티어가 언랭이면 0점, 현재 티어만 언랭이면 최고 티어 점수만 씀. 점수표에는 넣지 않음
const UNRANKED = "언랭";
const TIER_OPTIONS = [UNRANKED, ...Object.keys(TIER_SCORE)];   // 티어 고르는 칸의 목록   // 새 회차의 기본 점수표 (진행자 화면 '경매 설정'에서 회차마다 바꿀 수 있음)

// 지금 보고 있는 경매의 점수표·비율 (진행자·팀장·운영자 화면이 서버에서 받아 넣음)
let SCORE_CFG = null;
function setScoreConfig(cfg) { SCORE_CFG = cfg || null; }
function tierPoints(tier, cfg = SCORE_CFG) {
  const table = (cfg && cfg.tierScores) || TIER_SCORE;
  return Number(table[tier] ?? TIER_SCORE[tier] ?? 0);
}
function peakWeight(cfg = SCORE_CFG) { return cfg && cfg.peakWeight != null ? Number(cfg.peakWeight) : 0.5; }
// 자동 점수 = 최고 티어 점수 × 비율 + 현재 티어 점수 × (1 − 비율), 소수점 첫째 자리까지 (기본 비율 50% = 두 점수의 평균)
function autoScore(p, cfg = SCORE_CFG) {
  if (p.peak === UNRANKED) return 0;
  if (p.current === UNRANKED) return round1(tierPoints(p.peak, cfg));
  const w = peakWeight(cfg);
  return round1(tierPoints(p.peak, cfg) * w + tierPoints(p.current, cfg) * (1 - w));
}
// 선수 점수 = 운영자가 직접 정한 점수가 있으면 그 점수, 없으면 자동 점수
function playerScore(p, cfg = SCORE_CFG) {
  if (p.score !== null && p.score !== undefined && p.score !== "") return round1(Number(p.score));
  return autoScore(p, cfg);
}
function scoreFormula(p, cfg = SCORE_CFG) {
  if (p.peak === UNRANKED) return "최고 티어 언랭 → 0";
  if (p.current === UNRANKED) return `현재 티어 언랭 → 최고 티어 ${tierPoints(p.peak, cfg)}점만 = ${autoScore(p, cfg).toFixed(1)}`;
  const w = peakWeight(cfg), a = tierPoints(p.peak, cfg), b = tierPoints(p.current, cfg);
  return w === 0.5 ? `(${a} + ${b}) ÷ 2 = ${autoScore(p, cfg).toFixed(1)}` : `${a}×${Math.round(w * 100)}% + ${b}×${Math.round((1 - w) * 100)}% = ${autoScore(p, cfg).toFixed(1)}`;
}
// 팀 점수 = 팀장을 포함한 선수 점수 합계, 평균 = 합계 ÷ 선수 수
function teamScore(roster) {
  const sum = round1(roster.reduce((a, p) => a + playerScore(p), 0));
  return { sum, avg: roster.length ? round1(sum / roster.length) : null };
}
function round1(n) { return Math.round(n * 10) / 10; }

/* [3] 가짜 선수 25명 (팀장 5명 + 경매 선수 20명) */
const POSITIONS = ["타격대", "척후대", "감시자", "전략가"];
// 포지션 여러 개 고르기: 누른 순서대로 "타격대, 척후대"처럼 저장 (신청·콘솔·선수 관리·연습판이 함께 씀)
function posList(v) { return String(v || "").split(",").map(x => x.trim()).filter(x => POSITIONS.includes(x)); }
function mountPosPicker(root, value, onChange) {
  const picked = posList(value);
  function draw() {
    root.classList.add("pos-multi");
    root.innerHTML = POSITIONS.map(p => { const i = picked.indexOf(p);
      return `<button type="button" data-pos="${p}" class="${i >= 0 ? "on" : ""}">${i >= 0 && picked.length > 1 ? `<span class="no">${i + 1}</span>` : ""}${p}</button>`; }).join("");
  }
  root.onclick = e => {
    const b = e.target.closest("[data-pos]"); if (!b) return;
    const i = picked.indexOf(b.dataset.pos);
    if (i >= 0) picked.splice(i, 1); else picked.push(b.dataset.pos);
    draw(); onChange && onChange(picked.join(", "));
  };
  draw();
  return { get: () => picked.join(", ") };
}
// 주 요원 고르기 목록 (2026년 9월 기준 29명). 새 요원이 나오면 알맞은 역할 줄에 이름만 더하면 됨
const AGENTS = {
  "타격대": ["제트", "레이즈", "레이나", "피닉스", "요루", "네온", "아이소", "웨이레이"],
  "척후대": ["소바", "브리치", "스카이", "케이/오", "페이드", "게코", "테호"],
  "감시자": ["킬조이", "사이퍼", "세이지", "체임버", "데드록", "바이스", "비토"],
  "전략가": ["브림스톤", "바이퍼", "오멘", "아스트라", "하버", "클로브", "믹스"],
};
const MAX_AGENTS = 3;
// 요원 아이콘: agents/agents.json (GitHub Actions "Update agent icons"가 받아 둔 목록). 없으면 이름만 보임
const AGENT_ICONS = {};
const agentListeners = [];
function onAgentIcons(fn) { agentListeners.push(fn); }
function loadAgentIcons() {
  fetch("agents/agents.json", { cache: "no-cache" }).then(r => (r.ok ? r.json() : [])).then(list => {
    (list || []).forEach(a => {
      if (!a || !a.name || !a.file) return;
      AGENT_ICONS[a.name] = a.file;
      if (AGENTS[a.role] && !Object.values(AGENTS).some(l => l.includes(a.name))) AGENTS[a.role].push(a.name);   // 새 요원은 목록에 자동 추가
    });
    agentListeners.forEach(fn => { try { fn(); } catch (e) { /* 화면마다 다음 갱신 때 다시 그림 */ } });
  }).catch(() => {});
}
function agentIcon(name, size) {
  const f = AGENT_ICONS[name];
  return f ? `<img class="ag-ic" src="${esc(f)}" alt="" width="${size}" height="${size}">` : "";
}
// 주 요원 고르기 칸 (신청 화면·운영자 콘솔이 함께 씀). 누르면 고르고 다시 누르면 빠짐, 최대 3개
function mountAgentPicker(root, selected, onChange) {
  const picked = selected.slice(0, MAX_AGENTS), me = {};
  root._picker = me;                       // 같은 칸에 다시 만들면 예전 것은 그리지 않음
  function draw() {
    if (root._picker !== me) return;
    root.className = "agent-pick";
    root.innerHTML = Object.entries(AGENTS).map(([role, list]) => `<div class="role"><small>${role}</small><div>${list.map(a => {
      const i = picked.indexOf(a);
      return `<button type="button" data-agent="${esc(a)}" class="${i >= 0 ? "on" : ""}">${i >= 0 ? `<span class="no">${i + 1}</span>` : ""}${agentIcon(a, 22)}${esc(a)}</button>`;
    }).join("")}</div></div>`).join("");
  }
  root.onclick = e => {
    const b = e.target.closest("[data-agent]"); if (!b) return;
    const a = b.dataset.agent, i = picked.indexOf(a);
    if (i >= 0) picked.splice(i, 1);
    else if (picked.length >= MAX_AGENTS) return toast(`주 요원은 ${MAX_AGENTS}개까지 고를 수 있어요. 먼저 하나를 빼 주세요.`);
    else picked.push(a);
    draw(); onChange && onChange(picked.slice());
  };
  draw();
  onAgentIcons(draw);
  return { get: () => picked.slice() };
}
// 이름이 길수록 글자를 작게 (띄어쓰기 없는 긴 영어 닉네임이 카드를 밀어내지 않게). 한글·전각은 1, 영문·숫자는 0.62칸으로 셈
function nameScale(name) {
  const w = [...String(name || "")].reduce((a, ch) => a + (/[\u0000-\u024f]/.test(ch) ? (/[A-Z@MWmw]/.test(ch) ? 0.78 : 0.6) : 1), 0);
  return w <= 7 ? 1 : Math.max(0.42, 7 / w);
}
// 사진 파일을 가운데 기준 정사각형으로 잘라 작게 줄임 (신청 화면 등)
function resizePhotoFile(file, size = CONFIG.photoSize) {
  return new Promise((resolve, reject) => {
    if (!file || !/^image\//.test(file.type)) return reject(new Error("image"));
    const img = new Image(), url = URL.createObjectURL(file);
    img.onload = () => {
      const side = Math.min(img.width, img.height), c = document.createElement("canvas"); c.width = c.height = size;
      c.getContext("2d").drawImage(img, (img.width - side) / 2, (img.height - side) / 2, side, side, 0, 0, size, size);
      URL.revokeObjectURL(url); resolve(c.toDataURL("image/jpeg", 0.82));
    };
    img.onerror = () => { URL.revokeObjectURL(url); reject(new Error("image")); };
    img.src = url;
  });
}
// 팀장 링크 이름: "팀장 닉네임" (그 팀의 팀장 선수 이름)
function captainLabel(state, teamIdx) {
  const c = state.players.find(p => p.team === teamIdx && p.how === "captain");
  return `팀장 ${c ? c.name : `${teamIdx + 1}팀`}`;
}
function agentsOf(p) { return Array.isArray(p && p.agents) ? p.agents : []; }
// 주 요원 칩 (없으면 빈 문자열)
function agentChips(p, cls = "", icon = 20) {
  const a = agentsOf(p);
  return a.length ? `<span class="agents ${cls}">${a.map(x => `<span class="ag">${agentIcon(x, icon)}${esc(x)}</span>`).join("")}</span>` : "";
}
// Riot Games 팬 콘텐츠 정책(Legal Jibber Jabber)에 따라 요원 그림을 쓸 때 붙이는 안내
const RIOT_NOTICE = "이 사이트는 Riot Games의 ‘Legal Jibber Jabber’ 정책에 따라 Riot Games 소유 자산을 사용해 만들었습니다. Riot Games는 이 프로젝트를 보증하거나 후원하지 않습니다.";
const PLAYERS_SEED = [
  ["새벽고양이", "불멸 2", "초월자 3", "타격대", true, "우승 아니면 은퇴합니다"],
  ["한강라면", "다이아몬드 1", "플래티넘 3", "전략가", true, "연막 하나는 자신 있어요"],
  ["멍때리는부엉이", "골드 3", "골드 1", "감시자", false, "사이트는 제가 지킵니다"],
  ["조준점요정", "초월자 1", "다이아몬드 2", "타격대", false, "헤드 아니면 안 쏩니다"],
  ["연막장인", "플래티넘 2", "플래티넘 1", "전략가", false, "시야는 제가 가려 드릴게요"],
  ["섬광은사랑", "실버 3", "실버 2", "척후대", false, "섬광 쓰기 전에 말할게요"],
  ["헤드만노림", "레디언트", "불멸 3", "타격대", false, "싸게 사면 이득입니다"],
  ["수비의신", "다이아몬드 3", "다이아몬드 1", "감시자", true, "한 명도 못 지나갑니다"],
  ["드론조종사", "골드 2", "실버 3", "척후대", false, "정보는 제가 먼저"],
  ["고구마맛탕", "브론즈 3", "브론즈 2", "감시자", false, "열심히 배우겠습니다"],
  ["칼침전문가", "불멸 1", "초월자 2", "타격대", false, "칼 들면 조심하세요"],
  ["밤하늘연막", "초월자 2", "초월자 1", "전략가", true, "오더는 제가 합니다"],
  ["달리는토끼", "실버 1", "브론즈 3", "타격대", false, "일단 들어가고 봅니다"],
  ["정보수집가", "플래티넘 3", "골드 3", "척후대", false, "적 위치 다 불러 드림"],
  ["철벽함정", "골드 1", "골드 1", "감시자", false, "함정 위치는 비밀"],
  ["초코우유", "아이언 3", "아이언 2", "전략가", false, "재밌게 하는 게 목표"],
  ["에임연습중", "다이아몬드 2", "플래티넘 2", "타격대", false, "연습한 만큼 보여 드림"],
  ["바람의검객", "초월자 3", "초월자 2", "타격대", false, "대시 한 번에 끝냅니다"],
  ["포켓힐러", "플래티넘 1", "골드 2", "감시자", false, "팀원 체력은 제가 책임"],
  ["스캔한번만", "불멸 3", "불멸 1", "척후대", true, "스캔 맞으면 끝입니다"],
  ["늦잠대장", "브론즈 1", "아이언 3", "척후대", false, "경기 시간엔 깨어 있겠습니다"],
  ["벽뒤의그림자", "다이아몬드 1", "다이아몬드 1", "전략가", false, "벽 뒤에서 기다릴게요"],
  ["클러치장인", "초월자 1", "플래티넘 3", "감시자", false, "1대3도 해 봤습니다"],
  ["노란우산", "실버 2", "실버 1", "전략가", false, "우산처럼 팀을 지킵니다"],
  ["마지막한발", "골드 3", "골드 2", "척후대", false, "마지막 한 발은 꼭 맞힘"],
  ["새벽세시", "초월자 2", "다이아몬드 3", "척후대", true, "밤샘은 자신 있습니다"],
  ["포탑수리공", "플래티넘 2", "골드 1", "감시자", false, "포탑 위치는 늘 같은 곳"],
  ["번개배달", "다이아몬드 3", "다이아몬드 2", "타격대", false, "제일 먼저 도착합니다"],
  ["구석탐험가", "실버 3", "실버 3", "척후대", false, "구석 확인은 제 담당"],
  ["연막한스푼", "골드 2", "골드 2", "전략가", false, "연막은 딱 필요한 만큼"],
  ["늦게온손님", "플래티넘 1", "플래티넘 1", "타격대", false, "늦게 신청했지만 대타 가능"],
];
function seedProfiles() {
  const list = PLAYERS_SEED.map(([name, peak, current, pos, captain, motto], i) =>
    ({ id: i, name, peak, current, pos, captain, motto, photo: "",
       agents: [0, 3].slice(0, 1 + (i % 2)).map(k => AGENTS[pos][(i + k) % AGENTS[pos].length]) }));   // 연습용 주 요원 1~2개
  // 31명 → 6팀(30명) + 늦게 온 1명은 대기, 경매 티어 A~D 자동 나누기
  const sp = splitGrades(list.map(p => ({ id: p.id, captain: p.captain, order: p.id, score: autoScore(p) })), 5);
  list.forEach(p => { p.grade = p.captain ? null : sp.grades[p.id]; p.bench = sp.bench.includes(p.id); });
  return list;
}
// 1단계 연습판에서 고쳐 둔 선수 정보가 있으면 그것을 씀
function localProfiles() {
  try {
    const list = JSON.parse(localStorage.getItem("valo-auction-profiles-v1") || "null");
    if (Array.isArray(list) && list.length) return list;
  } catch (e) { /* 없으면 기본값 */ }
  return seedProfiles();
}

/* [4] 경매 규칙 계산 (화면 표시용 — 진짜 판정은 서버가 한 번 더 합니다) */
function rosterOf(state, teamIdx) {
  return state.players.filter(p => p.team === teamIdx)
    .sort((a, b) => (b.how === "captain") - (a.how === "captain") || a.id - b.id);
}
function openSlots(state, teamIdx) { return state.config.teamSize - rosterOf(state, teamIdx).length; }
function maxBid(state, team) {
  const open = openSlots(state, team.idx);
  return open <= 0 ? 0 : team.points - state.config.reservePerSlot * (open - 1);
}
function bidBlockReason(state, team, amount) {
  const c = state.config, open = openSlots(state, team.idx);
  if (state.status !== "running") return "경매 진행 중이 아님";
  if (open <= 0) return "팀 인원이 꽉 참";
  const cur = state.players.find(p => p.id === state.current);
  if (hasGrade(state, team.idx, cur && cur.grade)) return `이미 우리 팀에 ${cur.grade}티어 선수가 있음`;
  if (state.bid_team === team.idx) return "우리 팀이 최고가";
  if (amount > team.points) return "포인트 부족";
  if (amount > maxBid(state, team)) return `빈자리 ${open - 1}칸 몫 ${c.reservePerSlot * (open - 1)}P는 남겨야 함`;
  return null;
}

/* [4-2] 경매 티어 A·B·C·D: 팀장 말고 팀마다 한 티어에 한 명씩 (게임 랭크 티어와는 다른 것) */
const GRADES = ["A", "B", "C", "D"];
function hasGrade(state, teamIdx, grade) {
  return !!grade && state.players.some(p => p.team === teamIdx && p.grade === grade);
}
function missingGrades(state, teamIdx) {
  if (!state.players.some(p => p.grade)) return [];
  return GRADES.filter(g => !hasGrade(state, teamIdx, g));
}
function gradeBadge(p, cls = "") { return p && p.grade ? `<span class="grade g-${esc(p.grade)} ${cls}">${esc(p.grade)}</span>` : ""; }
// 5명 단위 맞추기: 팀 수 = 전체 ÷ 팀 인원 (나머지는 늦게 신청한 사람부터 대기).
// list: [{id, captain, order(신청 순서), score}], 돌려줌: {teams, bench: [id], grades: {id: "A"}}
function splitGrades(list, teamSize = 5, teamsWanted = null) {
  const teams = teamsWanted || Math.floor(list.length / teamSize);
  const caps = list.filter(x => x.captain);
  const rest = list.filter(x => !x.captain).sort((a, b) => a.order - b.order);   // 신청 순서
  const need = Math.max(0, teams * teamSize - caps.length);
  const main = rest.slice(0, need), bench = rest.slice(need);
  const grades = {};
  const ranked = main.slice().sort((a, b) => b.score - a.score || a.order - b.order);
  const per = Math.max(1, Math.ceil(ranked.length / GRADES.length));
  ranked.forEach((x, i) => { grades[x.id] = GRADES[Math.min(GRADES.length - 1, Math.floor(i / (ranked.length === teams * 4 ? teams : per)))]; });
  // 대기 인원: 점수가 들어갈 티어 (그 티어의 가장 낮은 점수 이상이면 그 티어)
  const floor = {}; GRADES.forEach(g => { const sc = ranked.filter(x => grades[x.id] === g).map(x => x.score); floor[g] = sc.length ? Math.min(...sc) : -Infinity; });
  bench.forEach(x => { grades[x.id] = GRADES.find(g => x.score >= floor[g]) || "D"; });
  return { teams, bench: bench.map(x => x.id), grades };
}

/* [4-3] 효과음 (파일 없이 브라우저가 직접 만드는 소리) */
const SFX = (() => {
  let ctx = null, master = null;
  const KEY = "valo-sfx-on";
  let on = true;
  try { on = localStorage.getItem(KEY) !== "0"; } catch (e) { /* 저장이 막혀도 켜 둠 */ }
  function ac() {
    if (!ctx) {
      const AC = window.AudioContext || window.webkitAudioContext; if (!AC) return null;
      ctx = new AC(); master = ctx.createGain(); master.gain.value = 0.5; master.connect(ctx.destination);
    }
    if (ctx.state === "suspended") ctx.resume().catch(() => {});
    return ctx;
  }
  // 브라우저는 사용자가 한 번 누르기 전에는 소리를 막으므로 첫 클릭·키에서 깨움 (OBS는 바로 됨)
  ["pointerdown", "keydown"].forEach(ev => addEventListener(ev, () => { if (on) ac(); }, { once: false, passive: true }));
  function tone(freq, t0, dur, { type = "sine", vol = 0.3, to = null, attack = 0.005 } = {}) {
    const c = ac(); if (!c || !on) return;
    const t = c.currentTime + t0, o = c.createOscillator(), g = c.createGain();
    o.type = type; o.frequency.setValueAtTime(freq, t);
    if (to) o.frequency.exponentialRampToValueAtTime(to, t + dur);
    g.gain.setValueAtTime(0.0001, t); g.gain.exponentialRampToValueAtTime(vol, t + attack);
    g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
    o.connect(g); g.connect(master); o.start(t); o.stop(t + dur + 0.02);
  }
  function noise(t0, dur, { vol = 0.2, from = 800, to = 4000 } = {}) {
    const c = ac(); if (!c || !on) return;
    const t = c.currentTime + t0, n = Math.floor(c.sampleRate * dur), buf = c.createBuffer(1, n, c.sampleRate), d = buf.getChannelData(0);
    for (let i = 0; i < n; i++) d[i] = Math.random() * 2 - 1;
    const src = c.createBufferSource(), f = c.createBiquadFilter(), g = c.createGain();
    src.buffer = buf; f.type = "bandpass"; f.frequency.setValueAtTime(from, t); f.frequency.exponentialRampToValueAtTime(to, t + dur);
    g.gain.setValueAtTime(vol, t); g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
    src.connect(f); f.connect(g); g.connect(master); src.start(t); src.stop(t + dur);
  }
  return {
    get on() { return on; },
    set(v) { on = !!v; try { localStorage.setItem(KEY, on ? "1" : "0"); } catch (e) { /* */ } if (on) ac(); },
    bid() { tone(660, 0, 0.09, { type: "square", vol: 0.12 }); tone(990, 0.06, 0.12, { type: "square", vol: 0.1 }); },
    myBid() { tone(784, 0, 0.08, { type: "triangle", vol: 0.25 }); tone(1175, 0.07, 0.16, { type: "triangle", vol: 0.22 }); },
    tick(urgent) { tone(urgent ? 1320 : 880, 0, 0.07, { type: "square", vol: urgent ? 0.14 : 0.08 }); },
    lot() { noise(0, 0.35, { vol: 0.12, from: 300, to: 3000 }); tone(440, 0.12, 0.18, { type: "triangle", vol: 0.18 }); tone(660, 0.22, 0.25, { type: "triangle", vol: 0.18 }); },
    start() { tone(523, 0, 0.12, { type: "sawtooth", vol: 0.1 }); tone(784, 0.1, 0.25, { type: "sawtooth", vol: 0.12 }); },
    sold() {
      noise(0, 0.08, { vol: 0.5, from: 2000, to: 200 }); tone(110, 0, 0.25, { type: "sine", vol: 0.5, to: 60 });   // 망치
      [523, 659, 784, 1047].forEach((f, i) => tone(f, 0.18 + i * 0.09, 0.35, { type: "triangle", vol: 0.22 }));
      tone(1047, 0.6, 0.6, { type: "triangle", vol: 0.2 }); tone(1319, 0.6, 0.6, { type: "sine", vol: 0.12 });
    },
    random() { noise(0, 0.5, { vol: 0.18, from: 400, to: 5000 }); [392, 523, 659].forEach((f, i) => tone(f, 0.25 + i * 0.1, 0.3, { type: "triangle", vol: 0.18 })); },
    unsold() { tone(392, 0, 0.25, { type: "sawtooth", vol: 0.12 }); tone(330, 0.2, 0.25, { type: "sawtooth", vol: 0.12 }); tone(262, 0.4, 0.5, { type: "sawtooth", vol: 0.12, to: 200 }); },
    spin() { tone(1200 + Math.random() * 400, 0, 0.03, { type: "square", vol: 0.05 }); },
    lock() { tone(880, 0, 0.12, { type: "triangle", vol: 0.25 }); tone(1320, 0.05, 0.25, { type: "sine", vol: 0.15 }); },
    reveal() { noise(0, 0.25, { vol: 0.15, from: 500, to: 6000 }); tone(587, 0.08, 0.2, { type: "triangle", vol: 0.2 }); },
    crown() { [523, 659, 784, 1047, 1319].forEach((f, i) => tone(f, i * 0.12, 0.5, { type: "triangle", vol: 0.22 })); tone(1568, 0.65, 1.0, { type: "sine", vol: 0.18 }); noise(0.6, 0.8, { vol: 0.08, from: 3000, to: 9000 }); },
    pause() { tone(440, 0, 0.15, { type: "sine", vol: 0.15, to: 330 }); },
  };
})();
// 소리 켜기/끄기 버튼 (진행자·팀장·연습판)
function mountSoundToggle(btn) {
  const draw = () => { btn.textContent = SFX.on ? "소리 켜짐" : "소리 꺼짐"; btn.classList.toggle("off", !SFX.on); };
  btn.addEventListener("click", () => { SFX.set(!SFX.on); draw(); if (SFX.on) SFX.lock(); });
  draw();
}
// 상태가 바뀔 때 알맞은 소리 (진행자·팀장·방송·연습판이 함께 씀)
function soundForState(prev, s, { myTeam = null } = {}) {
  if (!prev) return;
  if (s.last_result && (!prev.last_result || s.last_result.seq !== prev.last_result.seq)) {
    const k = s.last_result.kind; if (k === "sold") SFX.sold(); else if (k === "random" || k === "auto") SFX.random(); else SFX.unsold();
    return;
  }
  if (s.current !== prev.current && s.current !== null) SFX.lot();
  if (s.status === "running" && prev.status === "ready") SFX.start();
  if (s.status === "paused" && prev.status === "running") SFX.pause();
  if (s.status === "running" && prev.status === "running" && s.current === prev.current && s.bid_amount > prev.bid_amount) {
    if (myTeam !== null && s.bid_team === myTeam) SFX.myBid(); else SFX.bid();
  }
}
// 마지막 5초 째깍 (1초마다 한 번)
function countdownTicker() {
  let last = null;
  return (state, leftMs) => {
    if (!state || state.status !== "running") { last = null; return; }
    const sec = Math.ceil(leftMs / 1000);
    if (sec <= 5 && sec >= 1 && sec !== last) { if (last !== null) SFX.tick(sec <= 3); last = sec; }
    else if (sec > 5) last = null;
  };
}

/* [4-4] 경매 중 폰·PC 화면이 저절로 꺼지지 않게 (지원하는 브라우저만) */
function keepScreenOn(isActive) {
  let lock = null, busy = false;
  async function sync() {
    if (!("wakeLock" in navigator) || busy) return;
    busy = true;
    try {
      const want = isActive() && document.visibilityState === "visible";
      if (want && !lock) { lock = await navigator.wakeLock.request("screen"); lock.addEventListener("release", () => { lock = null; }); }
      else if (!want && lock) { await lock.release(); lock = null; }
    } catch (e) { /* 배터리 절약 모드 등으로 거절되면 그냥 둠 */ }
    busy = false;
  }
  document.addEventListener("visibilitychange", sync);
  setInterval(sync, 5000); sync();
}

/* [4-5] 결과를 이미지(PNG) 한 장으로 저장 — 디스코드에 바로 올리기 좋게 */
function loadScript(src) {
  return new Promise((ok, fail) => { const t = document.createElement("script"); t.src = src; t.onload = ok; t.onerror = fail; document.head.appendChild(t); });
}
async function saveResultImage(state, title) {
  if (!window.html2canvas) await loadScript("https://cdn.jsdelivr.net/npm/html2canvas@1.4.1/dist/html2canvas.min.js");
  const n = state.teams.length, cols = n <= 4 ? n : n <= 6 ? 3 : 4;
  const box = document.createElement("div");
  box.className = "shot-box";
  box.style.cssText = `position:fixed;left:-20000px;top:0;width:${cols * 380 + 80}px;--cols:${cols}`;
  const pad = x => String(x).padStart(2, "0"), d = new Date();
  box.innerHTML = `<div class="shot-head"><div class="logo">VALORANT <span>내전 경매</span></div><h2>${esc(title || "경매 결과")}</h2>
      <small>${d.getFullYear()}.${pad(d.getMonth() + 1)}.${pad(d.getDate())}</small></div>
    ${resultHtml(state, { discord: false })}<p class="riot-notice">${esc(RIOT_NOTICE)}</p>`;
  document.body.appendChild(box);
  try {
    if (document.fonts && document.fonts.ready) await document.fonts.ready;
    // 못 불러온 디스코드 사진(글자 그림)은 글자 칸으로 바꿔서 그림
    await new Promise(r => setTimeout(r, 300));
    box.querySelectorAll("img.av").forEach(img => {
      if (img.src.startsWith("data:image/svg") || (img.complete && !img.naturalWidth)) {
        const sp = document.createElement("span"); sp.className = "av ph"; sp.style.cssText = img.style.cssText;
        sp.style.fontSize = Math.round(parseInt(img.style.width) * 0.45) + "px"; sp.textContent = img.dataset.ch || "?"; img.replaceWith(sp);
      }
    });
    const canvas = await window.html2canvas(box, { backgroundColor: "#0b0d14", scale: 1, useCORS: true, logging: false });
    const blob = await new Promise(r => canvas.toBlob(r, "image/png"));
    const url = URL.createObjectURL(blob), a = document.createElement("a");
    a.href = url; a.download = `auction-result_${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}.png`;
    document.body.appendChild(a); a.click(); setTimeout(() => { a.remove(); URL.revokeObjectURL(url); }, 4000);
    return true;
  } finally { box.remove(); }
}

/* [5] 화면 도우미 */
function esc(s) {
  return String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}
function letterSvg(ch) {       // 사진을 못 불러왔을 때 대신 쓰는 글자 그림
  return "data:image/svg+xml," + encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><rect width="100" height="100" fill="#2a3145"/><text x="50" y="66" font-size="48" text-anchor="middle" fill="#fff" font-family="sans-serif">${ch.replace(/[<&>'"]/g, "")}</text></svg>`);
}
function avatar(p, size) {
  if (p && p.photo && p.photo.startsWith("data:image/")) {
    return `<img class="av" src="${esc(p.photo)}" alt="" style="width:${size}px;height:${size}px">`;
  }
  // 사진이 없으면 디스코드 프로필 사진 (디스코드 주소만 씀)
  const dc = p && (p.dc_avatar || p.discord_avatar);
  if (dc && /^https:\/\/cdn\.discordapp\.com\//.test(dc)) {
    const ch = [...(p.name || p.nick || "?")][0] || "?";
    return `<img class="av" src="${esc(dc)}" alt="" data-ch="${esc(ch)}" referrerpolicy="no-referrer" style="width:${size}px;height:${size}px" onerror="this.onerror=null;this.src='${letterSvg(ch)}'">`;
  }
  return `<span class="av ph" style="width:${size}px;height:${size}px;font-size:${Math.round(size * 0.45)}px">${esc([...(p ? p.name : "?")][0] || "?")}</span>`;
}
function bumpEl(el, cls) { if (!el) return; el.classList.remove(cls); void el.offsetWidth; el.classList.add(cls); }
let toastTimer;
function toast(text) {
  const t = document.getElementById("toast");
  t.textContent = text; t.style.display = "block";
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (t.style.display = "none"), 2800);
}
function flash(title, subHtml, color, player) {
  const f = document.getElementById("flash");
  f.style.setProperty("--c", color);
  document.getElementById("flashPhoto").innerHTML = player ? avatar(player, 160) : "";
  document.getElementById("flashTitle").textContent = title;
  document.getElementById("flashSub").innerHTML = subHtml;
  bumpEl(f, "show");
}
// 서버가 알려 준 낙찰/유찰 결과를 번쩍이는 화면으로 보여 줌
function flashResult(state) {
  const r = state.last_result; if (!r) return;
  const p = state.players.find(x => x.id === r.player); if (!p) return;
  const t = state.teams[r.team];
  if (r.kind === "sold") flash("낙찰!", `<em>${esc(t.name)}</em> · ${esc(p.name)} · ${r.price}P`, t.color, p);
  else if (r.kind === "random") flash("무작위 배정", `${esc(p.name)} → <em>${esc(t.name)}</em>`, t.color, p);
  else if (r.kind === "auto") flash("자동 배정", `${esc(p.name)} → <em>${esc(t.name)}</em> · ${esc(p.grade || "")}티어 남은 팀이 하나`, t.color, p);
  else flash("유찰", `${esc(p.name)} · 순서 맨 뒤로`, "#8a93ab", p);
}
function eventsHtml(events) {
  return events.map(e => `<li class="${esc(e.kind)}">${esc(e.body)}</li>`).join("");
}
function linkParams() {
  const q = new URLSearchParams(location.search);
  return { id: q.get("a"), key: q.get("k") };
}
function isConfigured() {
  const c = window.AUCTION_CONFIG || {};
  return !!(c.supabaseUrl && c.supabaseKey && window.supabase);
}

/* [6] 서버 연결
   - 조작(입찰, 시작 등)은 서버 함수로 보내고, 서버가 순서대로 하나씩 처리합니다.
   - 처리 뒤 "바뀌었어요" 신호를 실시간 채널로 보내면, 다른 화면이 새 상태를 받아 옵니다.
   - 신호를 놓쳐도 4초마다 한 번씩 스스로 확인하므로, 새로고침·끊김 뒤에도 따라잡습니다. */
function connect({ id, key, presenceKey, presenceInfo, onState, onChat, onPresence, onConn, chat = true, onEvent = {} }) {
  const cfg = window.AUCTION_CONFIG;
  const sb = window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  let state = null, version = 0, offset = 0, bestRtt = Infinity, chStatus = "", failed = false;
  let photos = {}, photosVersion = -1, photosLoading = false;
  const seenChat = new Set(); let maxChat = 0;

  async function rpc(fn, args) {
    const { data, error } = await sb.rpc(fn, args);
    if (error) throw new Error(error.message);
    return data;
  }

  function apply(s, t0, t1) {
    if (!s) return;
    const rtt = t1 - t0;
    if (rtt <= bestRtt * 1.5) { offset = s.server_now - (t0 + t1) / 2; bestRtt = Math.min(bestRtt, rtt); }
    if (s.version < version) return;           // 늦게 도착한 옛날 상태는 버림
    version = s.version;
    if (s.players_version !== photosVersion) loadPhotos(s.players_version);
    s.players.forEach(p => { p.photo = photos[p.id] || ""; });
    state = s;
    onState(s);
  }

  async function loadPhotos(v) {
    if (photosLoading) return;
    photosLoading = true;
    try {
      photos = (await rpc("get_photos", { p_id: id, p_key: key })) || {};
      photosVersion = v;
      if (state) { state.players.forEach(p => { p.photo = photos[p.id] || ""; }); onState(state); }
    } catch (e) { /* 다음 확인 때 다시 시도 */ }
    photosLoading = false;
  }

  let inflight = false, again = false;
  async function refresh() {
    if (inflight) { again = true; return; }
    inflight = true;
    try {
      const t0 = Date.now();
      const s = await rpc("get_state", { p_id: id, p_key: key });
      apply(s, t0, Date.now());
      if (failed) { failed = false; onConn && onConn(chStatus); }   // 다시 붙으면 연결 표시도 되돌림
    } catch (e) { failed = true; onConn && onConn("error"); }
    inflight = false;
    if (again) { again = false; refresh(); }
  }

  // 조작 보내기: 서버가 돌려준 새 상태를 바로 그리고, 다른 화면에 신호를 보냄
  async function act(fn, args = {}) {
    const t0 = Date.now();
    let r;
    try { r = await rpc(fn, { p_id: id, p_key: key, ...args }); }
    catch (e) { toast("서버에 닿지 못했어요. 인터넷 연결을 확인해 주세요."); return null; }
    if (r && r.state) apply(r.state, t0, Date.now());
    if (r && r.state && (fn !== "tick" || r.changed)) ping();
    return r;
  }

  const channel = sb.channel(`auction-${id}`, {
    config: { broadcast: { self: false }, presence: { key: presenceKey } },
  });
  function ping() { channel.send({ type: "broadcast", event: "changed", payload: { v: version } }); }

  function addChat(list) {
    const fresh = (list || []).filter(m => m && !seenChat.has(m.id));
    if (!fresh.length) return;
    fresh.forEach(m => { seenChat.add(m.id); maxChat = Math.max(maxChat, m.id); });
    onChat(fresh.sort((a, b) => a.id - b.id));
  }
  async function refreshChat() {
    if (!chat) return;                         // 방송 화면은 채팅을 읽지 않음
    try { addChat(await rpc("get_chat", { p_id: id, p_key: key, p_after: Math.max(0, maxChat - 30) })); } catch (e) { /* 다음에 */ }
  }
  async function sendChat(body) {
    const r = await act("send_chat", { p_body: body });
    if (!r) return false;
    if (!r.ok) { toast(r.reason); return false; }
    addChat([r.msg]);
    channel.send({ type: "broadcast", event: "chat", payload: r.msg });
    return true;
  }

  channel
    .on("broadcast", { event: "changed" }, ({ payload }) => { if (!payload || payload.v > version) refresh(); })
    .on("broadcast", { event: "chat" }, ({ payload }) => chat && addChat([payload]))
    .on("broadcast", { event: "show" }, ({ payload }) => onEvent.show && onEvent.show(payload || {}))
    .on("presence", { event: "sync" }, () => onPresence && onPresence(channel.presenceState()))
    .subscribe(status => {
      chStatus = status;
      if (!failed) onConn && onConn(status);
      if (status === "SUBSCRIBED") {
        channel.track(presenceInfo || {});
        refresh(); refreshChat();
      }
    });

  // 안전장치: 4초마다 확인, 화면으로 돌아오거나 인터넷이 다시 붙으면 바로 확인
  setInterval(() => { refresh(); refreshChat(); }, 4000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) { refresh(); refreshChat(); } });
  window.addEventListener("online", () => { refresh(); refreshChat(); });

  // 시간이 다 되면 서버에 "끝났나요?"를 물음 (누가 물어도 서버가 한 번만 처리)
  let lastTick = 0;
  setInterval(() => {
    if (!state) return;
    const now = Date.now() + offset;
    const due = (state.status === "running" && now >= state.ends_at + 100) ||
                (state.status === "result" && now >= state.next_at + 100);
    if (due && Date.now() - lastTick > 900) { lastTick = Date.now(); act("tick"); }
  }, 200);

  refresh(); refreshChat();
  return {
    sb, act, sendChat, refresh,
    // 화면 연출 신호 (예: 순서 추첨) — 방송 화면이 받아서 같은 연출을 보여 줌
    show: payload => channel.send({ type: "broadcast", event: "show", payload }),
    rpc: (fn, args = {}) => rpc(fn, { p_id: id, p_key: key, ...args }),
    serverNow: () => Date.now() + offset,
    get state() { return state; },
  };
}

// 서버 기준 남은 시간(밀리초)
function timeLeftMs(state, serverNow) {
  if (!state) return 0;
  if (state.status === "running") return Math.max(0, state.ends_at - serverNow);
  if (state.status === "paused") return state.paused_left_ms || 0;
  if (state.status === "ready") return state.config.startSeconds * 1000;
  return 0;
}

/* [7] 채팅 창 (진행자와 팀장만) — 접었다 펼 수 있음 */
function mountChat(root, net, { storeKey, startCollapsed = false } = {}) {
  root.innerHTML = `
    <button class="chat-head" type="button"><span>채팅</span><b class="unread" hidden>0</b><span class="grow"></span><span class="chev"></span></button>
    <div class="chat-body">
      <ul class="chat-list"><li class="empty">진행자와 팀장만 보는 채팅이에요.</li></ul>
      <form class="chat-form"><input maxlength="200" placeholder="메시지 입력" enterkeyhint="send"><button>보내기</button></form>
    </div>`;
  const head = root.querySelector(".chat-head"), list = root.querySelector(".chat-list");
  const unreadEl = root.querySelector(".unread"), chev = root.querySelector(".chev");
  const input = root.querySelector("input");
  let unread = 0, collapsed = startCollapsed;
  try { const v = localStorage.getItem(storeKey); if (v !== null) collapsed = v === "1"; } catch (e) { /* 무시 */ }

  function setCollapsed(v) {
    collapsed = v;
    root.classList.toggle("collapsed", v);
    chev.textContent = v ? "펼치기 ▲" : "접기 ▼";
    if (!v) { unread = 0; list.scrollTop = list.scrollHeight; }
    unreadEl.hidden = unread === 0; unreadEl.textContent = unread;
    try { localStorage.setItem(storeKey, v ? "1" : "0"); } catch (e) { /* 무시 */ }
    root.dispatchEvent(new Event("chattoggle"));
  }
  head.addEventListener("click", () => setCollapsed(!collapsed));
  root.querySelector("form").addEventListener("submit", async e => {
    e.preventDefault();
    const body = input.value.trim(); if (!body) return;
    input.value = "";
    if (!(await net.sendChat(body))) input.value = body;
  });
  setCollapsed(collapsed);

  return {
    add(msgs) {
      list.querySelector(".empty")?.remove();
      const atBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 40;
      for (const m of msgs) {
        const li = document.createElement("li");
        li.dataset.id = m.id;
        const time = new Date(m.at).toLocaleTimeString("ko-KR", { hour: "2-digit", minute: "2-digit" });
        li.innerHTML = `<b style="color:${esc(m.color)}">${esc(m.sender)}</b>${esc(m.body)}<small>${time}</small>`;
        const after = [...list.children].find(x => Number(x.dataset.id) > m.id);
        list.insertBefore(li, after || null);
      }
      if (collapsed) { unread += msgs.length; unreadEl.hidden = false; unreadEl.textContent = unread; }
      else if (atBottom) list.scrollTop = list.scrollHeight;
    },
  };
}

/* [8] 경매 결과: 결과 화면과 엑셀 파일 (진행자·팀장·연습판·운영자 콘솔이 함께 씀) */
function resultTeams(state) {
  return state.teams.map(t => {
    const roster = rosterOf(state, t.idx);
    const start = (state.config.startPoints || 0) - (t.handicap || 0);
    const { sum, avg } = teamScore(roster);
    return { team: t, roster, start, used: start - t.points, sum, avg };
  });
}
function howLabel(p) { return p.how === "captain" ? "팀장" : p.how === "random" ? "유찰 → 무작위 배정" : p.how === "auto" ? "자동 배정" : "낙찰"; }
// 팀 명단의 오른쪽 값: 팀장 / 무작위 / 자동 / 낙찰가
function priceTag(r) {
  return r.how === "captain" ? `<span class="pr cap">팀장</span>` : r.how === "random" ? `<span class="pr rnd">무작위</span>`
    : r.how === "auto" ? `<span class="pr rnd">자동</span>` : `<span class="pr">${r.price}P</span>`;
}

// 팀 순위 = 티어 점수 합계 순 (새 실력 점수를 만들지 않고, 신청 티어 점수표 합계만 씀)
function resultRanks(state) {
  const teams = resultTeams(state);
  const sums = teams.map(x => round1(x.sum)).sort((a, b) => b - a);
  const rank = {};
  teams.forEach(x => { rank[x.team.idx] = sums.indexOf(round1(x.sum)) + 1; });   // 합계가 같으면 같은 순위
  return rank;
}
function resultHtml(state, { reveal = false, discord = true } = {}) {
  const teams = resultTeams(state), rank = resultRanks(state);
  const left = state.players.filter(p => p.team === null);
  return `<div class="result-grid ${reveal ? "reveal" : ""}">${teams.map(({ team: t, roster, start, sum, avg }) => `
      <div class="result-team ${rank[t.idx] === 1 && teams.length > 1 ? "top" : ""}" style="--c:${esc(t.color)}" data-rank="${rank[t.idx]}">
        ${rank[t.idx] === 1 && teams.length > 1 ? `<div class="rt-crown">우승 후보</div>` : ""}
        <div class="rt-head"><b>${esc(t.name)}</b><span class="rt-rank">점수 합계 ${rank[t.idx]}위</span><span>${roster.length}명</span></div>
        <div class="rt-nums"><div><small>남은 포인트</small><b>${t.points}P</b></div><div><small>시작</small><b>${start}P</b></div><div><small>점수 합계</small><b>${sum.toFixed(1)}</b></div><div><small>평균</small><b>${avg === null ? "-" : avg.toFixed(1)}</b></div></div>
        <table class="rt-table"><tbody>${roster.map(p => `<tr class="${p.how === "random" || p.how === "auto" ? "rnd" : ""}">
          <td>${avatar(p, 22)}</td><td>${gradeBadge(p, "sm")}<b>${esc(p.name)}</b>${discord && p.discord ? `<small>${esc(p.discord)}</small>` : ""}</td>
          <td>${esc(p.pos)}</td><td class="sc">${playerScore(p).toFixed(1)}</td>
          <td class="pr">${p.how === "captain" ? "팀장" : p.how === "random" ? "무작위" : p.how === "auto" ? "자동" : `${p.price}P`}</td></tr>`).join("")}</tbody></table>
      </div>`).join("")}</div>
    ${left.length ? `<div class="result-left">팀에 못 들어간 선수 ${left.length}명: ${left.map(p => esc(p.name)).join(", ")}</div>` : ""}`;
}

// 엑셀(.xlsx) 파일: 시트1 "팀 구성", 시트2 "팀 요약" (+ 남은 선수가 있으면 시트3)
function downloadResultXlsx(state, title) {
  const teams = resultTeams(state);
  const rows = [["팀", "구분", "경매 티어", "선수 닉네임", "디스코드 이름", "최고 티어", "현재 티어", "티어 점수", "포지션", "주 요원", "낙찰가", "비고"]];
  teams.forEach(({ team: t, roster }) => roster.forEach(p => rows.push([
    t.name, howLabel(p), p.grade || "", p.name, p.discord || "", p.peak, p.current, Number(playerScore(p).toFixed(1)), p.pos, agentsOf(p).join(", "),
    p.how === "bid" ? p.price : 0, p.how === "random" ? "유찰되어 무작위로 배정됨" : p.how === "auto" ? "그 티어를 받을 팀이 하나뿐이라 자동 배정" : p.how === "captain" ? "팀장" : ""])));
  const summary = [["팀", "팀장", "인원", "시작 포인트", "핸디캡", "쓴 포인트", "남은 포인트", "티어 점수 합계", "티어 점수 평균"]];
  teams.forEach(({ team: t, roster, start, used, sum, avg }) => summary.push([
    t.name, (roster.find(p => p.how === "captain") || {}).name || "", roster.length, start, t.handicap || 0, used, t.points,
    Number(sum.toFixed(1)), avg === null ? "" : Number(avg.toFixed(1))]));
  const left = state.players.filter(p => p.team === null);
  const pad = n => String(n).padStart(2, "0"), d = new Date();
  const stamp = `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}`;
  // 파일 이름은 영문 (한글 파일 이름을 "download"로 바꾸는 브라우저가 있음)
  const name = `auction-result_${stamp}`;
  if (window.XLSX) {
    const wb = XLSX.utils.book_new();
    const ws1 = XLSX.utils.aoa_to_sheet(rows);
    ws1["!cols"] = [14, 18, 8, 16, 16, 12, 12, 9, 9, 20, 8, 22].map(w => ({ wch: w }));
    const ws2 = XLSX.utils.aoa_to_sheet(summary);
    ws2["!cols"] = [16, 14, 6, 11, 8, 10, 11, 13, 13].map(w => ({ wch: w }));
    XLSX.utils.book_append_sheet(wb, ws1, "팀 구성");
    XLSX.utils.book_append_sheet(wb, ws2, "팀 요약");
    if (left.length) {
      const ws3 = XLSX.utils.aoa_to_sheet([["경매 티어", "선수 닉네임", "디스코드 이름", "최고 티어", "현재 티어", "티어 점수", "포지션", "주 요원", "유찰 횟수"]]
        .concat(left.map(p => [p.grade || "", p.name, p.discord || "", p.peak, p.current, Number(playerScore(p).toFixed(1)), p.pos, agentsOf(p).join(", "), p.unsold || 0])));
      XLSX.utils.book_append_sheet(wb, ws3, "팀에 못 들어간 선수");
    }
    wb.Props = { Title: title || "경매 결과" };
    XLSX.writeFile(wb, `${name}.xlsx`);
    return "xlsx";
  }
  // 엑셀 라이브러리를 못 불러오면 CSV로 (엑셀에서 열림)
  const cell = v => { const t = String(v ?? ""); return /[",\n\r]/.test(t) ? `"${t.replace(/"/g, '""')}"` : t; };
  const csv = "﻿" + rows.map(r => r.map(cell).join(",")).join("\r\n");
  const url = URL.createObjectURL(new Blob([csv], { type: "text/csv;charset=utf-8" }));
  const a = document.createElement("a"); a.href = url; a.download = `${name}.csv`; a.style.display = "none";
  document.body.appendChild(a); a.click();
  setTimeout(() => { a.remove(); URL.revokeObjectURL(url); }, 4000);
  return "csv";
}

// 방송용 결과 발표 연출: 점수 합계가 낮은 팀부터 한 장씩, 마지막에 1위 팀 강조
function playResultReveal(container, { gap = 1100 } = {}) {
  const grid = container.querySelector(".result-grid");
  if (!grid) return;
  const cards = [...grid.querySelectorAll(".result-team")];
  cards.forEach(c => c.classList.remove("shown", "crowned"));
  grid.classList.add("reveal");
  const order = cards.slice().sort((a, b) => Number(b.dataset.rank) - Number(a.dataset.rank));
  (grid._timers || []).forEach(clearTimeout);
  grid._timers = order.map((c, i) => setTimeout(() => {
    c.classList.add("shown"); SFX.reveal();
    if (i === order.length - 1 && c.classList.contains("top")) {
      setTimeout(() => {
        c.classList.add("crowned"); SFX.crown();
        const name = c.querySelector(".rt-head b").textContent;
        flash("우승 후보", `<em>${esc(name)}</em> · 티어 점수 합계 1위`, getComputedStyle(c).getPropertyValue("--c") || "#ffd166");
      }, 350);
    }
  }, 500 + i * gap));
}

loadAgentIcons();
