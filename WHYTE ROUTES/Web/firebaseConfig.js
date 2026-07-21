// Import Firebase SDKs
import { initializeApp } from "firebase/app";
import { getFirestore } from "firebase/firestore";
import { getAuth } from "firebase/auth";
import { getStorage } from "firebase/storage";

// Your Firebase project configuration
const firebaseConfig = {
  apiKey: "AIzaSyDacXb_CBPeN8jiUJpygjwlucqwaCvVBjQ",
  authDomain: "whyte-route.firebaseapp.com",
  projectId: "whyte-route",
  storageBucket: "whyte-route.firebasestorage.app",
  messagingSenderId: "596548238738",
  appId: "1:596548238738:web:0541ae6296e7633f02954b"
};

// Initialize Firebase
const app = initializeApp(firebaseConfig);

// 🔥 Initialize Firestore, Auth, Storage
export const db = getFirestore(app);
export const auth = getAuth(app);
export const storage = getStorage(app);

// Optional: Export app if needed
export default app;
