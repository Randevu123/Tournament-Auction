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
  maxSeconds: 30,        // 남은 시간 최대치(초)
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
CONFIG.tierScores = { ...TIER_SCORE };   // 새 회차의 기본 점수표 (진행자 화면 '경매 설정'에서 회차마다 바꿀 수 있음)

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
  const w = peakWeight(cfg);
  return round1(tierPoints(p.peak, cfg) * w + tierPoints(p.current, cfg) * (1 - w));
}
// 선수 점수 = 운영자가 직접 정한 점수가 있으면 그 점수, 없으면 자동 점수
function playerScore(p, cfg = SCORE_CFG) {
  if (p.score !== null && p.score !== undefined && p.score !== "") return round1(Number(p.score));
  return autoScore(p, cfg);
}
function scoreFormula(p, cfg = SCORE_CFG) {
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
];
function seedProfiles() {
  return PLAYERS_SEED.map(([name, peak, current, pos, captain, motto], i) =>
    ({ id: i, name, peak, current, pos, captain, motto, photo: "" }));
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
  if (state.bid_team === team.idx) return "우리 팀이 최고가";
  if (amount > team.points) return "포인트 부족";
  if (amount > maxBid(state, team)) return `빈자리 ${open - 1}칸 몫 ${c.reservePerSlot * (open - 1)}P는 남겨야 함`;
  return null;
}

/* [5] 화면 도우미 */
function esc(s) {
  return String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}
function avatar(p, size) {
  if (p && p.photo && p.photo.startsWith("data:image/")) {
    return `<img class="av" src="${esc(p.photo)}" alt="" style="width:${size}px;height:${size}px">`;
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
function connect({ id, key, presenceKey, presenceInfo, onState, onChat, onPresence, onConn }) {
  const cfg = window.AUCTION_CONFIG;
  const sb = window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  let state = null, version = 0, offset = 0, bestRtt = Infinity;
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
    } catch (e) { onConn && onConn("error"); }
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
    .on("broadcast", { event: "chat" }, ({ payload }) => addChat([payload]))
    .on("presence", { event: "sync" }, () => onPresence && onPresence(channel.presenceState()))
    .subscribe(status => {
      onConn && onConn(status);
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
