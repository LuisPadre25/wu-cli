import { LitElement, html, css } from 'lit';

class AppElement extends LitElement {
  static properties = { count: { type: Number } };

  static styles = css`
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
      background: linear-gradient(90deg, transparent, #324fff, transparent);
    }
    .icon-circle {
      width: 80px;
      height: 80px;
      margin: 0 auto 1.5rem;
      border-radius: 50%;
      background: linear-gradient(135deg, rgba(50,79,255,0.15), rgba(50,79,255,0.05));
      display: flex;
      align-items: center;
      justify-content: center;
      border: 1px solid rgba(50,79,255,0.2);
    }
    h1 {
      margin: 0 0 0.25rem;
      font-size: 1.5rem;
      font-weight: 700;
      color: #324fff;
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
      border: 1px solid rgba(50,79,255,0.3);
      background: rgba(50,79,255,0.08);
      color: #324fff;
      font-size: 1.2rem;
      cursor: pointer;
      display: flex;
      align-items: center;
      justify-content: center;
      transition: all 0.2s;
    }
    .counter-btn:hover {
      background: rgba(50,79,255,0.18);
      border-color: rgba(50,79,255,0.5);
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
  `;

  constructor() {
    super();
    this.count = 0;
  }

  render() {
    return html`
      <div class="container">
        <div class="card">
          <div class="accent-bar"></div>

          <div class="icon-circle">
            <svg width="36" height="36" viewBox="0 0 160 200" fill="none">
              <path d="M80 0L160 40v120l-80 40L0 160V40L80 0z" fill="#324fff" opacity="0.9"/>
              <path d="M80 30l50 25v80l-50 25-50-25V55l50-25z" fill="#283593"/>
              <circle cx="80" cy="100" r="20" fill="#fff" opacity="0.9"/>
              <path d="M80 10l60 30v100l-60 30" stroke="#5c6bc0" stroke-width="2" fill="none" opacity="0.5"/>
            </svg>
          </div>

          <h1>Lit</h1>
          <p class="subtitle">__APP_NAME__</p>

          <div>
            <p class="section-label">Interactions</p>
            <div class="counter-row">
              <button class="counter-btn" @click=${() => this.count--}>-</button>
              <span class="count-value">${this.count}</span>
              <button class="counter-btn" @click=${() => this.count++}>+</button>
            </div>
          </div>

          <div class="footer">
            <p>Powered by Wu Framework</p>
          </div>
        </div>
      </div>
    `;
  }
}
export default AppElement;
