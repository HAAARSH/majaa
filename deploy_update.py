import os

from supabase import create_client, Client

# ─── 1. YOUR SUPABASE CREDENTIALS ───

SUPABASE_URL = "https://ctrmpwmnnvvsciqouqyo.supabase.co"

SUPABASE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImN0cm1wd21ubnZ2c2NpcW91cXlvIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3NDI0ODMyNywiZXhwIjoyMDg5ODI0MzI3fQ.GyYfpB9I5-dJNP-oNjqmssGQNCNJqNluabIKZUNwBM8" 

# ─── 2. UPDATE THESE FOR EACH NEW RELEASE ───

VERSION_CODE = 2           # This must exactly match the number after the '+' in your pubspec.yaml

VERSION_NAME = "1.0.1"     # This is just for you to read

APK_PATH = "build/app/outputs/flutter-apk/app-release.apk" # Standard Flutter APK location

def deploy():

    print(f"🚀 Preparing to deploy Version {VERSION_NAME} (Code: {VERSION_CODE})...")

    # Make sure you actually built the APK first

    if not os.path.exists(APK_PATH):

        print("❌ Error: Could not find the APK.")

        print("Please run 'flutter build apk --release' in your terminal first.")

        return

    # Start the engine

    supabase: Client = create_client(SUPABASE_URL, SUPABASE_KEY)

    file_name = f"app-v{VERSION_CODE}.apk"

    

    # ACTION A: Upload the APK to the "apks" warehouse

    print("📦 Uploading APK to Supabase Storage...")

    with open(APK_PATH, 'rb') as f:

        supabase.storage.from_("apks").upload(

            path=file_name,

            file=f,

            file_options={"upsert": "true"} # Upsert means it will overwrite if a file with this name already exists

        )

    

    # ACTION B: Ask Supabase for the direct download link

    public_url = supabase.storage.from_("apks").get_public_url(file_name)

    print(f"🔗 Download link generated: {public_url}")

    # ACTION C: Write the new update into your "app_versions" logbook

    print("📝 Updating the database so devices know an update is ready...")

    supabase.table("app_versions").insert({

        "version_code": VERSION_CODE,

        "version_name": VERSION_NAME,

        "download_url": public_url,

        "is_mandatory": False, # Change to True if this update fixes a critical bug

        "release_notes": "Improved offline order syncing and beat tracking."

    }).execute()

    print("✅ Success! The update is live.")

if __name__ == "__main__":

    deploy()
