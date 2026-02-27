export default function App(container) {
  let count = 0;

  function render() {
    container.innerHTML = `
      <div style="display:flex;align-items:center;justify-content:center;min-height:400px;background:transparent;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;">
        <div style="max-width:420px;width:100%;background:#111;border:1px solid #222;border-radius:16px;padding:2.5rem;text-align:center;position:relative;overflow:hidden;">
          <div style="position:absolute;top:0;left:0;right:0;height:3px;background:linear-gradient(90deg,transparent,#f7df1e,transparent);"></div>

          <div style="width:80px;height:80px;margin:0 auto 1.5rem;border-radius:50%;background:linear-gradient(135deg,rgba(247,223,30,0.15),rgba(247,223,30,0.05));display:flex;align-items:center;justify-content:center;border:1px solid rgba(247,223,30,0.2);">
            <svg width="36" height="36" viewBox="0 0 256 256" fill="none">
              <rect width="256" height="256" rx="20" fill="#f7df1e"/>
              <path d="M67.312 213.932l19.532-11.768c3.79 6.702 7.248 12.375 15.542 12.375 7.924 0 12.937-3.106 12.937-15.18V118.16h24.074v81.672c0 25.016-14.662 36.408-36.044 36.408-19.326 0-30.518-10.006-36.04-22.308" fill="#0a0a0a"/>
              <path d="M152.381 211.354l19.532-11.288c5.16 8.398 11.892 14.584 23.78 14.584 9.996 0 16.382-5.002 16.382-11.916 0-8.27-6.562-11.2-17.564-16.018l-6.028-2.586c-17.4-7.408-28.966-16.702-28.966-36.348 0-18.088 13.784-31.862 35.332-31.862 15.34 0 26.378 5.344 34.318 19.318l-18.78 12.058c-4.142-7.41-8.608-10.324-15.538-10.324-7.07 0-11.564 4.484-11.564 10.324 0 7.228 4.494 10.152 14.882 14.64l6.028 2.586c20.482 8.778 32.046 17.742 32.046 37.89 0 21.716-17.064 33.588-39.98 33.588-22.41 0-36.876-10.678-43.88-24.646" fill="#0a0a0a"/>
            </svg>
          </div>

          <h1 style="margin:0 0 0.25rem;font-size:1.5rem;font-weight:700;color:#f7df1e;letter-spacing:-0.02em;">Vanilla JS</h1>
          <p style="margin:0 0 2rem;font-size:0.9rem;color:#888;font-weight:400;">oo</p>

          <div style="margin-bottom:2rem;">
            <p style="margin:0 0 0.75rem;font-size:0.8rem;color:#555;text-transform:uppercase;letter-spacing:0.1em;">Interactions</p>
            <div style="display:flex;align-items:center;justify-content:center;gap:1rem;">
              <button id="btn-dec" style="width:40px;height:40px;border-radius:10px;border:1px solid rgba(247,223,30,0.3);background:rgba(247,223,30,0.08);color:#f7df1e;font-size:1.2rem;cursor:pointer;display:flex;align-items:center;justify-content:center;transition:all 0.2s;">-</button>
              <span style="font-size:2rem;font-weight:700;color:#fff;min-width:3rem;font-variant-numeric:tabular-nums;">${count}</span>
              <button id="btn-inc" style="width:40px;height:40px;border-radius:10px;border:1px solid rgba(247,223,30,0.3);background:rgba(247,223,30,0.08);color:#f7df1e;font-size:1.2rem;cursor:pointer;display:flex;align-items:center;justify-content:center;transition:all 0.2s;">+</button>
            </div>
          </div>

          <div style="border-top:1px solid #222;padding-top:1.25rem;">
            <p style="margin:0;font-size:0.75rem;color:#444;">Powered by Wu Framework</p>
          </div>
        </div>
      </div>
    `;
    container.querySelector('#btn-inc').onclick = () => { count++; render(); };
    container.querySelector('#btn-dec').onclick = () => { count--; render(); };
  }

  render();
}
