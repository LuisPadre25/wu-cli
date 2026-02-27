<template>
  <div :style="s.container">
    <div :style="s.card">
      <div :style="s.bar"></div>

      <div :style="s.icon">
        <svg width="36" height="36" viewBox="0 0 261 226" fill="none">
          <path d="M161.1 0L130.5 53l-30.6-53H0l130.5 226L261 0h-99.9z" fill="#42b883"/>
          <path d="M161.1 0l-30.6 53-30.6-53H52.2l78.3 135.6L208.8 0h-47.7z" fill="#347a5e"/>
        </svg>
      </div>

      <h1 :style="{ margin: '0 0 0.25rem', fontSize: '1.5rem', fontWeight: '700', color: '#42b883' }">Vue</h1>
      <p :style="{ margin: '0 0 2rem', fontSize: '0.9rem', color: '#888' }">__APP_NAME__</p>

      <div>
        <p :style="{ margin: '0 0 0.75rem', fontSize: '0.8rem', color: '#555', textTransform: 'uppercase', letterSpacing: '0.1em' }">Interactions</p>
        <div :style="{ display: 'flex', alignItems: 'center', justifyContent: 'center', gap: '1rem', marginBottom: '2rem' }">
          <button @click="count--" :style="s.btn">-</button>
          <span :style="{ fontSize: '2rem', fontWeight: '700', color: '#fff', minWidth: '3rem' }">{{ count }}</span>
          <button @click="count++" :style="s.btn">+</button>
        </div>
      </div>

      <div :style="{ borderTop: '1px solid #222', paddingTop: '1.25rem' }">
        <p :style="{ margin: '0', fontSize: '0.75rem', color: '#444' }">Powered by Wu Framework</p>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, reactive } from 'vue';

const count = ref(0);

const s = reactive({
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
  bar: {
    position: 'absolute',
    top: '0',
    left: '0',
    right: '0',
    height: '3px',
    background: 'linear-gradient(90deg, transparent, #42b883, transparent)',
  },
  icon: {
    width: '80px',
    height: '80px',
    margin: '0 auto 1.5rem',
    borderRadius: '50%',
    background: 'linear-gradient(135deg, rgba(66,184,131,0.15), rgba(66,184,131,0.05))',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    border: '1px solid rgba(66,184,131,0.2)',
  },
  btn: {
    width: '40px',
    height: '40px',
    borderRadius: '10px',
    border: '1px solid rgba(66,184,131,0.3)',
    background: 'rgba(66,184,131,0.08)',
    color: '#42b883',
    fontSize: '1.2rem',
    cursor: 'pointer',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    transition: 'all 0.2s',
  },
});
</script>
