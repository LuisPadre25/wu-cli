import { wuPreact } from 'wu-framework/adapters/preact';
import App from './App.jsx';

await wuPreact.register('i', App);
