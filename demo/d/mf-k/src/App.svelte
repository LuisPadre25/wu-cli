<script>
  let count = $state(0);
</script>

<div style="display:flex;align-items:center;justify-content:center;min-height:400px;background:transparent;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;">
  <div style="max-width:420px;width:100%;background:#111;border:1px solid #222;border-radius:16px;padding:2.5rem;text-align:center;position:relative;overflow:hidden;">
    <div style="position:absolute;top:0;left:0;right:0;height:3px;background:linear-gradient(90deg,transparent,#ff3e00,transparent);"></div>
fffssd
    <div style="width:80px;height:80px;margin:0 auto 1.5rem;border-radius:50%;background:linear-gradient(135deg,rgba(255,62,0,0.15),rgba(255,62,0,0.05));display:flex;align-items:center;justify-content:center;border:1px solid rgba(255,62,0,0.2);">
      <svg width="36" height="36" viewBox="0 0 98.1 118" fill="none">
        <path d="M91.8 15.6C80.9-.1 59.2-4.7 43.6 5.2L16.1 22.8C8.6 27.5 3.4 35.2 1.9 43.9c-1.2 6.5-.5 13.2 2 19.4C1.5 67.1 0 71.5 0 76c0 3.6.6 7.2 1.8 10.5C4.3 97.9 13.2 107 24.4 110.5c2.2.7 4.5 1.1 6.8 1.3 2.8 10.5 12.3 18.2 23.5 18.2 3.2 0 6.3-.6 9.3-1.8l27.5-17.6c7.5-4.7 12.7-12.4 14.2-21.1 1.2-6.5.5-13.2-2-19.4 2.4-3.8 3.9-8.2 3.9-12.7 0-3.6-.6-7.2-1.8-10.5-2.5-11.4-11.4-20.5-22.6-24-2.2-.7-4.5-1.1-6.8-1.3C73.6 11.1 64.1 3.4 52.9 3.4c-3.2 0-6.3.6-9.3 1.8" fill="#ff3e00"/>
        <path d="M40.9 103.9a18 18 0 01-9-11.5c.2.1.5.2.8.3l27.5-17.6a9 9 0 004.1-6.1V35.8l11.6 6.7v33.7c-.1 15.5-12.7 28-28.2 28l.2-.3z" fill="#fff" opacity="0.85"/>
        <path d="M22.6 83.4a17.8 17.8 0 01-2.2-14.5c.2.2.4.4.7.6L48.6 87a9 9 0 007.4.6V121l-11.6-6.7V80.6c-7.9 4.2-17.5 5-25.8 2.8z" fill="#fff" opacity="0.65"/>
      </svg>
    </div>
sssxl
    <h1 style="margin:0 0 0.25rem;font-size:1.5rem;font-weight:700;color:#ff3e00;letter-spacing:-0.02em;">Svelte</h1>
    <p style="margin:0 0 2rem;font-size:0.9rem;color:#888;font-weight:400;">k</p>

    <div>
      <p style="margin:0 0 0.75rem;font-size:0.8rem;color:#555;text-transform:uppercase;letter-spacing:0.1em;">Interactions</p>
      <div style="display:flex;align-items:center;justify-content:center;gap:1rem;margin-bottom:2rem;">
        <button
          onclick={() => count--}
          style="width:40px;height:40px;border-radius:10px;border:1px solid rgba(255,62,0,0.3);background:rgba(255,62,0,0.08);color:#ff3e00;font-size:1.2rem;cursor:pointer;display:flex;align-items:center;justify-content:center;transition:all 0.2s;"
        >-</button>
        <span style="font-size:2rem;font-weight:700;color:#fff;min-width:3rem;font-variant-numeric:tabular-nums;">{count}</span>
        <button
          onclick={() => count++}
          style="width:40px;height:40px;border-radius:10px;border:1px solid rgba(255,62,0,0.3);background:rgba(255,62,0,0.08);color:#ff3e00;font-size:1.2rem;cursor:pointer;display:flex;align-items:center;justify-content:center;transition:all 0.2s;"
        >+</button>
      </div>
    </div>

    <div style="border-top:1px solid #222;padding-top:1.25rem;">
      <p style="margin:0;font-size:0.75rem;color:#444;">Powered by Wu Framework</p>
    </div>
  </div>
</div>
