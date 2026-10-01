import { initializeApp } from "firebase-admin/app";

initializeApp();

export { submitFeedback } from "./feedback";
export { deleteAccount } from "./account";

// claimTrial needs a DeviceCheck key, which only a paid Apple team can
// create. Until DEVICECHECK_ENABLED=true is in functions/.env it isn't
// exported, so it isn't deployed and its three Apple secrets aren't required
// (the CLI refuses any deploy while a secret the code mentions is missing).
// The app treats the missing function as "check again next launch".
if (process.env.DEVICECHECK_ENABLED === "true") {
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  exports.claimTrial = require("./trial").claimTrial;
}
