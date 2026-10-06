// Entry module for the Workers Issues relay (#2095). It must export nothing but the default
// handler: workerd treats every named export of the entry module as an entrypoint and refuses to
// start on anything else (e.g. a constant). The implementation lives in `app.ts`.

import { createWorker } from "./app.js";

export default createWorker();
