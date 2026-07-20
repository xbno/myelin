import Foundation

/// The live transcript page served at GET / on the hint listener port.
/// Open http://127.0.0.1:8737 while recording: timestamped lines append at
/// the bottom as they finalize. Blue = you (mic), green = identified names,
/// amber = anonymous voices (S1, S2, …).
enum LiveView {
    static let html: String = #"""
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>live-recorder</title>
        <style>
          :root { color-scheme: dark; }
          * { box-sizing: border-box; }
          body { margin: 0; font: 15px/1.55 -apple-system, sans-serif; background: #16181c; color: #e8eaed; }
          header { position: sticky; top: 0; background: #1f2227; border-bottom: 1px solid #2c3038;
                   padding: 12px 20px; display: flex; align-items: baseline; gap: 12px; }
          header .dot { width: 9px; height: 9px; border-radius: 50%; background: #e0524d; align-self: center;
                        animation: pulse 1.6s infinite; }
          header .dot.off { background: #5f6368; animation: none; }
          @keyframes pulse { 50% { opacity: .35; } }
          header h1 { font-size: 14px; font-weight: 600; margin: 0; }
          header .meta { color: #9aa0a6; font-size: 12px; margin-left: auto; }
          #feed { max-width: 780px; margin: 0 auto; padding: 20px 20px 40vh; }
          .turn { margin-bottom: 14px; }
          .who { font-weight: 700; font-size: 13px; margin-bottom: 2px; }
          .who .t { color: #7d838b; font-weight: 400; font-size: 11px; margin-left: 8px; }
          .me   .who { color: #8ab4f8; }
          .named .who { color: #81c995; }
          .anon .who { color: #fdd663; }
          .txt { color: #dfe1e5; }
          #jump { position: fixed; bottom: 24px; left: 50%; transform: translateX(-50%);
                  background: #8ab4f8; color: #16181c; border: 0; border-radius: 16px;
                  padding: 7px 16px; font-weight: 600; cursor: pointer; display: none; }
          #empty { color: #7d838b; text-align: center; margin-top: 15vh; }
        </style>
        </head>
        <body>
        <header>
          <div class="dot" id="dot"></div>
          <h1>live transcript</h1>
          <span class="meta" id="meta">connecting…</span>
        </header>
        <div id="feed"><div id="empty">waiting for the first line…</div></div>
        <button id="jump">↓ latest</button>
        <script>
        const feed = document.getElementById('feed');
        const meta = document.getElementById('meta');
        const dot = document.getElementById('dot');
        const jump = document.getElementById('jump');
        let rendered = 0, lastCount = 0, lastGrowth = Date.now(), firstT0 = null, prevKey = '';

        function atBottom() {
          return window.innerHeight + window.scrollY >= document.body.scrollHeight - 60;
        }
        jump.onclick = () => window.scrollTo({ top: document.body.scrollHeight });
        window.addEventListener('scroll', () => { if (atBottom()) jump.style.display = 'none'; });

        function classify(l) {
          if (l.source === 'mic') return ['me', l.speaker || 'Me'];
          const spk = l.speaker || 'Them';
          return [/^S\d+$/.test(spk) || spk === 'Them' ? 'anon' : 'named', spk];
        }
        function stamp(l) {
          if (l.t0 == null) return '';
          if (firstT0 === null) firstT0 = l.t0;
          const rel = Math.max(0, l.t0 - firstT0);
          return Math.floor(rel / 60) + ':' + String(Math.floor(rel % 60)).padStart(2, '0');
        }

        async function poll() {
          let lines = [];
          try {
            const res = await fetch('/transcript');
            if (!res.ok) throw 0;
            const text = await res.text();
            lines = text.split('\n').filter(Boolean).map(s => { try { return JSON.parse(s); } catch { return null; } }).filter(Boolean);
            dot.classList.remove('off');
          } catch {
            dot.classList.add('off');
            meta.textContent = 'recorder offline';
            return;
          }
          if (lines.length > lastCount) { lastCount = lines.length; lastGrowth = Date.now(); }
          const idle = Math.round((Date.now() - lastGrowth) / 1000);
          meta.textContent = lines.length + ' lines' + (idle > 15 ? ' · quiet ' + idle + 's' : '');
          if (lines.length <= rendered) return;

          const stick = atBottom();
          const empty = document.getElementById('empty');
          if (empty) empty.remove();
          for (const l of lines.slice(rendered)) {
            const [cls, spk] = classify(l);
            const key = cls + '|' + spk;
            const div = document.createElement('div');
            div.className = 'turn ' + cls;
            div.innerHTML = (key === prevKey ? '' :
              '<div class="who">' + spk + '<span class="t">' + stamp(l) + '</span></div>')
              + '<div class="txt"></div>';
            div.querySelector('.txt').textContent = l.text || '';
            feed.appendChild(div);
            prevKey = key;
          }
          rendered = lines.length;
          if (stick) window.scrollTo({ top: document.body.scrollHeight });
          else jump.style.display = 'block';
        }
        setInterval(poll, 1200); poll();
        </script>
        </body>
        </html>
        """#
}
