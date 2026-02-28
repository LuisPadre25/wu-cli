import { Controller } from '@hotwired/stimulus';

export default {
  controllers: {
    counter: class extends Controller {
      static targets = ['count'];

      connect() {
        this.value = 0;
      }

      inc() {
        this.value++;
        this.countTarget.textContent = this.value;
      }

      dec() {
        this.value--;
        this.countTarget.textContent = this.value;
      }
    }
  },
  template: `
    <div style="display:flex;align-items:center;justify-content:center;min-height:400px;background:transparent;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;">
      <div style="max-width:420px;width:100%;background:#111;border:1px solid #222;border-radius:16px;padding:2.5rem;text-align:center;position:relative;overflow:hidden;">
        <div style="position:absolute;top:0;left:0;right:0;height:3px;background:linear-gradient(90deg,transparent,#77e8b9,transparent);"></div>

        <div style="width:80px;height:80px;margin:0 auto 1.5rem;border-radius:50%;background:linear-gradient(135deg,rgba(119,232,185,0.15),rgba(119,232,185,0.05));display:flex;align-items:center;justify-content:center;border:1px solid rgba(119,232,185,0.2);">
          <svg width="36" height="36" viewBox="0 0 256 256" fill="none">
            <rect x="28" y="80" width="200" height="96" rx="12" fill="none" stroke="#77e8b9" stroke-width="10"/>
            <line x1="128" y1="80" x2="128" y2="176" stroke="#77e8b9" stroke-width="8" opacity="0.6"/>
            <circle cx="78" cy="128" r="16" fill="#77e8b9" opacity="0.85"/>
            <circle cx="178" cy="128" r="16" fill="#77e8b9" opacity="0.85"/>
            <line x1="78" y1="52" x2="78" y2="80" stroke="#77e8b9" stroke-width="6" stroke-linecap="round" opacity="0.5"/>
            <line x1="178" y1="52" x2="178" y2="80" stroke="#77e8b9" stroke-width="6" stroke-linecap="round" opacity="0.5"/>
            <line x1="78" y1="176" x2="78" y2="204" stroke="#77e8b9" stroke-width="6" stroke-linecap="round" opacity="0.5"/>
            <line x1="178" y1="176" x2="178" y2="204" stroke="#77e8b9" stroke-width="6" stroke-linecap="round" opacity="0.5"/>
          </svg>
        </div>

        <h1 style="margin:0 0 0.25rem;font-size:1.5rem;font-weight:700;color:#77e8b9;letter-spacing:-0.02em;">Stimulus</h1>
        <p style="margin:0 0 2rem;font-size:0.9rem;color:#888;font-weight:400;">__APP_NAME__</p>

        <div data-controller="counter">
          <p style="margin:0 0 0.75rem;font-size:0.8rem;color:#555;text-transform:uppercase;letter-spacing:0.1em;">Interactions</p>
          <div style="display:flex;align-items:center;justify-content:center;gap:1rem;margin-bottom:2rem;">
            <button
              data-action="click->counter#dec"
              style="width:40px;height:40px;border-radius:10px;border:1px solid rgba(119,232,185,0.3);background:rgba(119,232,185,0.08);color:#77e8b9;font-size:1.2rem;cursor:pointer;display:flex;align-items:center;justify-content:center;transition:all 0.2s;"
            >-</button>
            <span
              data-counter-target="count"
              style="font-size:2rem;font-weight:700;color:#fff;min-width:3rem;font-variant-numeric:tabular-nums;"
            >0</span>
            <button
              data-action="click->counter#inc"
              style="width:40px;height:40px;border-radius:10px;border:1px solid rgba(119,232,185,0.3);background:rgba(119,232,185,0.08);color:#77e8b9;font-size:1.2rem;cursor:pointer;display:flex;align-items:center;justify-content:center;transition:all 0.2s;"
            >+</button>
          </div>
        </div>

        <div style="border-top:1px solid #222;padding-top:1.25rem;">
          <p style="margin:0;font-size:0.75rem;color:#444;">Powered by Wu Framework</p>
        </div>
      </div>
    </div>
  `
};
