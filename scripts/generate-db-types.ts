import { exec } from "child_process";
import { copyFileSync } from "fs";
import path from "path";
import * as dotenv from "dotenv";
dotenv.config();

const SUPABASE_URL = process.env.SUPABASE_URL;
const source = path.resolve("packages/database/src/types.ts");
const destination = path.resolve(
  "packages/database/supabase/functions/lib/types.ts"
);

if (!SUPABASE_URL) {
  throw new Error("Missing SUPABASE_URL");
}

if (SUPABASE_URL.includes("localhost")) {
  exec("npm run db:types", (error, stdout, stderr) => {
    if (error) {
      console.error(`error: ${error.message}`);
      return;
    }

    if (stderr) {
      console.error(`stderr:\n${stderr}`);
    }

    copyFileSync(source, destination);
    console.log(`stdout:\n${stdout}`);
  });
}
