class AppElement extends HTMLElement {
  constructor() {
    super();
    this.attachShadow({ mode: 'open' });
    this._count = 0;
  }

  connectedCallback() {
    this.render();
  }

  inc() {
    this._count++;
    this.render();
  }

  dec() {
    this._count--;
    this.render();
  }

  render() {
    this.shadowRoot.innerHTML = `
      <style>
        :host {
          display: block;
          font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
        }
        .container {
          display: flex;
          align-items: center;
          justify-content: center;
          min-height: 400px;
          background: transparent;
        }
        .card {
          max-width: 420px;
          width: 100%;
          background: #111;
          border: 1px solid #222;
          border-radius: 16px;
          padding: 2.5rem;
          text-align: center;
          position: relative;
          overflow: hidden;
        }
        .accent-bar {
          position: absolute;
          top: 0;
          left: 0;
          right: 0;
          height: 3px;
          background: linear-gradient(90deg, transparent, #4c48ff, transparent);
        }
        .icon-circle {
          width: 80px;
          height: 80px;
          margin: 0 auto 1.5rem;
          border-radius: 50%;
          background: linear-gradient(135deg, rgba(76,72,255,0.15), rgba(76,72,255,0.05));
          display: flex;
          align-items: center;
          justify-content: center;
          border: 1px solid rgba(76,72,255,0.2);
        }
        h1 {
          margin: 0 0 0.25rem;
          font-size: 1.5rem;
          font-weight: 700;
          color: #4c48ff;
          letter-spacing: -0.02em;
        }
        .subtitle {
          margin: 0 0 2rem;
          font-size: 0.9rem;
          color: #888;
          font-weight: 400;
        }
        .section-label {
          margin: 0 0 0.75rem;
          font-size: 0.8rem;
          color: #555;
          text-transform: uppercase;
          letter-spacing: 0.1em;
        }
        .counter-row {
          display: flex;
          align-items: center;
          justify-content: center;
          gap: 1rem;
          margin-bottom: 2rem;
        }
        .counter-btn {
          width: 40px;
          height: 40px;
          border-radius: 10px;
          border: 1px solid rgba(76,72,255,0.3);
          background: rgba(76,72,255,0.08);
          color: #4c48ff;
          font-size: 1.2rem;
          cursor: pointer;
          display: flex;
          align-items: center;
          justify-content: center;
          transition: all 0.2s;
        }
        .counter-btn:hover {
          background: rgba(76,72,255,0.18);
          border-color: rgba(76,72,255,0.5);
        }
        .count-value {
          font-size: 2rem;
          font-weight: 700;
          color: #fff;
          min-width: 3rem;
          font-variant-numeric: tabular-nums;
        }
        .footer {
          border-top: 1px solid #222;
          padding-top: 1.25rem;
        }
        .footer p {
          margin: 0;
          font-size: 0.75rem;
          color: #444;
        }
      </style>
      <div class="container">
        <div class="card">
          <div class="accent-bar"></div>

          <div class="icon-circle">
            <svg width="36" height="36" viewBox="0 0 256 256" fill="none">
              <circle cx="128" cy="128" r="100" fill="none" stroke="#4c48ff" stroke-width="12"/>
              <circle cx="128" cy="128" r="50" fill="none" stroke="#4c48ff" stroke-width="10" opacity="0.6"/>
              <circle cx="128" cy="128" r="16" fill="#4c48ff"/>
              <line x1="128" y1="28" x2="128" y2="78" stroke="#4c48ff" stroke-width="8" stroke-linecap="round" opacity="0.4"/>
              <line x1="128" y1="178" x2="128" y2="228" stroke="#4c48ff" stroke-width="8" stroke-linecap="round" opacity="0.4"/>
              <line x1="28" y1="128" x2="78" y2="128" stroke="#4c48ff" stroke-width="8" stroke-linecap="round" opacity="0.4"/>
              <line x1="178" y1="128" x2="228" y2="128" stroke="#4c48ff" stroke-width="8" stroke-linecap="round" opacity="0.4"/>
            </svg>
          </div>

          <h1>Stencil</h1>
          <p class="subtitle">__APP_NAME__</p>

          <div>
            <p class="section-label">Interactions</p>
            <div class="counter-row">
              <button class="counter-btn" id="btn-dec">-</button>
              <span class="count-value">${this._count}</span>
              <button class="counter-btn" id="btn-inc">+</button>
            </div>
          </div>

          <div class="footer">
            <p>Powered by Wu Framework</p>
          </div>
        </div>
      </div>
    `;

    this.shadowRoot.getElementById('btn-inc').addEventListener('click', () => this.inc());
    this.shadowRoot.getElementById('btn-dec').addEventListener('click', () => this.dec());
  }
}

customElements.define('wu-stencil-app', AppElement);
export default AppElement;
