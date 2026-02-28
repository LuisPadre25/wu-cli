import { Component, signal } from '@angular/core';

@Component({
  selector: 'app-root',
  standalone: true,
  template: `
    <div class="container">
      <div class="card">
        <div class="accent-bar"></div>

        <div class="icon-circle">
          <svg width="36" height="36" viewBox="0 0 256 272" fill="none">
            <path d="M128 0L0 45.2l19.5 169.4L128 272l108.5-57.4L256 45.2L128 0z" fill="#dd0031"/>
            <path d="M128 0v30.1l-.001 0V272l108.5-57.4L256 45.2L128 0z" fill="#c3002f"/>
            <path d="M128 30.1L47.4 208.4h30.1l16.2-40.5h68.5l16.2 40.5h30.1L128 30.1zm23.5 113.8h-47l23.5-57.2 23.5 57.2z" fill="#fff"/>
          </svg>
        </div>

        <h1>Angular</h1>
        <p class="subtitle">__APP_NAME__</p>

        <div>
          <p class="section-label">Interactions</p>
          <div class="counter-row">
            <button class="counter-btn" (click)="dec()">-</button>
            <span class="count-value">{{ count() }}</span>
            <button class="counter-btn" (click)="inc()">+</button>
          </div>
        </div>

        <div class="footer">
          <p>Powered by Wu Framework</p>
        </div>
      </div>
    </div>
  `,
  styles: [`
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
      background: linear-gradient(90deg, transparent, #dd0031, transparent);
    }
    .icon-circle {
      width: 80px;
      height: 80px;
      margin: 0 auto 1.5rem;
      border-radius: 50%;
      background: linear-gradient(135deg, rgba(221,0,49,0.15), rgba(221,0,49,0.05));
      display: flex;
      align-items: center;
      justify-content: center;
      border: 1px solid rgba(221,0,49,0.2);
    }
    h1 {
      margin: 0 0 0.25rem;
      font-size: 1.5rem;
      font-weight: 700;
      color: #dd0031;
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
      border: 1px solid rgba(221,0,49,0.3);
      background: rgba(221,0,49,0.08);
      color: #dd0031;
      font-size: 1.2rem;
      cursor: pointer;
      display: flex;
      align-items: center;
      justify-content: center;
      transition: all 0.2s;
    }
    .counter-btn:hover {
      background: rgba(221,0,49,0.18);
      border-color: rgba(221,0,49,0.5);
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
  `]
})
export class AppComponent {
  count = signal(0);
  inc() { this.count.update(v => v + 1); }
  dec() { this.count.update(v => v - 1); }
}
