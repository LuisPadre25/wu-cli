import { wuSvelte } from 'wu-framework/adapters/svelte';
import App from './App.svelte';

await wuSvelte.registerSvelte5('k', App);
