import { createSignal } from 'solid-js';

const accent = '#446b9e';
const accentRgb = '68,107,158';

export default function App() {
  const [count, setCount] = createSignal(0);

  const container = {
    display: 'flex',
    'align-items': 'center',
    'justify-content': 'center',
    'min-height': '400px',
    background: 'transparent',
    'font-family': "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif",
  };

  const card = {
    'max-width': '420px',
    width: '100%',
    background: '#111',
    border: '1px solid #222',
    'border-radius': '16px',
    padding: '2.5rem',
    'text-align': 'center',
    position: 'relative',
    overflow: 'hidden',
  };

  const btn = {
    width: '40px',
    height: '40px',
    'border-radius': '10px',
    border: `1px solid rgba(${accentRgb},0.3)`,
    background: `rgba(${accentRgb},0.08)`,
    color: accent,
    'font-size': '1.2rem',
    cursor: 'pointer',
    display: 'flex',
    'align-items': 'center',
    'justify-content': 'center',
    transition: 'all 0.2s',
  };

  return (
    <div style={container}>
      <div style={card}>
        <div style={{
          position: 'absolute', top: '0', left: '0', right: '0', height: '3px',
          background: `linear-gradient(90deg, transparent, ${accent}, transparent)`,
        }}></div>

        <div style={{
          width: '80px', height: '80px', margin: '0 auto 1.5rem', 'border-radius': '50%',
          background: `linear-gradient(135deg, rgba(${accentRgb},0.15), rgba(${accentRgb},0.05))`,
          display: 'flex', 'align-items': 'center', 'justify-content': 'center',
          border: `1px solid rgba(${accentRgb},0.2)`,
        }}>
          <svg width="36" height="36" viewBox="0 0 166 155" fill="none">
            <path fill-rule="evenodd" clip-rule="evenodd" d="M83 0l83 38.7v77.4L83 155 0 116.1V38.7L83 0z" fill="#2c4f7c"/>
            <path d="M83 24c-20 0-36 14-40 33l-2 10c-4 18-20 32-40 32v12c26 0 48-18 53-43l2-10c3-14 16-24 27-24s24 10 27 24l2 10c5 25 27 43 53 43v-12c-20 0-36-14-40-32l-2-10c-4-19-20-33-40-33z" fill="#fff" opacity="0.85"/>
            <circle cx="50" cy="112" r="8" fill="#fff" opacity="0.6"/>
            <circle cx="116" cy="112" r="8" fill="#fff" opacity="0.6"/>
          </svg>
        </div>

        <h1 style={{
          margin: '0 0 0.25rem', 'font-size': '1.5rem', 'font-weight': '700',
          color: accent, 'letter-spacing': '-0.02em',
        }}>SolidJS</h1>
        <p style={{ margin: '0 0 2rem', 'font-size': '0.9rem', color: '#888', 'font-weight': '400' }}>__APP_NAME__</p>

        <div>
          <p style={{
            margin: '0 0 0.75rem', 'font-size': '0.8rem', color: '#555',
            'text-transform': 'uppercase', 'letter-spacing': '0.1em',
          }}>Interactions</p>
          <div style={{
            display: 'flex', 'align-items': 'center', 'justify-content': 'center',
            gap: '1rem', 'margin-bottom': '2rem',
          }}>
            <button style={btn} onClick={() => setCount(c => c - 1)}>-</button>
            <span style={{
              'font-size': '2rem', 'font-weight': '700', color: '#fff',
              'min-width': '3rem', 'font-variant-numeric': 'tabular-nums',
            }}>{count()}</span>
            <button style={btn} onClick={() => setCount(c => c + 1)}>+</button>
          </div>
        </div>

        <div style={{ 'border-top': '1px solid #222', 'padding-top': '1.25rem' }}>
          <p style={{ margin: '0', 'font-size': '0.75rem', color: '#444' }}>Powered by Wu Framework</p>
        </div>
      </div>
    </div>
  );
}
