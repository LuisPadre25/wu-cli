import { wuVanilla } from 'wu-framework/adapters/vanilla';
import App from './App.js';

await wuVanilla.register('oo', {
  render(container) { App(container); }
});
