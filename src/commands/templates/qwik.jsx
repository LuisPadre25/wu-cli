import { component$, useSignal } from '@builder.io/qwik';

const accent = '#ac7ef4';
const accentRgb = '172,126,244';

export default component$(() => {
  const count = useSignal(0);

  return (
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', minHeight: '400px', background: 'transparent', fontFamily: "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif" }}>
      <div style={{ maxWidth: '420px', width: '100%', background: '#111', border: '1px solid #222', borderRadius: '16px', padding: '2.5rem', textAlign: 'center', position: 'relative', overflow: 'hidden' }}>
        <div style={{ position: 'absolute', top: 0, left: 0, right: 0, height: '3px', background: `linear-gradient(90deg, transparent, ${accent}, transparent)` }}></div>

        <div style={{ width: '80px', height: '80px', margin: '0 auto 1.5rem', borderRadius: '50%', background: `linear-gradient(135deg, rgba(${accentRgb},0.15), rgba(${accentRgb},0.05))`, display: 'flex', alignItems: 'center', justifyContent: 'center', border: `1px solid rgba(${accentRgb},0.2)` }}>
          <svg width="36" height="36" viewBox="0 0 256 256" fill="none">
            <path d="M128 24L24 200h72l32-80 32 80h72L128 24z" fill={accent} opacity="0.9"/>
            <path d="M128 88l-20 50h40l-20-50z" fill="#fff" opacity="0.85"/>
            <circle cx="128" cy="200" r="12" fill={accent}/>
            <line x1="128" y1="188" x2="128" y2="148" stroke={accent} stroke-width="4" stroke-linecap="round"/>
          </svg>
        </div>

        <h1 style={{ margin: '0 0 0.25rem', fontSize: '1.5rem', fontWeight: 700, color: accent, letterSpacing: '-0.02em' }}>Qwik</h1>
        <p style={{ margin: '0 0 2rem', fontSize: '0.9rem', color: '#888', fontWeight: 400 }}>__APP_NAME__</p>

        <div>
          <p style={{ margin: '0 0 0.75rem', fontSize: '0.8rem', color: '#555', textTransform: 'uppercase', letterSpacing: '0.1em' }}>Interactions</p>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: '1rem', marginBottom: '2rem' }}>
            <button onClick$={() => count.value--} style={{ width: '40px', height: '40px', borderRadius: '10px', border: `1px solid rgba(${accentRgb},0.3)`, background: `rgba(${accentRgb},0.08)`, color: accent, fontSize: '1.2rem', cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center', transition: 'all 0.2s' }}>-</button>
            <span style={{ fontSize: '2rem', fontWeight: 700, color: '#fff', minWidth: '3rem', fontVariantNumeric: 'tabular-nums' }}>{count.value}</span>
            <button onClick$={() => count.value++} style={{ width: '40px', height: '40px', borderRadius: '10px', border: `1px solid rgba(${accentRgb},0.3)`, background: `rgba(${accentRgb},0.08)`, color: accent, fontSize: '1.2rem', cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center', transition: 'all 0.2s' }}>+</button>
          </div>
        </div>

        <div style={{ borderTop: '1px solid #222', paddingTop: '1.25rem' }}>
          <p style={{ margin: 0, fontSize: '0.75rem', color: '#444' }}>Powered by Wu Framework</p>
        </div>
      </div>
    </div>
  );
});
