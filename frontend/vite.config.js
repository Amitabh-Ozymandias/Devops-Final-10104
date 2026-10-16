import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    // During `npm run dev`, forward API calls to a locally running backend
    proxy: {
      "/api": "http://localhost:8000",
    },
  },
});
