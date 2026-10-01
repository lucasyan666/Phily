import { initializeApp } from "firebase-admin/app";

initializeApp();

export { submitFeedback } from "./feedback";
export { claimTrial } from "./trial";
export { deleteAccount } from "./account";
