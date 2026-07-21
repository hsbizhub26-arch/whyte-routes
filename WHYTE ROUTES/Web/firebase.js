// firebase.js

// Import Firebase SDKs
import { initializeApp } from "https://www.gstatic.com/firebasejs/10.7.1/firebase-app.js";
import { getFirestore } from "https://www.gstatic.com/firebasejs/10.7.1/firebase-firestore.js";
import { getAuth } from "https://www.gstatic.com/firebasejs/10.7.1/firebase-auth.js";
import { getStorage } from "https://www.gstatic.com/firebasejs/10.7.1/firebase-storage.js";

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
export const app = initializeApp(firebaseConfig);

// Init Firestore, Auth, Storage
export const db = getFirestore(app);
export const auth = getAuth(app);
export const storage = getStorage(app);
