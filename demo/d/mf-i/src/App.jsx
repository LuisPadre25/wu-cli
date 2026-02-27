import { useState } from 'preact/hooks';

const accent = '#673ab8';
const accentRgb = '103,58,184';

const styles = {
  container: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    minHeight: '400px',
    background: 'transparent',
    fontFamily: "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif",
  },
  card: {
    maxWidth: '420px',
    width: '100%',
    background: '#111',
    border: '1px solid #222',
    borderRadius: '16px',
    padding: '2.5rem',
    textAlign: 'center',
    position: 'relative',
    overflow: 'hidden',
  },
  accentBar: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    height: '3px',
    background: `linear-gradient(90deg, transparent, ${accent}, transparent)`,
  },
  iconCircle: {
    width: '80px',
    height: '80px',
    margin: '0 auto 1.5rem',
    borderRadius: '50%',
    background: `linear-gradient(135deg, rgba(${accentRgb},0.15), rgba(${accentRgb},0.05))`,
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    border: `1px solid rgba(${accentRgb},0.2)`,
  },
  title: {
    margin: '0 0 0.25rem',
    fontSize: '1.5rem',
    fontWeight: 700,
    color: accent,
    letterSpacing: '-0.02em',
  },
  subtitle: {
    margin: '0 0 2rem',
    fontSize: '0.9rem',
    color: '#888',
    fontWeight: 400,
  },
  sectionLabel: {
    margin: '0 0 0.75rem',
    fontSize: '0.8rem',
    color: '#555',
    textTransform: 'uppercase',
    letterSpacing: '0.1em',
  },
  counterRow: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    gap: '1rem',
    marginBottom: '2rem',
  },
  btn: {
    width: '40px',
    height: '40px',
    borderRadius: '10px',
    border: `1px solid rgba(${accentRgb},0.3)`,
    background: `rgba(${accentRgb},0.08)`,
    color: accent,
    fontSize: '1.2rem',
    cursor: 'pointer',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    transition: 'all 0.2s',
  },
  countValue: {
    fontSize: '2rem',
    fontWeight: 700,
    color: '#fff',
    minWidth: '3rem',
    fontVariantNumeric: 'tabular-nums',
  },
  footer: {
    borderTop: '1px solid #222',
    paddingTop: '1.25rem',
  },
  footerText: {
    margin: 0,
    fontSize: '0.75rem',
    color: '#444',
  },
};

export default function App() {
  const [count, setCount] = useState(0);

  return (
    <div style={styles.container}>
      <div style={styles.card}>
        <div style={styles.accentBar}></div>

        <div style={styles.iconCircle}>
          <svg width="36" height="36" viewBox="0 0 256 296" fill="none">
            <path d="M128 0l128 73.9v147.8l-128 73.9L0 221.7V73.9L128 0z" fill={accent} opacity="0.9"/>
            <path d="M128 56l80 46.2v92.4L128 240l-80-46.2v-92.4L128 56z" fill="#512da8"/>
            <path d="M128 112l32 18.5v37L128 186l-32-18.5v-37L128 112z" fill="#fff" opacity="0.85"/>
          </svg>
        </div>

        <h1 style={styles.title}>Preact</h1>
        <p style={styles.subtitle}>i</p>

        <div>
          <p style={styles.sectionLabel}>Interactions</p>
          <div style={styles.counterRow}>
            <button style={styles.btn} onClick={() => setCount(c => c - 1)}>-</button>
            <span style={styles.countValue}>{count}</span>
            <button style={styles.btn} onClick={() => setCount(c => c + 1)}>+</button>
          </div>
        </div>

        <div style={styles.footer}>
          <p style={styles.footerText}>Powered by Wu Framework</p>
        </div>
      </div>
    </div>
  );
}
