# 판스티커 투명배경 정리 도구
# 사용: .\sticker_clean.ps1 -In 원본.png -Out 결과.png [-BorderMm 1.2] [-GapMm 3] [-MarginMm 4]
# - 원화에서 스티커를 하나씩 오려내 같은 간격의 격자로 다시 배치 (칼선 간격 보장)
# - 배경 알파 0 / 스티커 알파 255 로 이진화 (반투명 잔여물 제거)
# - 잔점·가는 선 제거, 스티커 내부 구멍 메우기
# - 모든 스티커에 같은 두께의 매끈한 흰 테두리(칼선 여유) 추가
# - 100x130mm / 300dpi (1181x1535) 투명 PNG로 저장
param(
  [Parameter(Mandatory)] [string]$In,
  [Parameter(Mandatory)] [string]$Out,
  [double]$BorderMm = 1.2,
  [double]$GapMm = 3.0,
  [double]$MarginMm = 4.0
)
Add-Type -AssemblyName System.Drawing
if (-not ('StickerClean3' -as [type])) {
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class StickerClean3 {
  static int[] Load(Bitmap b) {
    var d = b.LockBits(new Rectangle(0, 0, b.Width, b.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
    var px = new int[b.Width * b.Height]; Marshal.Copy(d.Scan0, px, 0, px.Length); b.UnlockBits(d); return px;
  }
  static Bitmap Make(int[] px, int w, int h) {
    var b = new Bitmap(w, h, PixelFormat.Format32bppArgb);
    var d = b.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
    Marshal.Copy(px, 0, d.Scan0, px.Length); b.UnlockBits(d); return b;
  }
  static int[] Dist(bool[] m, int w, int h) {
    const int INF = 1 << 28; var d = new int[w * h];
    for (int i = 0; i < d.Length; i++) d[i] = m[i] ? 0 : INF;
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
      int i = y * w + x, v = d[i];
      if (x > 0) v = Math.Min(v, d[i - 1] + 3);
      if (y > 0) { v = Math.Min(v, d[i - w] + 3); if (x > 0) v = Math.Min(v, d[i - w - 1] + 4); if (x < w - 1) v = Math.Min(v, d[i - w + 1] + 4); }
      d[i] = v;
    }
    for (int y = h - 1; y >= 0; y--) for (int x = w - 1; x >= 0; x--) {
      int i = y * w + x, v = d[i];
      if (x < w - 1) v = Math.Min(v, d[i + 1] + 3);
      if (y < h - 1) { v = Math.Min(v, d[i + w] + 3); if (x < w - 1) v = Math.Min(v, d[i + w + 1] + 4); if (x > 0) v = Math.Min(v, d[i + w - 1] + 4); }
      d[i] = v;
    }
    return d;
  }
  static bool[] Dilate(bool[] m, int w, int h, double r) { var d = Dist(m, w, h); var o = new bool[m.Length]; double t = r * 3; for (int i = 0; i < o.Length; i++) o[i] = d[i] <= t; return o; }
  static bool[] Erode(bool[] m, int w, int h, double r) { var inv = new bool[m.Length]; for (int i = 0; i < m.Length; i++) inv[i] = !m[i]; var e = Dilate(inv, w, h, r); for (int i = 0; i < e.Length; i++) e[i] = !e[i]; return e; }
  static int[] Label(bool[] m, int w, int h, out int n, out List<int> areas) {
    var lab = new int[m.Length]; n = 0; areas = new List<int> { 0 }; var st = new Stack<int>();
    for (int s = 0; s < m.Length; s++) {
      if (!m[s] || lab[s] != 0) continue;
      n++; int a = 0; lab[s] = n; st.Push(s);
      while (st.Count > 0) {
        int i = st.Pop(); a++; int x = i % w, y = i / w;
        if (x > 0 && m[i - 1] && lab[i - 1] == 0) { lab[i - 1] = n; st.Push(i - 1); }
        if (x < w - 1 && m[i + 1] && lab[i + 1] == 0) { lab[i + 1] = n; st.Push(i + 1); }
        if (y > 0 && m[i - w] && lab[i - w] == 0) { lab[i - w] = n; st.Push(i - w); }
        if (y < h - 1 && m[i + w] && lab[i + w] == 0) { lab[i + w] = n; st.Push(i + w); }
      }
      areas.Add(a);
    }
    return lab;
  }
  static bool[] FillHoles(bool[] m, int w, int h) {
    int N = w * h; var outside = new bool[N]; var st = new Stack<int>();
    for (int x = 0; x < w; x++) { st.Push(x); st.Push((h - 1) * w + x); }
    for (int y = 0; y < h; y++) { st.Push(y * w); st.Push(y * w + w - 1); }
    while (st.Count > 0) { int i = st.Pop(); if (outside[i] || m[i]) continue; outside[i] = true; int x = i % w, y = i / w;
      if (x > 0) st.Push(i - 1); if (x < w - 1) st.Push(i + 1); if (y > 0) st.Push(i - w); if (y < h - 1) st.Push(i + w); }
    var b = new bool[N]; for (int i = 0; i < N; i++) b[i] = !outside[i]; return b;
  }

  class Piece { public int x0, y0, x1, y1; public double cx, cy; public int label; }

  public static string Run(string inPath, string outPath, int W, int H, double borderPx, double gapPx, double marginPx) {
    var raw = new Bitmap(inPath); int rw = raw.Width, rh = raw.Height, RN = rw * rh;
    var rp = Load(raw); raw.Dispose();

    // 1) foreground on the raw art
    int transp = 0; foreach (var p in rp) if (((p >> 24) & 255) < 128) transp++;
    bool hasAlpha = transp > RN * 0.05;
    var fg = new bool[RN]; string mode = "alpha";
    if (hasAlpha) { for (int i = 0; i < RN; i++) fg[i] = ((rp[i] >> 24) & 255) >= 128; }
    else {
      var rs = new List<int>(); var gs = new List<int>(); var bs = new List<int>();
      for (int x = 0; x < rw; x += 2) foreach (int y in new[] { 1, rh - 2 }) { int p = rp[y * rw + x]; rs.Add((p >> 16) & 255); gs.Add((p >> 8) & 255); bs.Add(p & 255); }
      for (int y = 0; y < rh; y += 2) foreach (int x in new[] { 1, rw - 2 }) { int p = rp[y * rw + x]; rs.Add((p >> 16) & 255); gs.Add((p >> 8) & 255); bs.Add(p & 255); }
      rs.Sort(); gs.Sort(); bs.Sort();
      int br = rs[rs.Count / 2], bgc = gs[gs.Count / 2], bb = bs[bs.Count / 2];
      mode = string.Format("chroma({0},{1},{2})", br, bgc, bb);
      for (int i = 0; i < RN; i++) { int p = rp[i]; int dr = ((p >> 16) & 255) - br, dg = ((p >> 8) & 255) - bgc, db = (p & 255) - bb; fg[i] = dr * dr + dg * dg + db * db > 70 * 70; }
    }

    // 2) drop specks / thin stray lines, keep thin details attached to a sticker, fill holes
    var opened = Dilate(Erode(fg, rw, rh, 3), rw, rh, 3);
    for (int i = 0; i < RN; i++) opened[i] = opened[i] && fg[i];
    int n; List<int> areas; var lab = Label(opened, rw, rh, out n, out areas);
    int minArea = (int)(RN * 0.0015); int dropped = 0;
    var core = new bool[RN]; var ok = new bool[n + 1];
    for (int k = 1; k <= n; k++) { ok[k] = areas[k] >= minArea; if (!ok[k]) dropped++; }
    for (int i = 0; i < RN; i++) core[i] = lab[i] > 0 && ok[lab[i]];
    var near = Dilate(core, rw, rh, 8);
    var art = new bool[RN]; for (int i = 0; i < RN; i++) art[i] = fg[i] && near[i];
    var body = FillHoles(art, rw, rh);

    // 3) one piece per sticker
    int np; List<int> pa; var pl = Label(body, rw, rh, out np, out pa);
    var pieces = new List<Piece>();
    for (int k = 1; k <= np; k++) if (pa[k] >= minArea) pieces.Add(new Piece { x0 = int.MaxValue, y0 = int.MaxValue, x1 = -1, y1 = -1, label = k });
    var byLab = new Dictionary<int, Piece>(); foreach (var p in pieces) byLab[p.label] = p;
    for (int i = 0; i < RN; i++) { Piece p; if (pl[i] > 0 && byLab.TryGetValue(pl[i], out p)) { int x = i % rw, y = i / rw; if (x < p.x0) p.x0 = x; if (x > p.x1) p.x1 = x; if (y < p.y0) p.y0 = y; if (y > p.y1) p.y1 = y; } }
    // 3b) split pieces that are two stickers touching in the raw art (cut at the thinnest seam)
    int splits = 0;
    for (int guard = 0; guard < 20; guard++) {
      var ws = new List<int>(); var hh = new List<int>();
      foreach (var p in pieces) { ws.Add(p.x1 - p.x0); hh.Add(p.y1 - p.y0); }
      ws.Sort(); hh.Sort(); double mw = ws[ws.Count / 2], mh = hh[hh.Count / 2];
      Piece big = null; bool horiz = true;
      foreach (var p in pieces) {
        if (p.x1 - p.x0 > 1.6 * mw) { big = p; horiz = true; break; }
        if (p.y1 - p.y0 > 1.6 * mh) { big = p; horiz = false; break; }
      }
      if (big == null) break;
      int a0 = horiz ? big.x0 : big.y0, a1 = horiz ? big.x1 : big.y1, len = a1 - a0;
      int best = -1, bestCnt = int.MaxValue;
      for (int t = a0 + (int)(len * 0.3); t <= a0 + (int)(len * 0.7); t++) {
        int cnt = 0;
        if (horiz) { for (int y = big.y0; y <= big.y1; y++) if (pl[y * rw + t] == big.label) cnt++; }
        else { for (int x = big.x0; x <= big.x1; x++) if (pl[t * rw + x] == big.label) cnt++; }
        if (cnt < bestCnt) { bestCnt = cnt; best = t; }
      }
      int nl = ++np; var np2 = new Piece { x0 = int.MaxValue, y0 = int.MaxValue, x1 = -1, y1 = -1, label = nl };
      big.x0 = int.MaxValue; big.y0 = int.MaxValue; big.x1 = -1; big.y1 = -1;
      for (int i = 0; i < RN; i++) {
        if (pl[i] != big.label) continue;
        int x = i % rw, y = i / rw; Piece t = (horiz ? x >= best : y >= best) ? np2 : big;
        if (t == np2) pl[i] = nl;
        if (x < t.x0) t.x0 = x; if (x > t.x1) t.x1 = x; if (y < t.y0) t.y0 = y; if (y > t.y1) t.y1 = y;
      }
      pieces.Add(np2); splits++;
    }
    foreach (var p in pieces) { p.cx = (p.x0 + p.x1) / 2.0; p.cy = (p.y0 + p.y1) / 2.0; }

    // 4) rows: cluster by vertical centre, keep the artist's reading order
    pieces.Sort((a, b) => a.cy.CompareTo(b.cy));
    var hs = new List<int>(); foreach (var p in pieces) hs.Add(p.y1 - p.y0); hs.Sort();
    double medH = hs.Count > 0 ? hs[hs.Count / 2] : 1;
    var rows = new List<List<Piece>>();
    foreach (var p in pieces) { if (rows.Count == 0 || p.cy - rows[rows.Count - 1][0].cy > medH * 0.5) rows.Add(new List<Piece>()); rows[rows.Count - 1].Add(p); }
    int C = 1; foreach (var r in rows) { r.Sort((a, b) => a.cx.CompareTo(b.cx)); C = Math.Max(C, r.Count); }
    int R = rows.Count;

    // 5) uniform scale so every sticker + border fits its cell with the required gap
    double cellW = (W - 2 * marginPx) / C, cellH = (H - 2 * marginPx) / R;
    double s = double.MaxValue;
    foreach (var p in pieces) {
      s = Math.Min(s, (cellW - 2 * borderPx - gapPx) / (p.x1 - p.x0 + 1));
      s = Math.Min(s, (cellH - 2 * borderPx - gapPx) / (p.y1 - p.y0 + 1));
    }

    // 6) place each sticker (art pixels; holes inside the sticker become white)
    var canvas = new Bitmap(W, H, PixelFormat.Format32bppArgb);
    using (var g = Graphics.FromImage(canvas)) {
      g.Clear(Color.Transparent);
      g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
      g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.HighQuality;
      for (int ri = 0; ri < R; ri++) {
        var row = rows[ri]; double rowOff = (C - row.Count) * cellW / 2.0;
        for (int ci = 0; ci < row.Count; ci++) {
          var p = row[ci]; int pw = p.x1 - p.x0 + 1, ph = p.y1 - p.y0 + 1;
          var sub = new int[pw * ph];
          for (int y = 0; y < ph; y++) for (int x = 0; x < pw; x++) {
            int i = (p.y0 + y) * rw + p.x0 + x;
            if (pl[i] != p.label) { sub[y * pw + x] = 0; continue; }
            int c = rp[i]; int a = hasAlpha ? (c >> 24) & 255 : 255;
            if (!art[i]) a = 0;
            int r = (c >> 16) & 255, gg = (c >> 8) & 255, b = c & 255;
            r = (r * a + 255 * (255 - a)) / 255; gg = (gg * a + 255 * (255 - a)) / 255; b = (b * a + 255 * (255 - a)) / 255;
            sub[y * pw + x] = unchecked((int)0xFF000000) | (r << 16) | (gg << 8) | b;
          }
          using (var sb = Make(sub, pw, ph)) {
            double dw = pw * s, dh = ph * s;
            double cx = marginPx + rowOff + cellW * (ci + 0.5), cy = marginPx + cellH * (ri + 0.5);
            g.DrawImage(sb, (float)(cx - dw / 2), (float)(cy - dh / 2), (float)dw, (float)dh);
          }
        }
      }
    }
    var px = Load(canvas); canvas.Dispose(); int N = W * H;

    // 7) binarise, uniform rounded white border, compose
    var bodyC = new bool[N]; for (int i = 0; i < N; i++) bodyC[i] = ((px[i] >> 24) & 255) >= 128;
    bodyC = FillHoles(bodyC, W, H);
    var outer = Dilate(bodyC, W, H, borderPx);
    outer = Dilate(Erode(outer, W, H, borderPx * 0.6), W, H, borderPx * 0.6);
    var o = new int[N];
    for (int i = 0; i < N; i++) {
      if (!(outer[i] || bodyC[i])) { o[i] = 0; continue; }
      int c = px[i]; int a = (c >> 24) & 255;
      if (bodyC[i] && a > 0) {
        int r = (c >> 16) & 255, gg = (c >> 8) & 255, b = c & 255;
        r = (r * a + 255 * (255 - a)) / 255; gg = (gg * a + 255 * (255 - a)) / 255; b = (b * a + 255 * (255 - a)) / 255;
        o[i] = unchecked((int)0xFF000000) | (r << 16) | (gg << 8) | b;
      } else o[i] = unchecked((int)0xFFFFFFFF);
    }
    var res = Make(o, W, H); res.SetResolution(300, 300); res.Save(outPath, ImageFormat.Png); res.Dispose();

    // 8) verify
    var fin = new bool[N]; for (int i = 0; i < N; i++) fin[i] = ((o[i] >> 24) & 255) == 255;
    int ns; List<int> ar; Label(fin, W, H, out ns, out ar);
    int ng; List<int> ag; Label(Dilate(fin, W, H, gapPx / 2.0 - 1), W, H, out ng, out ag);
    int semi = 0; foreach (var c in o) { int a = (c >> 24) & 255; if (a != 0 && a != 255) semi++; }
    return string.Format("mode={0} pieces={1} grid={2}x{3} stickers={4} droppedSpecks={5} split={9} tooClose={6} semi={7} scale={8:0.00}",
      mode, pieces.Count, R, C, ns, dropped, ns - ng, semi, s, splits);
  }
}
'@
}
$W = 1181; $H = 1535; $pxPerMm = 300 / 25.4
[StickerClean3]::Run((Resolve-Path $In).Path, [System.IO.Path]::GetFullPath($Out), $W, $H, $BorderMm * $pxPerMm, $GapMm * $pxPerMm, $MarginMm * $pxPerMm)
