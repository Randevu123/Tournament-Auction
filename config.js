// Supabase 연결 정보 — 두 값이 채워지면 온라인 경매가 켜집니다.
// supabaseKey 칸에는 "anon" 또는 "publishable" 키를 넣습니다. (공개돼도 되는 키)
// "service_role" 이나 "secret" 키는 절대 넣지 마세요.
window.AUCTION_CONFIG = {
  supabaseUrl: "https://umfusewgrukutppexbyz.supabase.co",
  supabaseKey: "sb_publishable_3B9oOuL0lN_XNIkNAl6Buw_3QZU3rZ0",
  // 이 사이트를 열어도 되는 주소. 여기 없는 주소에서 열면 바나나 그림만 보이고 서버에 연결하지 않아요.
  // 다른 GitHub으로 옮기면 새 주소로 바꾸세요 (예: "새아이디.github.io"). 비워 두면 [] 잠그지 않아요.
  allowedHosts: ["randevu123.github.io"],
};
